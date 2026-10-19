"""The dedicated xCreen Hermes session (port of the 1.x Swift HermesSessionRuntime and
SharedSessionController).

``SessionRuntime`` owns the turn queue: one turn at a time, manual questions before
automatic batches, and a turn completes only on a terminal gateway event, never on
admission. ``SessionController`` serializes lifecycle operations (connect, model,
visibility, verify) and applies the xCreen model default.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Awaitable, Callable

from .errors import Cancelled, GatewayError, ProtocolError, ProviderFailure, RemoteFailure, Unavailable
from .gateway import Event, HermesGateway, Launch
from .receipts import BatchReceipt, ProtocolFailure
from .store import Binding

log = logging.getLogger("xcreen.session")

TERMINAL = {"message.complete", "run.completed", "turn.completed", "message.failed", "run.failed", "turn.failed", "error"}
CANCELLED = {"message.cancelled", "run.cancelled", "turn.cancelled", "session.interrupted"}
BUILT_IN_MODEL = ("anthropic", "claude-haiku-5-5")


def provider_failure(event_type: str, payload: dict) -> ProviderFailure | None:
    """Stock Hermes closes provider errors with ``message.complete {status:"error", error_surface:{code}}``."""
    failed = event_type in ("message.failed", "run.failed", "turn.failed", "error") or payload.get("status") == "error"
    if not failed:
        return None
    surface = payload.get("error_surface") if isinstance(payload.get("error_surface"), dict) else {}
    code = str(surface.get("code") or "").lower()
    text = f"{payload.get('error') or ''} {payload.get('failure_reason') or ''}".lower()
    limited = code in ("rate_limit", "upstream_rate_limit", "rate_limited") or any(
        token in text for token in ("429", "rate limit", "rate-limit", "usage limit", "too many requests"))
    return ProviderFailure(limited)


def decode_inventory(inventory: dict) -> list[tuple[str, str]]:
    """``providers[] = {slug, models: [str]}`` from ``model.options``; identifiers kept verbatim."""
    providers = inventory.get("providers")
    if not isinstance(providers, list):
        raise ProtocolError("model inventory has no providers")
    routes = []
    for provider in providers:
        slug = provider.get("slug") if isinstance(provider, dict) else None
        if not isinstance(slug, str) or not slug:
            continue
        for model in provider.get("models") or []:
            if isinstance(model, str) and model:
                routes.append((slug, model))
    return routes


class StateFile:
    """Small persisted server state: session identity, visibility, model default."""

    def __init__(self, path: str | Path):
        self.path = Path(path)
        try:
            self.values = json.loads(self.path.read_text())
        except (FileNotFoundError, ValueError):
            self.values = {}

    def get(self, key, default=None):
        return self.values.get(key, default)

    def set(self, **values) -> None:
        self.values.update(values)
        temporary = self.path.with_name(f".{self.path.name}.{uuid.uuid4().hex}")
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w") as handle:
            json.dump(self.values, handle, indent=1)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, self.path)


@dataclass
class Turn:
    id: str
    kind: str  # "manual" | "automatic"
    text: str
    future: asyncio.Future
    epoch: int
    images: list[tuple[str, Path]] = field(default_factory=list)
    binding: Binding | None = None
    phase_changed: Callable[[str], Awaitable[None]] | None = None
    prepared: Callable[[str], Awaitable[None]] | None = None
    receipt_changed: Callable[[BatchReceipt], Awaitable[None]] | None = None


class SessionRuntime:
    HARD_COMPACTION_THRESHOLD = 500_000
    HARD_COMPACTION_KEEP_LAST = 2

    def __init__(self, gateway: HermesGateway, state: StateFile):
        self.gateway = gateway
        self.state = state
        self.manual: list[Turn] = []
        self.automatic: list[Turn] = []
        self.current: Turn | None = None
        self.draining = False
        self.connected = False
        self.generation = 0
        self.cancelled_manual: set[str] = set()
        self.current_cancelled = False
        self.current_submitting = False
        self.awaiting_admission = False
        self.delayed_terminal: Event | None = None
        self.output = ""
        self.reconciling: str | None = None
        self.context_tokens = 0
        self.context_limit = 500_000
        self.integrity = True
        self.epoch = 0
        self.compacting = False
        self.hard_compactions = 0
        self.listeners: list[Callable[[Event], None]] = []
        self._events: asyncio.Task | None = None
        self._queue: asyncio.Queue | None = None
        self._tasks: set[asyncio.Task] = set()

    @property
    def session_id(self) -> str | None:
        return self.state.get("runtime_session_id") if self.connected else None

    def _spawn(self, coro) -> asyncio.Task:
        task = asyncio.create_task(coro)
        self._tasks.add(task)
        task.add_done_callback(self._tasks.discard)
        return task

    async def connect(self, launch: Launch) -> None:
        self.generation += 1
        token = self.generation
        await self.gateway.start(launch)
        identity = await self.gateway.open(self.state.get("stored_session_id"))
        if token != self.generation:
            raise Unavailable()
        self.state.set(stored_session_id=identity.stored_id, runtime_session_id=identity.runtime_id)
        if not (await self.gateway.capabilities()).get("per_session_exclusive_submit"):
            raise ProtocolError("Hermes gateway lacks per-session exclusive submit.")
        if token != self.generation:
            raise Unavailable()
        self.connected = True
        self._observe(token)

    async def disconnect(self) -> None:
        self.generation += 1
        self.connected = False
        if self._events:
            self._events.cancel()
            self._events = None
        if self._queue is not None:
            self.gateway.unsubscribe(self._queue)
            self._queue = None
        self._fail_queues(Unavailable())
        self._finish(Unavailable())
        await self.gateway.stop()

    async def set_integrity(self, enabled: bool) -> None:
        self.integrity = enabled
        if not enabled:
            return
        self.epoch += 1
        rejected, self.automatic = self.automatic, []
        for turn in rejected:
            if not turn.future.done():
                turn.future.set_exception(Cancelled())
        if self.current and self.current.kind == "automatic" and self.session_id:
            try:
                await self.gateway.cancel(self.session_id)
            except GatewayError:
                pass

    async def submit_manual(self, text: str, turn_id: str | None = None, connection_token: int | None = None) -> str:
        _validate(text)
        turn_id = turn_id or str(uuid.uuid4())
        if turn_id in self.cancelled_manual:
            self.cancelled_manual.discard(turn_id)
            raise Cancelled()
        if not self.connected:
            raise Unavailable()
        if connection_token is not None and connection_token != self.generation:
            raise Unavailable()
        return await self._enqueue(Turn(turn_id, "manual", text, asyncio.get_running_loop().create_future(), self.epoch))

    async def submit_automatic(self, manifest: str, images: list[tuple[str, Path]], *, binding: Binding | None = None,
                               prepared=None, receipt_changed=None, phase_changed=None) -> str:
        if self.integrity:
            raise Cancelled()
        if not self.connected:
            raise Unavailable()
        _validate(manifest)
        return await self._enqueue(Turn(str(uuid.uuid4()), "automatic", manifest, asyncio.get_running_loop().create_future(), self.epoch,
                                        images, binding, phase_changed, prepared, receipt_changed))

    async def switch_model(self, model: str, provider: str) -> None:
        await self._wait_idle()
        if not self.session_id:
            raise Unavailable()
        await self.gateway.switch_model(self.session_id, model, provider)

    async def model_options(self) -> dict:
        await self._wait_idle()
        if not self.session_id:
            raise Unavailable()
        return await self.gateway.models(self.session_id)

    async def cancel_manual(self, turn_id: str) -> None:
        """Cancel an admitted user question, not whichever automatic turn owns the session. A
        tombstone covers cancellation before the caller's submission is scheduled."""
        for index, turn in enumerate(self.manual):
            if turn.id == turn_id:
                self.manual.pop(index)
                if not turn.future.done():
                    turn.future.set_exception(Cancelled())
                return
        if self.current and self.current.id == turn_id:
            self.current_cancelled = True
            if self.current_submitting and self.session_id:
                await self.gateway.cancel(self.session_id)
        else:
            self.cancelled_manual.add(turn_id)

    def update_usage(self, tokens: int, limit: int | None) -> None:
        self.context_tokens = max(0, int(tokens or 0))
        if limit and limit > 0:
            self.context_limit = int(limit)
        self._drain_if_needed()

    async def read_receipt(self, binding: Binding, session_id: str) -> BatchReceipt:
        data = await self.gateway.batch_receipt(session_id, binding.batch_id, binding.source_ids)
        try:
            return BatchReceipt.parse(data, batch_id=binding.batch_id, source_ids=binding.source_ids, session_id=session_id)
        except ProtocolFailure as exc:
            raise ProtocolError(str(exc)) from exc

    # ── queue ────────────────────────────────────────────────────────────────

    async def _enqueue(self, turn: Turn) -> str:
        (self.manual if turn.kind == "manual" else self.automatic).append(turn)
        self._drain_if_needed()
        return await turn.future

    @property
    def _hard_compaction_due(self) -> bool:
        return self.connected and not self.compacting and self.context_tokens >= self.HARD_COMPACTION_THRESHOLD and bool(self.session_id)

    def _drain_if_needed(self) -> None:
        if self.draining or self.current is not None or not (self.manual or self.automatic or self._hard_compaction_due):
            return
        self.draining = True
        self._spawn(self._drain_one())

    async def _hard_compact_if_due(self) -> None:
        if not self._hard_compaction_due:
            return
        session_id, before = self.session_id, self.context_tokens
        self.compacting = True
        try:
            await self.gateway.compact_hard(session_id, self.HARD_COMPACTION_KEEP_LAST)
            self.hard_compactions += 1
            log.info("hard compaction (/compress here %d) at ~%d tokens", self.HARD_COMPACTION_KEEP_LAST, before)
        except GatewayError as exc:
            log.warning("hard compaction failed at ~%d tokens: %s", before, exc)
        finally:
            self.compacting = False
            # Fresh usage arrives with the next session.info; never retry-loop on a stale count.
            if self.context_tokens == before:
                self.context_tokens = 0

    async def _drain_one(self) -> None:
        try:
            session_id = self.session_id
            if not self.connected or not session_id:
                self._fail_queues(Unavailable())
                return
            await self._hard_compact_if_due()
            if not self.connected or self.session_id != session_id:
                self._fail_queues(Unavailable())
                return
            turn = self.manual.pop(0) if self.manual else (self.automatic.pop(0) if self.automatic else None)
            if turn is None:
                return
            self.current, self.current_cancelled, self.current_submitting = turn, False, False
            self.awaiting_admission, self.delayed_terminal, self.output = False, None, ""
            try:
                await self._compact_if_needed(len(turn.text.encode()) // 3 + len(turn.images) * 1000)
                if self.current is not turn or self.current_cancelled:
                    raise Cancelled()
                self.current_submitting = turn.kind == "automatic"
                self.awaiting_admission = turn.kind == "automatic" and turn.phase_changed is not None
                if turn.kind == "automatic":
                    if self.integrity or turn.epoch != self.epoch:
                        raise Cancelled()
                    if turn.phase_changed:
                        await turn.phase_changed("submitting")
                    if turn.binding:
                        if turn.prepared:
                            await turn.prepared(session_id)  # persist identity before any host-side preparation
                        if not self._transmission_allowed(turn):
                            raise Cancelled()
                        reply = await self.gateway.prepare_batch(session_id, turn.binding.batch_id, turn.binding.source_ids)
                        if (reply.get("prepared") is not True or reply.get("batch_id") != turn.binding.batch_id
                                or reply.get("session_id") != session_id or sorted(reply.get("source_ids") or []) != sorted(turn.binding.source_ids)):
                            raise ProtocolError("Hermes did not confirm the batch binding.")
                    if not self._transmission_allowed(turn):
                        raise Cancelled()
                    await self.gateway.submit_batch(session_id, turn.text, turn.images, lambda: self._transmission_allowed(turn))
                    if turn.phase_changed:
                        await turn.phase_changed("admitted")
                else:
                    await self.gateway.manual_context(session_id)
                    if self.current is not turn or self.current_cancelled or not self.connected or self.session_id != session_id:
                        raise Cancelled()
                    self.current_submitting = True
                    await self.gateway.submit(session_id, turn.text)
                if self.current is not turn:
                    return
                self.awaiting_admission = False
                if self.delayed_terminal is not None:
                    event, self.delayed_terminal = self.delayed_terminal, None
                    self.receive(event, self.generation)
                # Completion is intentionally deferred to a terminal event.
            except Exception as exc:  # noqa: BLE001 - every failure finishes this turn
                if self.current is turn:
                    self._finish(exc)
        finally:
            self.draining = False
            if self.current is None:
                self._drain_if_needed()

    def _transmission_allowed(self, turn: Turn) -> bool:
        return (self.connected and not self.integrity and self.epoch == turn.epoch and self.current is turn
                and turn.kind == "automatic")

    def _observe(self, generation: int) -> None:
        if self._events:
            self._events.cancel()
        queue = self.gateway.subscribe()
        self._queue = queue

        async def pump():
            while True:
                event = await queue.get()
                if event is None:
                    break
                self.receive(event, generation)
                for listener in list(self.listeners):
                    try:
                        listener(event)
                    except Exception:  # noqa: BLE001 - listeners never break the session
                        log.exception("event listener failed")
            self._gateway_disconnected(generation)
        self._events = self._spawn(pump())

    def receive(self, event: Event, generation: int) -> None:
        if generation != self.generation:
            return
        if self.awaiting_admission and self.current and self.current.phase_changed and event.type in TERMINAL | CANCELLED:
            self.delayed_terminal = event
            return
        body = event.body
        if event.type in ("message.delta", "message.interim"):
            self.output += body.get("text") or ""
        elif event.type in ("session.info", "session.usage"):
            usage = body.get("usage")
            if isinstance(usage, dict):
                self.update_usage(usage.get("context_used") or 0, usage.get("context_max"))
        elif event.type in TERMINAL:
            failure = provider_failure(event.type, body)
            if failure is None and isinstance(body.get("text"), str) and body["text"]:
                self.output = body["text"]
            turn = self.current
            fenced = self.current_cancelled or (turn is not None and turn.kind == "automatic" and (self.integrity or turn.epoch != self.epoch))
            if turn is None:
                return
            if fenced and (turn.kind != "automatic" or turn.binding is None):
                self._finish(Cancelled())
            elif turn.binding is not None and self.session_id:
                # A fenced automatic turn may already have written its durable host receipt before
                # the interrupt; reading it transmits nothing, so reconcile instead of leaving it uncertain.
                if self.reconciling == turn.id:
                    return
                self.reconciling = turn.id
                self._spawn(self._reconcile(turn, self.session_id, fenced, failure))
            elif failure is not None and turn.kind == "automatic":
                self._finish(failure)
            elif failure is not None and event.type != "message.complete":
                self._finish(RemoteFailure("turn failed"))
            else:
                # Manual error completions keep Hermes's explanatory text as the answer.
                if isinstance(body.get("text"), str) and body["text"]:
                    self.output = body["text"]
                self._finish(None)
        elif event.type in CANCELLED:
            self._finish(Cancelled())

    async def _reconcile(self, turn: Turn, session_id: str, fenced: bool, failure: ProviderFailure | None) -> None:
        try:
            # Even a failed turn may have produced effects before failing.
            receipt = await self.read_receipt(turn.binding, session_id)
            if self.current is not turn:
                return
            if turn.receipt_changed:
                await turn.receipt_changed(receipt)
            if self.current is not turn:
                return
            if receipt.completes_processing:
                self._finish(None)
            elif fenced:
                self._finish(Cancelled())
            else:
                self._finish(failure or RemoteFailure("batch processing receipt missing or uncertain"))
        except Exception as exc:  # noqa: BLE001
            if self.current is turn:
                self._finish(exc)

    def _finish(self, error: BaseException | None) -> None:
        turn = self.current
        if turn is None:
            return
        self.current = None
        self.reconciling = None
        if not turn.future.done():
            if error is not None:
                turn.future.set_exception(error)
            else:
                turn.future.set_result(self.output)
        self._drain_if_needed()

    def _gateway_disconnected(self, generation: int) -> None:
        if generation != self.generation:
            return
        self.connected = False
        self._events = None
        self._fail_queues(Unavailable())
        self._finish(Unavailable())
        for listener in list(self.listeners):
            try:
                listener(Event("gateway.disconnected", {}))
            except Exception:  # noqa: BLE001
                pass

    def _fail_queues(self, error: BaseException) -> None:
        turns, self.manual, self.automatic = self.manual + self.automatic, [], []
        for turn in turns:
            if not turn.future.done():
                turn.future.set_exception(error)

    async def _wait_idle(self) -> None:
        while self.current is not None or self.draining:
            await asyncio.sleep(0.01)

    async def _compact_if_needed(self, incoming: int) -> None:
        cap = min(500_000, max(1, self.context_limit - incoming - 8192))
        if self.context_tokens >= cap and self.session_id:
            await self.gateway.compress(self.session_id)
            self.context_tokens = 0


def _validate(text: str) -> None:
    if not isinstance(text, str) or not text.strip() or len(text.encode()) > 32_000:
        raise ProtocolError("turn text must be non-empty and at most 32,000 bytes")


class SessionController:
    """Lifecycle owner. Operations are serialized FIFO (asyncio.Lock is fair); integrity
    changes bypass the lock so a slow connection can't delay a pause."""

    def __init__(self, runtime: SessionRuntime, launch: Callable[[], Launch]):
        self.runtime = runtime
        self.gateway = runtime.gateway
        self.state = runtime.state
        self.launch = launch
        self.lock = asyncio.Lock()
        self.connected = False
        self.read_only = False
        self.generation = 0
        self.actual_visible: bool | None = None
        self.model_applied = False
        self.model_status = "Not applied yet; waiting for the xCreen session."
        self.inventory: dict | None = None
        self.on_ready: Callable[[], Awaitable[None]] | None = None
        self.last_error = ""
        self.closed = False
        self._ready_task: asyncio.Task | None = None
        runtime.listeners.append(self._on_event)

    # persisted preferences
    @property
    def session_visible(self) -> bool:
        return bool(self.state.get("session_visible", False))

    @property
    def model_preference(self) -> tuple[str, str]:
        pref = self.state.get("model_default") or {}
        provider, model = pref.get("provider"), pref.get("model")
        return (provider, model) if provider and model else BUILT_IN_MODEL

    @property
    def visibility_pending(self) -> bool:
        return self.actual_visible != self.session_visible

    def _on_event(self, event: Event) -> None:
        if event.type == "gateway.disconnected" and self.connected:
            self.generation += 1
            self.connected = False
            self.actual_visible = None

    async def connect(self) -> None:
        async with self.lock:
            await self._connect()

    async def disconnect(self) -> None:
        async with self.lock:
            await self._disconnect()

    async def reconnect(self) -> None:
        async with self.lock:
            await self._disconnect()
            await self._connect()

    async def close(self) -> None:
        """Final shutdown: no later operation may reconnect."""
        self.closed = True
        if self._ready_task and not self._ready_task.done():
            self._ready_task.cancel()
            try:
                await self._ready_task
            except BaseException:  # noqa: BLE001 - cancelled or failed, either way finished
                pass
        async with self.lock:
            await self._disconnect()

    async def _connect(self) -> None:
        if self.closed:
            raise Unavailable("The xCreen server is stopping.")
        if self.connected and self.runtime.connected:
            return
        self.generation += 1
        token = self.generation
        try:
            await self.runtime.connect(self.launch())
            try:
                await self._apply_visibility()
            except GatewayError:
                self.actual_visible = None
            inventory = await self.runtime.model_options()
            if token != self.generation:
                raise Unavailable()
            # Before the ready hook: pending automatic work must run on the xCreen default.
            self.inventory = await self._apply_model_preference(inventory, token)
            if token != self.generation:
                raise Unavailable()
            self.connected = True
            self.last_error = ""
            log.info("connected session=%s runtime=%s", self.state.get("stored_session_id"), self.state.get("runtime_session_id"))
        except Exception as exc:
            self.last_error = str(exc)
            await self._disconnect()
            raise
        if self.on_ready and not self.read_only:
            self._ready_task = asyncio.get_running_loop().create_task(self.on_ready())

    async def _disconnect(self) -> None:
        self.generation += 1
        self.model_applied = False
        self.connected = False
        self.actual_visible = None
        await self.runtime.disconnect()

    async def _apply_visibility(self) -> None:
        self.actual_visible = None
        session_id = self.runtime.session_id
        if not session_id:
            raise Unavailable()
        token = self.generation
        hidden = await self.gateway.set_hidden(session_id, not self.session_visible)
        if token != self.generation or hidden != (not self.session_visible):
            raise ProtocolError("Hermes did not confirm session visibility.")
        self.actual_visible = not hidden

    async def set_visible(self, visible: bool) -> None:
        async with self.lock:
            self.state.set(session_visible=visible)
            if self.connected:
                await self._apply_visibility()

    async def model_options(self) -> dict:
        async with self.lock:
            await self._connect()
            token = self.generation
            inventory = await self.runtime.model_options()
            if not self.connected or token != self.generation:
                raise Unavailable()
            self.inventory = inventory
            return inventory

    async def switch_model(self, provider: str, model: str) -> None:
        """Picker/CLI selection: switch the xCreen session, then persist it as the default."""
        async with self.lock:
            await self._connect()
            routes = decode_inventory(self.inventory or await self.runtime.model_options())
            if (provider, model) not in routes:
                raise RemoteFailure(f"{provider} · {model} is not in Hermes's configured model inventory")
            token = self.generation
            await self.runtime.switch_model(model, provider)
            if not self.connected or token != self.generation:
                raise Unavailable()
            self.state.set(model_default={"provider": provider, "model": model})
            self.model_applied, self.model_status = True, "Applied to the xCreen session."

    async def set_default_model(self, provider: str, model: str) -> None:
        """Offline the preference is saved and applied on the next connect; connected, it must
        exist in the live inventory or it is rejected."""
        async with self.lock:
            if not self.connected:
                self.state.set(model_default={"provider": provider, "model": model})
                self.model_applied, self.model_status = False, "Saved; will be applied to the xCreen session on connect."
                return
            token = self.generation
            inventory = await self.runtime.model_options()
            if token != self.generation:
                raise Unavailable()
            if (provider, model) not in decode_inventory(inventory):
                raise RemoteFailure(f"{provider} · {model} is not in Hermes's configured model inventory; default unchanged")
            self.state.set(model_default={"provider": provider, "model": model})
            self.inventory = await self._apply_model_preference(inventory, token)

    async def _apply_model_preference(self, inventory: dict, token: int) -> dict:
        """Resolve the preference against live ``model.options``; never substitute another route."""
        provider, model = self.model_preference
        self.model_applied = False
        try:
            routes = decode_inventory(inventory)
        except ProtocolError:
            self.model_status = "Unavailable: Hermes model inventory could not be read; session model unchanged."
            return inventory
        if (provider, model) not in routes:
            def leaf(value: str) -> str:
                return value.split("/")[-1].replace(".", "-")
            alternatives = [f"{p} · {m}" for p, m in routes if leaf(m) == leaf(model)][:3]
            self.model_status = (f"Unavailable: {provider} · {model} is not in Hermes's configured inventory; session model unchanged (no fallback)."
                                 + (f" Configured alternatives: {', '.join(alternatives)}." if alternatives else ""))
            return inventory
        if inventory.get("provider") == provider and inventory.get("model") == model:
            self.model_applied, self.model_status = True, "Applied to the xCreen session."
            return inventory
        try:
            await self.runtime.switch_model(model, provider)
            if token != self.generation:
                return inventory
            # The gateway verified Hermes's session-scoped ack; model.options on a lazy session
            # reports the profile default, not the override.
            self.model_applied, self.model_status = True, "Applied to the xCreen session."
            try:
                return await self.runtime.model_options()
            except GatewayError:
                return inventory
        except GatewayError as exc:
            self.model_status = f"Switch to {provider} · {model} failed: {exc}"
            return inventory

    async def history_page(self, cursor: str | None) -> dict:
        async with self.lock:
            await self._connect()
            session_id = self.runtime.session_id
            if not session_id:
                raise Unavailable()
            return await self.gateway.history_page(session_id, cursor)

    async def verify(self, store) -> int:
        async with self.lock:
            return await self._verify(store)

    async def recover(self, store) -> int:
        """Verify, then return only receipt-proven effect-free, non-terminal uncertain batches to
        pending. Never submits inference itself."""
        async with self.lock:
            failure = None
            try:
                await self._verify(store)
            except Exception as exc:  # noqa: BLE001
                failure = exc
            requeued = sum(1 for batch_id in store.uncertain_ids() if store.requeue_retry_safe(batch_id))
            if failure is not None and requeued == 0:
                raise failure
            return requeued

    async def _verify(self, store) -> int:
        self.read_only = True
        try:
            await self._connect()
        finally:
            self.read_only = False
        verified, failure = 0, None
        for binding in store.bindings():
            if not binding.session_id:
                continue
            try:
                receipt = await self.runtime.read_receipt(binding, binding.session_id)
                store.reconcile(receipt)
                verified += 1 if receipt.completes_processing else 0
            except Exception as exc:  # noqa: BLE001
                store.invalidate_receipt(binding.batch_id)
                failure = exc
        if failure is not None:
            raise failure
        return verified
