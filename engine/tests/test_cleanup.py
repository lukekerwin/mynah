from types import SimpleNamespace

import mlx_lm

from mynah_engine import cleanup
from mynah_engine.cleanup import Llm
from mynah_engine.models import LLM_MODELS
from mynah_engine.prompts import basic_cleanup


class FakeTokenizer:
    bos_token = None

    def apply_chat_template(self, messages, **_):
        return "\n".join(m["content"] for m in messages)

    def encode(self, text, **_):
        return list(range(len(text.split())))


def fake_llm(monkeypatch, pieces):
    llm = Llm.__new__(Llm)
    llm.spec, llm.tokenizer, llm.model, llm._prefixes = LLM_MODELS["gemma-4-e4b"], FakeTokenizer(), None, {}
    monkeypatch.setattr(mlx_lm, "stream_generate",
                        lambda *a, **k: (SimpleNamespace(text=p) for p in pieces))
    return llm


def test_clean_uses_model_output(monkeypatch):
    llm = fake_llm(monkeypatch, ["Sounds ", "good."])
    assert llm.clean("sounds good", "Slack", []) == "Sounds good."


def test_clean_falls_back_to_plain_transcript_when_too_slow(monkeypatch):
    llm = fake_llm(monkeypatch, ["Sounds ", "good", " indeed."])
    monkeypatch.setattr(cleanup, "CLEAN_DEADLINE_S", 0.0)
    assert llm.clean("sounds good", "Slack", []) == basic_cleanup("sounds good")
