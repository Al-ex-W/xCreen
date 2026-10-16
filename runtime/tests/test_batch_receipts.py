import json
import unittest
from runtime.tests import test_xcreen_tools as fixtures


class BatchReceiptTests(unittest.TestCase):
    setUp = fixtures.XCreenToolsTests.setUp
    tearDown = fixtures.XCreenToolsTests.tearDown
    def setup_service(self):
        from runtime.xcreen_receipts import BatchReceipts
        from runtime.xcreen_tools import EvidenceReader, VaultDailyWriter
        vault = self.root.parent / 'batch-vault'
        (vault / 'Daily').mkdir(parents=True)
        index = json.loads((self.root / 'index.json').read_text())
        index['batches'] = [{'batch': {'id': 'batch-a', 'images': [], 'ocr': [index['ocr'][0]], 'startedAt': 0, 'completedAt': 1}, 'status': 'submitting'}]
        (self.root / 'index.json').write_text(json.dumps(index))
        self.reader = EvidenceReader(self.root, now=lambda: self.now)
        self.writer = VaultDailyWriter(vault, self.reader, hermes_home=self.root.parent)
        self.service = BatchReceipts(self.reader, self.writer)

    def test_host_binding_rejects_spoof_and_out_of_batch_sources(self):
        self.setup_service()
        params = dict(session_id='session-a', batch_id='batch-a', source_ids=['ocr-a'])
        self.assertTrue(self.service.prepare(params)['prepared'])
        with self.assertRaises(ValueError):
            self.service.prepare(dict(params, source_ids=['image-a']))
        with self.assertRaises(ValueError):
            self.service.append({'fact':'Useful.', 'source_ids':['ocr-a'], 'batch_id':'forged'}, 'session-a', 'turn-a')
        with self.assertRaises(ValueError):
            self.service.append({'fact':'Useful.', 'source_ids':['image-a']}, 'session-a', 'turn-a')
        result = self.service.append({'fact':'Useful.', 'source_ids':['ocr-a'], 'entry_id':'milestone'}, 'session-a', 'turn-a')
        with self.assertRaises(ValueError):
            self.service.append({'fact':'Useful.', 'source_ids':['ocr-a']}, 'session-b', 'turn-a')
        with self.assertRaises(ValueError):
            self.service.append({'fact':'Useful.', 'source_ids':['ocr-a']}, 'session-a', 'turn-b')
        with self.assertRaises(ValueError):
            self.service.result({'outcome':'saved', 'effect_ids':[]}, 'session-a','turn-a')
        terminal = self.service.result({'outcome':'saved', 'effect_ids':[result['entry_id']]}, 'session-a','turn-a')
        self.assertTrue(terminal['verified'])
        (self.root / 'index.json').unlink()
        receipt = self.service.receipt(dict(params, reconcile=True))
        self.assertEqual(receipt['status'], 'saved')
        self.assertTrue(receipt['verified'])
        from runtime.xcreen_receipts import BatchReceipts
        restarted = BatchReceipts(self.reader, self.writer)
        self.assertEqual(restarted.receipt(params), receipt)

    def test_prepared_source_metadata_is_immutable_not_just_membership(self):
        self.setup_service()
        params = dict(session_id='session-a', batch_id='batch-a', source_ids=['ocr-a'])
        self.service.prepare(params)
        index = json.loads((self.root/'index.json').read_text())
        index['ocr'][0]['timestamp'] += 60
        (self.root/'index.json').write_text(json.dumps(index))
        with self.assertRaisesRegex(ValueError,'metadata'):
            self.service.append({'entry_id':'fact','fact':'Useful.','source_ids':['ocr-a']},'session-a','turn-a')
        self.assertEqual(list((self.writer.vault/'Daily').iterdir()),[])
        index['batches'][0]['batch']['completedAt'] = 99
        (self.root/'index.json').write_text(json.dumps(index))
        with self.assertRaisesRegex(ValueError,'conflict'):
            self.service.prepare(params)

    def test_manual_writer_separate_and_never_batch_spoofs(self):
        self.setup_service()
        params = dict(session_id='session-a', batch_id='batch-a', source_ids=['ocr-a'])
        self.service.prepare(params)
        args = {'entry_id':'manual-fact','fact':'Useful manual fact.','source_ids':['image-a']}
        with self.assertRaises(ValueError):
            self.service.append_manual(args,'session-a','turn-a')
        self.service.context({'session_id':'session-a','mode':'manual'})
        with self.assertRaises(ValueError):
            self.service.append_manual(dict(args,batch_id='batch-a'),'session-a','manual-a')
        self.assertTrue(self.service.append_manual(args,'session-a','manual-a')['written'])
        with self.assertRaises(ValueError):
            self.service.append_manual(args,'session-a','manual-b')
        with self.assertRaises(ValueError):
            self.service.result({'outcome':'skipped','reason':'no_useful_fact','effect_ids':[]},'session-a','manual-a')

    def test_saved_receipt_survives_lost_ack_and_detects_note_edit(self):
        from unittest.mock import patch
        from runtime.xcreen_tools import _PinnedDB
        self.setup_service()
        params = dict(session_id='session-a', batch_id='batch-a', source_ids=['ocr-a'])
        self.service.prepare(params)
        effect = self.service.append({'entry_id':'fact','fact':'Useful.','source_ids':['ocr-a']},'session-a','turn-a')
        original = _PinnedDB.commit
        def lost_ack(db):
            original(db)
            row = db.execute('SELECT terminal FROM batches WHERE id=?', ('batch-a',)).fetchone()
            if row and row['terminal']:
                raise OSError('synthetic crash after terminal fsync')
        with patch.object(_PinnedDB,'commit',lost_ack), self.assertRaises(OSError):
            self.service.result({'outcome':'saved','effect_ids':[effect['entry_id']]},'session-a','turn-a')
        (self.root/'index.json').unlink()
        receipt = self.service.receipt(params)
        self.assertTrue(receipt['verified'])
        note = self.writer.vault/'Daily'/(effect['day']+'.md')
        note.write_text('# User edited away the effect\n')
        self.assertFalse(self.service.receipt(params)['verified'])
        self.assertEqual(self.service.receipt(params)['status'],'uncertain')

    def test_effects_without_explicit_terminal_are_never_completion(self):
        self.setup_service()
        params = dict(session_id='session-a', batch_id='batch-a', source_ids=['ocr-a'])
        self.service.prepare(params)
        self.service.append({'entry_id':'fact','fact':'Useful.','source_ids':['ocr-a']},'session-a','turn-a')
        receipt = self.service.receipt(params)
        self.assertEqual(receipt['status'],'uncertain')
        self.assertFalse(receipt['verified'])
        with self.assertRaises(ValueError):
            self.service.result({'outcome':'skipped','reason':'no_useful_fact','effect_ids':[]},'session-a','turn-a')

    def test_skipped_requires_zero_effects_and_immutable_terminal(self):
        self.setup_service()
        params = dict(session_id='session-a', batch_id='batch-a', source_ids=['ocr-a'])
        self.service.prepare(params)
        with self.assertRaises(ValueError):
            self.service.result({'outcome':'skipped','reason':'whatever','effect_ids':[]}, 'session-a','turn-a')
        result = self.service.result({'outcome':'skipped','reason':'no_useful_fact','effect_ids':[]}, 'session-a','turn-a')
        self.assertEqual(result['status'], 'skipped')
        self.assertEqual(self.service.receipt(params), result)
        with self.assertRaises(ValueError):
            self.service.append({'fact':'Useful.', 'source_ids':['ocr-a']}, 'session-a','turn-a')
        self.service.context({'session_id':'session-a','mode':'manual'})
        with self.assertRaises(ValueError):
            self.service.result({'outcome':'skipped','reason':'no_useful_fact','effect_ids':[]}, 'session-a','manual-turn')
