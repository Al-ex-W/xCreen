import asyncio
import shutil
import unittest
from datetime import timedelta

from tests.helpers import TempDirTestCase, now, png, run, stamps
from xcreen_server.images import ImageCompactor, MozJPEGEncoder, NetpbmCjpegEncoder, PillowEncoder, default_encoder
from xcreen_server.receipts import BatchReceipt
from xcreen_server.store import BATCH_IMAGES, EvidenceStore


class FakeEncoder:
    name = "fake"

    def __init__(self, data: bytes):
        self.data = data

    async def encode(self, path):
        return self.data


class CompactorTests(TempDirTestCase):
    def digested_store(self) -> EvidenceStore:
        store = EvidenceStore(self.tmp / "evidence")
        for n, moment in enumerate(stamps(BATCH_IMAGES, now() - timedelta(minutes=10))):
            store.ingest_image(f"image-{n}", moment, png(64, 64, seed=n))
        batch = store.form_batches()[0]
        store.transition(batch.id, "submitting")
        store.bind(batch.id, "runtime-1")
        store.transition(batch.id, "admitted")
        store.reconcile(BatchReceipt.parse({"batch_id": batch.id, "source_ids": batch.source_ids, "session_id": "runtime-1",
                                            "status": "skipped", "verified": True, "effects": []},
                                           batch_id=batch.id, source_ids=batch.source_ids, session_id="runtime-1"))
        return store

    def test_replaces_only_with_smaller_jpeg_and_stops_without_encoder(self):
        store = self.digested_store()
        self.assertEqual(run(ImageCompactor(store, None).run()), 0)
        self.assertEqual(run(ImageCompactor(store, FakeEncoder(b"\xff\xd8\xff" + b"\0" * 100_000)).run()), 0)
        self.assertEqual(len(store.compressible_images(100)), BATCH_IMAGES)
        self.assertEqual(run(ImageCompactor(store, FakeEncoder(b"\xff\xd8\xff\xe0" + b"\0" * 8)).run(limit=10)), 10)
        self.assertEqual(len(store.compressible_images(100)), BATCH_IMAGES - 10)

    def test_real_encoders_produce_jpeg_when_installed(self):
        store = self.digested_store()
        path = store.compressible_images(1)[0].path
        encoders = [e for e in (MozJPEGEncoder.locate(), PillowEncoder.locate(), NetpbmCjpegEncoder.locate()) if e]
        if not encoders:
            self.skipTest("no JPEG encoder installed")
        for encoder in encoders:
            data = run(encoder.encode(path))
            self.assertTrue(data.startswith(b"\xff\xd8\xff"), encoder.name)
            sharper = run(encoder.encode(path, quality=85))
            self.assertTrue(sharper.startswith(b"\xff\xd8\xff"), encoder.name)
            self.assertGreater(len(sharper), len(data), encoder.name)
        self.assertIsNotNone(default_encoder())


if __name__ == "__main__":
    unittest.main()
