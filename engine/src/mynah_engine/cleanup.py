"""LLM cleanup (dictation polish) and command mode (voice-driven edits)."""

import copy
import time

from .models import LLM_MODELS, LlmModel, offline_if_cached
from .prompts import general_messages, s1_messages, sanitize, spokenly_prompt

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

    def _generate(self, prompt: str, max_tokens: int, kind: str) -> str:
        import mlx.core as mx
        from mlx_lm import stream_generate

        tokens, cache = self._encode(prompt), None
        prefix = self._prefixes.get(kind)
        if prefix and len(tokens) > len(prefix[0]) and tokens[:len(prefix[0])] == prefix[0]:
            cache = copy.deepcopy(prefix[1])
            tokens = tokens[len(prefix[0]):]

        text = ""
        for resp in stream_generate(self.model, self.tokenizer, mx.array(tokens), max_tokens=max_tokens,
                                    prompt_cache=cache):
            text += resp.text
            # spokenly/cleanup-1 is a completion model: stop if it starts a new record
            if self.spec.style == "spokenly" and "\ntext:" in text:
                text = text.split("\ntext:")[0]
                break
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
        out = self._generate(self._clean_prompt(raw, app, tuple(vocab)),
                             max_tokens=int(len(raw.split()) * 2.5) + 64, kind="clean")
        return sanitize(out, raw)

    def command(self, instruction: str, selection: str, app: str) -> str:
        budget = max(256, int(len(selection.split()) * 2.5) + 128)
        out = self._generate(self._command_prompt(instruction, selection, app), max_tokens=budget, kind="command")
        return sanitize(out, "").strip()
