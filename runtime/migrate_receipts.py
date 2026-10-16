"""Explicit offline metadata-only migration. Never reads evidence or note bodies.

Run with the app stopped. Unknown schemas, sidecars and existing destinations fail
closed; retain every file for review rather than guess or discard pending effects.
"""
from __future__ import annotations
import argparse
from contextlib import closing
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys
import uuid


def _private_file(path):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) & 0o077):
        raise ValueError('unsafe migration metadata file')
    return info


def migrate(home, vault):
    home, vault = Path(home), Path(vault)
    for root in (home, vault):
        if not root.is_absolute() or not root.is_dir() or any(p.is_symlink() for p in (root,*root.parents)):
            raise ValueError('absolute non-symlink directories required')
    if home.stat().st_uid != os.getuid() or stat.S_IMODE(home.stat().st_mode) != 0o700:
        raise ValueError('private owned HERMES_HOME required')
    key = hashlib.sha256(str(vault.resolve()).encode()).hexdigest()[:20]
    legacy = home/f'xcreen-daily-{key}-receipts.sqlite3'
    backup = home/(legacy.name+'.pre-migration-backup')
    private = home/'xcreen-receipts'
    target = private/f'daily-{key}.sqlite3'
    lock = os.open(home/'vault-write.lock', os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_NONBLOCK, 0o600)
    try:
        _private_file(home/'vault-write.lock')
        fcntl.flock(lock,fcntl.LOCK_EX)
        if target.exists() or target.is_symlink() or backup.exists() or backup.is_symlink():
            raise ValueError('migration target/backup already exists; stop and review retained metadata, never delete ledgers')
        identity = _private_file(legacy)
        # Offline-only: no sidecar can be omitted from a backup or silently checkpointed.
        if any((Path(str(legacy)+s).exists() or Path(str(legacy)+s).is_symlink()) for s in ('-wal','-shm','-journal')):
            raise ValueError('legacy sidecars present; stop app and obtain reviewed SQLite checkpoint/backup before migration')
        fd = os.open(legacy,os.O_RDONLY|os.O_NOFOLLOW)
        try:
            with closing(sqlite3.connect(legacy.as_uri()+'?mode=ro',uri=True)) as source:
                source.execute('PRAGMA query_only=ON')
                objects = source.execute("SELECT type,name FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'").fetchall()
                columns = source.execute('PRAGMA table_info(entries)').fetchall()
                names = [r[1] for r in columns]
                base = ['id','day','digest','state','position']
                if objects != [('table','entries')] or names not in (base,base+['sources','batch']):
                    raise ValueError('unsupported legacy schema; reviewed metadata migration required, original untouched')
                if source.execute('PRAGMA integrity_check').fetchone() != ('ok',):
                    raise ValueError('legacy database integrity check failed')
                rows = source.execute('SELECT * FROM entries ORDER BY id').fetchall()
            upgraded = []
            for row in rows:
                eid,day,digest,state,position = row[:5]
                if (not isinstance(eid,str) or not re.fullmatch(r'(?:[0-9a-f]{20}|[0-9a-f]{64})',eid)
                        or not isinstance(day,str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}',day)
                        or not isinstance(digest,str) or not re.fullmatch(r'[0-9a-f]{64}',digest)
                        or state not in ('pending','completed','uncertain') or type(position) is not int or position < -1):
                    raise ValueError('unsupported legacy metadata values; original untouched')
                sources,batch = row[5:] if len(row)==7 else ('[]','manual')
                ids = json.loads(sources)
                if (not isinstance(ids,list) or len(ids)>8 or any(not isinstance(i,str) or not re.fullmatch(r'[A-Za-z0-9-]{1,100}',i) for i in ids)
                        or not isinstance(batch,str) or not re.fullmatch(r'[A-Za-z0-9-]{1,100}',batch)):
                    raise ValueError('unsupported legacy source metadata')
                upgraded.append((eid,day,digest,state,position,sources,batch))
            current = _private_file(legacy)
            if (current.st_dev,current.st_ino,current.st_size,current.st_mtime_ns) != (identity.st_dev,identity.st_ino,identity.st_size,identity.st_mtime_ns) or os.fstat(fd).st_ino != identity.st_ino:
                raise ValueError('legacy ledger changed during migration')
            private.mkdir(mode=0o700,exist_ok=True)
            if private.is_symlink() or private.stat().st_uid != os.getuid() or stat.S_IMODE(private.stat().st_mode)!=0o700:
                raise ValueError('unsafe migration destination directory')
            temporary = private/('migration-'+uuid.uuid4().hex+'.sqlite3')
            outfd=os.open(temporary,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600); os.close(outfd)
            try:
                with closing(sqlite3.connect(temporary)) as dest:
                    dest.execute("CREATE TABLE entries (id TEXT PRIMARY KEY, day TEXT NOT NULL, digest TEXT NOT NULL, state TEXT NOT NULL, position INTEGER NOT NULL DEFAULT -1, sources TEXT NOT NULL DEFAULT '[]', batch TEXT NOT NULL DEFAULT 'manual')")
                    dest.executemany('INSERT INTO entries VALUES (?,?,?,?,?,?,?)',upgraded)
                    dest.commit()
                    if dest.execute('SELECT * FROM entries ORDER BY id').fetchall()!=upgraded:
                        raise ValueError('migration readback mismatch')
                with temporary.open('rb') as out: os.fsync(out.fileno())
                # link is exclusive: never replace a destination created by another actor.
                os.link(temporary,target)
                temporary.unlink()
                directory=os.open(private,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
                try: os.fsync(directory)
                finally: os.close(directory)
                os.link(legacy,backup)
                legacy.unlink()
                os.fsync(lock)
                directory=os.open(home,os.O_RDONLY|os.O_DIRECTORY|os.O_NOFOLLOW)
                try: os.fsync(directory)
                finally: os.close(directory)
            finally:
                if temporary.exists(): temporary.unlink()
            return {'target':str(target),'backup':str(backup),'entries':len(upgraded),'note_writes':0}
        finally:
            os.close(fd)
    finally:
        os.close(lock)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--hermes-home',required=True)
    parser.add_argument('--vault',required=True)
    args=parser.parse_args()
    try:
        print(json.dumps(migrate(args.hermes_home,args.vault)))
    except (ValueError,OSError,sqlite3.Error) as exc:
        parser.exit(2,'Migration blocked: '+str(exc)+'\n')
