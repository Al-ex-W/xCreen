import json
import os
import unittest
from datetime import timedelta
from pathlib import Path

from tests.helpers import TempDirTestCase, now, png, stamps
from xcreen_server.receipts import BatchReceipt
from xcreen_server.store import (BATCH_IMAGES, Conflict, Deferred, EvidenceStore, StoreError, provider_backoff,
                                 timestamp_name, to_apple)


def receipt(batch, session="runtime-1", **overrides):
    body = {"batch_id": batch.id, "source_ids": batch.source_ids, "session_id": session, "status": "skipped", "verified": True, "effects": []}
    body.update(overrides)
    return BatchReceipt.parse(body, batch_id=batch.id, source_ids=batch.source_ids, session_id=session)


class StoreTestCase(TempDirTestCase):
    def open(self) -> EvidenceStore:
        return EvidenceStore(self.tmp / "evidence root")

    def fill(self, store, images=BATCH_IMAGES, start=None):
        times = stamps(images, start)
        store.ingest_ocr([{"id": f"ocr-{n}-{int(t.timestamp() * 1000)}", "timestamp": t - timedelta(seconds=1), "text": f"text {n}", "app": "com.app", "title": "T"}
                          for n, t in enumerate(times)])
        for n, moment in enumerate(times):
            store.ingest_image(f"image-{n}-{int(moment.timestamp() * 1000)}", moment, png(seed=n))
        return times


class IngestTests(StoreTestCase):
    def test_ocr_ingest_is_idempotent_and_rejects_conflicts(self):
        store = self.open()
        item = {"id": "ocr-1", "timestamp": now(), "text": "hello", "app": "a", "title": "t"}
        self.assertEqual(store.ingest_ocr([item]), {"accepted": 1, "duplicates": 0})
        self.assertEqual(store.ingest_ocr([item]), {"accepted": 0, "duplicates": 1})
        with self.assertRaises(Conflict):
            store.ingest_ocr([dict(item, text="changed")])
        self.assertEqual(len(EvidenceStore(store.root).ocr), 1)

    def test_rejects_invalid_ids_text_formats_and_timestamps(self):
        store = self.open()
        for bad in ({"id": "../x"}, {"text": ""}, {"text": "x" * 12_001}, {"timestamp": now() - timedelta(days=8)},
                    {"timestamp": now() + timedelta(hours=1)}):
            with self.assertRaises(StoreError):
                store.ingest_ocr([{"id": "ocr-1", "timestamp": now(), "text": "t", "app": "", "title": "", **bad}])
        with self.assertRaises(StoreError):
            store.ingest_image("image-1", now(), b"GIF89a....")
        with self.assertRaises(StoreError):
            store.ingest_image("image/1", now(), png())

    def test_image_ingest_writes_private_file_and_is_idempotent(self):
        store = self.open()
        moment = now()
        store.ingest_image("image-1", moment, png())
        image = store.image("image-1")
        self.assertEqual(image.path.suffix, ".png")
        self.assertEqual(os.stat(image.path).st_mode & 0o777, 0o600)
        self.assertEqual(store.ingest_image("image-1", moment, png()), {"accepted": 0, "duplicates": 1})
        with self.assertRaises(Conflict):
            store.ingest_image("image-1", moment + timedelta(seconds=1), png())


class BatchingTests(StoreTestCase):
    def test_thirty_images_form_one_batch_with_preceding_ocr(self):
        store = self.open()
        times = self.fill(store, BATCH_IMAGES + 5)
        late = {"id": "ocr-late", "timestamp": times[-1] + timedelta(seconds=1), "text": "later", "app": "", "title": ""}
        store.ingest_ocr([late])
        formed = store.form_batches()
        self.assertEqual(len(formed), 1)
        batch = formed[0]
        self.assertEqual(len(batch.images), BATCH_IMAGES)
        self.assertEqual(batch.completed_at, times[BATCH_IMAGES - 1])
        self.assertTrue(all(o.timestamp <= batch.completed_at for o in batch.ocr))
        self.assertEqual(len(batch.ocr), BATCH_IMAGES)
        self.assertEqual(store.unbatched_counts(), {"images": 5, "ocr": 6})
        self.assertEqual(store.form_batches(), [])
        self.assertEqual(store.batch_state(batch.id), "pending")

    def test_batches_survive_reopen(self):
        store = self.open()
        self.fill(store)
        batch = store.form_batches()[0]
        reopened = self.open()
        self.assertEqual([b.id for b in reopened.pending_batches()], [batch.id])
        self.assertEqual(reopened.pending_batches()[0].source_ids, batch.source_ids)


