"""Host-only immutable batch membership and metadata result receipts.

No receipt authority derives from assistant prose or compactable history.
"""
from __future__ import annotations
import hashlib
import json
import re
import threading
from dataclasses import dataclass
from runtime.xcreen_tools import _safe_id, _utc, VaultDailyWriter


@dataclass(frozen=True)
class ActiveBatch:
    batch_id: str
    source_ids: tuple[str, ...]
    turn_id: str = ''


class BatchReceipts:
    def __init__(self, evidence, writer):
        self.evidence, self.writer = evidence, writer
        self.active = {}
        self.manual = {}
        self.host_revisions = {}
        self.mutex = threading.RLock()

    def _lock(self):
        if self.writer is None:
            raise ValueError('batch receipts require a configured vault')
        return self.writer._lock()

    def _db(self):
        if self.writer is None:
            raise ValueError('batch receipts require a configured vault')
        db = self.writer._receipts_db()
        db.execute("CREATE TABLE IF NOT EXISTS batches (id TEXT PRIMARY KEY, session TEXT NOT NULL, sources TEXT NOT NULL, manifest TEXT NOT NULL, terminal TEXT)")
        db.commit()
        return db

    @staticmethod
    def _sources(value):
        if not isinstance(value, list) or not 1 <= len(value) <= 2000:
            raise ValueError('bounded nonempty source_ids required')
        ids = tuple(sorted(_safe_id(v) for v in value))
        if len(ids) != len(set(ids)):
            raise ValueError('duplicate batch source')
        if len(json.dumps(ids,ensure_ascii=True).encode()) > 24000:
            raise ValueError('batch source metadata exceeds receipt byte bound')
        return ids

    def prepare(self, params):
        sid, bid = _safe_id(params.get('session_id')), _safe_id(params.get('batch_id'))
        sources = self._sources(params.get('source_ids'))
        with self.mutex, self._lock():
            # This path reads only the local persisted native batch and metadata.
            rows = [r.get('batch') for r in self.evidence._index().get('batches', []) if isinstance(r, dict)]
            matches = [b for b in rows if isinstance(b, dict) and b.get('id') == bid]
            if len(matches) != 1:
                raise ValueError('persisted batch missing or ambiguous')
            batch = matches[0]
            records = []
            for kind in ('images', 'ocr'):
                for item in batch.get(kind, []):
                    records.append({'id': _safe_id(item.get('id')), 'timestamp': item.get('timestamp'), 'kind': kind})
            if tuple(sorted(r['id'] for r in records)) != sources:
                raise ValueError('source membership does not match persisted batch')
            manifest = json.dumps({'sources':sorted(records, key=lambda r:r['id']), 'startedAt':batch.get('startedAt'), 'completedAt':batch.get('completedAt')}, sort_keys=True, separators=(',', ':'))
            encoded = json.dumps(sources, separators=(',', ':'))
            db = self._db()
            try:
                prior = db.execute('SELECT * FROM batches WHERE id=?', (bid,)).fetchone()
                if prior and (prior['sources'] != encoded or prior['manifest'] != manifest):
                    raise ValueError('conflicting immutable batch binding')
                if prior and prior['session'] != sid:
                    # Only a provably effect-free, non-terminal batch may move to a
                    # new runtime session for a native-authorized retry.
                    if prior['terminal'] or db.execute('SELECT 1 FROM entries WHERE batch=? LIMIT 1', (bid,)).fetchone():
                        raise ValueError('conflicting immutable batch binding')
                    db.execute('UPDATE batches SET session=? WHERE id=? AND terminal IS NULL', (sid, bid))
                    self.active.pop(prior['session'], None)
                db.execute('INSERT OR IGNORE INTO batches (id,session,sources,manifest) VALUES (?,?,?,?)', (bid,sid,encoded,manifest))
                effect_free = not (prior and prior['terminal']) and not db.execute('SELECT 1 FROM entries WHERE batch=? LIMIT 1', (bid,)).fetchone()
                db.commit()
                current = self.active.get(sid)
                # A finished, effect-free turn may not keep the pin: the native retry
                # turn needs a fresh one. Once effects exist the pin stays immutable.
                if current is None or current.batch_id != bid or (current.turn_id and effect_free):
                    self.active[sid] = ActiveBatch(bid, sources)
                self.manual.pop(sid, None)
            finally:
                db.close()
        return dict(batch_id=bid, source_ids=list(sources), session_id=sid, prepared=True)

    def context(self, params):
        sid = _safe_id(params.get('session_id'))
        with self.mutex:
            if params.get('mode') == 'manual':
                self.active.pop(sid, None)
                self.manual[sid] = ''
                return {'session_id': sid, 'mode':'manual'}
            return self.prepare(params)

    def _bound(self, sid, turn):
        if not sid or not turn:
            raise ValueError('host session and turn context required')
        context = self.active.get(sid)
        if context is None or (context.turn_id and context.turn_id != turn):
            raise ValueError('no active batch for this host session/turn')
        if not context.turn_id:
            context = ActiveBatch(context.batch_id, context.source_ids, turn)
            self.active[sid] = context
        return context

    def append_manual(self, args, sid, turn):
        if not isinstance(args, dict) or set(args) - {'entry_id','fact','source_ids'}:
            raise ValueError('manual writer denies batch/day spoofing')
        _safe_id(args.get('entry_id'))
        with self.mutex:
            if not turn or sid not in self.manual or self.manual[sid] not in ('', turn) or sid in self.active:
                raise ValueError('explicit manual host context required')
            self.manual[sid] = turn
            return self.writer.append(dict(args, batch_id='manual-' + hashlib.sha256((sid+turn).encode()).hexdigest()[:32]))

    def append(self, args, sid, turn):
        if not isinstance(args, dict) or set(args) - {'entry_id','fact','source_ids'}:
            raise ValueError('model cannot select batch identity or capture day')
        _safe_id(args.get('entry_id'))
        with self.mutex:
            context = self._bound(sid, turn)
            if not set(args.get('source_ids', [])).issubset(context.source_ids):
                raise ValueError('source outside active batch')
            with self._lock():
                db = self._db()
                try:
                    row = db.execute('SELECT manifest FROM batches WHERE id=?', (context.batch_id,)).fetchone()
                    if row is None:
                        raise ValueError('batch reservation missing')
                    expected = {r['id']:{'id':r['id'],'timestamp':_utc(r['timestamp']),'kind':r['kind']} for r in json.loads(row['manifest'])['sources']}
                finally:
                    db.close()
            return self.writer.append(dict(args, batch_id=context.batch_id), expected_sources=expected)

    def _verify(self, db, bid):
        effects = []
        for row in db.execute('SELECT * FROM entries WHERE batch=? ORDER BY id', (bid,)).fetchall():
            valid = False
            try:
                with self.writer._daily_note(row['day'], create=False) as fd:
                    text = self.writer._read_note(fd)
                    matches = list(re.finditer(rf"<!-- xcreen-entry:{row['id']} digest:([0-9a-f]{{64}}) -->\n(.*?)<!-- /xcreen-entry:{row['id']} -->", text, re.DOTALL))
                    valid = (len(matches) == 1 and matches[0][1] == row['digest']
                             and hashlib.sha256(matches[0][2].encode()).hexdigest() == row['digest'])
                    self.writer._verify_note(fd, row['day'])
            except (OSError, ValueError, UnicodeError):
                valid = False
            state = 'completed' if valid else 'uncertain'
            db.execute('UPDATE entries SET state=? WHERE id=?', (state,row['id']))
            effects.append({'entry_id':row['id'], 'day':row['day'], 'digest':row['digest'], 'state':state})
        db.commit()
        return effects

    def result(self, args, sid, turn):
        if not isinstance(args, dict) or set(args) - {'outcome','effect_ids','reason'}:
            raise ValueError('unsupported result fields; batch identity is host-owned')
        with self.mutex:
            context = self._bound(sid, turn)
            outcome, ids = args.get('outcome'), args.get('effect_ids')
            if not isinstance(ids, list) or len(ids) != len(set(ids)) or len(ids) > 100:
                raise ValueError('exact bounded effect_ids required')
            if outcome == 'skipped':
                if args.get('reason') != 'no_useful_fact' or ids:
                    raise ValueError('skipped requires no_useful_fact and zero effects')
            elif outcome != 'saved' or not ids or args.get('reason') not in (None, ''):
                raise ValueError('saved requires nonempty exact effect IDs')
            with self._lock():
                db = self._db()
                try:
                    effects = self._verify(db, context.batch_id)
                    if (set(ids) != {e['entry_id'] for e in effects}
                            or any(e['state'] != 'completed' for e in effects)):
                        raise ValueError('result does not match exact reconciled effects')
                    result = dict(batch_id=context.batch_id, session_id=sid, source_ids=list(context.source_ids),
                                  status=outcome, verified=True, effects=effects, reason=args.get('reason') or None)
                    if len(json.dumps(result,ensure_ascii=True).encode()) > 48000:
                        raise ValueError('terminal receipt exceeds byte bound')
                    encoded = json.dumps(result, sort_keys=True, separators=(',', ':'))
                    prior = db.execute('SELECT terminal FROM batches WHERE id=?', (context.batch_id,)).fetchone()
                    if prior is None:
                        raise ValueError('batch reservation missing')
                    if prior['terminal'] and prior['terminal'] != encoded:
                        raise ValueError('immutable terminal receipt conflict')
                    db.execute('UPDATE batches SET terminal=? WHERE id=? AND terminal IS NULL', (encoded,context.batch_id))
                    db.commit()
                    actual = db.execute('SELECT terminal FROM batches WHERE id=?', (context.batch_id,)).fetchone()
                    if actual['terminal'] != encoded:
                        raise ValueError('terminal receipt readback failed')
                    return result
                finally:
                    db.close()

    def receipt(self, params):
        sid, bid = _safe_id(params.get('session_id')), _safe_id(params.get('batch_id'))
        sources = self._sources(params.get('source_ids'))
        with self.mutex, self._lock():
            db = self._db()
            try:
                row = db.execute('SELECT * FROM batches WHERE id=?', (bid,)).fetchone()
                if row is None:
                    return dict(batch_id=bid, session_id=sid, source_ids=list(sources), status='missing', verified=False, effects=[])
                if row['session'] != sid or tuple(json.loads(row['sources'])) != sources:
                    raise ValueError('receipt binding mismatch')
                effects = self._verify(db, bid)
                if not row['terminal']:
                    return dict(batch_id=bid, session_id=sid, source_ids=list(sources), status='uncertain', verified=False, effects=effects, retry_safe=not effects)
                result = dict(json.loads(row['terminal']), session_id=sid)
                if effects != result['effects'] or any(e['state'] != 'completed' for e in effects):
                    return dict(result, status='uncertain', verified=False, effects=effects)
                return result
            finally:
                db.close()
