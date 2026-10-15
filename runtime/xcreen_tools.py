"""Confined, read-only evidence tools and the bounded xCreen daily-note writer."""
from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import mimetypes
import os
import re
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


class VaultDailyWriter:
    """A locked, source-bound append-only writer for an existing Daily note."""

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
        self.vault = self.vault.resolve(strict=True)
        self.hermes_home = self.hermes_home.resolve(strict=True)

    def _read_conventions(self) -> None:
        # Deliberately do not interpret note contents as commands. They are read only so established
        # vault conventions remain in the model-visible workflow, while this writer retains fixed bounds.
        for name in ("Agent operating rules.md", "Agent Operating Rules.md", "AGENTS.md", "Conventions.md"):
            path = self.vault / name
            if path.exists() and path.is_file() and not path.is_symlink():
                path.read_text(encoding="utf-8", errors="replace")[:16_000]

    def _daily_note(self, day: str) -> Path:
        directory = self.vault / "Daily"
        note = directory / f"{day}.md"
        if directory.is_symlink() or not directory.is_dir() or note.is_symlink() or not note.is_file():
            raise ValueError("existing daily note is required")
        resolved = note.resolve(strict=True)
        if resolved.parent != directory.resolve(strict=True):
            raise ValueError("unsafe daily note path")
        return resolved

    @contextmanager
    def _lock(self):
        lock = self.hermes_home / "vault-write.lock"
        if lock.is_symlink():
            raise ValueError("unsafe vault lock")
        with lock.open("a+", encoding="utf-8") as handle:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    def append(self, args: dict) -> dict:
        fact = args.get("fact", "") if isinstance(args, dict) else ""
        source_ids = args.get("source_ids", []) if isinstance(args, dict) else []
        if not isinstance(fact, str) or not fact.strip():
            return {"written": False, "reason": "no_useful_fact"}
        if len(fact) > _MAX_FACT or not isinstance(source_ids, list) or not 1 <= len(source_ids) <= 8:
            raise ValueError("bounded fact and source_ids are required")
        sources = [self.evidence.source(item) for item in source_ids]
        if len({item["id"] for item in sources}) != len(sources):
            raise ValueError("duplicate source id")
        days = {item["timestamp"].astimezone(self.timezone).date().isoformat() for item in sources}
        if len(days) != 1:
            raise ValueError("sources must belong to one capture day")
        day = next(iter(days))
        normalized = " ".join(fact.split())
        marker = hashlib.sha256((day + "\0" + normalized + "\0" + ",".join(sorted(item["id"] for item in sources))).encode()).hexdigest()[:20]
        entry = f"\n- {normalized}\n  <!-- xcreen:{marker}; xcreen-sources: {', '.join(sorted(item['id'] for item in sources))} -->\n"
        with self._lock():
            self._read_conventions()
            note = self._daily_note(day)
            existing = note.read_text(encoding="utf-8", errors="replace")
            if f"xcreen:{marker}" in existing:
                return {"written": False, "reason": "already_recorded", "day": day}
            with note.open("a", encoding="utf-8") as handle:
                handle.write(entry)
                handle.flush()
                os.fsync(handle.fileno())
            if f"xcreen:{marker}" not in note.read_text(encoding="utf-8", errors="replace"):
                raise OSError("daily note readback failed")
        return {"written": True, "day": day, "source_ids": sorted(item["id"] for item in sources)}


def register_xcreen_tools(evidence: EvidenceReader, writer: VaultDailyWriter | None, *, registry=None) -> None:
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
    def daily(args, **_):
        if writer is None:
            return json.dumps({"error": "xCreen daily note writing is unavailable: no vault path configured"})
        try:
            return json.dumps(writer.append(args), ensure_ascii=False)
        except (ValueError, OSError) as exc:
            return json.dumps({"error": str(exc)}, ensure_ascii=False)
    registry.register("xcreen_daily_note", "xcreen", {"description": "Append one genuinely useful, source-cited durable fact to the existing capture-date Daily note. Use only when there is a useful fact; no-op is allowed.", "parameters": {"type": "object", "properties": {"fact": {"type": "string", "maxLength": _MAX_FACT}, "source_ids": {"type": "array", "items": {"type": "string"}, "minItems": 1, "maxItems": 8}}, "required": ["fact", "source_ids"]}}, daily, max_result_size_chars=2_000)
