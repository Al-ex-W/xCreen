"""Confined, read-only evidence tools and the bounded xCreen daily-note writer."""
from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import mimetypes
import os
import re
import sqlite3
import stat
import unicodedata
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit, unquote
from zoneinfo import ZoneInfo

_APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
_TTL = timedelta(days=7)
_ID = re.compile(r"^[A-Za-z0-9-]{1,100}$")
_MAX_QUERY = 512
_MAX_TEXT = 4_000
_MAX_RESULTS = 20
_MAX_IMAGE_BYTES = 8 * 1024 * 1024
_MAX_FACT = 2_000


def _utc(value: object) -> datetime:
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return _APPLE_EPOCH + timedelta(seconds=float(value))
    if isinstance(value, str):
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.replace(tzinfo=parsed.tzinfo or timezone.utc).astimezone(timezone.utc)
    raise ValueError("invalid evidence timestamp")


def _stamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _safe_id(value: object) -> str:
    if not isinstance(value, str) or not _ID.fullmatch(value):
        raise ValueError("invalid evidence id")
    return value


class EvidenceReader:
    """Reads the Swift EvidenceStore index without exposing paths or stale data."""

    def __init__(self, root: str | Path, *, now=None):
        self.root = Path(root)
        self._now = now or (lambda: datetime.now(timezone.utc))
        self._validate_root()

    def _validate_root(self) -> None:
        if not self.root.is_absolute() or self.root.is_symlink() or not self.root.is_dir():
            raise ValueError("unsafe evidence root")
        self.root = self.root.resolve(strict=True)
        images = self.root / "images"
        if not images.is_dir() or images.is_symlink():
            raise ValueError("unsafe evidence images directory")

    def _index(self) -> dict:
        path = self.root / "index.json"
        if path.is_symlink() or not path.is_file():
            raise ValueError("unsafe evidence index")
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise ValueError("unreadable evidence index") from exc
        if not isinstance(data, dict):
            raise ValueError("invalid evidence index")
        return data

    def _fresh(self, record: dict) -> bool:
        try:
            return _utc(record.get("timestamp")) >= self._now().astimezone(timezone.utc) - _TTL
        except (TypeError, ValueError, OverflowError):
            return False

    def _records(self, name: str) -> list[dict]:
        records = self._index().get(name, [])
        return [item for item in records if isinstance(item, dict) and self._fresh(item)] if isinstance(records, list) else []

    def _ocr_row(self, record: dict) -> dict:
        text = str(record.get("text", ""))[:_MAX_TEXT]
        return {"id": _safe_id(record.get("id")), "timestamp": _stamp(_utc(record["timestamp"])),
                "timestamp_local": _utc(record["timestamp"]).astimezone().isoformat(timespec="seconds"),
                "text_truncated": len(str(record.get("text", ""))) > _MAX_TEXT,
                "text": text, "app": str(record.get("app", ""))[:256], "title": str(record.get("title", ""))[:512]}

    def search_ocr(self, query: object, limit: object = _MAX_RESULTS) -> list[dict]:
        if not isinstance(query, str) or not query.strip() or len(query) > _MAX_QUERY:
            raise ValueError("query must be non-empty and bounded")
        if not isinstance(limit, int) or isinstance(limit, bool):
            raise ValueError("limit must be an integer")
        normalize = lambda text: unicodedata.normalize("NFKC", text).casefold()
        terms = normalize(query).split()[:8]
        rows = []
        for record in self._records("ocr"):
            try:
                row = self._ocr_row(record)
            except (KeyError, ValueError, TypeError, OverflowError):
                continue
            full_text = str(record.get("text", ""))[:12_000]
            if all(term in normalize(full_text + " " + str(record.get("app", ""))[:256] + " " + str(record.get("title", ""))[:1024]) for term in terms):
                # Keep a bounded original-text window near a match, not just the first page.
                position = next((i for i in range(0, len(full_text), 1000) if any(term in normalize(full_text[i:i + 2000]) for term in terms)), 0)
                row["text"] = full_text[max(0, position - 500):max(0, position - 500) + _MAX_TEXT]
                row["text_truncated"] = len(full_text) > len(row["text"])
                rows.append(row)
        return sorted(rows, key=lambda row: row["timestamp"], reverse=True)[:max(0, min(limit, _MAX_RESULTS))]

    def coverage(self) -> dict:
        def latest(kind):
            stamps = [_utc(r["timestamp"]) for r in self._records(kind)]
            if not stamps:
                return None
            value = max(stamps)
            return {"utc": _stamp(value), "local": value.astimezone().isoformat(timespec="seconds")}
        path = self.root / "capture-status.json"
        state = {}
        if path.is_file() and not path.is_symlink() and path.stat().st_size <= 16_000:
            try:
                value = json.loads(path.read_text())
                if isinstance(value, dict):
                    state = value
            except (ValueError, OSError):
                pass
        return {"latest_ocr": latest("ocr"), "latest_image": latest("images"),
                "desired_integrity": state.get("desired_integrity", "unknown"),
                "capture_state": state.get("capture", "unknown"), "capture_reason": state.get("capture_reason", "unknown"),
                "capture_status_timestamp": state.get("updated"), "excluded": "Known credential/security apps, System Settings and xCreen are excluded. Browsers are eligible; browser password fields, extensions and private windows are not detected or redacted.",
                "retention_days": 7, "limitations": "Sparse retained snapshots, not continuous coverage. No match is not proof something was never seen. Pauses, exclusions, deduplication and expiry leave gaps; status is a timestamped observation, not live proof."}

    def recent_ocr(self, limit: object = _MAX_RESULTS, start=None, end=None) -> dict:
        if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= _MAX_RESULTS:
            raise ValueError("limit must be between 1 and 20")
        lower, upper = _utc(start) if start is not None else None, _utc(end) if end is not None else None
        if lower is not None and upper is not None and lower > upper:
            raise ValueError("start must not follow end")
        rows = []
        for record in self._records("ocr"):
            try:
                stamp = _utc(record["timestamp"])
                if (lower is None or stamp >= lower) and (upper is None or stamp <= upper):
                    row = self._ocr_row(record)
                    row["timestamp_local"] = stamp.astimezone().isoformat(timespec="seconds")
                    rows.append(row)
            except (KeyError, ValueError, TypeError, OverflowError):
                continue
        rows.sort(key=lambda r: r["timestamp"], reverse=True)
        return {"rows": rows[:limit], "has_more": len(rows) > limit, "coverage": self.coverage()}

    def images_near(self, timestamp: object, seconds: object = 30) -> list[dict]:
        target = _utc(timestamp)
        if not isinstance(seconds, (int, float)) or isinstance(seconds, bool) or not 0 <= seconds <= 86_400:
            raise ValueError("seconds must be between 0 and 86400")
        rows = []
        for record in self._records("images"):
            try:
                stamp = _utc(record["timestamp"])
                if abs((stamp - target).total_seconds()) <= seconds:
                    rows.append({"id": _safe_id(record["id"]), "timestamp": _stamp(stamp)})
            except (KeyError, ValueError, TypeError, OverflowError):
                continue
        return sorted(rows, key=lambda row: row["timestamp"])[:_MAX_RESULTS]

    def _image_record(self, image_id: object) -> dict:
        image_id = _safe_id(image_id)
        for record in self._records("images"):
            if record.get("id") == image_id:
                return record
        raise ValueError("image is unavailable or expired")

    def _image_path(self, record: dict) -> Path:
        raw = record.get("fileURL")
        if not isinstance(raw, str) or not raw:
            raise ValueError("invalid image record")
        images = (self.root / "images").resolve(strict=True)
        if raw.startswith("file:"):
            url = urlsplit(raw)
            if url.scheme != "file" or url.netloc or "?" in raw or "#" in raw or re.search(r"%(?![0-9a-fA-F]{2})", raw):
                raise ValueError("unsafe image URL")
            raw = unquote(url.path, errors="strict")
        if "\x00" in raw or "\\" in raw or any(part in {".", ".."} for part in raw.split("/")):
            raise ValueError("unsafe image path")
        path = Path(raw)
        if not path.is_absolute() or any(parent.is_symlink() for parent in path.parents) or path.is_symlink() or not path.is_file():
            raise ValueError("unsafe image path")
        resolved = path.resolve(strict=True)
        if resolved.parent != images or resolved.is_symlink():
            raise ValueError("image is outside evidence store")
        return resolved

    def view_image(self, image_id: object) -> dict:
        record = self._image_record(image_id)
        path = self._image_path(record)
        data = path.read_bytes()
        if not data or len(data) > _MAX_IMAGE_BYTES:
            raise ValueError("image is empty or exceeds tool limit")
        mime, _ = mimetypes.guess_type(path.name)
        mime = mime if mime in {"image/png", "image/jpeg", "image/gif", "image/webp"} else "image/png"
        data_url = "data:%s;base64,%s" % (mime, base64.b64encode(data).decode("ascii"))
        stamp = _stamp(_utc(record["timestamp"]))
        return {"_multimodal": True,
                "content": [{"type": "text", "text": f"xCreen evidence image {record['id']} captured {stamp}."},
                            {"type": "image_url", "image_url": {"url": data_url}}],
                "text_summary": f"xCreen evidence image {record['id']} attached ({stamp}).",
                "meta": {"image_id": record["id"], "timestamp": stamp, "native_vision": True}}

    def source(self, source_id: object) -> dict:
        source_id = _safe_id(source_id)
        for kind in ("ocr", "images"):
            for record in self._records(kind):
                if record.get("id") == source_id:
                    return {"id": source_id, "timestamp": _utc(record["timestamp"]), "kind": kind}
        raise ValueError("source is unavailable or expired")


