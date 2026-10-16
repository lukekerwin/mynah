"""Model downloads with progress the app can show (first launch pulls several GB)."""

import logging
import threading
from dataclasses import dataclass

log = logging.getLogger("mynah_engine")


@dataclass
class Progress:
    repo: str
    label: str
    done: int = 0
    total: int = 0

    def as_dict(self) -> dict:
        return {"repo": self.repo, "label": self.label, "done": self.done, "total": self.total}


_lock = threading.Lock()
_current: Progress | None = None


def current() -> dict | None:
    with _lock:
        return _current.as_dict() if _current else None


def is_cached(repo: str) -> bool:
    from huggingface_hub import snapshot_download

    try:
        snapshot_download(repo, local_files_only=True)
        return True
    except Exception:
        return False


def ensure_downloaded(repo: str, label: str) -> None:
    """Download `repo` into the Hugging Face cache if needed, publishing progress."""
    global _current
    if is_cached(repo):
        return
    from huggingface_hub import HfApi, snapshot_download
    from huggingface_hub.utils import tqdm as hf_tqdm

    try:
        info = HfApi().model_info(repo, files_metadata=True)
        total = sum(s.size or 0 for s in info.siblings or [])
    except Exception:
        total = 0
    progress = Progress(repo, label, 0, total)
    with _lock:
        _current = progress

    class Tracker(hf_tqdm):
        """snapshot_download reports reconstructed bytes through this bar."""

        def __init__(self, *args, **kwargs):
            self._track = kwargs.get("unit") == "B" and kwargs.get("name") == "huggingface_hub.snapshot_download"
            super().__init__(*args, **kwargs)

        def update(self, n=1):
            if self._track and n:
                with _lock:
                    progress.done += int(n)
                    if not total and getattr(self, "total", None):
                        progress.total = int(self.total)
            return super().update(n)

    log.info("downloading %s (%.1f GB)", repo, total / 1e9)
    try:
        snapshot_download(repo, tqdm_class=Tracker)
    finally:
        with _lock:
            _current = None
