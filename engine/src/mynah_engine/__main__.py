import argparse
import logging
import os

from .models import DEFAULT_ASR, DEFAULT_COMMAND_LLM, DEFAULT_LLM
from .server import serve


def main() -> None:
    ap = argparse.ArgumentParser(prog="mynah-engine")
    ap.add_argument("--port", type=int, default=int(os.environ.get("MYNAH_ENGINE_PORT", 47821)))
    ap.add_argument("--asr", default=DEFAULT_ASR)
    ap.add_argument("--llm", default=DEFAULT_LLM, help="cleanup model, or 'none'")
    ap.add_argument("--command-llm", default=DEFAULT_COMMAND_LLM, help="command-mode model, or 'none'")
    ap.add_argument("--parent-pid", type=int, help="exit when this process exits")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    none = lambda v: None if v in (None, "", "none") else v  # noqa: E731
    serve(args.port, args.asr, none(args.llm), none(args.command_llm), args.parent_pid)


if __name__ == "__main__":
    main()
