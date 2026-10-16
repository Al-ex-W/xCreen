"""Test-only real installed stdio server with synthetic session; never inference.
Not packaged in the application. No stock RPC or tool handler is replaced.
"""
import os
from pathlib import Path
import sys
sys.dont_write_bytecode=True
hermes, project, work = map(Path,sys.argv[1:4])
os.environ['HERMES_DISABLE_LAZY_INSTALLS']='1'
os.environ['HERMES_TUI_SKIP_MCP']='1'
os.environ['HERMES_TUI_TOOLSETS']='xcreen'
sys.path[:0]=[str(hermes),str(project)]
# Activate installed dependencies read-only before selecting the synthetic home;
# selecting it first asks new Hermes PM versions to build a second installation.
import hermes_bootstrap
os.environ['HERMES_HOME']=str(work/'home')
import json
import threading
from datetime import datetime,timezone
from types import SimpleNamespace
from tui_gateway import server
from tools.registry import registry
from runtime.xcreen_tools import EvidenceReader,VaultDailyWriter,register_xcreen_tools
from runtime.xcreen_receipts import BatchReceipts
from runtime.xcreen_rpc import register_xcreen_methods
from model_tools import _execute_tool,_CallIds

source={'id':'ocr-a','timestamp':datetime.now(timezone.utc).isoformat(),'text':'Synthetic useful fact only.'}
evidence=work/'evidence'; (evidence/'images').mkdir(parents=True)
(evidence/'index.json').write_text(json.dumps({'ocr':[source],'images':[],'batches':[{'batch':{'id':'batch-a','ocr':[source],'images':[]}}]}))
vault=work/'vault'; (vault/'Daily').mkdir(parents=True)
reader=EvidenceReader(evidence); writer=VaultDailyWriter(vault,reader)
receipts=BatchReceipts(reader,writer)
register_xcreen_tools(reader,writer,registry=registry,receipts=receipts)
register_xcreen_methods(receipts,server=server)
session={'session_key':'synthetic-durable','running':False,'history':[], 'history_lock':threading.RLock(),'agent':SimpleNamespace(session_id='synthetic-durable')}
server._sessions['synthetic-runtime']=session
params={'session_id':'synthetic-runtime','batch_id':'batch-a','source_ids':['ocr-a']}
assert server._methods['xcreen.batch.prepare']('fixture',params)['result']['prepared']
session['running']=True
ids=_CallIds(session_id='synthetic-durable',turn_id='synthetic-turn',tool_call_id='synthetic-call')
def tool(name,args):
    return json.loads(_execute_tool(name,args,args,ids,user_task='synthetic',enabled_tools=[name],skip_tool_execution_middleware=True))
effect=tool('xcreen_daily_note',{'entry_id':'semantic-a','fact':'Synthetic useful fact.','source_ids':['ocr-a']})
assert effect['written'],effect
assert tool('xcreen_batch_result',{'outcome':'saved','effect_ids':[effect['entry_id']]})['verified']
session['running']=False
session['history']=[{'role':'assistant','content':'synthetic-'+str(i)+'x'*12000} for i in range(90)]
# No database-backed agent row: host pager uses this synthetic in-memory history.
session['session_key']=''
session['agent']=None
from tui_gateway.entry import main
try:
    main()
finally:
    server._sessions.clear()