class _PinnedDB:
    """Retain directory + inode through SQLite use; same-UID tampering is out of scope."""
    def __init__(self, path: Path):
        self.path = path
        self.directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        self.fd = None
        self.db = None
        try:
            self._directory_identity = os.fstat(self.directory)
            self._check_directory()
            self.fd = os.open(path.name, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=self.directory)
            self.identity = os.fstat(self.fd)
            self._check()
            os.fsync(self.directory)
            # SQLite must reopen a filename; retain both descriptors and check identity
            # around every operation. Private directory excludes other-UID rename races.
            self.db = sqlite3.connect(str(path))
            self.db.row_factory = sqlite3.Row
            self._check()
            self.execute('PRAGMA journal_mode=DELETE')
            self.execute('PRAGMA synchronous=FULL')
        except BaseException:
            self.close()
            raise

    def _check_directory(self):
        current = os.stat(self.path.parent, follow_symlinks=False)
        info = self._directory_identity
        if (not stat.S_ISDIR(current.st_mode) or current.st_uid != os.getuid()
                or stat.S_IMODE(current.st_mode) != 0o700
                or (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino)):
            raise ValueError('unsafe receipt directory')

    def _check(self):
        self._check_directory()
        for suffix in ('', '-journal', '-wal', '-shm'):
            try:
                info = os.stat(self.path.name + suffix, dir_fd=self.directory, follow_symlinks=False)
            except FileNotFoundError:
                if suffix:
                    continue
                raise ValueError('receipt database was replaced')
            if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid()
                    or stat.S_IMODE(info.st_mode) & 0o077):
                raise ValueError('unsafe receipt database or sidecar')
            if not suffix and (info.st_dev, info.st_ino) != (self.identity.st_dev, self.identity.st_ino):
                raise ValueError('receipt database was replaced')
        assert self.fd is not None
        retained = os.fstat(self.fd)
        if retained.st_nlink != 1:
            raise ValueError('receipt database was replaced or hardlinked')

    def execute(self, *args):
        self._check()
        assert self.db is not None
        result = self.db.execute(*args)
        self._check()
        return result

    def commit(self):
        self._check()
        assert self.db is not None
        self.db.commit()
        self._check()

    def close(self):
        if self.db is not None:
            self.db.close()
            self.db = None
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None
        if self.directory is not None:
            os.close(self.directory)
            self.directory = None


