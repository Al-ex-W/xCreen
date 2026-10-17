"""Real installed Hermes, synthetic home/evidence only; no inference."""
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import unittest



def _isolated_env(home):
    """Synthetic HERMES_HOME, but pin Hermes's runtime store to the real one.

    If a pending Hermes self-update completes while a probe imports hermes_bootstrap,
    it republishes the user's `hermes` launchers from the store resolved under
    HERMES_HOME; a temp home would point them at a soon-deleted interpreter.
    """
    env = dict(os.environ, HERMES_HOME=str(home))
    store = Path(sys.executable).resolve().parents[2]
    if store.name == 'tools':
        env['HERMES_RUNTIME_DIR'] = str(store)
    return env

class InstalledGatewayTests(unittest.TestCase):
    def test_real_host_tool_turn_and_cold_receipt_contract(self):
        root = os.environ.get('XCREEN_HERMES_ROOT')
        if not root:
            self.skipTest('set XCREEN_HERMES_ROOT to installed Hermes')
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
            home = Path(tmp)/'home'
            home.mkdir(mode=0o700)
            probe = Path(__file__).with_name('host_contract_probe.py')
            result = subprocess.run([sys.executable,str(probe)],env=_isolated_env(home),capture_output=True,text=True,timeout=30)
            self.assertEqual(result.returncode,0,result.stderr+'\n'+result.stdout)
            parsed = json.loads(result.stdout.strip().splitlines()[-1])
            self.assertTrue(parsed['host_turn_context'])
            self.assertTrue(parsed['cold_reconcile_after_expiry'])

    def test_real_registration_dispatch_and_stdio_ping(self):
        root = os.environ.get('XCREEN_HERMES_ROOT')
        if not root:
            self.skipTest('set XCREEN_HERMES_ROOT to installed Hermes')
        with tempfile.TemporaryDirectory(dir=os.environ.get('TMPDIR')) as tmp:
            work = Path(tmp)
            evidence = work/'evidence'
            (evidence/'images').mkdir(parents=True)
            (evidence/'index.json').write_text('{"ocr":[],"images":[],"batches":[]}')
            home = work/'home'
            home.mkdir(mode=0o700)
            env = dict(_isolated_env(home),HERMES_TUI_SKIP_MCP='1',PYTHONDONTWRITEBYTECODE='1')
            gateway = Path(__file__).resolve().parents[1]/'xcreen_gateway.py'
            proc = subprocess.Popen([sys.executable,str(gateway),'--hermes-root',root,'--evidence-root',str(evidence)],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
            try:
                requests = [{'jsonrpc':'2.0','id':'ping-test','method':'ping','params':{}}]
                for name in ('xcreen.batch.prepare','xcreen.batch.context','xcreen.batch.receipt','xcreen.batch.reconcile','xcreen.history.page'):
                    requests.append({'jsonrpc':'2.0','id':name,'method':name,'params':{'session_id':'synthetic-missing'}})
                proc.stdin.write(('\n'.join(json.dumps(r) for r in requests)+'\n').encode())
                proc.stdin.flush()
                replies = {}
                import time
                deadline = time.monotonic()+30
                while len(replies) < len(requests) and time.monotonic() < deadline:
                    if select.select([proc.stdout],[],[],max(0,deadline-time.monotonic()))[0]:
                        line = proc.stdout.readline()
                        if not line:
                            break
                        try:
                            frame = json.loads(line)
                        except ValueError:
                            continue
                        if frame.get('id') in {r['id'] for r in requests}:
                            replies[frame['id']] = frame
                self.assertEqual(set(replies),{r['id'] for r in requests})
                self.assertEqual(replies['ping-test']['result'],{'pong':True})
                for request in requests[1:]:
                    self.assertNotEqual(replies[request['id']].get('error',{}).get('code'),-32601)
                    self.assertIn('error',replies[request['id']])
            finally:
                proc.terminate()
                try:
                    _,error = proc.communicate(timeout=5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    _,error = proc.communicate(timeout=5)
                if proc.returncode not in (0,-15):
                    print(error.decode(errors='replace')[-3000:],file=sys.stderr)
