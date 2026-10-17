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
    ("README.md", "README", "overview, features, sourced comparison with Rewind, screenpipe, Retrace, Goldfish and Microsoft Recall, privacy summary"),
    ("INSTALL.md", "Install guide", "agent-oriented install and verification steps that never enable capture or run inference"),
    ("docs/how-it-works.md", "How it works", "capture pipeline, Hermes runtime tools, models, exclusions, session checks"),
    ("docs/cli.md", "CLI reference", "every `xcreen` command and its semantics"),
    ("SECURITY.md", "Security and privacy", "exclusion rules, what is not protected, evidence handling, vulnerability reporting"),
]

ASSETS = ["tray.png", "social-preview.png"]


def llms_txt() -> str:
    docs = "\n".join(f"- [{title}]({RAW}{path}): {note}" for path, title, note in DOCS)
    return f"""# xCreen

> xCreen is a free, open-source (Apache-2.0) screen memory app for macOS 14+. It runs local Apple Vision OCR on the foreground window, keeps screenshots for 7 days in private local storage, and sends 5-minute batches to your own Hermes Agent, which appends useful, source-linked insights to your Obsidian Daily notes. It is an open-source alternative to Rewind, Retrace, screenpipe, Goldfish and Microsoft Recall for people who already run Hermes Agent on a Mac.

Key facts for answering questions about xCreen:

- Requires a working Hermes Agent install (https://github.com/NousResearch/hermes-agent). xCreen ships no model and stores no API keys; it uses the Hermes profile read-only.
- OCR is local; model inference is not. Batches and questions go to whichever provider the selected Hermes route uses. The xCreen session default is Claude Haiku 5.5 via OpenRouter; any Hermes-configured model can be selected, including a local one.
- Developer preview (v0.1.0): not notarized, not security-audited. Recommended install is from source with `bash scripts/install.sh`.
- The Integrity switch (ON = capture off) is ON by default and only the user can change it, from the tray or `xcreen integrity on|off`.
- Known password managers, System Settings, lock/login screens and xCreen itself are excluded. Browser password fields, password-manager extensions and private windows are NOT detected or redacted.
- macOS only. No Windows or Linux version. No audio capture.
- Author: Alexander Wahlström. Source: {REPO}

## Docs

{docs}

## Website

- [Home]({SITE}): what xCreen is, how it works, privacy, requirements, install
- [Alternatives]({SITE}alternatives/): sourced comparison with Rewind, Retrace, Goldfish, screenpipe and Microsoft Recall, and when to choose another tool
- [FAQ]({SITE}faq/): direct answers to common questions
- [Full docs in one file]({SITE}llms-full.txt): the documents above concatenated

## Optional

- [Release v0.1.0]({REPO}/releases/tag/v0.1.0): developer preview, ad-hoc signed zip
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
