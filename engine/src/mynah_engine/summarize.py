"""Meeting summaries + action items from a timestamped transcript.

Runs as a BACKGROUND job on the MLX worker: the token loop calls the worker's
checkpoint() so dictation can run between tokens and cancellation is prompt.
Long transcripts are summarized per section (map) and then merged (reduce).
"""

import gc
import json
import logging
import re
import time

log = logging.getLogger("mynah_engine")

SECTION_TOKENS = 24_000  # single pass below this; map/reduce above
MAX_OUTPUT_TOKENS = 2_000
CHECKPOINT_EVERY = 8
PREFILL_STEP = 256  # tokens per prefill step; dictation can run between steps

SYSTEM = """You write notes for a recorded call. The transcript lines look like "[mm:ss] Speaker: text". "You" is the person these notes are for. Everyone else appears either by name, as "Speaker N" (a voice that hasn't been named yet), or as "Others" (everyone else together).

Return ONLY a JSON object with exactly these keys:
{
  "title": "short title naming what the call was about, 3-8 words, no date",
  "tldr": "2-3 sentence summary of the call",
  "key_points": ["main topics or facts discussed"],
  "decisions": ["things that were agreed or decided"],
  "open_questions": ["questions left unanswered or needing follow-up"],
  "action_items": [
    {"text": "what needs to be done, starting with a verb", "owner": "me" | "<person's name>" | "unassigned",
     "due": "YYYY-MM-DD or null", "time": "the [mm:ss] stamp of the line where it was said, copied exactly"}
  ]
}

Rules:
- Include every commitment or task, whoever owns it.
- owner is "me" when You commits to something, or when Others ask You to do something and You agree. Use a person's name only if it is a speaker's name or is said in the call; never use "Speaker N" or "Others" as an owner, use "unassigned" instead.
- Only give a due date if a specific date or day is stated; resolve relative days ("Friday") against the meeting date when it is given, else null.
- The title names the main topic (e.g. "Q3 budget review with finance"), not the app or the date.
- Use only what is in the transcript. Do not invent names, numbers or tasks. Empty lists are fine.
- Write in the language of the transcript. Output the JSON object only, with no code fences or commentary."""

MERGE_SYSTEM = """You merge partial notes for different sections of the same call into one set of notes. Each input is a JSON object with keys title, tldr, key_points, decisions, open_questions, action_items.

Return ONLY one JSON object with the same keys: a single title (3-8 words, the main topic of the whole call) and tldr (2-3 sentences) for the whole call, and the other lists combined with duplicates removed (keep the earliest time of duplicate action items). Do not invent anything. Output the JSON object only."""


# -- pure helpers ---------------------------------------------------------

def fmt_time(seconds: float) -> str:
    s = max(0, int(seconds))
    h, m, s = s // 3600, (s % 3600) // 60, s % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}"


def parse_time(stamp: str) -> float | None:
    parts = stamp.strip().split(":")
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        return None
    total = 0
    for n in nums:
        total = total * 60 + n
    return float(total)


def format_transcript(segments: list[dict], my_name: str | None = None) -> str:
    """'[mm:ss] You: …' / '[mm:ss] Bob: …' lines in time order; consecutive lines
    from the same speaker are merged under the first timestamp. Lines from the other
    side use their "speaker" name when the app sent one, else "Others"."""
    you = f"You ({my_name})" if my_name else "You"
    lines: list[list] = []  # [start, speaker, text]
    for seg in sorted(segments, key=lambda s: s["start"]):
        speaker = you if seg.get("track") == "you" else (seg.get("speaker") or "Others")
        text = seg.get("text", "").strip()
        if not text:
            continue
        if lines and lines[-1][1] == speaker:
            lines[-1][2] += " " + text
        else:
            lines.append([seg["start"], speaker, text])
    return "\n".join(f"[{fmt_time(start)}] {speaker}: {text}" for start, speaker, text in lines)


def split_sections(text: str, max_tokens: int, count_tokens) -> list[str]:
    """Split on line boundaries into chunks of at most max_tokens (a single
    over-long line becomes its own chunk)."""
    sections: list[str] = []
    current: list[str] = []
    size = 0
    for line in text.splitlines():
        n = count_tokens(line) + 1
        if current and size + n > max_tokens:
            sections.append("\n".join(current))
            current, size = [], 0
        current.append(line)
        size += n
    if current:
        sections.append("\n".join(current))
    return sections


def parse_json(raw: str) -> dict:
    """Extract the outermost JSON object from model output (tolerates code fences
    and stray text around it)."""
    text = re.sub(r"```(?:json)?", "", raw)
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("no JSON object in model output")
    value = json.loads(text[start:end + 1])
    if not isinstance(value, dict):
        raise ValueError("model output is not a JSON object")
    return value


def _strings(value) -> list[str]:
    if isinstance(value, str):
        value = [value]
    if not isinstance(value, list):
        return []
    return [str(v).strip() for v in value if str(v).strip()]


