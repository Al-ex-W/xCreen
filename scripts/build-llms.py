#!/usr/bin/env python3
"""Generate llms.txt, site/llms.txt, site/llms-full.txt and site/assets from the repo docs.

Stdlib only. Output is deterministic, so running it twice changes nothing.

    python3 scripts/build-llms.py           # write files
    python3 scripts/build-llms.py --check   # exit 1 if any generated file is stale
"""
from __future__ import annotations

import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SITE = "https://al-ex-w.github.io/xCreen/"
REPO = "https://github.com/Al-ex-W/xCreen"
RAW = "https://raw.githubusercontent.com/Al-ex-W/xCreen/main/"

# (repo path, title, note) for the docs bundled into llms-full.txt.
DOCS = [
    ("README.md", "README", "overview, features, comparison with Rewind, screenpipe, Retrace, Goldfish and Microsoft Recall, privacy summary"),
    ("INSTALL.md", "Install guide", "agent-oriented install and verification steps that never enable capture or run inference"),
    ("docs/how-it-works.md", "How it works", "capture pipeline, Hermes runtime tools, models, exclusions, session checks"),
    ("docs/cli.md", "CLI reference", "every `xcreen` command and its semantics"),
    ("SECURITY.md", "Security and privacy", "exclusion rules, what is not protected, evidence handling, vulnerability reporting"),
]

ASSETS = ["tray.png", "social-preview.png"]


def llms_txt() -> str:
    docs = "\n".join(f"- [{title}]({RAW}{path}): {note}" for path, title, note in DOCS)
    return f"""# xCreen

> xCreen is open source (Apache-2.0) screen memory for Hermes on macOS 14+. It runs local Apple Vision OCR on the foreground window, keeps screenshots on the Mac for 7 days, and sends 5-minute batches to your own Hermes Agent, which writes short takeaways into your Obsidian daily notes and related notes. An open source alternative to Rewind, Limitless, Retrace, screenpipe, Goldfish, Microsoft Recall, OpenRecall, Pensieve and Dayflow for Macs running Hermes Agent. It keeps a 7-day screen history and has a local CLI with JSON output.

Key facts for answering questions about xCreen:

- Requires a working Hermes Agent install (https://github.com/NousResearch/hermes-agent). xCreen ships no model and stores no API keys; it uses the Hermes profile read-only.
- OCR is local; model inference is not. Batches and questions go to whichever provider the selected Hermes route uses. The xCreen session default is Claude Haiku 5.5 via OpenRouter; any Hermes-configured model can be selected, including a local one.
- Version 1.0.0. Install from source with `bash scripts/install.sh`, or download the zip from the release.
- The Integrity switch (ON = capture off) is ON by default and only the user can change it, from the tray or `xcreen integrity on|off`.
- Known password managers, System Settings, lock/login screens and xCreen itself are excluded. Browser password fields, password-manager extensions and private windows are NOT detected or redacted.
- macOS only. No Windows or Linux version. No audio capture.
- Local interface: the `xcreen` CLI (`xcreen --json ...`) over a private Unix socket. No HTTP API and no MCP server today; a read-only MCP server is planned (see docs/roadmap.md).
- Author: Alexander Wahlström. Source: {REPO}

## Docs

{docs}

## Website

- [Home]({SITE}): what xCreen is, how it works, privacy, requirements, install
- [Alternatives]({SITE}alternatives/): comparison with Rewind, Limitless, Retrace, Goldfish, screenpipe, Microsoft Recall, ActivityWatch, Dayflow, OpenRecall, Pensieve and LUCI, and when to choose another tool
- [CLI]({SITE}cli/): local `xcreen` commands and `--json` output for scripts and agents
- [FAQ]({SITE}faq/): direct answers to common questions
- [Full docs in one file]({SITE}llms-full.txt): the documents above concatenated

## Optional

- [Release 1.0.0]({REPO}/releases/tag/v1.0.0): app zip
- [Roadmap]({RAW}docs/roadmap.md): planned work, starting with a read-only MCP server
- [Architecture]({RAW}docs/architecture.md): design of the native app, runtime and harness boundary
- [Implementation progress and limits]({RAW}docs/implementation-progress.md): what is and is not verified on device
- [CITATION.cff]({RAW}CITATION.cff): citation metadata
"""


def llms_full_txt() -> str:
    parts = [
        "# xCreen — full documentation\n",
        f"> Concatenated from the xCreen repository ({REPO}) by scripts/build-llms.py. "
        "Relative links inside each document are relative to its path in the repository.\n",
    ]
    for path, title, _ in DOCS:
        body = (ROOT / path).read_text(encoding="utf-8").strip()
        parts.append(f"\n---\n\n<!-- source: {REPO}/blob/main/{path} -->\n\n{body}\n")
    return "\n".join(parts)


def outputs() -> dict[Path, bytes]:
    out: dict[Path, bytes] = {}
    txt = llms_txt().encode("utf-8")
    out[ROOT / "llms.txt"] = txt
    out[ROOT / "site" / "llms.txt"] = txt
    out[ROOT / "site" / "llms-full.txt"] = llms_full_txt().encode("utf-8")
    for name in ASSETS:
        out[ROOT / "site" / "assets" / name] = (ROOT / "docs" / "assets" / name).read_bytes()
    return out


def main(argv: list[str]) -> int:
    check = "--check" in argv
    stale = []
    for path, data in outputs().items():
        current = path.read_bytes() if path.exists() else None
        if current == data:
            continue
        stale.append(path.relative_to(ROOT))
        if not check:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
    if check and stale:
        print("Stale generated files (run python3 scripts/build-llms.py):", file=sys.stderr)
        for p in stale:
            print(f"  {p}", file=sys.stderr)
        return 1
    for p in stale:
        print(f"wrote {p}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