class StateMachineTests(StoreTestCase):
    def setUp(self):
        super().setUp()
        self.store = self.open()
        self.fill(self.store)
        self.batch = self.store.form_batches()[0]

    def test_happy_path_completes_only_with_verified_receipt(self):
        s, b = self.store, self.batch
        s.transition(b.id, "submitting")
        s.bind(b.id, "runtime-1")
        s.transition(b.id, "admitted")
        s.reconcile(receipt(b))
        self.assertEqual(s.batch_state(b.id), "completed")
        self.assertEqual(self.open().batch_state(b.id), "completed")

    def test_invalid_transitions_and_rebinding_are_rejected(self):
        with self.assertRaises(StoreError):
            self.store.transition(self.batch.id, "admitted")
        self.store.transition(self.batch.id, "submitting")
        self.store.bind(self.batch.id, "runtime-1")
        with self.assertRaises(StoreError):
            self.store.bind(self.batch.id, "runtime-2")
        with self.assertRaises(StoreError):
            self.store.reconcile(receipt(self.batch, session="runtime-2"))

    def test_interrupted_submission_reopens_uncertain_without_blind_retry(self):
        self.store.transition(self.batch.id, "submitting")
        reopened = self.open()
        self.assertEqual(reopened.batch_state(self.batch.id), "uncertain")
        self.assertEqual(reopened.pending_batches(), [])

    def test_pre_admission_failures_are_bounded_and_unsent_work_costs_nothing(self):
        s, b = self.store, self.batch
        s.record_failure(b.id, not_sent=True)
        self.assertEqual(s.batch_state(b.id), "pending")
        for _ in range(3):
            s.record_failure(b.id)
        self.assertEqual(s.batch_state(b.id), "deadletter")

    def test_provider_429_with_zero_effect_proof_requeues_with_global_throttle(self):
        s, b = self.store, self.batch
        s.transition(b.id, "submitting")
        s.bind(b.id, "runtime-1")
        s.transition(b.id, "admitted")
        s.reconcile(receipt(b, status="uncertain", verified=False, retry_safe=True))
        s.record_failure(b.id, provider_failure=True, rate_limited=True)
        self.assertEqual(s.batch_state(b.id), "pending")
        self.assertEqual(s.pending_batches(), [])
        self.assertIsNotNone(s.next_retry_date())
        self.assertGreaterEqual(s.throttle_until - now(), provider_backoff(1, True) - timedelta(seconds=5))
        with self.assertRaises(Deferred):
            s.transition(b.id, "submitting")
        later = now() + timedelta(hours=5)
        self.assertEqual([x.id for x in s.pending_batches(later)], [b.id])

    def test_failure_with_effects_or_without_proof_stays_uncertain(self):
        s, b = self.store, self.batch
        s.transition(b.id, "submitting")
        s.bind(b.id, "runtime-1")
        s.transition(b.id, "admitted")
        s.record_failure(b.id, provider_failure=True)
        self.assertEqual(s.batch_state(b.id), "uncertain")
        self.assertFalse(s.requeue_retry_safe(b.id))

    def test_explicit_recovery_requires_zero_effect_receipt(self):
        s, b = self.store, self.batch
        s.transition(b.id, "submitting")
        s.bind(b.id, "runtime-1")
        s.transition(b.id, "uncertain")
        s.reconcile(receipt(b, status="uncertain", verified=False, retry_safe=True))
        self.assertTrue(s.requeue_retry_safe(b.id))
        self.assertEqual([x.id for x in s.pending_batches()], [b.id])

    def test_batch_page_is_bounded(self):
        rows = self.store.batch_page()
        self.assertEqual(rows[0]["id"], self.batch.id)
        self.assertEqual(rows[0]["images"], BATCH_IMAGES)
        self.assertEqual(self.store.batch_page(after=self.batch.id), [])


