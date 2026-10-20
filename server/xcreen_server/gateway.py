"""Adapter for Hermes's stdio JSON-RPC ``tui_gateway`` (port of the 1.x Swift HermesGateway).

The gateway runs as a child process started through ``runtime/xcreen_gateway.py``, which
registers only the scoped xCreen tools and RPC methods before handing over to Hermes.
"""
from __future__ import annotations

import asyncio
import base64
import itertools
import json
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Awaitable, Callable

from .errors import Cancelled, DeadlineExceeded, ProtocolError, RemoteFailure, Unavailable

MAX_LINE = 1_048_576
# Hermes's image.attach_bytes limit per attachment.
MAX_ATTACHMENT = 8 * 1024 * 1024
SAFE_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
_PASSTHROUGH = {"HOME", "USER", "LOGNAME", "LANG", "TMPDIR", "TZ", "SHELL", "__CF_USER_TEXT_ENCODING",
                "SSL_CERT_FILE", "SSL_CERT_DIR", "REQUESTS_CA_BUNDLE"}
_ATTACHMENT_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


def child_environment(parent: dict[str, str]) -> dict[str, str]:
    """Identity, locale, temp dir and Hermes's own ``HERMES_*`` settings only. Interpreter and
    loader injection variables (PYTHONPATH, PYTHONHOME, DYLD_*, LD_*) are dropped."""
    env = {k: v for k, v in parent.items() if k in _PASSTHROUGH or k.startswith("LC_") or k.startswith("HERMES_")}
    env["PATH"] = SAFE_PATH
    env["PYTHONUNBUFFERED"] = "1"
    return env


def attachment_filename(ident: str, data: bytes) -> str:
    """Hermes infers the media type from the filename, so it follows the bytes."""
    suffix = "jpg" if data.startswith(b"\xff\xd8\xff") else "png"
    return f"{ident}.{suffix}"


@dataclass(frozen=True)
class Launch:
    """How to start the gateway child: ``bundled`` uses the scoped runtime; ``command`` is a
    raw argv used by tests with a fake gateway."""
    executable: str
    arguments: tuple[str, ...]
    cwd: str | None = None

    @classmethod
    def bundled(cls, *, python: str, hermes_root: str, evidence_root: str, runtime_dir: str, vault: str | None, timezone: str) -> "Launch":
        def directory(path: str | None) -> bool:
            return bool(path) and os.path.isabs(path) and os.path.isdir(path)
        launcher = os.path.join(runtime_dir, "xcreen_gateway.py")
        if not (os.path.isabs(python) and os.access(python, os.X_OK) and directory(hermes_root) and directory(evidence_root)
                and os.path.isfile(launcher)):
            raise Unavailable("Hermes is not configured: set hermes_python and hermes_root (xcreen-server init).")
        args = ["-B", launcher, "--hermes-root", hermes_root, "--evidence-root", evidence_root, "--timezone", timezone]
        if vault:
            if not directory(vault):
                raise Unavailable(f"Configured vault is not a directory: {vault}")
            args += ["--vault", vault]
        return cls(python, tuple(args), os.path.dirname(runtime_dir))


@dataclass(frozen=True)
class Event:
    type: str
    payload: dict

    @property
    def body(self) -> dict:
        value = self.payload.get("payload")
        return value if isinstance(value, dict) else {}


@dataclass(frozen=True)
class SessionIdentity:
    stored_id: str
    runtime_id: str


