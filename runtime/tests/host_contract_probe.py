"""Executed by installed Python with a synthetic HERMES_HOME. No inference."""
import json
import os
from pathlib import Path
import sys
import threading
from types import SimpleNamespace
from datetime import datetime, timezone

sys.path.insert(0, os.environ['XCREEN_HERMES_ROOT'])
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import hermes_bootstrap
from tui_gateway import server
from tools.registry import registry
from runtime.xcreen_tools import EvidenceReader, VaultDailyWriter, register_xcreen_tools
from runtime.xcreen_receipts import BatchReceipts
from runtime.xcreen_rpc import register_xcreen_methods
from model_tools import _execute_tool, _CallIds

root = Path(os.environ['HERMES_HOME']).parent
now = datetime.now(timezone.utc).isoformat()
evidence = root/'probe-evidence'
(evidence/'images').mkdir(parents=True)
source = {'id':'ocr-a','timestamp':now,'text':'synthetic only'}
(evidence/'index.json').write_text(json.dumps({'ocr':[source], 'images':[], 'batches':[{'batch':{'id':'batch-a','images':[],'ocr':[source]},'status':'submitting'}]}))
vault = root/'probe-vault'
(vault/'Daily').mkdir(parents=True)
reader = EvidenceReader(evidence)
writer = VaultDailyWriter(vault, reader)
service = BatchReceipts(reader, writer)
register_xcreen_tools(reader, writer, registry=registry, receipts=service)
register_xcreen_methods(service, server=server)
session = {'session_key':'durable_key','running':False,'history':[], 'history_lock':threading.RLock(),'agent':SimpleNamespace(session_id='durable_key')}
server._sessions['runtime-a'] = session
params = {'session_id':'runtime-a','batch_id':'batch-a','source_ids':['ocr-a']}
prepared = server._methods['xcreen.batch.prepare']('prepare',params)
assert prepared['result']['prepared'], prepared
session['running'] = True
ids = _CallIds(session_id='durable_key', turn_id='host-turn-a',tool_call_id='synthetic-call')
def tool(name,args):
    return json.loads(_execute_tool(name,args,args,ids,user_task='synthetic',enabled_tools=[name],skip_tool_execution_middleware=True))
session['history_version'] = 1  # a no-tools prior turn advanced host history
blocked = tool('xcreen_daily_note',{'entry_id':'leaked','fact':'Must not inherit stale authority.','source_ids':['ocr-a']})
assert 'error' in blocked and not writer.receipts(), blocked
session['running'] = False
assert server._methods['xcreen.batch.prepare']('fresh-native-context',params)['result']['prepared']
session['running'] = True
effect = tool('xcreen_daily_note',{'entry_id':'semantic-a','fact':'Synthetic useful fact.', 'source_ids':['ocr-a']})
assert effect.get('written'), effect
terminal = tool('xcreen_batch_result',{'outcome':'saved','effect_ids':[effect['entry_id']]})
assert terminal.get('status') == 'saved' and terminal.get('verified'), terminal
ids = _CallIds(session_id='durable_key', turn_id='manual-next-turn', tool_call_id='next-synthetic-call')
assert 'error' in tool('xcreen_daily_note',{'entry_id':'spoof','fact':'Must fail.', 'source_ids':['ocr-a']})
session['running'] = False
manual = server._methods['xcreen.batch.context']('native-manual',{'session_id':'runtime-a','mode':'manual'})
assert manual.get('result',{}).get('mode') == 'manual', manual
session['running'] = True
assert 'error' in tool('xcreen_batch_result',{'outcome':'skipped','reason':'no_useful_fact','effect_ids':[]})
assert 'error' in tool('xcreen_daily_note',{'entry_id':'automatic-spoof','fact':'Must fail.', 'source_ids':['ocr-a']})
assert tool('xcreen_manual_daily_note',{'entry_id':'manual-fact','fact':'Synthetic explicit manual fact.', 'source_ids':['ocr-a']}).get('written')
session['running'] = False
server._sessions['history-a'] = {'history':[{'role':'assistant','content':[{'type':'text','text':'synthetic'},{'type':'image_url','image_url':{'url':'data:image/png;base64,'+'A'*200000}}]} for _ in range(45)]}
history = server._methods['xcreen.history.page']('host-history',{'session_id':'history-a','max_bytes':48000,'limit':20})
assert 'result' in history and history['result']['next_cursor'], history
assert len(json.dumps(history['result']).encode()) <= 48000
assert 'data:image' not in json.dumps(history)
cursor = history['result']['next_cursor']
server._sessions['history-a']['history'] = []  # compaction cannot change an existing cursor
page2 = server._methods['xcreen.history.page']('host-history-2',{'session_id':'history-a','cursor':cursor})
assert len(page2['result']['messages']) == 20, page2
server._sessions.pop('runtime-a')
(evidence/'index.json').unlink()
receipt = server._methods['xcreen.batch.receipt']('cold-recovery',params)
assert receipt.get('result',{}).get('verified'), receipt
print(json.dumps({'real_registry':True,'host_turn_context':True,'cold_reconcile_after_expiry':True,'terminal_receipt':True}), file=sys.__stdout__, flush=True)
# Avoid the host shutdown hook trying to finalize a synthetic agent.
server._sessions.clear()
