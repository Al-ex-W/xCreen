import json
import os
import unittest
from unittest.mock import patch
from runtime.tests import test_xcreen_tools as fixtures
from runtime.xcreen_tools import EvidenceReader, VaultDailyWriter


class WriterSecurityTests(unittest.TestCase):
    setUp = fixtures.XCreenToolsTests.setUp
    tearDown = fixtures.XCreenToolsTests.tearDown
    def writer(self):
        vault = self.root.parent / 'secure-vault'
        (vault / 'Daily').mkdir(parents=True)
        return VaultDailyWriter(vault, EvidenceReader(self.root, now=lambda: self.now), hermes_home=self.root.parent)

    def test_pending_payload_conflict_cannot_replace_reservation(self):
        writer = self.writer()
        args = {'fact': 'First immutable fact.', 'source_ids': ['ocr-a'], 'entry_id': 'stable'}
        original = writer._append_bytes
        def crash(fd, data):
            if b'xcreen-entry:' in data:
                raise OSError('crash before append')
            original(fd, data)
        with patch.object(writer, '_append_bytes', side_effect=crash), self.assertRaises(OSError):
            writer.append(args)
        before = writer.receipts()
        with self.assertRaisesRegex(ValueError, 'conflict'):
            writer.append(dict(args, fact='Different payload.'))
        self.assertEqual(writer.receipts(), before)

    def test_receipt_hardlink_rejected_without_touching_target(self):
        writer = self.writer()
        writer.receipts_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        target = self.root.parent / 'unrelated'
        target.write_bytes(b'not a database')
        os.link(target, writer.receipts_path)
        with self.assertRaises((ValueError, OSError)):
            writer.receipts()
        self.assertEqual(target.read_bytes(), b'not a database')

    def test_receipt_sidecars_and_directory_permissions_fail_closed(self):
        writer = self.writer()
        writer.receipts()
        target = self.root.parent/'sidecar-target'
        target.write_bytes(b'untouched')
        for suffix in ('-journal','-wal','-shm'):
            path = writer.receipts_path.with_name(writer.receipts_path.name+suffix)
            path.symlink_to(target)
            with self.assertRaises(ValueError):
                writer.receipts()
            path.unlink()
            os.link(target,path)
            with self.assertRaises(ValueError):
                writer.receipts()
            path.unlink()
        self.assertEqual(target.read_bytes(),b'untouched')
        writer.receipts_path.parent.chmod(0o755)
        with self.assertRaises(ValueError):
            writer.receipts()
        writer.receipts_path.parent.chmod(0o700)

    def test_pinned_database_detects_replacement_before_operation(self):
        writer = self.writer()
        db = writer._receipts_db()
        original = writer.receipts_path.with_suffix('.retained')
        writer.receipts_path.rename(original)
        writer.receipts_path.write_bytes(b'user replacement')
        writer.receipts_path.chmod(0o600)
        try:
            with self.assertRaisesRegex(ValueError,'replaced'):
                db.execute('SELECT * FROM entries')
        finally:
            db.close()
        self.assertEqual(writer.receipts_path.read_bytes(),b'user replacement')

    def test_conventions_checked_before_note_create(self):
        writer = self.writer()
        with patch.object(writer, '_read_conventions', side_effect=ValueError('unsafe conventions')):
            with self.assertRaises(ValueError):
                writer.append({'fact': 'Useful.', 'source_ids': ['ocr-a']})
        self.assertEqual(list((writer.vault / 'Daily').iterdir()), [])

    def test_sources_revalidated_under_lock(self):
        writer = self.writer()
        original = writer._read_conventions
        def expire():
            original()
            (self.root / 'index.json').write_text(json.dumps({'ocr': [], 'images': []}))
        with patch.object(writer, '_read_conventions', side_effect=expire), self.assertRaises(ValueError):
            writer.append({'fact': 'Useful.', 'source_ids': ['ocr-a']})
        self.assertEqual(list((writer.vault / 'Daily').iterdir()), [])
