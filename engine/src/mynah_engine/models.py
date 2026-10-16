"""Registry of speech-to-text and cleanup models (shared with bench/)."""

from contextlib import contextmanager
from dataclasses import dataclass, field


@dataclass(frozen=True)
class AsrModel:
    key: str
    repo: str
    params: str
    notes: str
    generate_kwargs: dict = field(default_factory=dict)
    subfolder: str | None = None  # some repos keep the MLX weights in a subdirectory
    gated: bool = False  # needs `hf auth login` + accepting the license on huggingface.co
    hotwords: bool = False  # accepts a vocabulary list to bias recognition


ASR_MODELS: dict[str, AsrModel] = {
    m.key: m
    for m in [
        AsrModel("parakeet-v3", "mlx-community/parakeet-tdt-0.6b-v3", "0.6B",
                 "NVIDIA, fastest; 25 EU languages"),
        AsrModel("nemotron-3.5", "mlx-community/nemotron-3.5-asr-streaming-0.6b", "0.6B",
                 "NVIDIA streaming RNNT"),
        AsrModel("qwen3-asr-0.6b", "mlx-community/Qwen3-ASR-0.6B-8bit", "0.6B",
                 "Alibaba, 8-bit", {"language": "English"}, hotwords=True),
        AsrModel("qwen3-asr-1.7b", "mlx-community/Qwen3-ASR-1.7B-8bit", "1.7B",
                 "Alibaba, 8-bit", {"language": "English"}, hotwords=True),
        AsrModel("granite-4.0-1b", "mlx-community/granite-4.0-1b-speech-8bit", "1B",
                 "IBM, 8-bit"),
        AsrModel("granite-4.1-2b-nar", "mlx-community/granite-speech-4.1-2b-nar-mlx", "2B",
                 "IBM, non-autoregressive (fast) variant"),
        # Passing `language` to Granite AR switches it to translation, so don't.
        AsrModel("granite-4.1-2b", "divydeep/granite-speech-4.1-2b-mlx-6bit", "2B",
                 "IBM, #1 on Open ASR; community 6-bit MLX port"),
        # mlx-audio loads the original (gated) checkpoint; community MLX ports
        # use a different weight layout and produce garbage.
        AsrModel("cohere-transcribe", "CohereLabs/cohere-transcribe-03-2026", "2B",
                 "Cohere, Apache 2.0 but gated on HF", {"language": "en"}, gated=True),
        AsrModel("whisper-turbo", "mlx-community/whisper-large-v3-turbo-asr-fp16", "0.8B",
                 "OpenAI baseline", {"language": "en"}, hotwords=True),
    ]
}


@dataclass(frozen=True)
class LlmModel:
    key: str
    repo: str
    params: str
    style: str  # prompt format: "general" | "s1" | "spokenly"

    @property
    def can_command(self) -> bool:
        """Dedicated cleanup models can't follow free-form editing instructions."""
        return self.style == "general"


LLM_MODELS: dict[str, LlmModel] = {
    m.key: m
    for m in [
        LlmModel("s1-mini", "mlx-community/S1-mini-MLX-8bit", "0.6B", "s1"),
        LlmModel("spokenly-cleanup-1", "spokenly/cleanup-1", "0.6B", "spokenly"),
        LlmModel("qwen3.5-0.8b", "mlx-community/Qwen3.5-0.8B-8bit", "0.8B", "general"),
        LlmModel("qwen3.5-2b", "mlx-community/Qwen3.5-2B-6bit", "2B", "general"),
        LlmModel("qwen3-4b-2507", "mlx-community/Qwen3-4B-Instruct-2507-4bit", "4B", "general"),
        LlmModel("qwen3.5-4b", "mlx-community/Qwen3.5-4B-MLX-4bit", "4B", "general"),
        LlmModel("gemma-4-e4b", "mlx-community/gemma-4-e4b-it-4bit", "4B (8B total)", "general"),
        LlmModel("qwen3.5-9b", "mlx-community/Qwen3.5-9B-MLX-4bit", "9B", "general"),
        LlmModel("gemma-4-26b-a4b", "mlx-community/gemma-4-26b-a4b-it-4bit", "26B MoE (4B active)", "general"),
    ]
}

DEFAULT_ASR = "parakeet-v3"
DEFAULT_LLM = "gemma-4-e4b"
DEFAULT_COMMAND_LLM = "gemma-4-e4b"


@contextmanager
def offline_if_cached(repo: str):
    """Skip Hugging Face network calls when a model is already downloaded, so
    loading works offline and nothing leaves the machine. Uncached models still
    download normally."""
    import huggingface_hub.constants as hf_constants

    from .downloads import is_cached

    cached = is_cached(repo)
    previous = hf_constants.HF_HUB_OFFLINE
    hf_constants.HF_HUB_OFFLINE = previous or cached
    try:
        yield
    finally:
        hf_constants.HF_HUB_OFFLINE = previous