class HermesGateway:
    def __init__(self, *, default_deadline: float = 20, long_deadline: float = 600, stderr_path: str | None = None):
        self.default_deadline = min(max(default_deadline, 0.1), 60)
        self.long_deadline = min(max(long_deadline, self.default_deadline), 1800)
        self.stderr_path = stderr_path
        self._process: asyncio.subprocess.Process | None = None
        self._token = 0
        self._ids = itertools.count(1)
        self._pending: dict[int, asyncio.Future] = {}
        self._long: dict[int, list[float]] = {}
        self._subscribers: list[asyncio.Queue] = []
        self._ready = asyncio.Event()
        self._reader: asyncio.Task | None = None

    @property
    def running(self) -> bool:
        return self._process is not None and self._process.returncode is None

    async def start(self, launch: Launch) -> None:
        if self._process is not None:
            return
        self._token += 1
        token = self._token
        stderr = open(self.stderr_path, "ab") if self.stderr_path else asyncio.subprocess.DEVNULL
        try:
            self._process = await asyncio.create_subprocess_exec(
                launch.executable, *launch.arguments, cwd=launch.cwd, env=child_environment(dict(os.environ)),
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=stderr, limit=MAX_LINE * 2)
        finally:
            if hasattr(stderr, "close"):
                stderr.close()
        self._ready = asyncio.Event()
        self._reader = asyncio.create_task(self._read(token, self._process))
        try:
            await asyncio.wait_for(self._ready.wait(), timeout=self.default_deadline)
        except asyncio.TimeoutError:
            await self.stop()
            raise DeadlineExceeded()
        if not self.running:
            raise Unavailable()
        await self.request("client.capabilities", {"server_requests": False})

    def subscribe(self) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue(maxsize=1024)
        self._subscribers.append(queue)
        return queue

    def unsubscribe(self, queue: asyncio.Queue) -> None:
        if queue in self._subscribers:
            self._subscribers.remove(queue)

    def _broadcast(self, item) -> None:
        for queue in list(self._subscribers):
            if queue.full():
                try:
                    queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass
            queue.put_nowait(item)

    async def _read(self, token: int, process: asyncio.subprocess.Process) -> None:
        remainder = b""
        discarding = False
        assert process.stdout is not None
        try:
            while True:
                chunk = await process.stdout.read(65536)
                if not chunk:
                    break
                remainder += chunk
                while b"\n" in remainder:
                    line, remainder = remainder.split(b"\n", 1)
                    if not discarding and len(line) <= MAX_LINE:
                        self._receive(line, token)
                    discarding = False
                if len(remainder) > MAX_LINE:
                    remainder, discarding = b"", True
        finally:
            self._disconnect(token)

    def _receive(self, line: bytes, token: int) -> None:
        if token != self._token:
            return
        try:
            obj = json.loads(line)
        except ValueError:
            return
        if not isinstance(obj, dict):
            return
        if obj.get("method") == "event" and isinstance(obj.get("params"), dict) and isinstance(obj["params"].get("type"), str):
            now = time.monotonic()
            for wait in self._long.values():
                wait[1] = now
            event = Event(obj["params"]["type"], obj["params"])
            if event.type == "gateway.ready":
                self._ready.set()
            self._broadcast(event)
            return
        rid = obj.get("id")
        future = self._pending.pop(rid, None) if isinstance(rid, int) else None
        if future is None or future.done():
            return
        self._long.pop(rid, None)
        if isinstance(obj.get("error"), dict):
            future.set_exception(RemoteFailure(str(obj["error"].get("message", "unknown error"))))
        elif "result" in obj:
            future.set_result(obj["result"])
        else:
            future.set_exception(ProtocolError())

    def _disconnect(self, token: int | None = None) -> None:
        if token is not None and token != self._token:
            return
        self._token += 1
        self._process = None
        self._ready.set()
        for queue in list(self._subscribers):
            self._broadcast_end(queue)
        self._subscribers.clear()
        pending, self._pending = self._pending, {}
        self._long.clear()
        for future in pending.values():
            if not future.done():
                future.set_exception(Unavailable())

    @staticmethod
    def _broadcast_end(queue: asyncio.Queue) -> None:
        if queue.full():
            try:
                queue.get_nowait()
            except asyncio.QueueEmpty:
                pass
        queue.put_nowait(None)

    async def stop(self) -> None:
        process = self._process
        self._disconnect()
        if process is not None and process.returncode is None:
            process.terminate()
            try:
                await asyncio.wait_for(process.wait(), timeout=5)
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()

    async def request(self, method: str, params: dict, *, long: bool = False):
        process = self._process
        if process is None or process.returncode is not None or process.stdin is None:
            raise Unavailable()
        rid = next(self._ids)
        future = asyncio.get_running_loop().create_future()
        self._pending[rid] = future
        frame = json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}, ensure_ascii=False).encode() + b"\n"
        try:
            process.stdin.write(frame)
            await process.stdin.drain()
        except (ConnectionError, RuntimeError) as exc:
            self._pending.pop(rid, None)
            raise Unavailable() from exc
        if long:
            now = time.monotonic()
            self._long[rid] = [now, now]
            return await self._await_long(rid, future)
        try:
            return await asyncio.wait_for(asyncio.shield(future), timeout=self.default_deadline)
        except asyncio.TimeoutError:
            self._pending.pop(rid, None)
            raise DeadlineExceeded()

    async def _await_long(self, rid: int, future: asyncio.Future):
        """Idle deadline that any gateway event resets, bounded by ``long_deadline``."""
        while True:
            wait = self._long.get(rid)
            if wait is None:
                return await future
            now = time.monotonic()
            started, progress = wait
            if now - progress >= self.default_deadline or now - started >= self.long_deadline:
                self._long.pop(rid, None)
                self._pending.pop(rid, None)
                raise DeadlineExceeded()
            remaining = min(progress + self.default_deadline, started + self.long_deadline) - now
            try:
                return await asyncio.wait_for(asyncio.shield(future), timeout=max(remaining, 0.01))
            except asyncio.TimeoutError:
                continue

    # ── typed methods ────────────────────────────────────────────────────────

    @staticmethod
    def _object(value) -> dict:
        if not isinstance(value, dict):
            raise ProtocolError()
        return value

    async def capabilities(self) -> dict:
        return self._object(await self.request("gateway.capabilities", {}))

    async def open(self, stored_session_id: str | None) -> SessionIdentity:
        if stored_session_id:
            reply = self._object(await self.request("session.resume", {"session_id": stored_session_id, "lazy": True,
                                                                         "inline_images": False, "omit_messages": True}))
        else:
            reply = self._object(await self.request("session.create", {"source": "desktop", "title": "xCreen", "hidden": True,
                                                                         "close_on_disconnect": False}))
        # session.create and live re-attach return stored_session_id; a cold session.resume returns resumed.
        stored = reply.get("stored_session_id") or reply.get("resumed")
        runtime = reply.get("session_id")
        if not isinstance(stored, str) or not stored or not isinstance(runtime, str) or not runtime:
            raise ProtocolError()
        if stored_session_id and stored != stored_session_id:
            raise ProtocolError("Hermes resumed a different session than requested.")
        return SessionIdentity(stored, runtime)

    async def models(self, session_id: str) -> dict:
        return self._object(await self.request("model.options", {"session_id": session_id, "explicit_only": False}))

    async def history_page(self, session_id: str, cursor: str | None) -> dict:
        params = {"session_id": session_id, "max_bytes": 48_000, "limit": 20}
        if cursor:
            params["cursor"] = cursor
        reply = self._object(await self.request("xcreen.history.page", params))
        if len(json.dumps(reply)) > 48_000:
            raise ProtocolError()
        return reply

    async def manual_context(self, session_id: str) -> None:
        reply = self._object(await self.request("xcreen.batch.context", {"session_id": session_id, "mode": "manual"}, long=True))
        if reply.get("session_id") != session_id or reply.get("mode") != "manual":
            raise ProtocolError()

    async def prepare_batch(self, session_id: str, batch_id: str, source_ids: list[str]) -> dict:
        return self._object(await self.request("xcreen.batch.prepare", {"session_id": session_id, "batch_id": batch_id, "source_ids": source_ids}))

    async def batch_receipt(self, session_id: str, batch_id: str, source_ids: list[str]) -> dict:
        return self._object(await self.request("xcreen.batch.receipt", {"session_id": session_id, "batch_id": batch_id,
                                                                         "source_ids": source_ids, "reconcile": True}))

    async def set_hidden(self, session_id: str, hidden: bool) -> bool:
        reply = self._object(await self.request("session.set_hidden", {"session_id": session_id, "hidden": hidden}))
        if type(reply.get("hidden")) is not bool or not isinstance(reply.get("session_key"), str) or not reply["session_key"]:
            raise ProtocolError()
        return reply["hidden"]

    async def switch_model(self, session_id: str, model: str, provider: str) -> dict:
        if not _valid_text(model, 256) or not _valid_text(provider, 128):
            raise ProtocolError()
        # config.set pins a per-session model_override even on a lazy resumed session with no live
        # agent; slash.exec /model silently no-ops there.
        reply = self._object(await self.request("config.set", {"session_id": session_id, "key": "model",
                                                                "value": f"{model} --provider {provider} --session"}))
        if reply.get("value") != model or reply.get("scope") != "session" or reply.get("confirm_required") is True:
            raise RemoteFailure(f"Hermes did not confirm a session-scoped switch to {provider} · {model}")
        return reply

    async def compress(self, session_id: str) -> None:
        await self.request("session.compress", {"session_id": session_id}, long=True)

    async def compact_hard(self, session_id: str, keep_last: int) -> None:
        """Hermes parses ``here N`` in ``session.compress``'s focus_topic and keeps only the last N exchanges."""
        await self.request("session.compress", {"session_id": session_id, "focus_topic": f"here {min(max(keep_last, 1), 20)}"}, long=True)

    async def submit(self, session_id: str, text: str) -> None:
        if not _valid_text(text, 32_000):
            raise ProtocolError()
        await self.request("prompt.submit", {"session_id": session_id, "text": text}, long=True)

    async def submit_batch(self, session_id: str, text: str, images: list[tuple[str, Path]],
                           allowed: Callable[[], Awaitable[bool] | bool]) -> None:
        if not images or len(images) > 64 or not _valid_text(text, 32_000):
            raise ProtocolError()

        async def permitted() -> bool:
            result = allowed()
            return await result if asyncio.iscoroutine(result) else bool(result)

        for ident, path in images:
            if not await permitted() or not _ATTACHMENT_ID.match(ident):
                raise Cancelled()
            data = await asyncio.to_thread(Path(path).read_bytes)
            if not data or len(data) > MAX_ATTACHMENT:
                raise ProtocolError(f"attachment {ident} is {len(data)} bytes; the limit is {MAX_ATTACHMENT}")
            if not await permitted():
                raise Cancelled()
            await self.request("image.attach_bytes", {"session_id": session_id, "content_base64": base64.b64encode(data).decode(),
                                                      "filename": attachment_filename(ident, data)})
        if not await permitted():
            raise Cancelled()
        await self.submit(session_id, text)

    async def cancel(self, session_id: str) -> None:
        await self.request("session.interrupt", {"session_id": session_id})


def _valid_text(value: object, maximum: int) -> bool:
    return isinstance(value, str) and bool(value.strip()) and len(value.encode()) <= maximum
