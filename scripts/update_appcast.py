#!/usr/bin/env python3
"""Add a release to the Sparkle appcast that Mynah checks for updates.

    scripts/update_appcast.py appcast.xml --version 0.2.0 --url https://…/Mynah-0.2.0.dmg \\
        --signature <sign_update -p output> --length <bytes> --notes .github/release-notes.md \\
        --release-url https://github.com/…/releases/tag/v0.2.0 [--beta]

The newest release goes first. Pre-releases get the "beta" channel, which the app
only follows with Settings › Updates › Beta versions on. Re-running for a version
already in the feed replaces its entry.
"""

import argparse
import re
from email.utils import formatdate
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

HEADER = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel>
<title>Mynah</title>
<link>https://github.com/lukekerwin/mynah</link>
<description>Mynah releases</description>
<language>en</language>
"""
FOOTER = "</channel>\n</rss>\n"


def item(args: argparse.Namespace) -> str:
    notes = Path(args.notes).read_text().replace("]]>", "]]]]><![CDATA[>")
    channel = "    <sparkle:channel>beta</sparkle:channel>\n" if args.beta else ""
    return (
        "<item>\n"
        f"    <title>Mynah {escape(args.version)}</title>\n"
        f"    <pubDate>{formatdate(usegmt=True)}</pubDate>\n"
        f"    <sparkle:version>{escape(args.version)}</sparkle:version>\n"
        f"    <sparkle:shortVersionString>{escape(args.version)}</sparkle:shortVersionString>\n"
        f"    <sparkle:minimumSystemVersion>{escape(args.min_system)}</sparkle:minimumSystemVersion>\n"
        f"{channel}"
        f"    <sparkle:fullReleaseNotesLink>{escape(args.release_url)}</sparkle:fullReleaseNotesLink>\n"
        f'    <description sparkle:format="markdown"><![CDATA[{notes}]]></description>\n'
        f"    <enclosure url={quoteattr(args.url)} length=\"{args.length}\" type=\"application/octet-stream\"\n"
        f"               sparkle:edSignature={quoteattr(args.signature)}/>\n"
        "</item>\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("appcast")
    parser.add_argument("--version", required=True)
    parser.add_argument("--url", required=True)
    parser.add_argument("--signature", required=True)
    parser.add_argument("--length", required=True, type=int)
    parser.add_argument("--notes", required=True)
    parser.add_argument("--release-url", required=True)
    parser.add_argument("--min-system", default="14.0")
    parser.add_argument("--beta", action="store_true")
    args = parser.parse_args()

    path = Path(args.appcast)
    existing = path.read_text() if path.exists() else HEADER + FOOTER
    items = re.findall(r"<item>.*?</item>\n", existing, flags=re.S)
    tag = f"<sparkle:version>{escape(args.version)}</sparkle:version>"
    items = [i for i in items if tag not in i]
    path.write_text(HEADER + item(args) + "".join(items) + FOOTER)


if __name__ == "__main__":
    main()
