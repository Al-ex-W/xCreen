import json
import unittest

from tests.helpers import ROOT  # noqa: F401
from xcreen_server.receipts import BatchReceipt, ProtocolFailure

BINDING = dict(batch_id="batch-1", source_ids=["ocr-1", "image-1"], session_id="runtime-1")


def receipt(**overrides):
    body = {"batch_id": "batch-1", "source_ids": ["image-1", "ocr-1"], "session_id": "runtime-1", "status": "skipped", "verified": True, "effects": []}
    body.update(overrides)
    return json.dumps(body)


class ReceiptTests(unittest.TestCase):
    def test_verified_skipped_and_saved_complete_processing(self):
        self.assertTrue(BatchReceipt.parse(receipt(), **BINDING).completes_processing)
        saved = BatchReceipt.parse(receipt(status="saved", effects=[{"entry_id": "e1", "state": "completed"}]), **BINDING)
        self.assertTrue(saved.completes_processing)
        self.assertEqual(saved.effect_count, 1)

    def test_binding_mismatch_is_rejected(self):
        for change in ({"batch_id": "other"}, {"session_id": "other"}, {"source_ids": ["image-1"]}, {"source_ids": ["image-1", "image-1"]}):
            with self.assertRaises(ProtocolFailure):
                BatchReceipt.parse(receipt(**change), **BINDING)

    def test_verified_status_must_match_effects(self):
        with self.assertRaises(ProtocolFailure):
            BatchReceipt.parse(receipt(status="saved"), **BINDING)
        with self.assertRaises(ProtocolFailure):
            BatchReceipt.parse(receipt(effects=[{"entry_id": "e1", "state": "completed"}]), **BINDING)
        with self.assertRaises(ProtocolFailure):
            BatchReceipt.parse(receipt(status="saved", effects=[{"entry_id": "e1", "state": "pending"}]), **BINDING)

    def test_retry_safe_only_for_unverified_effect_free_uncertain(self):
        ok = BatchReceipt.parse(receipt(status="uncertain", verified=False, retry_safe=True), **BINDING)
        self.assertTrue(ok.retry_safe)
        self.assertFalse(ok.completes_processing)
        with self.assertRaises(ProtocolFailure):
            BatchReceipt.parse(receipt(retry_safe=True), **BINDING)

    def test_stored_encoding_round_trips_with_swift_field_names(self):
        parsed = BatchReceipt.parse(receipt(), **BINDING)
        encoded = parsed.encode()
        self.assertEqual(set(encoded), {"batchID", "sourceIDs", "sessionID", "status", "verified", "effectCount", "effects"})
        self.assertEqual(BatchReceipt.decode(encoded), parsed)

    def test_oversized_receipt_is_rejected(self):
        with self.assertRaises(ProtocolFailure):
            BatchReceipt.parse(receipt(padding="x" * 50_000), **BINDING)


if __name__ == "__main__":
    unittest.main()
