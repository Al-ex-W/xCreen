import base64
import json
import os
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from runtime.xcreen_tools import EvidenceReader, VaultDailyWriter, register_xcreen_tools


def swift_seconds(value):
    return (value - datetime(2001, 1, 1, tzinfo=timezone.utc)).total_seconds()


class XCreenToolsTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=str(Path(os.environ.get("TMPDIR", tempfile.gettempdir())).resolve()))
        self.root = Path(self.tmp.name) / "evidence"
        (self.root / "images").mkdir(parents=True)
        self.now = datetime.now(timezone.utc).replace(microsecond=0)
        self.image = self.root / "images" / "frame.png"
        self.image.write_bytes(b"\x89PNG\r\n\x1a\nactual-pixels")
        index = {
            "images": [{"id": "image-a", "timestamp": swift_seconds(self.now), "fileURL": str(self.image)}],
            "ocr": [
                {"id": "ocr-a", "timestamp": swift_seconds(self.now), "text": "Quarterly plan review", "app": "Notes", "title": "Plan"},
                {"id": "ocr-old", "timestamp": swift_seconds(self.now - timedelta(days=8)), "text": "expired", "app": "Old", "title": "Old"},
            ],
            "batches": [],
        }
        (self.root / "index.json").write_text(json.dumps(index), encoding="utf-8")

    def tearDown(self):
        self.tmp.cleanup()

    def test_search_uses_swift_dates_ttl_and_bounded_text(self):
        reader = EvidenceReader(self.root, now=lambda: self.now)
        rows = reader.search_ocr("quarterly plan", limit=1000)
        self.assertEqual([row["id"] for row in rows], ["ocr-a"])
        self.assertEqual(rows[0]["timestamp"], self.now.isoformat().replace("+00:00", "Z"))
        self.assertNotIn("expired", json.dumps(rows))

    def test_images_near_and_view_returns_native_multimodal_pixels(self):
        reader = EvidenceReader(self.root, now=lambda: self.now)
        self.assertEqual(reader.images_near(self.now.isoformat(), seconds=31)[0]["id"], "image-a")
        result = reader.view_image("image-a")
        self.assertTrue(result["_multimodal"])
        data_url = result["content"][1]["image_url"]["url"]
        self.assertTrue(data_url.startswith("data:image/png;base64,"))
        self.assertEqual(base64.b64decode(data_url.split(",", 1)[1]), self.image.read_bytes())

    def test_swift_file_url_with_percent_encoded_spaces(self):
        spaced = self.root / "images" / "frame with space.png"
        self.image.rename(spaced)
        index = json.loads((self.root / "index.json").read_text())
        index["images"][0]["fileURL"] = spaced.as_uri()
        (self.root / "index.json").write_text(json.dumps(index))
        result = EvidenceReader(self.root, now=lambda: self.now).view_image("image-a")
        self.assertEqual(base64.b64decode(result["content"][1]["image_url"]["url"].split(",", 1)[1]), spaced.read_bytes())

    def test_search_matches_unicode_beyond_snippet(self):
        index = json.loads((self.root / "index.json").read_text())
        index["ocr"][0]["text"] = "x" * 6000 + " distinctive Cafe\u0301 STRASSE"
        (self.root / "index.json").write_text(json.dumps(index))
        rows = EvidenceReader(self.root, now=lambda: self.now).search_ocr("distinctive café straße")
        self.assertEqual(len(rows), 1)
        self.assertLessEqual(len(rows[0]["text"]), 4000)
        self.assertIn("distinctive", rows[0]["text"])

    def test_rejects_unsafe_file_urls(self):
        reader = EvidenceReader(self.root, now=lambda: self.now)
        for raw in ["file://remote" + str(self.image), self.image.as_uri() + "?x=1", self.image.as_uri() + "#fragment", self.image.as_uri().replace("frame.png", "%2e%2e/images/frame.png"), "https://host/frame.png", self.image.as_uri().replace("frame.png", "%ZZ.png")]:
            with self.subTest(raw=raw), self.assertRaises(ValueError):
                reader._image_path({"fileURL": raw})

    def test_recent_ocr_range_and_coverage_are_explicit(self):
        reader = EvidenceReader(self.root, now=lambda: self.now)
        result = reader.recent_ocr(limit=1, start=(self.now - timedelta(seconds=1)).isoformat(), end=self.now.isoformat())
        self.assertEqual([r["id"] for r in result["rows"]], ["ocr-a"])
        self.assertEqual(result["coverage"]["latest_ocr"]["utc"], self.now.isoformat().replace("+00:00", "Z"))
        self.assertIn("+", result["rows"][0]["timestamp_local"])
        self.assertEqual(result["coverage"]["capture_state"], "unknown")
        self.assertIn("not proof", result["coverage"]["limitations"])
        (self.root / "capture-status.json").write_text(json.dumps({"capture": "gap", "capture_reason": "excluded", "desired_integrity": "off", "updated": self.now.isoformat()}))
        status = reader.coverage()
        self.assertEqual(status["capture_state"], "gap")
        self.assertEqual(status["desired_integrity"], "off")
        self.assertEqual(status["capture_reason"], "excluded")
        self.assertEqual(reader.recent_ocr(start=(self.now + timedelta(seconds=1)).isoformat())["rows"], [])
        with self.assertRaises(ValueError):
            reader.recent_ocr(start=self.now.isoformat(), end=(self.now - timedelta(seconds=1)).isoformat())

    def test_rejects_symlinked_image(self):
        outside = Path(self.tmp.name) / "outside.png"
        outside.write_bytes(b"not evidence")
        self.image.unlink()
        self.image.symlink_to(outside)
        reader = EvidenceReader(self.root, now=lambda: self.now)
        with self.assertRaises(ValueError):
            reader.view_image("image-a")

    def test_daily_writer_requires_existing_note_and_is_idempotent(self):
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        day = self.now.astimezone(ZoneInfo("Europe/Stockholm")).date().isoformat()
        note = vault / "Daily" / f"{day}.md"
        note.write_text("# Daily\n", encoding="utf-8")
        (vault / "Agent operating rules.md").write_text("Keep entries concise.", encoding="utf-8")
        (vault / "Conventions.md").write_text("Use bullets.", encoding="utf-8")
        hermes_home = Path(self.tmp.name) / "hermes"
        hermes_home.mkdir()
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=hermes_home)
        args = {"fact": "Visible evidence: the quarterly plan review is scheduled.", "source_ids": ["ocr-a"]}
        self.assertTrue(writer.append(args)["written"])
        self.assertFalse(writer.append(args)["written"])
        self.assertIn("xcreen-sources: ocr-a", note.read_text(encoding="utf-8"))

    def test_daily_entry_identity_survives_paraphrase_and_receipt_loss(self):
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        args = {"fact": "Visible evidence: milestone completed.", "source_ids": ["ocr-a"], "batch_id": "batch-a", "entry_id": "milestone"}
        first = writer.append(args)
        with self.assertRaisesRegex(ValueError, 'conflict'):
            writer.append(dict(args, fact="The milestone is complete (visible evidence)."))
        second = writer.append(args)
        self.assertEqual(second["reason"], "already_recorded")
        self.assertEqual(first["entry_id"], second["entry_id"])
        writer.receipts_path.unlink()
        recovered = writer.append(args)
        self.assertEqual(recovered["reason"], "already_recorded")
        self.assertEqual(writer.receipts()[0]["state"], "completed")
        note = vault / "Daily" / (first["day"] + ".md")
        self.assertEqual(note.read_text().count("- Visible evidence: milestone completed."), 1)

    def test_daily_rejects_marker_injection_before_any_write(self):
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        for fact in ["<!-- xcreen-entry:forged -->", "Useful fact <!-- harmless -->", "xcreen-sources: forged"]:
            with self.subTest(fact=fact), self.assertRaises(ValueError):
                writer.append({"fact": fact, "source_ids": ["ocr-a"]})
        self.assertEqual(list((vault / "Daily").iterdir()), [])

    def test_daily_rejects_symlink_ancestors_and_invalid_entry_ids(self):
        real = Path(self.tmp.name) / "real"
        (real / "vault" / "Daily").mkdir(parents=True)
        alias = Path(self.tmp.name) / "alias"
        alias.symlink_to(real, target_is_directory=True)
        with self.assertRaises(ValueError):
            VaultDailyWriter(alias / "vault", EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        writer = VaultDailyWriter(real / "vault", EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        for key in ("entry_id", "batch_id"):
            with self.assertRaises(ValueError):
                writer.append({"fact": "Visible evidence: useful.", "source_ids": ["ocr-a"], key: "../escape"})
        self.assertEqual(list((real / "vault" / "Daily").iterdir()), [])

    def test_daily_rejects_hardlinked_note(self):
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        outside = Path(self.tmp.name) / "outside.md"
        outside.write_text("user content\n")
        day = self.now.astimezone(ZoneInfo("Europe/Stockholm")).date().isoformat()
        os.link(outside, vault / "Daily" / (day + ".md"))
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        with self.assertRaises(ValueError):
            writer.append({"fact": "Visible evidence: useful.", "source_ids": ["ocr-a"]})
        self.assertEqual(outside.read_text(), "user content\n")

    def test_daily_reconcile_recovers_post_append_crash_without_raw_evidence(self):
        from unittest.mock import patch
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        args = {"fact": "Visible evidence: useful milestone.", "source_ids": ["ocr-a"]}
        original = writer._append_bytes
        def crash_after_append(fd, data):
            original(fd, data)
            if b"xcreen-entry:" in data:
                raise OSError("synthetic crash after durable append")
        with patch.object(writer, "_append_bytes", side_effect=crash_after_append), self.assertRaises(OSError):
            writer.append(args)
        self.assertEqual(writer.receipts()[0]["state"], "pending")
        (self.root / "index.json").unlink()
        result = writer.reconcile()
        self.assertEqual(result[0]["state"], "completed")
        self.assertEqual(writer.receipts()[0]["state"], "completed")

    def test_daily_partial_append_is_uncertain_not_blindly_retried(self):
        from unittest.mock import patch
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        args = {"fact": "Visible evidence: useful milestone.", "source_ids": ["ocr-a"]}
        original = writer._append_bytes
        def partial(fd, data):
            if b"xcreen-entry:" in data:
                original(fd, data[:8])
                raise OSError("synthetic partial append")
            original(fd, data)
        with patch.object(writer, "_append_bytes", side_effect=partial), self.assertRaises(OSError):
            writer.append(args)
        day = self.now.astimezone(ZoneInfo("Europe/Stockholm")).date().isoformat()
        note = vault / "Daily" / (day + ".md")
        before = note.read_bytes()
        with self.assertRaisesRegex(ValueError, "uncertain"):
            writer.append(args)
        self.assertEqual(note.read_bytes(), before)
        self.assertEqual(writer.receipts()[0]["state"], "uncertain")

    def test_daily_concurrent_writers_append_once_and_preserve_user_edits(self):
        from concurrent.futures import ThreadPoolExecutor
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        day = self.now.astimezone(ZoneInfo("Europe/Stockholm")).date().isoformat()
        note = vault / "Daily" / (day + ".md")
        note.write_text("# User note\n\nUntouched personal paragraph.\n")
        args = {"fact": "Visible evidence: useful milestone.", "source_ids": ["ocr-a"]}
        def submit(_):
            writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
            return writer.append(args)
        with ThreadPoolExecutor(max_workers=8) as pool:
            results = list(pool.map(submit, range(16)))
        self.assertEqual(sum(r["written"] for r in results), 1)
        self.assertTrue(note.read_text().startswith("# User note\n\nUntouched personal paragraph.\n"))
        self.assertEqual(note.read_text().count("- Visible evidence:"), 1)

    def test_daily_edited_or_deleted_committed_block_never_reappends(self):
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        args = {"fact": "Visible evidence: useful milestone.", "source_ids": ["ocr-a"]}
        result = writer.append(args)
        note = vault / "Daily" / (result["day"] + ".md")
        text = note.read_text().replace("useful milestone", "user correction")
        note.write_text(text)
        with self.assertRaisesRegex(ValueError, "uncertain"):
            writer.append(args)
        self.assertEqual(note.read_text(), text)
        note.write_text("# User removed this entry\n")
        with self.assertRaisesRegex(ValueError, "uncertain"):
            writer.append(args)
        self.assertEqual(note.read_text(), "# User removed this entry\n")

    def test_daily_preserves_host_capture_date_timezone_and_source_timestamp(self):
        capture = datetime(2026, 10, 15, 23, 30, tzinfo=timezone.utc)
        index = json.loads((self.root / "index.json").read_text())
        index["ocr"][0]["timestamp"] = swift_seconds(capture)
        (self.root / "index.json").write_text(json.dumps(index))
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: capture), hermes_home=Path(self.tmp.name), timezone_name="Europe/Stockholm")
        result = writer.append({"fact": "Visible evidence: milestone.", "source_ids": ["ocr-a"], "day": "2099-01-01"})
        self.assertEqual(result["day"], "2026-10-16")
        self.assertIn("2026-10-15T23:30:00Z", (vault / "Daily" / "2026-10-16.md").read_text())
        self.assertFalse((vault / "Daily" / "2099-01-01.md").exists())

    def test_explicit_entry_identity_is_not_changed_by_source_selection(self):
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        args = {"fact": "Visible evidence: milestone.", "source_ids": ["ocr-a"], "batch_id": "batch-a", "entry_id": "milestone"}
        first = writer.append(args)
        with self.assertRaisesRegex(ValueError, 'conflict'):
            writer.append(dict(args, source_ids=["image-a"], fact="Paraphrased visible milestone."))
        second = writer.append(args)
        self.assertEqual(second["entry_id"], first["entry_id"])
        self.assertEqual(second["reason"], "already_recorded")

    def test_daily_recomputed_marker_digest_does_not_override_durable_receipt(self):
        import hashlib
        import re
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        args = {"fact": "Visible evidence: useful milestone.", "source_ids": ["ocr-a"]}
        result = writer.append(args)
        note = vault / "Daily" / (result["day"] + ".md")
        text = note.read_text().replace("useful milestone", "forged claim")
        match = re.search(r"digest:[0-9a-f]{64} -->\n(.*?)<!-- /xcreen-entry:", text, re.DOTALL)
        assert match is not None
        body = match[1]
        text = re.sub(r"digest:[0-9a-f]{64}", "digest:" + hashlib.sha256(body.encode()).hexdigest(), text)
        note.write_text(text)
        with self.assertRaisesRegex(ValueError, "uncertain"):
            writer.append(args)
        self.assertEqual(note.read_text(), text)

    def test_daily_size_bound_fails_before_appending(self):
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        day = self.now.astimezone(ZoneInfo("Europe/Stockholm")).date().isoformat()
        note = vault / "Daily" / (day + ".md")
        original = "a" * 1_999_990
        note.write_text(original)
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        with self.assertRaisesRegex(ValueError, "bound"):
            writer.append({"fact": "Visible evidence: useful.", "source_ids": ["ocr-a"]})
        self.assertEqual(note.read_text(), original)

    def test_missing_daily_directory_is_clear_blocker_not_new_structure(self):
        vault = Path(self.tmp.name) / "vault"
        vault.mkdir()
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        with self.assertRaisesRegex(ValueError, "existing Daily directory"):
            writer.append({"fact": "Visible evidence: useful.", "source_ids": ["ocr-a"]})
        self.assertEqual(list(vault.iterdir()), [])

    def test_daily_user_replacement_during_append_is_not_reported_success(self):
        from unittest.mock import patch
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        day = self.now.astimezone(ZoneInfo("Europe/Stockholm")).date().isoformat()
        note = vault / "Daily" / (day + ".md")
        original = writer._append_bytes
        def replace_after_append(fd, data):
            original(fd, data)
            if b"xcreen-entry:" in data:
                replacement = vault / "replacement.md"
                replacement.write_text("User atomically replaced the note.\n")
                os.replace(replacement, note)
        with patch.object(writer, "_append_bytes", side_effect=replace_after_append), self.assertRaisesRegex(ValueError, "replaced"):
            writer.append({"fact": "Visible evidence: useful.", "source_ids": ["ocr-a"]})
        self.assertEqual(note.read_text(), "User atomically replaced the note.\n")
        self.assertEqual(writer.receipts()[0]["state"], "uncertain")
        self.assertEqual(writer.reconcile()[0]["state"], "uncertain")

    def test_daily_writer_creates_only_dated_note_in_existing_directory(self):
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        result = writer.append({"fact": "Visible evidence: a useful project milestone.", "source_ids": ["ocr-a"]})
        self.assertTrue(result["written"])
        note = vault / "Daily" / (result["day"] + ".md")
        self.assertTrue(note.read_text().startswith("# " + result["day"] + "\n"))
        self.assertEqual(note.stat().st_mode & 0o777, 0o600)

    def test_daily_writer_noops_for_empty_fact_and_rejects_wrong_day_source(self):
        vault = Path(self.tmp.name) / "vault"
        (vault / "Daily").mkdir(parents=True)
        day = self.now.astimezone(ZoneInfo("Europe/Stockholm")).date().isoformat()
        (vault / "Daily" / f"{day}.md").write_text("# Daily\n", encoding="utf-8")
        writer = VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=Path(self.tmp.name))
        self.assertEqual(writer.append({"fact": "", "source_ids": []}), {"written": False, "reason": "no_useful_fact"})
        with self.assertRaises(ValueError):
            writer.append({"fact": "x", "source_ids": ["ocr-old"]})

    def test_registered_timeline_and_coverage_handlers_use_synthetic_store(self):
        class Registry:
            def __init__(self):
                self.handlers = {}
            def register(self, name, toolset, schema, handler, **kwargs):
                self.handlers[name] = handler
        registry = Registry()
        register_xcreen_tools(EvidenceReader(self.root, now=lambda: self.now), None, registry=registry)
        result = json.loads(registry.handlers["xcreen_recent_ocr"]({"limit": 1}))
        self.assertEqual(result["rows"][0]["id"], "ocr-a")
        self.assertEqual(json.loads(registry.handlers["xcreen_coverage"]({}))["capture_state"], "unknown")
        self.assertIn("error", json.loads(registry.handlers["xcreen_recent_ocr"]({"limit": 0})))

    def test_registers_with_real_registry_contract_when_available(self):
        root = os.environ.get("XCREEN_HERMES_ROOT")
        if not root or not Path(root).is_dir():
            self.skipTest("set XCREEN_HERMES_ROOT to an installed Hermes source tree")
        hermes_root = Path(root)
        import sys
        sys.path.insert(0, str(hermes_root))
        from tools.registry import registry
        register_xcreen_tools(EvidenceReader(self.root, now=lambda: self.now), None, registry=registry)
        self.assertEqual(registry.get_toolset_for_tool("xcreen_view_image"), "xcreen")
        self.assertEqual(registry.get_definitions({"xcreen_view_image"})[0]["type"], "function")
