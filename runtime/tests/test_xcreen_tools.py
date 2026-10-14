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
