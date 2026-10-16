"""Process-local RPC extension using Hermes' actual register_method seam."""
from __future__ import annotations
from collections import OrderedDict
import json
import re
import threading
import uuid


def _clean(value, depth=0):
    if depth > 12:
        return '[nested content omitted]'
    if isinstance(value, str):
        if len(value) > 48000:
            return '[oversized content omitted]'
        # Tool results may themselves be encoded multimodal envelopes.
        if value.startswith(('{', '[')):
            try:
                return json.dumps(_clean(json.loads(value), depth+1), ensure_ascii=True)
            except (ValueError, RecursionError):
                pass
        return re.sub(r'data:image/[^\s\"\'<>\)]+', '[image omitted]', value, flags=re.IGNORECASE)
    if isinstance(value, list):
        return [_clean(v, depth+1) for v in value if not (isinstance(v,dict) and v.get('type') in ('image','image_url','input_image','image_file'))]
    if isinstance(value, dict):
        return {k:_clean(v,depth+1) for k,v in value.items() if k in ('role','content','text','type','id','row_id','timestamp','name','tool_call_id') and not str(k).startswith('image')}
    if value is None or isinstance(value,(bool,int,float)):
        return value
    return '[unsupported content omitted]'


class HistoryPager:
    def __init__(self):
        self.snapshots = OrderedDict()
        self.lock = threading.RLock()

    def page(self, sid, history, *, cursor=None, max_bytes=48000, limit=20):
        if type(limit) is not int or not 1 <= limit <= 20 or type(max_bytes) is not int or not 2000 <= max_bytes <= 48000:
            raise ValueError('invalid history bounds')
        with self.lock:
            if cursor is None:
                token, position = uuid.uuid4().hex, 0
                messages = []
                for message in history:
                    # Bound each raw message first; sanitize before retaining snapshot.
                    if len(json.dumps(message, ensure_ascii=True)) > 48000:
                        messages.append({'role':str(message.get('role','unknown'))[:32], 'content':'[oversized message omitted]', 'oversized':True})
                    else:
                        messages.append(_clean(message))
                self.snapshots[token] = (sid, messages)
                while len(self.snapshots) > 4:
                    self.snapshots.popitem(last=False)
            else:
                if not isinstance(cursor,str) or not re.fullmatch(r'[0-9a-f]{32}:[0-9]{1,10}',cursor):
                    raise ValueError('invalid history cursor')
                token, pos = cursor.split(':')
                position = int(pos)
                if token not in self.snapshots or self.snapshots[token][0] != sid:
                    raise ValueError('stale history cursor; request first page')
                messages = self.snapshots[token][1]
                if position > len(messages):
                    raise ValueError('invalid history cursor position')
            def envelope(rows, end):
                more = end < len(messages)
                return {'messages':rows, 'count':len(rows), 'has_more':more, 'next_cursor':f'{token}:{end}' if more else None}
            rows = []
            end = position
            while end < len(messages) and len(rows) < limit:
                item = messages[end]
                candidate = envelope(rows+[item], end+1)
                if len(json.dumps(candidate,ensure_ascii=True).encode()) > max_bytes:
                    if rows:
                        break
                    item = {'role':str(item.get('role','unknown'))[:32], 'content':'[oversized message omitted]', 'oversized':True}
                rows.append(item)
                end += 1
            return envelope(rows,end)


def register_xcreen_methods(service, *, server=None):
    if server is None:
        from tui_gateway import server
    pager = HistoryPager()
    def register(name, operation, *, live=True):
        def handler(rid, params):
            session = None
            if live:
                session, error = server._sess_nowait(params, rid)
                if error:
                    return error
            try:
                result = operation(params,session)
                if len(json.dumps(result,ensure_ascii=True).encode()) > 48000:
                    raise ValueError('RPC result exceeds byte bound')
                return server._ok(rid, result)
            except (ValueError,OSError,TypeError) as exc:
                return server._err(rid, -32602, str(exc)[:400])
        server.register_method(name,handler)
    def prepare(params, session):
        if session.get('running'):
            raise ValueError('batch context cannot change while a host turn is running')
        result = service.prepare(params)
        with service.mutex:
            service.host_revisions[params['session_id']] = (session, int(session.get('history_version',0)))
        return result
    def context(params, session):
        if session.get('running'):
            raise ValueError('batch context cannot change while a host turn is running')
        result = service.context(params)
        with service.mutex:
            service.host_revisions[params['session_id']] = (session, int(session.get('history_version',0)))
        return result
    register('xcreen.batch.prepare', prepare)
    register('xcreen.batch.context', context)
    register('xcreen.batch.receipt', lambda p,s:service.receipt(p), live=False)
    register('xcreen.batch.reconcile', lambda p,s:service.receipt(p), live=False)
    def history(params, session):
        raw = []
        if not params.get('cursor'):
            raw = list(session.get('history', []))
            row_session = server._submit_row_target_key(session)
            if row_session:
                with server._session_db(session) as db:
                    if db is not None:
                        raw = db.get_messages_as_conversation(row_session, include_ancestors=True, include_row_ids=True)
        return pager.page(params['session_id'], raw, cursor=params.get('cursor'), max_bytes=params.get('max_bytes',48000), limit=params.get('limit',20))
    register('xcreen.history.page',history)
    return pager


def host_tool_context(kwargs, receipts):
    """Read only host-injected dispatch identity, never model arguments.

    Installed Hermes sets approval observability inside model_tools._execute_tool.
    This narrow adapter fails closed if a host upgrade removes that context.
    """
    from tools import approval_context
    from tui_gateway import server
    actual = kwargs.get('session_id')
    turn = approval_context._approval_turn_id.get()
    if not actual or not turn:
        raise ValueError('missing host execution identity')
    with server._sessions_lock:
        candidates = [(sid,s) for sid,s in server._sessions.items()
                      if actual in (sid,s.get('session_key'),getattr(s.get('agent'),'session_id',None))]
    if len(candidates) != 1 or not candidates[0][1].get('running'):
        raise ValueError('host session unavailable or not running')
    sid, session = candidates[0]
    with receipts.mutex:
        revision = receipts.host_revisions.get(sid)
        if revision is None or revision[0] is not session or revision[1] != int(session.get('history_version',0)):
            raise ValueError('host turn history revision changed; fresh native context required')
    return sid, turn
