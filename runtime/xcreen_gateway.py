#!/usr/bin/env python3
"""Process-only Hermes TUI gateway launcher for xCreen evidence tools."""
from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from zoneinfo import ZoneInfo


def _directory(value: str) -> Path:
    path = Path(value)
    if not path.is_absolute() or path.is_symlink() or not path.is_dir():
        raise argparse.ArgumentTypeError("must be an existing, non-symlink absolute directory")
    return path.resolve(strict=True)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Start an xCreen-scoped Hermes TUI gateway")
    parser.add_argument("--hermes-root", required=True, type=_directory)
    parser.add_argument("--evidence-root", required=True, type=_directory)
    parser.add_argument("--vault", type=_directory)
    parser.add_argument("--timezone", default="Europe/Stockholm")
    args = parser.parse_args(argv)
    # The bundled layout is <Resources>/runtime/xcreen_gateway.py, so the package
    # parent must be importable regardless of the working directory.
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    sys.path.insert(0, str(args.hermes_root))
    # Same bootstrap the installed `hermes` launcher performs before any Hermes import.
    if not os.environ.get("HERMES_HOME"):
        from hermes_constants import get_default_hermes_root
        os.environ["HERMES_HOME"] = str(get_default_hermes_root())
    import hermes_bootstrap  # noqa: F401  (side-effect import, as in the official launcher)
    from runtime.xcreen_tools import EvidenceReader, VaultDailyWriter, register_xcreen_tools
    evidence = EvidenceReader(args.evidence_root)
    try:
        ZoneInfo(args.timezone)
    except Exception as exc:
        parser.error(f"invalid timezone: {exc}")
    writer = VaultDailyWriter(args.vault, evidence, timezone_name=args.timezone) if args.vault else None
    register_xcreen_tools(evidence, writer)
    # Hermes reads this documented process env while creating sessions. It affects this child only.
    os.environ["HERMES_TUI_TOOLSETS"] = "xcreen"
    from tui_gateway.entry import main as gateway_main
    gateway_main()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
