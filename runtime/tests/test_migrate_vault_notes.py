"""Synthetic-fixture tests for scripts/migrate-vault-notes.py (never the real vault)."""
import importlib.util
import io
import os
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
_spec = importlib.util.spec_from_file_location("migrate_vault_notes", ROOT / "scripts" / "migrate-vault-notes.py")
migrate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(migrate)

A, B = "a" * 64, "b" * 64
BODY_A = "- Shipped the plan draft.\n  <!-- xcreen-sources: ocr-11111111-x; captured-utc: ocr-11111111-x@2026-10-15T18:27:40Z -->\n"
FIXTURE = (
    "# 2026-10-15\n\nUser paragraph with <!-- a user comment --> kept.\n\n"
    "- Old inline entry.\n  <!-- xcreen:3f8fcd085e9596679bae; xcreen-sources: ocr-22222222-y, ocr-33333333-z -->\n\n"
    f"<!-- xcreen-entry:{A} digest:{migrate._sha(BODY_A)} -->\n{BODY_A}<!-- /xcreen-entry:{A} -->\n\n"
    f"<!-- xcreen-entry:{B} digest:{'c'*64} -->\n- Second bullet.\n  <!-- xcreen-sources: image-44444444-w; captured-utc: image-44444444-w@2026-10-15T19:00:00Z -->\n<!-- /xcreen-entry:{B} -->\n"
    "\n## User section\n\nUntouched.\n"
)
EXPECTED = (
    "# 2026-10-15\n\nUser paragraph with <!-- a user comment --> kept.\n\n"
    "- Old inline entry.\n\n"
    "- Shipped the plan draft.\n- Second bullet.\n"
    "\n## User section\n\nUntouched.\n"
)


class MigrateVaultNotesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=str(Path(os.environ.get("TMPDIR", tempfile.gettempdir())).resolve()))
        base = Path(self.tmp.name)
        self.vault, self.home = base / "vault", base / "home"
        (self.vault / "Daily").mkdir(parents=True)
        self.home.mkdir()
        self.note = self.vault / "Daily" / "2026-10-15.md"
        self.note.write_text(FIXTURE)
        self.other = self.vault / "Daily" / "2026-10-14.md"
        self.other.write_text("# 2026-10-14\n\n- nothing from xcreen here <!-- keep -->\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_script(self, *extra):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            code = migrate.main(["--vault", str(self.vault), "--hermes-home", str(self.home), *extra])
        return code, out.getvalue()

    def test_dry_run_prints_diff_and_changes_nothing(self):
        code, diff = self.run_script("--dry-run")
        self.assertEqual(code, 0)
        self.assertIn("-<!-- xcreen-entry:" + A, diff)
        self.assertEqual(self.note.read_text(), FIXTURE)
        self.assertFalse((self.home / "xcreen-receipts").exists() and any((self.home / "xcreen-receipts").iterdir()))

    def test_apply_strips_only_xcreen_markup_and_journals_provenance(self):
        self.assertEqual(self.run_script()[0], 0)
        self.assertEqual(self.note.read_text(), EXPECTED)
        self.assertIn("<!-- keep -->", self.other.read_text())
        from runtime.xcreen_tools import VaultDailyWriter
        rows = {r["id"]: r for r in VaultDailyWriter(self.vault, None, hermes_home=self.home).receipts(limit=10)}
        self.assertEqual(rows[A]["text"], "- Shipped the plan draft.")
        self.assertEqual(rows[A]["sources"], '["ocr-11111111-x"]')
        self.assertEqual(rows[A]["path"], "Daily/2026-10-15.md")
        self.assertEqual(rows[B]["sources"], '["image-44444444-w"]')
        self.assertEqual(len(rows), 3)
        # Idempotent: a second run finds nothing to do.
        self.run_script()
        self.assertEqual(self.note.read_text(), EXPECTED)


if __name__ == "__main__":
    unittest.main()
