"""Server evidence store and batch state machine.

On-disk format is the 1.x Swift ``EvidenceStore`` layout (``index.json``, ``images/``),
so the scoped Hermes tools in ``runtime/`` read it unchanged and a complete install
upgrades in place. Timestamps are seconds since 2001-01-01 UTC (Swift's default Date
encoding) and image references are ``file://`` URLs.

All methods are synchronous and must be called from one thread (the server's event
loop); the store is not internally locked.
"""
from __future__ import annotations

import json
import os
import re
import stat
import uuid
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import quote, unquote, urlsplit

from .receipts import BatchReceipt

APPLE_EPOCH = datetime(2001, 1, 1, tzinfo=timezone.utc)
RETENTION = timedelta(days=7)
MAX_INDEX_BYTES = 128_000_000
MAX_IMAGE_BYTES = 30_000_000
MAX_OCR_CHARS = 12_000
BATCH_IMAGES = 30
MAX_PROVIDER_ATTEMPTS = 6
_ID = re.compile(r"^[A-Za-z0-9-]{1,100}$")
_FILE_NAME = re.compile(r"^[0-9T:.Z-]{1,40}_[A-Za-z0-9-]{1,100}\.(png|jpg)$")
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
JPEG_MAGIC = b"\xff\xd8\xff"


class StoreError(Exception):
    """Invalid input, unsafe path or a conflicting duplicate."""


class Conflict(StoreError):
    """Same id, different content."""


class Deferred(StoreError):
    """Batch is backed off; leave it pending for the retry timer."""


def valid_id(value: object) -> bool:
    return isinstance(value, str) and bool(_ID.match(value))


def to_apple(moment: datetime) -> float:
    return (moment - APPLE_EPOCH).total_seconds()


def from_apple(value: float) -> datetime:
    return APPLE_EPOCH + timedelta(seconds=float(value))


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def timestamp_name(moment: datetime, ident: str, suffix: str) -> str:
    stamp = moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H-%M-%S.") + f"{moment.microsecond // 1000:03d}Z"
    return f"{stamp}_{ident}.{suffix}"


@dataclass(frozen=True)
class Image:
    id: str
    timestamp: datetime
    path: Path

    def encode(self) -> dict:
        return {"id": self.id, "timestamp": to_apple(self.timestamp), "fileURL": self.path.as_uri()}


@dataclass(frozen=True)
class OCR:
    id: str
    timestamp: datetime
    text: str
    app: str
    title: str

    def encode(self) -> dict:
        return {"id": self.id, "timestamp": to_apple(self.timestamp), "text": self.text, "app": self.app, "title": self.title}


@dataclass(frozen=True)
class Batch:
    id: str
    images: tuple[Image, ...]
    started_at: datetime
    completed_at: datetime
    ocr: tuple[OCR, ...]

    @property
    def source_ids(self) -> list[str]:
        return sorted([i.id for i in self.images] + [o.id for o in self.ocr])

    def encode(self) -> dict:
        return {"id": self.id, "images": [i.encode() for i in self.images], "startedAt": to_apple(self.started_at),
                "completedAt": to_apple(self.completed_at), "ocr": [o.encode() for o in self.ocr]}


STATES = ("pending", "submitting", "admitted", "completed", "uncertain", "deadletter")


@dataclass
class BatchRecord:
    batch: Batch
    status: str
    attempts: int | None = None
    source_ids: list[str] | None = None
    session_id: str | None = None
    receipt: BatchReceipt | None = None
    retry_after: datetime | None = None
    provider_retries: int | None = None

    def encode(self) -> dict:
        out = {"batch": self.batch.encode(), "status": self.status}
        if self.attempts is not None:
            out["attempts"] = self.attempts
        if self.source_ids is not None:
            out["sourceIDs"] = self.source_ids
        if self.session_id is not None:
            out["sessionID"] = self.session_id
        if self.receipt is not None:
            out["receipt"] = self.receipt.encode()
        if self.retry_after is not None:
            out["retryAfter"] = to_apple(self.retry_after)
        if self.provider_retries is not None:
            out["providerRetries"] = self.provider_retries
        return out

    def summary(self) -> dict:
        return {"id": self.batch.id, "state": self.status, "attempts": self.attempts or 0,
                "started_at": self.batch.started_at.isoformat(), "completed_at": self.batch.completed_at.isoformat(),
                "images": len(self.batch.images), "ocr": len(self.batch.ocr),
                "receipt": self.receipt.summary() if self.receipt else None,
                "retry_after": self.retry_after.isoformat() if self.retry_after else None}


@dataclass(frozen=True)
class Binding:
    batch_id: str
    source_ids: list[str]
    session_id: str | None


def provider_backoff(retry: int, rate_limited: bool) -> timedelta:
    exponent = min(max(retry - 1, 0), 4)
    seconds = min(15 * 60 * 2 ** exponent, 4 * 3600) if rate_limited else min(2 * 60 * 2 ** exponent, 3600)
    return timedelta(seconds=seconds)


def _atomic_write(data: bytes, target: Path) -> None:
    directory = target.parent
    if directory.is_symlink():
        raise StoreError("unsafe directory")
    temporary = directory / f".write-{uuid.uuid4()}"
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


def _private_dir(path: Path) -> None:
    if path.is_symlink():
        raise StoreError(f"unsafe directory: {path}")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)


