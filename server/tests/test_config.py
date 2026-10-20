import os
import sqlite3
import unittest

from tests.helpers import TempDirTestCase
from xcreen_server.config import (ServerConfig, create_token, journal_key, load_token, migrate_journal, parse_obsidian_vaults,
                                  parse_runtime_command)


class ConfigTests(TempDirTestCase):
    def test_token_is_private_and_stable_until_rotated(self):
        config = self.config()
        token = create_token(config)
        self.assertEqual(os.stat(config.token_path).st_mode & 0o777, 0o600)
        self.assertEqual(load_token(config), token)
        self.assertEqual(create_token(config), token)
        self.assertNotEqual(create_token(config, rotate=True), token)
        os.chmod(config.token_path, 0o644)
        with self.assertRaises(PermissionError):
            load_token(config)

    def test_validation_refuses_wildcard_bind_and_relative_paths(self):
        config = self.config()
        self.assertEqual(config.validate(), [])
        config.bind = "0.0.0.0"
        config.vault = "relative/vault"
        problems = " ".join(config.validate())
        self.assertIn("0.0.0.0", problems)
        self.assertIn("vault", problems)

    def test_save_and_load_round_trip(self):
        config = self.config()
        config.vault = "/srv/vault"
        config.save()
        self.assertEqual(os.stat(config.path).st_mode & 0o777, 0o600)
        self.assertEqual(ServerConfig.load(config.path).vault, "/srv/vault")

    def test_runtime_command_and_obsidian_parsing(self):
        command = '["/opt/py/bin/python3", "-I", "-c", "import sys; sys.path.insert(0, \'/opt/hermes\'); run()"]'
        self.assertEqual(parse_runtime_command(command), ("/opt/py/bin/python3", "/opt/hermes"))
        self.assertIsNone(parse_runtime_command("not json"))
        daily, plain = self.tmp / "with-daily", self.tmp / "plain"
        (daily / "Daily").mkdir(parents=True)
        plain.mkdir()
        listing = {"vaults": {"a": {"path": str(plain), "open": True, "ts": 9}, "b": {"path": str(daily), "ts": 1}}}
        import json
        self.assertEqual(parse_obsidian_vaults(json.dumps(listing)), str(daily))


class JournalMigrationTests(TempDirTestCase):
    def journal(self, path, rows):
        connection = sqlite3.connect(path)
        connection.execute("CREATE TABLE entries (id TEXT)")
        connection.execute("CREATE TABLE batches (id TEXT)")
        connection.executemany("INSERT INTO entries VALUES (?)", [(str(i),) for i in range(rows)])
        connection.commit()
        connection.close()

    def setUp(self):
        super().setUp()
        self.home = self.tmp / "hermes"
        (self.home / "xcreen-receipts").mkdir(parents=True, mode=0o700)
        self.new_vault = self.tmp / "vault"
        self.new_vault.mkdir()
        self.old = self.home / "xcreen-receipts" / f"daily-{journal_key('/Users/me/Vault')}.sqlite3"
        self.journal(self.old, 3)
        self.target = self.home / "xcreen-receipts" / f"daily-{journal_key(os.path.realpath(self.new_vault))}.sqlite3"

    def test_copies_old_journal_to_the_new_vault_key_and_keeps_an_empty_one(self):
        self.journal(self.target, 0)
        migrate_journal(self.home, "/Users/me/Vault", str(self.new_vault))
        connection = sqlite3.connect(self.target)
        self.assertEqual(connection.execute("SELECT count(*) FROM entries").fetchone()[0], 3)
        connection.close()
        self.assertEqual(os.stat(self.target).st_mode & 0o777, 0o600)
        self.assertEqual(len(list(self.target.parent.glob(self.target.name + ".empty-*"))), 1)
        self.assertTrue(self.old.exists())

    def test_never_overwrites_a_journal_with_receipts(self):
        self.journal(self.target, 1)
        with self.assertRaises(FileExistsError):
            migrate_journal(self.home, "/Users/me/Vault", str(self.new_vault))

    def test_missing_source_is_an_error(self):
        with self.assertRaises(FileNotFoundError):
            migrate_journal(self.home, "/nowhere", str(self.new_vault))


if __name__ == "__main__":
    unittest.main()
