"""Server facade: every operation the HTTP API (and the tests) can perform.

Runs on one asyncio event loop; the store, session runtime and pipeline are only touched
from that loop.
"""
from __future__ import annotations

import asyncio
import logging
import time
import uuid
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

from . import PROTOCOL, VERSION, prompts
from .config import ServerConfig, detect_hermes, detect_vault
from .errors import Cancelled, GatewayError, ProviderFailure, RemoteFailure, Unavailable
from .gateway import Event, HermesGateway, Launch
from .images import ImageCompactor, ImageEncoder, default_encoder, describe
from .session import SessionController, SessionRuntime, StateFile, decode_inventory
from .store import Batch, Binding, Deferred, EvidenceStore, StoreError, utcnow

log = logging.getLogger("xcreen.service")


class InvalidRequest(Exception):
    pass


class BatchPipeline:
    """Automatic digests (port of the 1.x app's submit/retry loop)."""

    def __init__(self, store: EvidenceStore, runtime: SessionRuntime, controller: SessionController, allowed):
        self.store = store
        self.runtime = runtime
        self.controller = controller
        self.allowed = allowed
        self.in_flight: set[str] = set()
        self.retry_task: asyncio.Task | None = None
        self.next_retry: datetime | None = None
        self.message = ""
        self._tasks: set[asyncio.Task] = set()

    def kick(self) -> None:
        if self.allowed():
            self._spawn(self.submit_pending())

    def _spawn(self, coro) -> None:
        task = asyncio.get_running_loop().create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)

    async def submit_pending(self) -> None:
        for batch in self.store.pending_batches():
            self._spawn(self.submit(batch))
        self.schedule_retry()

    async def submit(self, batch: Batch) -> None:
        if not self.allowed() or batch.id in self.in_flight:
            return
        self.in_flight.add(batch.id)
        try:
            manifest = prompts.batch(batch.id, batch.images, batch.ocr, batch.started_at, batch.completed_at)
            images = [(i.id, i.path) for i in batch.images]
            log.info("sending batch %s images=%d", batch.id, len(images))
            if not self.controller.connected:
                try:
                    await self.controller.connect()
                except Exception as exc:  # noqa: BLE001
                    log.warning("batch %s deferred: gateway unavailable (%s)", batch.id, exc)
                    return
            # Backed off (e.g. provider rate limit): leave it pending for the retry timer.
            if batch.id not in {b.id for b in self.store.pending_batches()}:
                self.schedule_retry()
                return

            async def prepared(session_id: str) -> None:
                self.store.bind(batch.id, session_id)

            async def receipt_changed(receipt) -> None:
                self.store.reconcile(receipt)

            async def phase_changed(state: str) -> None:
                self.store.transition(batch.id, state)

            await self.runtime.submit_automatic(manifest, images, binding=Binding(batch.id, batch.source_ids, None),
                                                prepared=prepared, receipt_changed=receipt_changed, phase_changed=phase_changed)
            log.info("verified processing receipt for batch %s", batch.id)
            self.message = f"Batch {batch.id} digested."
        except Deferred:
            self.schedule_retry()
        except Exception as exc:  # noqa: BLE001 - classify every failure
            # Pre-send work stays retryable. After send, only a provider failure with a host receipt
            # proving zero effects returns to pending (with backoff).
            not_sent = isinstance(exc, (Cancelled, Unavailable))
            failure = exc if isinstance(exc, ProviderFailure) else None
            try:
                self.store.record_failure(batch.id, not_sent=not_sent, provider_failure=failure is not None,
                                          rate_limited=bool(failure and failure.rate_limited))
            except StoreError:
                pass
            self.message = self._summary(exc, self.store.batch_state(batch.id))
            log.warning("batch %s %s", batch.id, self.message)
            self.schedule_retry()
        finally:
            self.in_flight.discard(batch.id)

    def schedule_retry(self) -> None:
        if self.retry_task:
            self.retry_task.cancel()
        due = self.store.next_retry_date()
        self.next_retry = due
        if due is None:
            return

        async def wait():
            await asyncio.sleep(max(1.0, (due - utcnow()).total_seconds() + 1))
            self.next_retry = None
            if self.allowed() and self.controller.connected:
                await self.submit_pending()
        self.retry_task = asyncio.get_running_loop().create_task(wait())

    def _summary(self, error: Exception, state: str | None) -> str:
        if isinstance(error, ProviderFailure):
            reason = "provider rate-limited" if error.rate_limited else "provider failed"
        else:
            reason = "interrupted"
        if state == "pending":
            due = self.store.next_retry_date()
            when = due.isoformat() if due else "when due"
            return f"Automatic batch {reason}. No note effects were recorded; it will retry after backoff ({when})."
        if state == "deadletter":
            return f"Automatic batch {reason} repeatedly and was deadlettered; no blind resend."
        return f"Automatic batch {reason}. Effects may exist, so it stays uncertain; run receipt verification."