def _regular_file(path: Path) -> bool:
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    return stat.S_ISREG(info.st_mode)


class EvidenceStore:
    def __init__(self, root: str | Path, *, now: datetime | None = None):
        given = Path(root).absolute()
        if given.is_symlink():
            raise StoreError("evidence root must not be a symlink")
        # Resolve symlinked parents (e.g. macOS /var -> /private/var): the runtime's image reader
        # rejects any path with a symlinked component.
        self.root = Path(os.path.realpath(given.parent)) / given.name
        self.images_dir = self.root / "images"
        self.ocr_dir = self.root / "ocr"
        self.index_path = self.root / "index.json"
        self.status_path = self.root / "capture-status.json"
        for directory in (self.root, self.images_dir, self.ocr_dir):
            _private_dir(directory)
        self.images: list[Image] = []
        self.ocr: list[OCR] = []
        self.batches: list[BatchRecord] = []
        self.throttle_until: datetime | None = None
        if self.index_path.exists():
            self._load()
        # Neither a lost submit reply nor an interrupted admitted run proves absence of effects.
        for record in self.batches:
            verified = record.receipt is not None and record.receipt.completes_processing
            if record.status not in ("pending", "completed", "deadletter", "uncertain") or (record.status == "completed" and not verified):
                record.status = "uncertain"
        # The 1.x app kept its active-window checkpoint here; its images are already indexed
        # and are batched by the server, so the client file is obsolete in a server store.
        checkpoint = self.root / "capture-checkpoint.json"
        if _regular_file(checkpoint):
            checkpoint.unlink()
        self.cleanup(now or utcnow())

    # ── persistence ──────────────────────────────────────────────────────────

    def _load(self) -> None:
        if not _regular_file(self.index_path) or self.index_path.stat().st_size > MAX_INDEX_BYTES:
            raise StoreError("index is not a bounded regular file")
        raw = json.loads(self.index_path.read_bytes())
        self.images = [self._image(i) for i in raw.get("images", [])]
        self.ocr = [self._ocr(o) for o in raw.get("ocr", [])]
        self.batches = [self._record(r) for r in raw.get("batches", [])]
        throttle = raw.get("providerThrottleUntil")
        self.throttle_until = from_apple(throttle) if throttle is not None else None

    def _image(self, obj: dict) -> Image:
        if not valid_id(obj.get("id")):
            raise StoreError("invalid image id in index")
        url = urlsplit(obj["fileURL"])
        if url.scheme != "file" or url.netloc not in ("", "localhost"):
            raise StoreError("invalid image URL in index")
        # Always re-anchor by file name under this store's images/: a store copied from another
        # machine (or the 1.x app) keeps working, and no index entry can point outside it.
        name = Path(unquote(url.path)).name
        if not _FILE_NAME.match(name):
            raise StoreError("invalid image file name in index")
        return Image(obj["id"], from_apple(obj["timestamp"]), self.images_dir / name)

    @staticmethod
    def _ocr(obj: dict) -> OCR:
        if not valid_id(obj.get("id")):
            raise StoreError("invalid OCR id in index")
        return OCR(obj["id"], from_apple(obj["timestamp"]), obj["text"], obj.get("app", ""), obj.get("title", ""))

    def _batch(self, obj: dict) -> Batch:
        if not valid_id(obj.get("id")):
            raise StoreError("invalid batch id in index")
        return Batch(obj["id"], tuple(self._image(i) for i in obj.get("images", [])), from_apple(obj["startedAt"]),
                     from_apple(obj["completedAt"]), tuple(self._ocr(o) for o in obj.get("ocr", [])))

    def _record(self, obj: dict) -> BatchRecord:
        receipt = BatchReceipt.decode(obj["receipt"]) if obj.get("receipt") else None
        retry = obj.get("retryAfter")
        return BatchRecord(self._batch(obj["batch"]), obj["status"], obj.get("attempts"), obj.get("sourceIDs"),
                           obj.get("sessionID"), receipt, from_apple(retry) if retry is not None else None, obj.get("providerRetries"))

    def _encode(self) -> bytes:
        body = {"images": [i.encode() for i in self.images], "ocr": [o.encode() for o in self.ocr],
                "batches": [r.encode() for r in self.batches]}
        if self.throttle_until is not None:
            body["providerThrottleUntil"] = to_apple(self.throttle_until)
        return json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()

    def persist(self) -> None:
        _atomic_write(self._encode(), self.index_path)

    def _transaction(self, mutate):
        """Apply ``mutate`` and persist; on a failed write, restore the previous state."""
        snapshot = (list(self.images), list(self.ocr), [replace(r) for r in self.batches], self.throttle_until)
        try:
            result = mutate()
            self.persist()
            return result
        except BaseException:
            self.images, self.ocr, self.batches, self.throttle_until = snapshot
            raise

    @staticmethod
    def _confined(path: Path, directory: Path) -> bool:
        candidate = Path(os.path.normpath(path))
        base = Path(os.path.normpath(directory))
        if candidate.is_symlink() or base.is_symlink() or candidate.name in ("", ".", ".."):
            return False
        return candidate.parent == base or os.path.realpath(candidate.parent) == os.path.realpath(base)

    @staticmethod
    def expired(moment: datetime, now: datetime) -> bool:
        return moment < now - RETENTION

    # ── ingest ───────────────────────────────────────────────────────────────

    def _check_timestamp(self, moment: datetime, now: datetime) -> None:
        if moment.tzinfo is None or self.expired(moment, now) or moment > now + timedelta(minutes=5):
            raise StoreError("timestamp must be timezone-aware, within the last seven days and not in the future")

    def ingest_ocr(self, items: list[dict], *, now: datetime | None = None) -> dict:
        """Idempotent by id. Returns counts; a conflicting duplicate raises Conflict before any write."""
        now = now or utcnow()
        known = {o.id: o for o in self.ocr}
        fresh: list[OCR] = []
        for item in items:
            text, app, title = item.get("text"), item.get("app", ""), item.get("title", "")
            if (not valid_id(item.get("id")) or not isinstance(text, str) or not text.strip() or len(text) > MAX_OCR_CHARS
                    or not isinstance(app, str) or not isinstance(title, str)):
                raise StoreError("invalid OCR item")
            moment = item["timestamp"]
            self._check_timestamp(moment, now)
            evidence = OCR(item["id"], moment, text, app[:256], title[:1024])
            existing = known.get(evidence.id)
            if existing is not None:
                if existing != evidence:
                    raise Conflict(f"OCR {evidence.id} already exists with different content")
                continue
            known[evidence.id] = evidence
            fresh.append(evidence)
        if fresh:
            self._transaction(lambda: self.ocr.extend(fresh))
        return {"accepted": len(fresh), "duplicates": len(items) - len(fresh)}

    def ingest_image(self, ident: str, moment: datetime, data: bytes, *, now: datetime | None = None) -> dict:
        now = now or utcnow()
        if not valid_id(ident) or not data or len(data) > MAX_IMAGE_BYTES:
            raise StoreError("invalid image")
        if data.startswith(PNG_MAGIC):
            suffix = "png"
        elif data.startswith(JPEG_MAGIC):
            suffix = "jpg"
        else:
            raise StoreError("image must be PNG or JPEG")
        self._check_timestamp(moment, now)
        existing = next((i for i in self.images if i.id == ident), None)
        if existing is not None:
            # The stored copy may already be recompressed, so identity is id + timestamp.
            if existing.timestamp != moment:
                raise Conflict(f"image {ident} already exists with a different timestamp")
            return {"accepted": 0, "duplicates": 1}
        path = self.images_dir / timestamp_name(moment, ident, suffix)
        _atomic_write(data, path)
        try:
            self._transaction(lambda: self.images.append(Image(ident, moment, path)))
        except BaseException:
            path.unlink(missing_ok=True)
            raise
        return {"accepted": 1, "duplicates": 0}

    def write_capture_status(self, state: str, reason: str, integrity: bool, now: datetime | None = None) -> None:
        values = {"capture": state[:32], "capture_reason": reason[:500], "desired_integrity": "on" if integrity else "off",
                  "updated": (now or utcnow()).strftime("%Y-%m-%dT%H:%M:%SZ")}
        _atomic_write(json.dumps(values).encode(), self.status_path)

    def capture_status(self) -> dict | None:
        try:
            return json.loads(self.status_path.read_bytes())
        except (FileNotFoundError, ValueError):
            return None

    # ── batching ─────────────────────────────────────────────────────────────

    def _batched_ids(self) -> set[str]:
        ids: set[str] = set()
        for record in self.batches:
            ids.update(i.id for i in record.batch.images)
            ids.update(o.id for o in record.batch.ocr)
            ids.update(record.source_ids or ())
        return ids

    def form_batches(self, *, now: datetime | None = None) -> list[Batch]:
        """Every 30 consecutive unbatched images (five active minutes at one image per ten
        active seconds) plus the unbatched OCR captured up to the last of them."""
        now = now or utcnow()
        batched = self._batched_ids()
        images = sorted((i for i in self.images if i.id not in batched and not self.expired(i.timestamp, now)), key=lambda i: i.timestamp)
        ocr = sorted((o for o in self.ocr if o.id not in batched and not self.expired(o.timestamp, now)), key=lambda o: o.timestamp)
        formed: list[Batch] = []
        while len(images) >= BATCH_IMAGES:
            chunk, images = images[:BATCH_IMAGES], images[BATCH_IMAGES:]
            cutoff = chunk[-1].timestamp
            text = [o for o in ocr if o.timestamp <= cutoff]
            ocr = [o for o in ocr if o.timestamp > cutoff]
            started = min([chunk[0].timestamp] + [o.timestamp for o in text])
            formed.append(Batch(f"batch-{uuid.uuid4()}", tuple(chunk), started, cutoff, tuple(text)))
        if formed:
            self._transaction(lambda: self.batches.extend(BatchRecord(b, "pending") for b in formed))
        return formed

    def unbatched_counts(self) -> dict:
        batched = self._batched_ids()
        return {"images": sum(1 for i in self.images if i.id not in batched), "ocr": sum(1 for o in self.ocr if o.id not in batched)}

    # ── batch state machine (port of the 1.x Swift EvidenceStore) ─────────────

    def _find(self, batch_id: str) -> BatchRecord:
        for record in self.batches:
            if record.batch.id == batch_id:
                return record
        raise StoreError(f"unknown batch {batch_id}")

    def batch_state(self, batch_id: str) -> str | None:
        return next((r.status for r in self.batches if r.batch.id == batch_id), None)

    def pending_batches(self, now: datetime | None = None) -> list[Batch]:
        """Due pending work only. A provider rate limit throttles the whole automatic
        pipeline (same account), a per-batch backoff only that batch."""
        now = now or utcnow()
        if (self.throttle_until or datetime.min.replace(tzinfo=timezone.utc)) > now:
            return []
        due = [r.batch for r in self.batches if r.status == "pending" and (r.retry_after is None or r.retry_after <= now)
               and not self.expired(r.batch.completed_at, now)]
        return sorted(due, key=lambda b: b.started_at)

    def next_retry_date(self, now: datetime | None = None) -> datetime | None:
        now = now or utcnow()
        waiting = [r for r in self.batches if r.status == "pending" and not self.expired(r.batch.completed_at, now)]
        if not waiting:
            return None
        floor = datetime.min.replace(tzinfo=timezone.utc)
        throttle = self.throttle_until or floor
        due = min(max(r.retry_after or floor, throttle) for r in waiting)
        return due if due > now else None

    def batch_page(self, after: str = "", limit: int = 20) -> list[dict]:
        rows = sorted((r for r in self.batches if r.batch.id > after), key=lambda r: r.batch.id)[: max(1, min(limit, 20))]
        out = [r.summary() for r in rows]
        while len(out) > 1 and len(json.dumps(out)) > 24_000:
            out.pop()
        return out

    def counts(self) -> dict:
        tally = {state: 0 for state in STATES}
        for record in self.batches:
            tally[record.status] = tally.get(record.status, 0) + 1
        return tally

    def record_failure(self, batch_id: str, *, not_sent: bool = False, provider_failure: bool = False,
                       rate_limited: bool = False, now: datetime | None = None) -> None:
        """Classify a finished automatic attempt. Only a host receipt for this exact binding that
        proves zero effects (``retry_safe``) plus a provider failure may return work to pending."""
        now = now or utcnow()
        record = self._find(batch_id)

        def mutate():
            if record.status == "pending":
                if not_sent:
                    return
                record.attempts = (record.attempts or 0) + 1
                limit = MAX_PROVIDER_ATTEMPTS if (record.provider_retries or 0) > 0 else 3
                if record.attempts >= limit:
                    record.status = "deadletter"
            elif record.status in ("submitting", "admitted", "uncertain"):
                if provider_failure and self._retry_safe(record):
                    self._requeue(record, now, backoff=True, rate_limited=rate_limited)
                elif record.status != "uncertain":
                    record.status = "uncertain"
        self._transaction(mutate)

    def requeue_retry_safe(self, batch_id: str, now: datetime | None = None) -> bool:
        """Explicit recovery for work stranded uncertain: requires the same zero-effect host proof."""
        now = now or utcnow()
        record = self._find(batch_id)
        if record.status != "uncertain" or not self._retry_safe(record):
            return False
        self._transaction(lambda: self._requeue(record, now, backoff=False, rate_limited=False))
        return record.status == "pending"

    @staticmethod
    def _retry_safe(record: BatchRecord) -> bool:
        receipt = record.receipt
        return (receipt is not None and record.session_id is not None and receipt.retry_safe is True and not receipt.verified
                and not receipt.effects and receipt.session_id == record.session_id and receipt.batch_id == record.batch.id)

    def _requeue(self, record: BatchRecord, now: datetime, *, backoff: bool, rate_limited: bool) -> None:
        record.provider_retries = (record.provider_retries or 0) + 1
        # A consumed retry proof cannot authorize a later attempt; the next binding is fresh.
        record.receipt = None
        record.session_id = None
        delay = provider_backoff(record.provider_retries, rate_limited) if backoff else timedelta(0)
        if rate_limited and delay > timedelta(0):
            until = now + delay
            self.throttle_until = max(self.throttle_until or until, until)
        if (record.attempts or 0) >= MAX_PROVIDER_ATTEMPTS or self.expired(record.batch.completed_at, now):
            record.status, record.retry_after = "deadletter", None
            return
        record.status = "pending"
        record.retry_after = now + delay if delay > timedelta(0) else None

    def uncertain_ids(self) -> list[str]:
        return sorted(r.batch.id for r in self.batches if r.status == "uncertain")

    def bindings(self) -> list[Binding]:
        return [Binding(r.batch.id, r.source_ids or r.batch.source_ids, r.session_id) for r in self.batches
                if r.status not in ("pending", "deadletter")]

    def bind(self, batch_id: str, session_id: str) -> None:
        record = self._find(batch_id)
        if record.session_id not in (None, session_id):
            raise StoreError("batch is bound to another session")

        def mutate():
            record.session_id = session_id
            record.source_ids = record.batch.source_ids
        self._transaction(mutate)

    def invalidate_receipt(self, batch_id: str) -> None:
        record = self._find(batch_id)

        def mutate():
            record.status, record.receipt = "uncertain", None
        self._transaction(mutate)

    def reconcile(self, receipt: BatchReceipt) -> None:
        record = self._find(receipt.batch_id)
        sources = record.source_ids or record.batch.source_ids
        if record.session_id != receipt.session_id or sorted(sources) != sorted(receipt.source_ids):
            raise StoreError("receipt does not match the batch binding")

        def mutate():
            record.receipt = receipt
            record.status = "completed" if receipt.completes_processing else "uncertain"
        self._transaction(mutate)

    def transition(self, batch_id: str, state: str, now: datetime | None = None) -> None:
        now = now or utcnow()
        record = self._find(batch_id)
        floor = datetime.min.replace(tzinfo=timezone.utc)
        if state == "submitting" and record.status == "pending" and max(self.throttle_until or floor, record.retry_after or floor) > now:
            raise Deferred(batch_id)
        allowed = {("pending", "submitting"), ("submitting", "admitted"), ("submitting", "uncertain"), ("admitted", "uncertain")}
        if (record.status, state) not in allowed:
            raise StoreError(f"invalid batch transition {record.status} -> {state}")

        def mutate():
            if state == "submitting":
                record.attempts = (record.attempts or 0) + 1
                record.retry_after = None
            record.status = state
        self._transaction(mutate)

    # ── queries ──────────────────────────────────────────────────────────────

    def image(self, ident: str, now: datetime | None = None) -> Image | None:
        if not valid_id(ident):
            raise StoreError("invalid image id")
        now = now or utcnow()
        found = next((i for i in self.images if i.id == ident), None)
        if found is None or self.expired(found.timestamp, now) or not self._confined(found.path, self.images_dir) or not _regular_file(found.path):
            return None
        return found

    def latest(self) -> dict:
        last_image = max((i.timestamp for i in self.images), default=None)
        last_ocr = max((o.timestamp for o in self.ocr), default=None)
        return {"image": last_image.isoformat() if last_image else None, "ocr": last_ocr.isoformat() if last_ocr else None}

    # ── image compaction (strategy lives in images.py) ───────────────────────

    def compressible_images(self, limit: int, now: datetime | None = None) -> list[Image]:
        """Digested images still stored losslessly. Only a verified completed digest releases an
        image: pending, uncertain and unbatched images keep full quality."""
        now = now or utcnow()
        digested = {i.id for r in self.batches if r.status == "completed" for i in r.batch.images}
        out = [i for i in self.images if i.id in digested and i.path.suffix.lower() == ".png" and not self.expired(i.timestamp, now)
               and self._confined(i.path, self.images_dir) and _regular_file(i.path)]
        return out[: max(0, min(limit, 1000))]

    def replace_image(self, ident: str, expected: Path, data: bytes, now: datetime | None = None) -> Image | None:
        """New file first, then the index, then the original, so a crash leaves the index
        pointing at a complete file either way. None when the image is no longer eligible."""
        if not valid_id(ident) or len(data) <= 3 or len(data) > MAX_IMAGE_BYTES or not data.startswith(JPEG_MAGIC):
            raise StoreError("replacement must be a JPEG")
        now = now or utcnow()
        index = next((n for n, i in enumerate(self.images) if i.id == ident), None)
        if index is None:
            return None
        current = self.images[index]
        digested = any(r.status == "completed" and any(i.id == ident for i in r.batch.images) for r in self.batches)
        if (current.path != expected or expected.suffix.lower() != ".png" or self.expired(current.timestamp, now) or not digested
                or not self._confined(expected, self.images_dir) or not _regular_file(expected)):
            return None
        target = expected.with_suffix(".jpg")
        if not self._confined(target, self.images_dir):
            raise StoreError("unsafe replacement path")
        image = Image(ident, current.timestamp, target)
        _atomic_write(data, target)

        def mutate():
            self.images[index] = image
            for record in self.batches:
                if any(i.id == ident for i in record.batch.images):
                    record.batch = replace(record.batch, images=tuple(image if i.id == ident else i for i in record.batch.images))
        try:
            self._transaction(mutate)
        except BaseException:
            target.unlink(missing_ok=True)
            raise
        expected.unlink(missing_ok=True)  # a leftover is removed by remove_superseded_originals or TTL
        return image

    def remove_superseded_originals(self) -> None:
        referenced = {os.path.normpath(i.path) for i in self.images}
        for image in self.images:
            if image.path.suffix.lower() != ".jpg":
                continue
            original = image.path.with_suffix(".png")
            if os.path.normpath(original) not in referenced and self._confined(original, self.images_dir) and _regular_file(original):
                original.unlink()

    # ── retention ────────────────────────────────────────────────────────────

    def cleanup(self, now: datetime | None = None) -> None:
        now = now or utcnow()
        cutoff = now - RETENTION

        def mutate():
            for image in self.images:
                if image.timestamp < cutoff and self._confined(image.path, self.images_dir):
                    image.path.unlink(missing_ok=True)
            self.images = [i for i in self.images if i.timestamp >= cutoff]
            self.ocr = [o for o in self.ocr if o.timestamp >= cutoff]
            # Keep source ids and receipts, not raw derivatives, beyond evidence expiry.
            for record in self.batches:
                batch = record.batch
                if batch.completed_at < cutoff or any(i.timestamp < cutoff for i in batch.images) or any(o.timestamp < cutoff for o in batch.ocr):
                    if record.source_ids is None:
                        record.source_ids = batch.source_ids
                    record.batch = Batch(batch.id, (), batch.started_at, batch.completed_at, ())
                    if record.status == "pending":
                        record.status = "deadletter"
            archive_cutoff = now - timedelta(days=180)
            self.batches = [r for r in self.batches if r.batch.completed_at >= archive_cutoff]
            archived = sorted((r for r in self.batches if r.batch.completed_at < cutoff), key=lambda r: r.batch.completed_at, reverse=True)[:128]
            while archived and len(json.dumps([r.encode() for r in archived])) > 2_000_000:
                archived.pop()
            keep = {r.batch.id for r in archived}
            self.batches = [r for r in self.batches if r.batch.completed_at >= cutoff or r.batch.id in keep]
        self._transaction(mutate)
        # A crash between a file write and the index write leaves an unindexed file; it gets the same TTL.
        for directory in (self.images_dir, self.ocr_dir):
            for entry in os.scandir(directory):
                if entry.name.startswith(".") and not entry.name.startswith(".write-"):
                    continue
                try:
                    info = entry.stat(follow_symlinks=False)
                except FileNotFoundError:
                    continue
                if stat.S_ISREG(info.st_mode) and datetime.fromtimestamp(info.st_mtime, timezone.utc) < cutoff:
                    os.unlink(entry.path)