_DATE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def normalize(d: dict, duration_s: float) -> dict:
    """Coerce the model's JSON into the exact response shape."""
    items = []
    for raw in d.get("action_items") or []:
        if isinstance(raw, str):
            raw = {"text": raw}
        if not isinstance(raw, dict):
            continue
        text = str(raw.get("text", "")).strip()
        if not text:
            continue
        owner = str(raw.get("owner") or "unassigned").strip()
        if owner.lower() in ("me", "you", "i"):
            owner = "me"
        elif owner.lower() in ("", "unassigned", "unknown", "none", "null", "others", "someone"):
            owner = "unassigned"
        due = raw.get("due")
        due = due.strip() if isinstance(due, str) and _DATE.match(due.strip()) else None
        t = raw.get("time", raw.get("time_s"))
        if isinstance(t, str):
            t = t.strip().strip("[]")
            t = parse_time(t) if ":" in t else (float(t) if t.replace(".", "", 1).isdigit() else None)
        t = float(t) if isinstance(t, (int, float)) else None
        if t is not None:
            t = min(max(t, 0.0), max(duration_s, 0.0))
        items.append({"text": text, "owner": owner, "due": due, "time_s": t})
    tldr = d.get("tldr")
    return {
        "title": clean_title(d.get("title")),
        "tldr": tldr.strip() if isinstance(tldr, str) else " ".join(_strings(tldr)),
        "key_points": _strings(d.get("key_points")),
        "decisions": _strings(d.get("decisions")),
        "open_questions": _strings(d.get("open_questions")),
        "action_items": items,
    }


def clean_title(value) -> str | None:
    """A one-line title: no quotes, trailing period or label, at most 80 characters."""
    if not isinstance(value, str):
        return None
    t = " ".join(value.split()).strip().strip('"\'“”‘’').strip()
    t = re.sub(r"^(title|meeting title)\s*:\s*", "", t, flags=re.I).rstrip(".").strip()
    if len(t) > 80:
        t = t[:80].rsplit(" ", 1)[0].rstrip(",;:-–")
    return t or None


# -- model side -----------------------------------------------------------

class Summarizer:
    def __init__(self, engine):
        self.engine = engine

    def summarize(self, segments: list[dict], title: str, my_name: str | None, model_key: str | None,
                  duration_s: float, meeting_date: str | None = None) -> dict:
        from .cleanup import Llm
        from .downloads import ensure_downloaded
        from .models import LLM_MODELS

        t0 = time.perf_counter()
        temporary = None
        if model_key and (not self.engine.llm or self.engine.llm.spec.key != model_key):
            spec = LLM_MODELS.get(model_key)
            if spec is None:
                raise ValueError(f"unknown model: {model_key}")
            if spec.style != "general":
                raise ValueError(f"{model_key} can't write summaries; pick a general-purpose model")
            ensure_downloaded(spec.repo, "Summary model")
            log.info("loading summary model %s", model_key)
            llm = temporary = Llm(model_key)
        else:
            llm = self.engine.llm
            if llm is None or llm.spec.style != "general":
                raise RuntimeError("summaries need a general-purpose cleanup model; pick one in Settings")

        try:
            transcript = format_transcript(segments, my_name)
            header = f"Call title: {title}\n" + (f"Meeting date: {meeting_date}\n" if meeting_date else "")
            count = lambda s: len(llm.tokenizer.encode(s))  # noqa: E731
            sections = split_sections(transcript, SECTION_TOKENS, count)
            parts = [self._ask(llm, SYSTEM, f"{header}\n<transcript>\n{s}\n</transcript>") for s in sections]
            if len(parts) == 1:
                result = parts[0]
            else:
                body = "\n\n".join(f"<section {i + 1}>\n{json.dumps(p)}\n</section>" for i, p in enumerate(parts))
                result = self._ask(llm, MERGE_SYSTEM, f"{header}\n{body}")
            out = normalize(result, duration_s)
            out["model"] = llm.spec.key
            out["llm_ms"] = round((time.perf_counter() - t0) * 1000)
            log.info("summarized %r: %d sections, %d items, %.1fs", title, len(sections),
                     len(out["action_items"]), out["llm_ms"] / 1000)
            return out
        finally:
            if temporary is not None:
                del llm, temporary
                gc.collect()
                import mlx.core as mx
                mx.clear_cache()

    def _ask(self, llm, system: str, user: str) -> dict:
        messages = [{"role": "system", "content": system}, {"role": "user", "content": user}]
        raw = self._generate(llm, llm._chat(messages))
        try:
            return parse_json(raw)
        except (ValueError, json.JSONDecodeError):
            log.warning("summary output wasn't JSON, retrying: %r", raw[:200])
            messages += [{"role": "assistant", "content": raw},
                         {"role": "user", "content": "Your previous output was not valid JSON. Output only the JSON object."}]
            return parse_json(self._generate(llm, llm._chat(messages)))

    def _generate(self, llm, prompt: str) -> str:
        import mlx.core as mx
        from mlx_lm import stream_generate
        from mlx_lm.models.cache import make_prompt_cache

        # Prefill in small steps ourselves (mlx-lm would do the whole prompt in
        # one go, blocking dictation for seconds on a long transcript).
        tokens = llm._encode(prompt)
        cache = make_prompt_cache(llm.model)
        while len(tokens) > PREFILL_STEP:
            llm.model(mx.array(tokens[:PREFILL_STEP])[None], cache=cache)
            mx.eval([c.state for c in cache])
            tokens = tokens[PREFILL_STEP:]
            self.engine.worker.checkpoint()

        text = ""
        for i, resp in enumerate(stream_generate(llm.model, llm.tokenizer, mx.array(tokens),
                                                 max_tokens=MAX_OUTPUT_TOKENS, prompt_cache=cache)):
            text += resp.text
            if i % CHECKPOINT_EVERY == 0:
                self.engine.worker.checkpoint()
        return text