@dataclass
class TurnRecord:
    id: str
    question: str
    state: str = "queued"  # queued | running | completed | failed | cancelled
    text: str = ""
    error: str | None = None
    version: int = 0
    created: float = field(default_factory=time.time)
    changed: asyncio.Event = field(default_factory=asyncio.Event)

    def bump(self) -> None:
        self.version += 1
        self.changed.set()
        self.changed = asyncio.Event()

    def public(self) -> dict:
        return {"id": self.id, "state": self.state, "text": self.text, "error": self.error, "version": self.version,
                "done": self.state in ("completed", "failed", "cancelled")}


class XCreenService:
    def __init__(self, config: ServerConfig, *, encoder: ImageEncoder | None | str = "auto", gateway: HermesGateway | None = None,
                 launch_override: Launch | None = None):
        self.config = config
        self.store = EvidenceStore(config.data_dir)
        self.state = StateFile(config.state_path)
        self.gateway = gateway or HermesGateway(stderr_path=str(config.logs() / "gateway.log"))
        self.runtime = SessionRuntime(self.gateway, self.state)
        self.launch_override = launch_override
        self.controller = SessionController(self.runtime, self._launch)
        self.controller.on_ready = self._on_ready
        self.encoder = default_encoder() if encoder == "auto" else encoder
        self.compactor = ImageCompactor(self.store, self.encoder)
        self.pipeline = BatchPipeline(self.store, self.runtime, self.controller, lambda: not self.integrity)
        status = self.store.capture_status() or {}
        # Fail closed: automatic digests stay blocked until a client reports Integrity OFF.
        self.integrity = status.get("desired_integrity") != "off"
        self.capture = status.get("capture", "unknown")
        self.capture_reason = status.get("capture_reason", "")
        self.client_seen: float | None = None
        self.turns: dict[str, TurnRecord] = {}
        self.active_turn: str | None = None
        self.current_model: tuple[str, str] | None = None
        self.started = time.time()
        self._maintenance: asyncio.Task | None = None
        self._tasks: set[asyncio.Task] = set()
        self.runtime.listeners.append(self._on_event)

    # ── lifecycle ────────────────────────────────────────────────────────────

    def _launch(self) -> Launch:
        if self.launch_override is not None:
            return self.launch_override
        c = self.config
        return Launch.bundled(python=c.hermes_python, hermes_root=c.hermes_root, evidence_root=str(self.store.root),
                              runtime_dir=c.runtime_dir, vault=c.vault or None, timezone=c.timezone)

    def _spawn(self, coro) -> asyncio.Task:
        task = asyncio.get_running_loop().create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    async def start(self, *, connect: bool = True) -> None:
        await self.runtime.set_integrity(self.integrity)
        self._maintenance = self._spawn(self._maintain())
        self.store.form_batches()
        if connect and (self.launch_override or (self.config.hermes_python and self.config.hermes_root)):
            self._spawn(self._connect_quietly())

    async def _connect_quietly(self) -> None:
        try:
            await self.controller.connect()
        except Exception as exc:  # noqa: BLE001
            log.warning("Hermes connect failed: %s", exc)

    async def stop(self) -> None:
        """Blocks automatic work, cancels background tasks, then closes the Hermes session."""
        await self.runtime.set_integrity(True)
        if self.pipeline.retry_task:
            self.pipeline.retry_task.cancel()
        tasks = list(self._tasks) + list(self.pipeline._tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await self.controller.close()

    async def _on_ready(self) -> None:
        try:
            requeued = await self.controller.recover(self.store)
            if requeued:
                log.info("recovered %d receipt-proven zero-effect batches for retry", requeued)
        except Exception as exc:  # noqa: BLE001
            log.warning("batch receipt verification unavailable: %s", exc)
        if not self.controller.model_applied:
            log.info("xCreen default model not applied: %s", self.controller.model_status)
        self.pipeline.kick()

    async def _maintain(self) -> None:
        while True:
            try:
                self.store.cleanup()
                compressed = await self.compactor.run()
                if compressed:
                    log.info("compressed %d digested images to JPEG", compressed)
            except Exception:  # noqa: BLE001
                log.exception("maintenance failed")
            await asyncio.sleep(60)

    def _on_event(self, event: Event) -> None:
        if event.type == "session.info":
            body = event.body
            if isinstance(body.get("provider"), str) and isinstance(body.get("model"), str):
                self.current_model = (body["provider"], body["model"])
        record = self.turns.get(self.active_turn) if self.active_turn else None
        current = self.runtime.current
        if record and current is not None and current.id == record.id:
            if record.state == "queued":
                record.state = "running"
            if event.type in ("message.start",):
                record.text = ""
            elif event.type in ("message.delta", "message.interim", "message.complete"):
                record.text = self.runtime.output
            record.bump()

    # ── status ───────────────────────────────────────────────────────────────

    def status(self) -> dict:
        c = self.controller
        provider, model = c.model_preference
        return {
            "protocol": PROTOCOL, "version": VERSION, "uptime": int(time.time() - self.started),
            "hermes": {"connected": c.connected, "configured": bool(self.launch_override or (self.config.hermes_python and self.config.hermes_root)),
                       "error": c.last_error, "session": self.state.get("stored_session_id")},
            "model": {"current": {"provider": self.current_model[0], "model": self.current_model[1]} if self.current_model else None,
                      "default": {"provider": provider, "model": model}, "applied": c.model_applied, "status": c.model_status},
            "session_visible": c.session_visible, "session_visible_confirmed": c.actual_visible, "visibility_pending": c.visibility_pending,
            "integrity": self.integrity, "capture": self.capture, "capture_reason": self.capture_reason,
            "client_seen": datetime.fromtimestamp(self.client_seen, timezone.utc).isoformat() if self.client_seen else None,
            "batches": self.store.counts(), "unbatched": self.store.unbatched_counts(), "latest": self.store.latest(),
            "next_retry": self.pipeline.next_retry.isoformat() if self.pipeline.next_retry else None,
            "message": self.pipeline.message, "vault": bool(self.config.vault), "compression": describe(self.encoder),
            "active_turn": self.active_turn,
        }

    # ── ingest ───────────────────────────────────────────────────────────────

    def ingest_ocr(self, items: list[dict]) -> dict:
        result = self.store.ingest_ocr(items)
        self.client_seen = time.time()
        return result

    def ingest_image(self, ident: str, moment: datetime, data: bytes) -> dict:
        result = self.store.ingest_image(ident, moment, data)
        self.client_seen = time.time()
        if self.store.form_batches():
            self.pipeline.kick()
        return result

    async def report_capture(self, capture: str, reason: str, integrity: bool) -> dict:
        self.client_seen = time.time()
        self.capture, self.capture_reason = capture[:32], reason[:500]
        changed = integrity != self.integrity
        self.integrity = integrity
        self.store.write_capture_status(self.capture, self.capture_reason, integrity)
        if changed:
            log.info("integrity %s (reported by client)", "on" if integrity else "off")
            await self.runtime.set_integrity(integrity)
            if not integrity:
                self.pipeline.kick()
        return {"integrity": self.integrity}

    # ── questions ────────────────────────────────────────────────────────────

    def ask(self, question: str) -> TurnRecord:
        if not isinstance(question, str) or not question.strip() or len(question) > 32_000:
            raise InvalidRequest("question must be 1-32000 characters")
        if self.active_turn:
            raise InvalidRequest("a question is already active; cancel it or wait")
        record = TurnRecord(str(uuid.uuid4()), question)
        self.turns[record.id] = record
        self.active_turn = record.id
        while len(self.turns) > 50:
            self.turns.pop(next(iter(self.turns)))
        self._spawn(self._run_turn(record))
        return record

    async def _run_turn(self, record: TurnRecord) -> None:
        try:
            await self.controller.connect()
            if record.state == "cancelled":
                return
            record.state = "running"
            record.bump()
            text = await self.runtime.submit_manual(prompts.manual(record.question), record.id, self.runtime.generation)
            record.text, record.state = text, "completed"
        except Cancelled:
            record.state = "cancelled"
        except Exception as exc:  # noqa: BLE001
            record.state, record.error = "failed", str(exc)
        finally:
            if self.active_turn == record.id:
                self.active_turn = None
            record.bump()

    async def wait_turn(self, turn_id: str, after: int, wait_ms: int) -> dict:
        record = self.turns.get(turn_id)
        if record is None:
            raise InvalidRequest("unknown turn")
        deadline = time.monotonic() + max(0, min(wait_ms, 30_000)) / 1000
        while record.version <= after and record.state not in ("completed", "failed", "cancelled"):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                break
            try:
                await asyncio.wait_for(record.changed.wait(), timeout=remaining)
            except asyncio.TimeoutError:
                break
        return record.public()

    async def cancel(self) -> None:
        if not self.active_turn:
            raise InvalidRequest("no active question to cancel")
        record = self.turns[self.active_turn]
        if record.state == "queued":
            record.state = "cancelled"
            self.runtime.cancelled_manual.add(record.id)
        else:
            await self.runtime.cancel_manual(record.id)

    # ── session operations ───────────────────────────────────────────────────

    async def history(self, cursor: str | None) -> dict:
        return await self.controller.history_page(cursor)

    def batches(self, after: str) -> list[dict]:
        return self.store.batch_page(after, 20)

    async def retry_batches(self) -> int:
        count = await self.controller.recover(self.store)
        self.pipeline.kick()
        return count

    async def verify(self) -> int:
        return await self.controller.verify(self.store)

    async def models(self) -> dict:
        inventory = await self.controller.model_options()
        return {"routes": [{"provider": p, "model": m} for p, m in decode_inventory(inventory)],
                "current": {"provider": inventory.get("provider"), "model": inventory.get("model")}}

    async def select_model(self, provider: str, model: str) -> None:
        await self.controller.switch_model(provider, model)
        self.current_model = (provider, model)

    async def set_default_model(self, provider: str, model: str) -> None:
        await self.controller.set_default_model(provider, model)

    async def set_visible(self, visible: bool) -> None:
        await self.controller.set_visible(visible)

    async def connection(self, action: str) -> None:
        if action == "connect":
            await self.controller.connect()
        elif action == "disconnect":
            await self.controller.disconnect()
        elif action == "reconnect":
            await self.controller.reconnect()
        else:
            raise InvalidRequest("action must be connect, disconnect or reconnect")

    async def configure(self, changes: dict) -> dict:
        unknown = set(changes) - set(ServerConfig.EDITABLE)
        if unknown:
            raise InvalidRequest(f"unknown settings: {', '.join(sorted(unknown))}")
        for key, value in changes.items():
            if not isinstance(value, str):
                raise InvalidRequest(f"{key} must be a string")
            setattr(self.config, key, value.strip())
        problems = self.config.validate()
        if problems:
            raise InvalidRequest("; ".join(problems))
        self.config.save()
        await self.controller.reconnect()
        return self.config.public()

    async def autodetect(self) -> dict:
        hermes, vault = await asyncio.to_thread(lambda: (detect_hermes(), detect_vault()))
        changes = {}
        if hermes:
            changes["hermes_python"], changes["hermes_root"] = hermes
        if vault:
            changes["vault"] = vault
        if not changes:
            raise InvalidRequest("no Hermes launcher or Obsidian vault found on the server")
        return await self.configure(changes)

    def image_path(self, ident: str) -> Path | None:
        image = self.store.image(ident)
        return image.path if image else None