class VaultDailyWriter:
    """Locked, source-bound append-only effects in the existing Daily convention."""

    def __init__(self, vault: str | Path, evidence: EvidenceReader, *, hermes_home: str | Path | None = None,
                 timezone_name: str = "Europe/Stockholm"):
        self.vault = Path(vault)
        self.evidence = evidence
        self.hermes_home = Path(hermes_home or os.environ.get("HERMES_HOME", ""))
        self.timezone = ZoneInfo(timezone_name)
        if not self.vault.is_absolute() or self.vault.is_symlink() or not self.vault.is_dir():
            raise ValueError("unsafe vault path")
        if not self.hermes_home.is_absolute() or self.hermes_home.is_symlink() or not self.hermes_home.is_dir():
            raise ValueError("HERMES_HOME is required for vault locking")
        if any(p.is_symlink() for root in (self.vault, self.hermes_home) for p in (root, *root.parents)):
            raise ValueError("symlink ancestor is not allowed")
        self.vault = self.vault.resolve(strict=True)
        self.hermes_home = self.hermes_home.resolve(strict=True)
        vault_key = hashlib.sha256(str(self.vault).encode()).hexdigest()[:20]
        legacy = self.hermes_home / f"xcreen-daily-{vault_key}-receipts.sqlite3"
        if legacy.exists() or legacy.is_symlink():
            raise ValueError('legacy receipt ledger blocks writing; stop xCreen, then run: python3 /Applications/xCreen.app/Contents/Resources/runtime/migrate_receipts.py --hermes-home HERMES_HOME --vault VAULT; see docs/runtime-receipts.md; never delete the legacy ledger')
        private = self.hermes_home / 'xcreen-receipts'
        try:
            private.mkdir(mode=0o700)
        except FileExistsError:
            pass
        with self._directory(self.hermes_home) as parent:
            os.fsync(parent)
        with self._directory(private) as fd:
            info = os.fstat(fd)
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise ValueError('unsafe receipt directory')
        self.receipts_path = private / f"daily-{vault_key}.sqlite3"

    def _receipts_db(self):
        db = _PinnedDB(self.receipts_path)
        try:
            db.execute("CREATE TABLE IF NOT EXISTS entries (id TEXT PRIMARY KEY, day TEXT NOT NULL, digest TEXT NOT NULL, state TEXT NOT NULL, position INTEGER NOT NULL DEFAULT -1, sources TEXT NOT NULL DEFAULT '[]', batch TEXT NOT NULL DEFAULT 'manual')")
            columns = {r['name'] for r in db.execute('PRAGMA table_info(entries)')}
            if 'sources' not in columns:
                db.execute("ALTER TABLE entries ADD COLUMN sources TEXT NOT NULL DEFAULT '[]'")
            if 'batch' not in columns:
                db.execute("ALTER TABLE entries ADD COLUMN batch TEXT NOT NULL DEFAULT 'manual'")
            db.commit()
            return db
        except BaseException:
            db.close()
            raise

    def receipts(self, *, after: str = "", limit: int = 20) -> list[dict]:
        """Bounded metadata only; no facts, OCR or image bytes in the ledger."""
        if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
            raise ValueError("invalid receipt limit")
        with self._lock():
            db = self._receipts_db()
            try:
                return [dict(r) for r in db.execute("SELECT * FROM entries WHERE id > ? ORDER BY id LIMIT ?", (after, limit))]
            finally:
                db.close()

    def reconcile(self, *, after: str = "", limit: int = 20) -> list[dict]:
        """Recover effects from note evidence, independently of OCR retention/host context.

        Does not submit inference, append facts or create a missing daily note.
        Caller advances `after` to the last returned ID until the page is short.
        """
        if not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 100:
            raise ValueError("invalid receipt limit")
        with self._lock():
            db = self._receipts_db()
            try:
                rows = [dict(r) for r in db.execute("SELECT * FROM entries WHERE id > ? ORDER BY id LIMIT ?", (after, limit))]
                for row in rows:
                    try:
                        with self._daily_note(row["day"], create=False) as fd:
                            text = self._read_note(fd)
                        pattern = rf"<!-- xcreen-entry:{row['id']} digest:([0-9a-f]{{64}}) -->\n(.*?)<!-- /xcreen-entry:{row['id']} -->"
                        matches = list(re.finditer(pattern, text, re.DOTALL))
                        valid = len(matches) == 1 and matches[0][1] == row["digest"] and hashlib.sha256(matches[0][2].encode()).hexdigest() == row["digest"]
                        if valid:
                            row["state"] = "completed"
                        elif row["id"] in text or row["state"] != "pending" or row["position"] != len(text.encode()):
                            row["state"] = "uncertain"
                    except (OSError, ValueError, UnicodeError):
                        row["state"] = "uncertain"
                    db.execute("UPDATE entries SET state = ? WHERE id = ?", (row["state"], row["id"]))
                db.commit()
                return rows
            finally:
                db.close()

    def _read_conventions(self) -> None:
        # Fixed authorization boundary, not executable template/rule evaluation.
        # Only the two established Agent convention files are inspected, bounded;
        # no entity notes, daily index contents or unrelated personal documents.
        agent = self.vault / "Agent"
        if not agent.exists():
            return  # Synthetic/minimal vaults need no personal convention fixture.
        with self._directory(agent) as directory:
            for name in ("Operating Rules.md", "Connections.md"):
                try:
                    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
                except FileNotFoundError:
                    continue
                try:
                    if not stat.S_ISREG(os.fstat(fd).st_mode):
                        raise ValueError("unsafe vault conventions")
                    os.read(fd, 16_000)
                finally:
                    os.close(fd)

    @staticmethod
    @contextmanager
    def _directory(path: Path):
        """Walk from / using no-follow directory FDs, including ancestor components."""
        fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in path.parts[1:]:
                if part in {".", ".."}:
                    raise ValueError("unsafe directory component")
                next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = next_fd
            yield fd
        finally:
            os.close(fd)

    @contextmanager
    def _daily_note(self, day: str, *, create: bool = True, writable: bool = False):
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", day):
            raise ValueError("unsafe capture day")
        if not (self.vault / "Daily").is_dir() or (self.vault / "Daily").is_symlink():
            raise ValueError("existing Daily directory is required (no new vault structure is created)")
        with self._directory(self.vault / "Daily") as directory:
            filename = f"{day}.md"
            flags = os.O_RDWR | os.O_APPEND | os.O_NOFOLLOW | os.O_NONBLOCK
            try:
                if create:
                    fd = os.open(filename, flags | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=directory)
                    created = True
                else:
                    fd = os.open(filename, flags if writable else os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
                    created = False
            except FileExistsError:
                fd = os.open(filename, flags, dir_fd=directory)
                created = False
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError("daily note must be a regular, non-hardlinked file")
                if created:
                    self._append_bytes(fd, f"# {day}\n".encode())
                    os.fsync(directory)
                yield fd
                current = os.stat(filename, dir_fd=directory, follow_symlinks=False)
                if (current.st_dev, current.st_ino) != (info.st_dev, info.st_ino) or current.st_nlink != 1:
                    raise ValueError("daily note was replaced during readback; reconciliation required")
            finally:
                os.close(fd)

    def _verify_note(self, fd: int, day: str) -> None:
        retained = os.fstat(fd)
        with self._directory(self.vault / "Daily") as directory:
            current = os.stat(f"{day}.md", dir_fd=directory, follow_symlinks=False)
        if (not stat.S_ISREG(current.st_mode) or retained.st_nlink != 1 or current.st_nlink != 1
                or (current.st_dev, current.st_ino) != (retained.st_dev, retained.st_ino)):
            raise ValueError("daily note was replaced during readback; reconciliation required")

    @staticmethod
    def _append_bytes(fd: int, data: bytes):
        view = memoryview(data)
        while view:
            written = os.write(fd, view)
            if written <= 0:
                raise OSError("incomplete daily append")
            view = view[written:]
        os.fsync(fd)

    @staticmethod
    def _read_note(fd: int) -> str:
        if os.fstat(fd).st_size > 2_000_000:
            raise ValueError("daily note exceeds safe read bound")
        os.lseek(fd, 0, os.SEEK_SET)
        data = bytearray()
        while chunk := os.read(fd, min(65_536, 2_000_001 - len(data))):
            data.extend(chunk)
            if len(data) > 2_000_000:
                raise ValueError("daily note exceeds safe read bound")
        return data.decode("utf-8")

    @contextmanager
    def _lock(self):
        with self._directory(self.hermes_home) as directory:
            fd = os.open("vault-write.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=directory)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
                    raise ValueError("unsafe vault lock")
                fcntl.flock(fd, fcntl.LOCK_EX)
                try:
                    yield
                finally:
                    fcntl.flock(fd, fcntl.LOCK_UN)
            finally:
                os.close(fd)

    @contextmanager
    def _write_boundary(self, day: str, sources: list[dict], marker: str, digest: str, batch_id: str):
        with self._lock():
            self._read_conventions()
            if [self.evidence.source(item['id']) for item in sources] != sources:
                raise ValueError('source changed at write boundary')
            db = self._receipts_db()
            try:
                prior = db.execute('SELECT * FROM entries WHERE id=?', (marker,)).fetchone()
                if prior and (prior['day'] != day or prior['digest'] != digest or prior['batch'] != batch_id
                              or prior['sources'] != json.dumps(sorted(s['id'] for s in sources),separators=(',', ':'))):
                    raise ValueError('conflicting retry: immutable day, sources or payload changed')
                if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='batches'").fetchone():
                    batch = db.execute('SELECT terminal FROM batches WHERE id=?',(batch_id,)).fetchone()
                    if batch and batch['terminal']:
                        raise ValueError('batch already has an immutable terminal receipt')
            finally:
                db.close()
            try:
                with self._daily_note(day, create=prior is None, writable=True) as note:
                    yield note
            except (ValueError, OSError) as exc:
                if isinstance(exc, FileNotFoundError) or 'replaced' in str(exc):
                    db = self._receipts_db()
                    try:
                        db.execute("UPDATE entries SET state='uncertain' WHERE id=?", (marker,))
                        db.commit()
                    finally:
                        db.close()
                raise

    def append(self, args: dict, *, expected_sources: dict | None = None) -> dict:
        fact = args.get("fact", "") if isinstance(args, dict) else ""
        source_ids = args.get("source_ids", []) if isinstance(args, dict) else []
        if not isinstance(fact, str) or not fact.strip():
            return {"written": False, "reason": "no_useful_fact"}
        if len(fact) > _MAX_FACT or not isinstance(source_ids, list) or not 1 <= len(source_ids) <= 8:
            raise ValueError("bounded fact and source_ids are required")
        if any(token in fact.casefold() for token in ("<!--", "-->", "xcreen-entry:", "xcreen-sources:", "xcreen:")) or any(ord(c) < 32 and c not in "\n\r\t" for c in fact):
            raise ValueError("fact contains reserved markup or control characters")
        sources = [self.evidence.source(item) for item in source_ids]
        if expected_sources is not None and any(expected_sources.get(item['id']) != item for item in sources):
            raise ValueError('source metadata differs from immutable batch manifest')
        if len({item["id"] for item in sources}) != len(sources):
            raise ValueError("duplicate source id")
        days = {item["timestamp"].astimezone(self.timezone).date().isoformat() for item in sources}
        if len(days) != 1:
            raise ValueError("sources must belong to one capture day")
        day = next(iter(days))
        normalized = " ".join(fact.split())
        batch_id = _safe_id(args.get("batch_id", "manual"))
        entry_id = _safe_id(args.get("entry_id", "fact"))
        # Explicit batch/entry identities survive paraphrase and source reselection.
        # Legacy calls without IDs conservatively permit one effect per source set.
        identity_parts: list[object] = [str(self.vault), batch_id, entry_id]
        if "entry_id" not in args:
            identity_parts.append(sorted(source_ids))
        identity = json.dumps(identity_parts, separators=(",", ":"))
        marker = hashlib.sha256(identity.encode()).hexdigest()
        stamps = ", ".join(f"{item['id']}@{_stamp(item['timestamp'])}" for item in sorted(sources, key=lambda s: s["id"]))
        body = f"- {normalized}\n  <!-- xcreen-sources: {', '.join(sorted(source_ids))}; captured-utc: {stamps} -->\n"
        digest = hashlib.sha256(body.encode()).hexdigest()
        entry = f"\n<!-- xcreen-entry:{marker} digest:{digest} -->\n{body}<!-- /xcreen-entry:{marker} -->\n"
        with self._write_boundary(day, sources, marker, digest, batch_id) as note:
            db = self._receipts_db()
            try:
                if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='batches'").fetchone():
                    terminal = db.execute('SELECT terminal FROM batches WHERE id=?', (batch_id,)).fetchone()
                    if terminal and terminal['terminal']:
                        raise ValueError('batch already has an immutable terminal receipt')
                existing = self._read_note(note)
                pattern = rf"<!-- xcreen-entry:{marker} digest:([0-9a-f]{{64}}) -->\n(.*?)<!-- /xcreen-entry:{marker} -->"
                matches = list(re.finditer(pattern, existing, re.DOTALL))
                prior = db.execute("SELECT * FROM entries WHERE id = ?", (marker,)).fetchone()
                frozen_sources = json.dumps(sorted(source_ids), separators=(',', ':'))
                if prior and (prior['day'] != day or prior['digest'] != digest
                              or prior['sources'] != frozen_sources or prior['batch'] != batch_id):
                    raise ValueError('conflicting retry: immutable day, sources or payload changed')
                if len(matches) == 1 and hashlib.sha256(matches[0][2].encode()).hexdigest() == matches[0][1] and matches[0][1] == digest and (prior is None or prior["digest"] == matches[0][1]):
                    self._verify_note(note, day)
                    db.execute("INSERT OR REPLACE INTO entries (id, day, digest, state, sources, batch) VALUES (?, ?, ?, 'completed', ?, ?)", (marker, day, matches[0][1], frozen_sources, batch_id))
                    db.commit()
                    return {"written": False, "reason": "already_recorded", "day": day, "entry_id": marker}
                if marker in existing or (prior and (prior["state"] != "pending" or prior["position"] != len(existing.encode()))):
                    if prior:
                        db.execute("UPDATE entries SET state = 'uncertain' WHERE id = ?", (marker,))
                    else:
                        db.execute("INSERT INTO entries (id, day, digest, state) VALUES (?, ?, ?, 'uncertain')", (marker, day, digest))
                    db.commit()
                    raise ValueError("daily entry uncertain: marker incomplete, edited or missing; manual reconciliation required")
                if len(existing.encode()) + len(entry.encode()) > 2_000_000:
                    raise ValueError("daily note append would exceed safe read bound")
                db.execute("INSERT OR IGNORE INTO entries (id, day, digest, state, position, sources, batch) VALUES (?, ?, ?, 'pending', ?, ?, ?)", (marker, day, digest, len(existing.encode()), frozen_sources, batch_id))
                db.commit()
                self._append_bytes(note, entry.encode())
                if entry not in self._read_note(note):
                    raise OSError("daily note readback failed")
                try:
                    self._verify_note(note, day)
                except (OSError, ValueError):
                    db.execute("UPDATE entries SET state = 'uncertain' WHERE id = ?", (marker,))
                    db.commit()
                    raise
                db.execute("UPDATE entries SET state = 'completed' WHERE id = ?", (marker,))
                db.commit()
            finally:
                db.close()
        return {"written": True, "day": day, "source_ids": sorted(source_ids), "entry_id": marker}


def register_xcreen_tools(evidence: EvidenceReader, writer: VaultDailyWriter | None, *, registry=None, receipts=None) -> None:
    """Register only process-local handlers through Hermes's public registry API."""
    if registry is None:
        from tools.registry import registry as hermes_registry
        registry = hermes_registry

    def json_handler(operation):
        def handler(args, **_):
            try:
                return json.dumps(operation(args), ensure_ascii=False)
            except (ValueError, OSError) as exc:
                return json.dumps({"error": str(exc)}, ensure_ascii=False)
        return handler

    registry.register("xcreen_recent_ocr", "xcreen", {"description": "List latest OCR without guessing search terms, optionally within an inclusive ISO-8601 range; includes timestamped capture coverage and gaps.", "parameters": {"type": "object", "properties": {"limit": {"type": "integer", "minimum": 1, "maximum": 20}, "start": {"type": "string"}, "end": {"type": "string"}}}}, json_handler(lambda a: evidence.recent_ocr(a.get("limit", 20), a.get("start"), a.get("end"))), max_result_size_chars=100_000)
    registry.register("xcreen_coverage", "xcreen", {"description": "Timestamped latest OCR/image, capture state, exclusions and coverage limitations; not continuous/live proof.", "parameters": {"type": "object", "properties": {}}}, json_handler(lambda a: evidence.coverage()))
    registry.register("xcreen_search_ocr", "xcreen", {"description": "Search bounded persisted OCR, not just returned snippets. No match is not proof it was never seen; check xcreen_coverage.", "parameters": {"type": "object", "properties": {"query": {"type": "string"}, "limit": {"type": "integer", "minimum": 1, "maximum": 20}}, "required": ["query"]}}, json_handler(lambda a: evidence.search_ocr(a.get("query"), a.get("limit", _MAX_RESULTS))), max_result_size_chars=100_000)
    registry.register("xcreen_images_near", "xcreen", {"description": "List xCreen image IDs near an ISO-8601 timestamp.", "parameters": {"type": "object", "properties": {"timestamp": {"type": "string"}, "seconds": {"type": "number", "minimum": 0, "maximum": 86400}}, "required": ["timestamp"]}}, json_handler(lambda a: evidence.images_near(a.get("timestamp"), a.get("seconds", 30))))
    registry.register("xcreen_view_image", "xcreen", {"description": "Load actual pixels for one xCreen evidence image ID.", "parameters": {"type": "object", "properties": {"image_id": {"type": "string"}}, "required": ["image_id"]}}, lambda a, **_: evidence.view_image(a.get("image_id")), max_result_size_chars=_MAX_IMAGE_BYTES * 2)
    def daily(args, **context):
        if writer is None or receipts is None:
            return json.dumps({"error": "xCreen daily note writing unavailable: no configured scoped receipt service"})
        try:
            from runtime.xcreen_rpc import host_tool_context
            sid, turn = host_tool_context(context, receipts)
            return json.dumps(receipts.append(args, sid, turn), ensure_ascii=False)
        except (ValueError, OSError) as exc:
            return json.dumps({"error": str(exc)}, ensure_ascii=False)
    registry.register("xcreen_daily_note", "xcreen", {"description": "Append a valuable sourced capture-date insight using the host-bound active automatic batch. Model cannot choose batch/day; source_ids must belong to that batch. Stable entry_id identifies one semantic effect; conflicting retries are rejected. No raw OCR, secrets or noise.", "parameters": {"type": "object", "additionalProperties": False, "properties": {"entry_id": {"type": "string", "maxLength": 100}, "fact": {"type": "string", "maxLength": _MAX_FACT}, "source_ids": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 8}}, "required": ["entry_id", "fact", "source_ids"]}}, daily, max_result_size_chars=2_000)
    def manual(args, **context):
        try:
            if receipts is None or writer is None:
                raise ValueError('manual daily writing unavailable')
            from runtime.xcreen_rpc import host_tool_context
            sid, turn = host_tool_context(context, receipts)
            return json.dumps(receipts.append_manual(args, sid, turn), ensure_ascii=True)
        except (ValueError, OSError) as exc:
            return json.dumps({'error':str(exc)})
    registry.register('xcreen_manual_daily_note', 'xcreen', {'description':'Separate manual-question writer. Requires explicit host-issued manual context; cannot write automatic batch results or select batch/day. Source-bound useful facts only; no secrets/raw OCR.', 'parameters':{'type':'object','additionalProperties':False,'properties':{'entry_id':{'type':'string','maxLength':100},'fact':{'type':'string','maxLength':2000},'source_ids':{'type':'array','items':{'type':'string'},'minItems':1,'maxItems':8}},'required':['entry_id','fact','source_ids']}}, manual, max_result_size_chars=2000)
    def result(args, **context):
        try:
            if receipts is None:
                raise ValueError('batch receipts unavailable')
            from runtime.xcreen_rpc import host_tool_context
            sid, turn = host_tool_context(context, receipts)
            return json.dumps(receipts.result(args, sid, turn), ensure_ascii=True)
        except (ValueError, OSError) as exc:
            return json.dumps({'error':str(exc)})
    registry.register('xcreen_batch_result', 'xcreen', {'description':'Persist an explicit automatic batch outcome. saved requires the exact nonempty set of all verified effect IDs; skipped requires reason no_useful_fact and zero effects. Assistant prose is not a receipt.', 'parameters':{'type':'object','additionalProperties':False,'properties':{'outcome':{'type':'string','enum':['saved','skipped']},'reason':{'type':'string','enum':['no_useful_fact']},'effect_ids':{'type':'array','items':{'type':'string'},'maxItems':100}},'required':['outcome','effect_ids']}}, result, max_result_size_chars=48000)
