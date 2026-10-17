#!/usr/bin/env python3
"""One-off: strip old xCreen provenance markup from Daily notes into the private journal.

Older xCreen builds wrapped every Daily bullet in HTML comments:

    <!-- xcreen-entry:<id> digest:<sha256> -->
    - bullet text
      <!-- xcreen-sources: ...; captured-utc: ... -->
    <!-- /xcreen-entry:<id> -->

(and an even older inline form `  <!-- xcreen:<hash>; xcreen-sources: ... -->`).
This script keeps the bullet text exactly, removes only those comment lines, and records
each entry's provenance (sources, note path, exact text, hashes) in xCreen's private
receipt journal so retries/reconciliation keep working. Nothing else in a note changes.

    python3 scripts/migrate-vault-notes.py --vault /path/to/vault --dry-run   # show diff
    python3 scripts/migrate-vault-notes.py --vault /path/to/vault             # apply

Stop xCreen first. Run under the same HERMES_HOME xCreen uses (default ~/.hermes).
"""
from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from runtime.xcreen_tools import VaultDailyWriter  # noqa: E402

_BLOCK = re.compile(
    r"(?P<lead>\n?)<!-- xcreen-entry:(?P<id>[0-9a-f]{64}) digest:(?P<digest>[0-9a-f]{64}) -->\n"
    r"(?P<body>(?:(?!<!-- /xcreen-entry:).)*?)"
    r"<!-- /xcreen-entry:(?P=id) -->\n?",
    re.DOTALL,
)
_SOURCES = re.compile(r"^[ \t]*<!-- (?:xcreen:(?P<legacy>[0-9a-f]+); )?xcreen-sources: (?P<ids>[^;>]*?)(?:; captured-utc: [^>]*?)? -->[ \t]*\n?", re.MULTILINE)
_DAY = re.compile(r"^\d{4}-\d{2}-\d{2}\.md$")


def _sha(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def migrate_text(text: str) -> tuple[str, list[dict]]:
    """Return (cleaned text, provenance records). Only xCreen comment markup is removed."""
    records: list[dict] = []
    out: list[str] = []
    cursor = 0
    previous_was_entry = False
    for match in _BLOCK.finditer(text):
        between = text[cursor:match.start()]
        out.append(between)
        body = match["body"]
        sources = _SOURCES.search(body)
        bullet = _SOURCES.sub("", body).rstrip("\n")
        if not bullet.strip() or "<!--" in bullet:
            # Unexpected/edited shape: leave the whole block untouched for manual review.
            out.append(match.group(0))
            cursor = match.end()
            previous_was_entry = False
            continue
        ids = [s.strip() for s in sources["ids"].split(",")] if sources else []
        records.append({"id": match["id"], "digest": match["digest"], "text": bullet,
                        "sources": sorted(i for i in ids if i), "body_ok": _sha(body) == match["digest"]})
        # Consecutive migrated bullets join one list; the first keeps the paragraph gap.
        lead = "" if (previous_was_entry and not between) else match["lead"]
        out.append(lead + bullet + "\n")
        cursor = match.end()
        previous_was_entry = True
    out.append(text[cursor:])
    cleaned = "".join(out)

    def inline(match: re.Match) -> str:
        records.append({"id": _sha("legacy-inline:" + match["legacy"]) if match["legacy"] else None,
                        "digest": None, "text": None, "sources": sorted(s.strip() for s in match["ids"].split(",") if s.strip()),
                        "legacy": match["legacy"]})
        return ""
    cleaned = _SOURCES.sub(inline, cleaned)
    return cleaned, records


def _keeps_non_xcreen_lines(before: str, after: str) -> bool:
    kept = [l for l in before.split("\n") if l.strip() and "xcreen-entry:" not in l and "xcreen-sources:" not in l]
    return [l for l in after.split("\n") if l.strip()] == kept


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    parser.add_argument("--vault", required=True)
    parser.add_argument("--hermes-home", default=os.environ.get("HERMES_HOME") or str(Path.home() / ".hermes"))
    parser.add_argument("--dry-run", action="store_true", help="print a unified diff; change nothing")
    args = parser.parse_args(argv)
    writer = VaultDailyWriter(Path(args.vault), None, hermes_home=Path(args.hermes_home))  # type: ignore[arg-type]
    daily = writer.vault / "Daily"
    if not daily.is_dir() or daily.is_symlink():
        parser.error("vault has no Daily directory")
    summary = {"notes_changed": 0, "entries": 0, "journal_rows": 0, "skipped_blocks": 0}
    with writer._lock():
        db = None if args.dry_run else writer._receipts_db()
        try:
            for note in sorted(daily.iterdir()):
                if not _DAY.match(note.name) or note.is_symlink() or not note.is_file():
                    continue
                with writer._directory(daily) as directory:
                    original, info = writer._read_at(directory, note.name)
                    if original is None or "xcreen" not in original:
                        continue
                    cleaned, records = migrate_text(original)
                    if cleaned == original:
                        continue
                    if not _keeps_non_xcreen_lines(original, cleaned):
                        print(f"skip {note.name}: unexpected markup shape, left untouched", file=sys.stderr)
                        summary["skipped_blocks"] += 1
                        continue
                    summary["notes_changed"] += 1
                    summary["entries"] += len(records)
                    rel = f"Daily/{note.name}"
                    if args.dry_run:
                        sys.stdout.writelines(difflib.unified_diff(original.splitlines(True), cleaned.splitlines(True), rel, rel + " (migrated)"))
                        continue
                    assert db is not None
                    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
                    for record in records:
                        if record["id"] is None:
                            continue
                        prior = db.execute("SELECT id FROM entries WHERE id=?", (record["id"],)).fetchone()
                        text = record["text"]
                        if text is None:  # inline legacy form: bullet text is the line above; journal sources only
                            if not prior:
                                db.execute("INSERT INTO entries (id, day, digest, state, sources, batch, path, written_at) VALUES (?,?,?,?,?,?,?,?)",
                                           (record["id"], note.name[:-3], record["legacy"], "migrated", json.dumps(record["sources"], separators=(",", ":")), "legacy-migrated", rel, stamp))
                                summary["journal_rows"] += 1
                            continue
                        if prior:
                            db.execute("UPDATE entries SET path=?, text=?, text_digest=?, written_at=COALESCE(written_at, ?) WHERE id=?",
                                       (rel, text, _sha(text), stamp, record["id"]))
                        else:
                            db.execute("INSERT INTO entries (id, day, digest, state, sources, batch, path, text, text_digest, written_at) VALUES (?,?,?,?,?,?,?,?,?,?)",
                                       (record["id"], note.name[:-3], record["digest"], "completed", json.dumps(record["sources"], separators=(",", ":")), "migrated", rel, text, _sha(text), stamp))
                        summary["journal_rows"] += 1
                    db.commit()  # provenance first: a crash leaves markup + journal, never lost provenance
                    writer._atomic_write(directory, note.name, cleaned.encode(), info, _sha(rel))
        finally:
            if db is not None:
                db.close()
    print(json.dumps(dict(summary, dry_run=args.dry_run)), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
