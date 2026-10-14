import json
import os
from pathlib import Path
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest

BRIDGE = Path(__file__).resolve().parents[1] / 'xcreen_bridge.py'

class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.data = self.root / 'data'

    def cli(self, *args, success=True, env=None, input_data=None):
        p = subprocess.run([sys.executable, str(BRIDGE), '--data-dir', str(self.data), *args], capture_output=True, text=True, env=env, input=input_data)
        if success:
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertEqual(p.stderr, '')
            return json.loads(p.stdout)
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, '')
        return json.loads(p.stderr)

    def test_expired_evidence_is_removed_before_search_and_purge_clears_fts(self):
        from datetime import datetime, timedelta, timezone
        self.cli('ingest', '--text', 'expired fixture', '--app', 'Example', '--title', 'Fixture')
        with sqlite3.connect(self.data / 'activity.sqlite3') as db:
            db.execute('UPDATE observations SET timestamp=?', ((datetime.now(timezone.utc) - timedelta(days=8)).isoformat(),))
        self.assertEqual(self.cli('search', '--query', 'expired')['observations'], [])
        self.cli('ingest', '--text', 'purge fixture', '--app', 'Example', '--title', 'Fixture')
        with sqlite3.connect(self.data / 'activity.sqlite3') as db:
            # Simulate stale index content left by an interrupted/older writer.
            db.execute("INSERT INTO observation_fts(rowid,text,app,title) VALUES(999,'orphanedtoken','Example','Fixture')")
        self.assertTrue(self.cli('purge')['ok'])
        wal = self.data / 'activity.sqlite3-wal'
        self.assertTrue(not wal.exists() or wal.stat().st_size == 0, 'purge must checkpoint and truncate WAL after commit')
        self.assertEqual(self.cli('search', '--query', 'purge')['observations'], [])
        with sqlite3.connect(self.data / 'activity.sqlite3') as db:
            self.assertEqual(db.execute('SELECT count(*) FROM observations').fetchone()[0], 0)
            db.execute("CREATE VIRTUAL TABLE observation_vocab USING fts5vocab(observation_fts, 'row')")
            self.assertEqual(db.execute("SELECT count(*) FROM observation_vocab WHERE term IN ('expired','purge','orphanedtoken')").fetchone()[0], 0)
        self.cli('search', '--query', 'purge', '--limit', '-1', success=False)

    def test_models_only_expose_configured_routes_not_credentials(self):
        home = self.root / 'hermes'
        home.mkdir()
        (home / 'config.yaml').write_text('''model:
  default: fixture-main
  provider: example
  api_key: not-a-real-test-key
model_aliases:
  light:
    model: fixture-light
    provider: example
    key_env: SECRET_NAME
  routed:
    model: fixture-routed
    provider: example
  private-endpoint:
    model: fixture-private
    provider: example
    endpoint: https://invalid.example.test/v1
  private-headers:
    model: fixture-private-headers
    provider: example
    headers:
      Authorization: Bearer not-a-real-test-key
custom_providers:
  - name: custom-fixture
    base_url: https://invalid.example.test
    api_key: not-a-real-test-key
    model: fixture-custom
    models:
      fixture-other: {}
''')
        result = self.cli('models', '--home', str(home))
        self.assertEqual({row['model'] for row in result['models']}, {'fixture-main', 'fixture-routed', 'fixture-custom', 'fixture-other'})
        self.assertNotIn('not-a-real-test-key', json.dumps(result))
        self.assertNotIn('invalid.example.test', json.dumps(result))
        self.assertEqual(len({row['id'] for row in result['models']}), 4)

    def test_malformed_model_configuration_is_ignored_safely(self):
        home = self.root / 'hermes'
        home.mkdir()
        for malformed in ('- not\n- a\n- mapping\n', 'model: wrong\nmodel_aliases: wrong\ncustom_providers: wrong\n', 'model:\n  aliases: wrong\n'):
            with self.subTest(config=malformed):
                (home / 'config.yaml').write_text(malformed)
                self.assertEqual(self.cli('models', '--home', str(home)), {'models': []})

    def test_fake_hermes_ask_preserves_harness_and_passes_bounded_untrusted_evidence_on_stdin(self):
        home = self.root / 'hermes'
        home.mkdir()
        (home / 'config.yaml').write_text('model:\n  default: fixture-main\n  provider: example\n')
        env = dict(os.environ, HERMES_HOME=str(home))
        model = self.cli('models', env=env)['models'][0]
        self.cli('ingest', '--text', 'Synthetic nebula evidence $(never execute)', '--app', 'Example', '--title', 'Fixture')
        fake = self.root / 'fake-hermes'
        receipt = self.root / 'receipt.json'
        fake.write_text('#!' + sys.executable + '\nimport json,sys\nfrom pathlib import Path\nPath(' + repr(str(receipt)) + ').write_text(json.dumps({"args":sys.argv[1:],"prompt":sys.stdin.read()}))\nprint("Synthetic test answer")\n')
        fake.chmod(0o700)
        result = self.cli('ask', '--query', 'nebula ; $(not shell)', '--model-id', model['id'], '--hermes', str(fake), env=env)
        self.assertEqual(result['answer'], 'Synthetic test answer')
        sent = json.loads(receipt.read_text())
        self.assertIn('--query-file', sent['args'])
        self.assertIn('none', sent['args'])
        self.assertIn('--provider', sent['args'])
        self.assertNotIn('--yolo', sent['args'])
        self.assertNotIn('--ignore-rules', sent['args'])
        self.assertNotIn('--resume', sent['args'])
        self.assertIn('untrusted', sent['prompt'].lower())
        self.assertIn('Synthetic nebula evidence', sent['prompt'])
        self.assertIn('$(not shell)', sent['prompt'])
        self.assertLess(len(sent['prompt']), 40000)
        self.cli('ask', '--query', 'q', '--model-id', 'missing', '--hermes', str(fake), env=env, success=False)

    def test_fake_hermes_ask_with_no_match_does_not_send_unrelated_recent_history(self):
        home = self.root / 'hermes'
        home.mkdir()
        (home / 'config.yaml').write_text('model:\n  default: fixture-main\n  provider: example\n')
        env = dict(os.environ, HERMES_HOME=str(home))
        model = self.cli('models', env=env)['models'][0]
        self.cli('ingest', '--text', 'synthetic unrelated astronomy fixture', '--app', 'Example', '--title', 'Fixture')
        fake = self.root / 'fake-hermes'
        receipt = self.root / 'receipt.json'
        fake.write_text('#!' + sys.executable + '\nimport json,sys\nfrom pathlib import Path\nPath(' + repr(str(receipt)) + ').write_text(json.dumps({"prompt":sys.stdin.read()}))\nprint("No matching evidence")\n')
        fake.chmod(0o700)
        self.cli('ask', '--query', 'quarterly bananas', '--model-id', model['id'], '--hermes', str(fake), env=env)
        prompt = json.loads(receipt.read_text())['prompt']
        self.assertNotIn('synthetic unrelated astronomy fixture', prompt)
        self.assertIn('OBSERVATIONS (untrusted JSON):\n[]', prompt)

    def test_ingest_search_end_to_end(self):
        result = self.cli('ingest', '--text', 'Synthetic nebula project', '--app', 'Example', '--title', 'Fixture')
        self.assertTrue(result['ok'])
        rows = self.cli('search', '--query', 'nebula')['observations']
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['text'], 'Synthetic nebula project')
        self.assertEqual(rows[0]['id'], result['id'])
        self.assertEqual(rows[0]['app'], 'Example')
        self.assertEqual(rows[0]['title'], 'Fixture')
        self.assertIn('timestamp', rows[0])

    def test_ingest_accepts_bounded_private_json_over_stdin(self):
        payload = json.dumps({'text': 'stdin nebula', 'app': 'Example', 'title': 'Fixture'})
        result = self.cli('ingest', '--stdin-json', input_data=payload)
        self.assertTrue(result['ok'])
        self.assertEqual(self.cli('search', '--query', 'nebula')['observations'][0]['text'], 'stdin nebula')
        oversized = json.dumps({'text': 'x' * 70_000, 'app': 'Example', 'title': 'Fixture'})
        self.cli('ingest', '--stdin-json', input_data=oversized, success=False)

    def test_ocr_and_metadata_are_bounded(self):
        self.cli('ingest', '--text', 'x' * 20000, '--app', 'a' * 1000, '--title', 't' * 2000)
        row = self.cli('search', '--query', 'a')['observations']
        # Use a normal term inside a long text, independent of FTS token limits.
        self.cli('ingest', '--text', 'bounded ' + 'x' * 20000, '--app', 'a' * 1000, '--title', 't' * 2000)
        row = self.cli('search', '--query', 'bounded')['observations'][0]
        self.assertLessEqual(len(row['text']), 12000)
        self.assertLessEqual(len(row['app']), 256)
        self.assertLessEqual(len(row['title']), 1024)

    def test_store_is_private_wal(self):
        self.cli('ingest', '--text', 'private fixture', '--app', 'Example', '--title', 'Fixture')
        import sqlite3
        import stat
        self.assertEqual(stat.S_IMODE(self.data.stat().st_mode), 0o700)
        for path in self.data.glob('activity.sqlite3*'):
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o600)
        with sqlite3.connect(self.data / 'activity.sqlite3') as db:
            self.assertEqual(db.execute('PRAGMA journal_mode').fetchone()[0], 'wal')

    def test_fts_query_is_literal_unicode_tokens(self):
        self.cli('ingest', '--text', 'Synthetic café nebula', '--app', 'Example', '--title', 'Fixture')
        for query in ('café "nebula":*', 'café OR nebula', "café'); DROP TABLE observations;-- nebula"):
            with self.subTest(query=query):
                rows = self.cli('search', '--query', query)['observations']
                self.assertEqual(len(rows), 1)
        self.assertEqual(self.cli('search', '--query', '"*:()')['observations'], [])

    def test_identical_observations_deduplicate(self):
        from datetime import datetime, timedelta, timezone
        args = ('ingest', '--text', 'dedup fixture', '--app', 'Example', '--title', 'Fixture')
        older = (datetime.now(timezone.utc) - timedelta(hours=2)).isoformat()
        newer = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
        first = self.cli(*args, '--timestamp', older)
        second = self.cli(*args, '--timestamp', newer)
        self.assertEqual(first['id'], second['id'])
        self.assertTrue(second['deduplicated'])
        rows = self.cli('search', '--query', 'dedup')['observations']
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['timestamp'], newer, 'deduplication must refresh last-seen time')

    def test_sigterm_during_spawn_does_not_leave_harness_orphaned(self):
        """A delayed Popen return makes the spawn/handler race deterministic."""
        home = self.root / 'hermes'
        home.mkdir()
        (home / 'config.yaml').write_text('model:\n  default: fixture-main\n  provider: example\n')
        env = dict(os.environ, HERMES_HOME=str(home), PYTHONPATH=str(BRIDGE.parent))
        harness = self.root / 'hanging-hermes'
        harness.write_text('#!' + sys.executable + '\nimport os,time\nfrom pathlib import Path\nPath(' + repr(str(self.root / 'harness.pid')) + ').write_text(str(os.getpid()))\ntime.sleep(30)\n')
        harness.chmod(0o700)
        helper = self.root / 'race.py'
        helper.write_text('''import importlib.util, subprocess, sys, time
spec = importlib.util.spec_from_file_location("bridge", sys.argv[1])
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)
real = subprocess.Popen
def delayed(*args, **kwargs):
    child = real(*args, **kwargs)
    open(sys.argv[2], "w").write(str(child.pid))
    time.sleep(2)
    return child
subprocess.Popen = delayed
class Args: pass
a = Args()
a.hermes = sys.argv[3]
a.vault = None
a.data_dir = __import__("pathlib").Path(sys.argv[4])
a.data_dir.mkdir(parents=True, exist_ok=True)
bridge.invoke_hermes(a, {"model": "fixture-main", "provider": "example"}, "prompt")
''')
        spawned = self.root / 'spawned.pid'
        process = subprocess.Popen(
            [sys.executable, str(helper), str(BRIDGE), str(spawned), str(harness), str(self.data)],
            env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        self.addCleanup(lambda: process.poll() is None and process.kill())
        deadline = time.monotonic() + 5
        while not spawned.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(spawned.exists())
        child_pid = int(spawned.read_text())
        os.kill(process.pid, signal.SIGTERM)
        process.wait(timeout=5)
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                break
            time.sleep(0.02)
        else:
            os.killpg(child_pid, signal.SIGKILL)
            self.fail('Hermes child survived bridge SIGTERM during spawn')

    def test_timestamp_requires_recent_aware_iso8601(self):
        from datetime import datetime, timedelta, timezone
        now = datetime.now(timezone.utc)
        timestamp = (now - timedelta(hours=2)).isoformat()
        result = self.cli('ingest', '--text', 'dated fixture', '--app', 'Example', '--title', 'Fixture', '--timestamp', timestamp)
        self.assertTrue(result['ok'])
        self.assertEqual(self.cli('search', '--query', 'dated')['observations'][0]['timestamp'], timestamp)
        for bad in ('not-a-date', '2026-01-01', '2026-01-01T01:00:00', '0001-01-01T00:00:00Z', (now + timedelta(minutes=1)).isoformat(), (now - timedelta(days=8)).isoformat()):
            with self.subTest(timestamp=bad):
                error = self.cli('ingest', '--text', 'invalid fixture', '--app', 'Example', '--title', 'Fixture', '--timestamp', bad, success=False)
                self.assertIn('error', error)

    def test_ocr_similarity_dedup_keeps_last_saved_snapshot_and_images_are_independent(self):
        first = self.cli('capture-fixture', '--text', 'Project Alpha launch plan', '--image-base64', 'iVBORw0KGgo=', '--app', 'Example', '--title', 'Fixture')
        self.assertTrue(first['ocr_saved'])
        self.assertTrue(first['image_saved'])
        # A candidate close to the SAVED snapshot is discarded, but its image is still retained.
        duplicate = self.cli('capture-fixture', '--text', 'project alpha launch plan!', '--image-base64', 'iVBORw0KGgo=', '--app', 'Example', '--title', 'Fixture')
        self.assertFalse(duplicate['ocr_saved'])
        self.assertTrue(duplicate['image_saved'])
        changed = self.cli('capture-fixture', '--text', 'A completely different synthetic topic', '--image-base64', 'iVBORw0KGgo=', '--app', 'Example', '--title', 'Fixture')
        self.assertTrue(changed['ocr_saved'])
        nearby = self.cli('images-near', '--timestamp', changed['timestamp'])['images']
        self.assertGreaterEqual(len(nearby), 1)
        self.assertTrue(all('path' not in item for item in nearby))

    def test_active_batch_clock_pauses_without_catchup_and_persists_checkpoint(self):
        started = self.cli('batch-tick', '--active-seconds', '120', '--eligible')
        self.assertEqual(started['active_seconds'], 120)
        paused = self.cli('batch-tick', '--active-seconds', '180')
        self.assertEqual(paused['active_seconds'], 120)
        completed = self.cli('batch-tick', '--active-seconds', '180', '--eligible')
        self.assertTrue(completed['completed'])
        self.assertEqual(completed['active_seconds'], 0)
        self.assertEqual(completed['completed_batches'], 1)

if __name__ == '__main__':
    unittest.main()