class RetentionAndCompactionTests(StoreTestCase):
    def test_cleanup_expires_raw_evidence_but_keeps_receipt_metadata(self):
        store = self.open()
        self.fill(store, start=now() - timedelta(days=6, hours=23))
        batch = store.form_batches()[0]
        store.transition(batch.id, "submitting")
        store.bind(batch.id, "runtime-1")
        store.transition(batch.id, "admitted")
        store.reconcile(receipt(batch))
        store.cleanup(now() + timedelta(days=1))
        self.assertEqual(store.images, [])
        self.assertEqual(store.ocr, [])
        record = store.batches[0]
        self.assertEqual(record.batch.images, ())
        self.assertEqual(record.source_ids, batch.source_ids)
        self.assertEqual(list(store.images_dir.iterdir()), [])

    def test_only_digested_images_are_replaced_and_crash_leftovers_removed(self):
        store = self.open()
        self.fill(store)
        batch = store.form_batches()[0]
        self.assertEqual(store.compressible_images(100), [])
        store.transition(batch.id, "submitting")
        store.bind(batch.id, "runtime-1")
        store.transition(batch.id, "admitted")
        store.reconcile(receipt(batch))
        candidates = store.compressible_images(100)
        self.assertEqual(len(candidates), BATCH_IMAGES)
        first = candidates[0]
        jpeg = b"\xff\xd8\xff\xe0" + b"\x00" * 10
        with self.assertRaises(StoreError):
            store.replace_image(first.id, first.path, png())
        self.assertIsNone(store.replace_image(first.id, first.path.with_name("other.png"), jpeg))
        replaced = store.replace_image(first.id, first.path, jpeg)
        self.assertEqual(replaced.path.suffix, ".jpg")
        self.assertFalse(first.path.exists())
        self.assertEqual(self.open().image(first.id).path, replaced.path)
        self.assertTrue(all(i.path.suffix == ".jpg" for i in store.batches[0].batch.images if i.id == first.id))
        first.path.write_bytes(png())  # crash between index write and unlink
        store.remove_superseded_originals()
        self.assertFalse(first.path.exists())


class SwiftCompatibilityTests(StoreTestCase):
    """A store written by the 1.x Swift app opens unchanged (complete-install upgrade)."""

    def test_opens_swift_index_and_batches_its_checkpoint_images(self):
        root = self.tmp / "Application Support" / "xCreen" / "Evidence"
        (root / "images").mkdir(parents=True)
        moment = now() - timedelta(hours=1)
        images, digested = [], []
        for n in range(BATCH_IMAGES * 2):
            stamp = moment + timedelta(seconds=10 * n)
            path = root / "images" / timestamp_name(stamp, f"image-{n:04d}", "png")
            path.write_bytes(png(seed=n))
            entry = {"id": f"image-{n:04d}", "timestamp": to_apple(stamp), "fileURL": path.as_uri()}
            (digested if n < BATCH_IMAGES else images).append(entry)
        receipt_obj = {"batchID": "batch-old", "sourceIDs": sorted(i["id"] for i in digested), "sessionID": "rt",
                       "status": "skipped", "verified": True, "effectCount": 0, "effects": []}
        index = {"images": digested + images, "ocr": [], "batches": [
            {"batch": {"id": "batch-old", "images": digested, "startedAt": digested[0]["timestamp"], "completedAt": digested[-1]["timestamp"], "ocr": []},
             "status": "completed", "attempts": 1, "sourceIDs": receipt_obj["sourceIDs"], "sessionID": "rt", "receipt": receipt_obj}]}
        (root / "index.json").write_text(json.dumps(index))
        (root / "capture-checkpoint.json").write_text("{}")
        self.assertIn("%20", digested[0]["fileURL"])
        store = EvidenceStore(root)
        self.assertEqual(store.batch_state("batch-old"), "completed")
        self.assertFalse((root / "capture-checkpoint.json").exists())
        self.assertEqual(len(store.compressible_images(100)), BATCH_IMAGES)
        formed = store.form_batches()
        self.assertEqual(len(formed), 1)
        self.assertEqual({i.id for i in formed[0].images}, {i["id"] for i in images})
        written = json.loads((root / "index.json").read_text())
        self.assertEqual(written["batches"][0]["receipt"]["batchID"], "batch-old")
        resolved = (Path(os.path.realpath(root / "images")) / Path(digested[0]["fileURL"]).name).as_uri()
        self.assertEqual(written["images"][0]["fileURL"], resolved)
        self.assertIn("Application%20Support", resolved)

    def test_runtime_evidence_reader_reads_server_store(self):
        import sys
        sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
        from runtime.xcreen_tools import EvidenceReader
        store = self.open()
        moment = now() - timedelta(minutes=5)
        store.ingest_ocr([{"id": "ocr-1", "timestamp": moment, "text": "quarterly roadmap review", "app": "com.app", "title": "Doc"}])
        store.ingest_image("image-1", moment, png())
        reader = EvidenceReader(store.root)
        self.assertEqual([hit["id"] for hit in reader.search_ocr("roadmap")], ["ocr-1"])
        self.assertEqual([hit["id"] for hit in reader.images_near(moment.isoformat(), 30)], ["image-1"])
        view = reader.view_image("image-1")
        self.assertTrue(view["_multimodal"])


if __name__ == "__main__":
    unittest.main()
