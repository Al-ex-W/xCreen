from contextlib import closing
import hashlib
import importlib.util
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest

class MigrationTests(unittest.TestCase):
    def test_metadata_only_migration_preserves_uncertain_and_backup(self):
        from runtime.migrate_receipts import migrate
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
            home = Path(tmp)/'home'; home.mkdir(mode=0o700)
            vault = Path(tmp)/'vault'; vault.mkdir()
            key = hashlib.sha256(str(vault.resolve()).encode()).hexdigest()[:20]
            legacy = home/f'xcreen-daily-{key}-receipts.sqlite3'
            with closing(sqlite3.connect(legacy)) as db, db:
                db.execute('CREATE TABLE entries (id TEXT PRIMARY KEY, day TEXT NOT NULL, digest TEXT NOT NULL, state TEXT NOT NULL, position INTEGER NOT NULL DEFAULT -1)')
                db.execute('INSERT INTO entries VALUES (?,?,?,?,?)',('a'*20,'2026-10-16','b'*64,'pending',23))
            legacy.chmod(0o600)
            result = migrate(home, vault)
            self.assertFalse(legacy.exists())
            self.assertTrue(Path(result['backup']).is_file())
            with closing(sqlite3.connect(result['target'])) as db:
                self.assertEqual(db.execute('SELECT state,position,sources,batch FROM entries').fetchone(),('pending',23,'[]','manual'))
            self.assertFalse(list(vault.iterdir()))
    def test_unknown_schema_refused_without_modification(self):
        from runtime.migrate_receipts import migrate
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
            home = Path(tmp)/'home'; home.mkdir(mode=0o700)
            vault = Path(tmp)/'vault'; vault.mkdir()
            key = hashlib.sha256(str(vault.resolve()).encode()).hexdigest()[:20]
            legacy = home/f'xcreen-daily-{key}-receipts.sqlite3'
            with closing(sqlite3.connect(legacy)) as db, db:
                db.execute('CREATE TABLE secrets (body TEXT)')
            legacy.chmod(0o600)
            before = legacy.read_bytes()
            with self.assertRaisesRegex(ValueError,'schema'):
                migrate(home,vault)
            self.assertEqual(before,legacy.read_bytes())
            self.assertFalse((home/'xcreen-receipts'/f'daily-{key}.sqlite3').exists())
