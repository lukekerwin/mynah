"""LLM cleanup (dictation polish) and command mode (voice-driven edits)."""

import copy
import logging
import subprocess
import time

from .models import LLM_MODELS, LlmModel, offline_if_cached
from .prompts import basic_cleanup, general_messages, s1_messages, sanitize, spokenly_prompt

log = logging.getLogger("mynah_engine")

# Cleanup normally takes 0.2-2 s. Around meetings it has stalled for 30-60 s, so past
# this the dictation gets the plain transcript instead of a spinner for a minute.
CLEAN_DEADLINE_S = 5.0
SLOW_GENERATE_S = 3.0  # log timings + memory when a generation takes longer


class TooSlow(Exception):
    pass

COMMAND_SYSTEM = """You are the editing assistant inside a dictation app. The user spoke an instruction.
- If <selection> is present, apply the instruction to that text and output the full rewritten text.
- If there is no selection, write the text the instruction asks for.
Output only the resulting text, ready to be inserted as-is: no preamble, quotes, or explanation. Preserve the language of the selection."""


class Llm:
    def __init__(self, key: str):
        from mlx_lm import load

        self.spec: LlmModel = LLM_MODELS[key]
        t0 = time.perf_counter()
        with offline_if_cached(self.spec.repo):
            self.model, self.tokenizer = load(self.spec.repo)
        # KV caches for the static start of each prompt (system prompt + examples),
        # keyed by prompt kind, so each request only prefills its own text.
        self._prefixes: dict[str, tuple[list[int], list]] = {}
        self._prime("clean", lambda raw, app: self._clean_prompt(raw, app, ()))
        if self.spec.can_command:
            self._prime("command", lambda raw, app: self._command_prompt(raw, "", app))
        self.load_s = time.perf_counter() - t0

    def _chat(self, messages: list[dict]) -> str:
        return self.tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True,
                                                  enable_thinking=False)

    def _encode(self, prompt: str) -> list[int]:
        # same rule mlx_lm uses: don't add BOS if the template already did
        bos = self.tokenizer.bos_token
        return self.tokenizer.encode(prompt, add_special_tokens=bos is None or not prompt.startswith(bos))

    def _prime(self, kind: str, build) -> None:
        """Find the static prefix by diffing two dummy prompts, then prefill it once."""
        import mlx.core as mx
        from mlx_lm.models.cache import make_prompt_cache

        a, b = self._encode(build("alpha", "Xylo")), self._encode(build("omega", "Quark"))
        n = next((i for i, (x, y) in enumerate(zip(a, b)) if x != y), min(len(a), len(b)))
        # Back off a few tokens: real values can tokenize together with what precedes them.
        n -= 8
        if n < 16:
            return
        cache = make_prompt_cache(self.model)
        self.model(mx.array(a[:n])[None], cache=cache)
        mx.eval([c.state for c in cache])
        self._prefixes[kind] = (a[:n], cache)

    def warm(self) -> None:
        """One forward pass over a couple of tokens. It reads every layer's weights, so
        weights paged out while the Mac slept or sat idle are back before a real request."""
        import mlx.core as mx
        from mlx_lm.models.cache import make_prompt_cache

        cache = make_prompt_cache(self.model)
        mx.eval(self.model(mx.array(self._encode("Hello"))[None], cache=cache))

    def _generate(self, prompt: str, max_tokens: int, kind: str, deadline_s: float | None = None) -> str:
        """Raises TooSlow once `deadline_s` has passed (checked between tokens)."""
        import mlx.core as mx
        from mlx_lm import stream_generate

        t0 = time.perf_counter()
        tokens, cache = self._encode(prompt), None
        prefix = self._prefixes.get(kind)
        if prefix and len(tokens) > len(prefix[0]) and tokens[:len(prefix[0])] == prefix[0]:
            cache = copy.deepcopy(prefix[1])
            tokens = tokens[len(prefix[0]):]

        text, steps, last = "", [], time.perf_counter()
        try:
            for resp in stream_generate(self.model, self.tokenizer, mx.array(tokens), max_tokens=max_tokens,
                                        prompt_cache=cache):
                now = time.perf_counter()
                steps.append(now - last)
                last = now
                text += resp.text
                # spokenly/cleanup-1 is a completion model: stop if it starts a new record
                if self.spec.style == "spokenly" and "\ntext:" in text:
                    text = text.split("\ntext:")[0]
                    break
                if deadline_s is not None and now - t0 > deadline_s:
                    raise TooSlow
        finally:
            if time.perf_counter() - t0 > SLOW_GENERATE_S:
                log_slow(kind, len(tokens), steps, time.perf_counter() - t0)
        return text

    def _clean_prompt(self, raw: str, app: str, vocab: tuple[str, ...]) -> str:
        if self.spec.style == "spokenly":
            return spokenly_prompt(raw, app, vocab)
        if self.spec.style == "s1":
            return self._chat(s1_messages(raw, app, vocab))
        return self._chat(general_messages(raw, app, vocab))

    def _command_prompt(self, instruction: str, selection: str, app: str) -> str:
        user = f"<app>{app}</app>\n<instruction>{instruction}</instruction>"
        if selection.strip():
            user += f"\n<selection>{selection}</selection>"
        return self._chat([{"role": "system", "content": COMMAND_SYSTEM}, {"role": "user", "content": user}])

    def clean(self, raw: str, app: str, vocab: list[str]) -> str:
        try:
            out = self._generate(self._clean_prompt(raw, app, tuple(vocab)),
                                 max_tokens=int(len(raw.split()) * 2.5) + 64, kind="clean",
                                 deadline_s=CLEAN_DEADLINE_S)
        except TooSlow:
            log.warning("cleanup passed %.0f s; using the plain transcript", CLEAN_DEADLINE_S)
            return basic_cleanup(raw)
        return sanitize(out, raw)

    def command(self, instruction: str, selection: str, app: str) -> str:
        budget = max(256, int(len(selection.split()) * 2.5) + 128)
        out = self._generate(self._command_prompt(instruction, selection, app), max_tokens=budget, kind="command")
        return sanitize(out, "").strip()


def log_slow(kind: str, prompt_tokens: int, steps: list[float], total_s: float) -> None:
    """Where a slow generation spent its time, and how short on memory the Mac was."""
    import mlx.core as mx

    try:
        swap = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True,
                              timeout=1).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        swap = "?"
    gb = lambda b: b / 2**30  # noqa: E731
    log.warning("slow %s: %.1fs total, %d prompt tokens, first token %.1fs, %d tokens after (max %.1fs); "
                "mlx active %.1f GB, cache %.1f GB, peak %.1f GB; swap %s",
                kind, total_s, prompt_tokens, steps[0] if steps else total_s, max(0, len(steps) - 1),
                max(steps[1:], default=0), gb(mx.get_active_memory()), gb(mx.get_cache_memory()),
                gb(mx.get_peak_memory()), swap)
