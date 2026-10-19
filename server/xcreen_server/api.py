"""HTTP/JSON transport for the /v1 protocol (see docs/protocol.md).

Standard library only. Request threads hand every operation to the service's event loop,
so all state is touched from one thread.
"""
from __future__ import annotations

import asyncio
import concurrent.futures
import hmac
import socket
import json
import logging
import re
import threading
from datetime import datetime
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

from . import PROTOCOL, VERSION
from .errors import DeadlineExceeded, GatewayError, Unavailable
from .service import InvalidRequest, XCreenService
from .store import Conflict, StoreError

log = logging.getLogger("xcreen.api")

MAX_JSON = 2_000_000
MAX_IMAGE = 30_000_000
_IMAGE_PATH = re.compile(r"^/v1/images/([A-Za-z0-9-]{1,100})$")
_TURN_PATH = re.compile(r"^/v1/turns/([0-9a-f-]{36})$")


class HTTPError(Exception):
    def __init__(self, status: int, code: str, message: str):
        super().__init__(message)
        self.status, self.code = status, code


def parse_time(value: object) -> datetime:
    if not isinstance(value, str) or len(value) > 40:
        raise HTTPError(400, "invalid_request", "timestamp must be an ISO-8601 string")
    try:
        moment = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        raise HTTPError(400, "invalid_request", "timestamp must be an ISO-8601 string") from None
    if moment.tzinfo is None:
        raise HTTPError(400, "invalid_request", "timestamp needs a UTC offset")
    return moment


class Server(ThreadingHTTPServer):
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, address, service: XCreenService, loop: asyncio.AbstractEventLoop, token: str):
        if ":" in address[0]:
            self.address_family = socket.AF_INET6
        super().__init__(address, Handler)
        self.service, self.loop, self.token = service, loop, token

    def call(self, coroutine, timeout: float = 120):
        future = asyncio.run_coroutine_threadsafe(coroutine, self.loop)
        try:
            return future.result(timeout=timeout)
        except (TimeoutError, concurrent.futures.TimeoutError):
            future.cancel()
            raise DeadlineExceeded("The server did not finish the request in time.")


def _sync(function, *args):
    async def run():
        return function(*args)
    return run()


class Handler(BaseHTTPRequestHandler):
    server: Server
    protocol_version = "HTTP/1.1"
    server_version = f"xcreen-server/{VERSION}"

    def log_message(self, fmt, *args):  # request lines only, never bodies or tokens
        log.debug("%s %s", self.address_string(), fmt % args)

    # ── plumbing ─────────────────────────────────────────────────────────────

    def _send(self, status: int, body: bytes, content_type: str = "application/json") -> None:
        self.send_response(status)
        if status in (400, 413):
            # The request body may be unread; never reuse this connection.
            self.close_connection = True
            self.send_header("Connection", "close")
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, status: int, payload: dict) -> None:
        self._send(status, json.dumps(payload, ensure_ascii=False).encode())

    def _authorized(self) -> bool:
        header = self.headers.get("Authorization", "")
        scheme, _, value = header.partition(" ")
        return scheme.lower() == "bearer" and hmac.compare_digest(value.strip().encode(), self.server.token.encode())

    def _body(self, limit: int) -> bytes:
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            raise HTTPError(400, "invalid_request", "invalid Content-Length") from None
        if length < 0 or length > limit:
            raise HTTPError(413, "too_large", f"request body exceeds {limit} bytes")
        return self.rfile.read(length) if length else b""

    def _payload(self) -> dict:
        raw = self._body(MAX_JSON)
        try:
            value = json.loads(raw or b"{}")
        except ValueError:
            raise HTTPError(400, "invalid_request", "body must be JSON") from None
        if not isinstance(value, dict):
            raise HTTPError(400, "invalid_request", "body must be a JSON object")
        return value

    def _dispatch(self) -> None:
        url = urlsplit(self.path)
        query = {k: v[-1] for k, v in parse_qs(url.query).items()}
        try:
            if url.path == "/v1/health" and self.command == "GET":
                self._json(200, {"ok": True, "protocol": PROTOCOL, "version": VERSION})
                return
            if not self._authorized():
                raise HTTPError(401, "unauthorized", "missing or invalid bearer token")
            result = self._route(self.command, url.path, query)
            if result is not None:
                self._json(200, {"ok": True, **result})
        except HTTPError as exc:
            self._json(exc.status, {"ok": False, "error": {"code": exc.code, "message": str(exc)}})
        except Conflict as exc:
            self._json(409, {"ok": False, "error": {"code": "conflict", "message": str(exc)}})
        except (InvalidRequest, StoreError) as exc:
            self._json(400, {"ok": False, "error": {"code": "invalid_request", "message": str(exc)}})
        except Unavailable as exc:
            self._json(503, {"ok": False, "error": {"code": exc.code, "message": str(exc)}})
        except GatewayError as exc:
            self._json(502, {"ok": False, "error": {"code": exc.code, "message": str(exc)}})
        except Exception:  # noqa: BLE001
            log.exception("unhandled error for %s %s", self.command, url.path)
            self._json(500, {"ok": False, "error": {"code": "internal", "message": "internal server error"}})

    do_GET = do_POST = do_PUT = _dispatch

    # ── routes ───────────────────────────────────────────────────────────────

    def _route(self, method: str, path: str, query: dict):
        s, call = self.server.service, self.server.call
        if method == "GET" and path == "/v1/status":
            return {"status": call(_sync(s.status))}
        if method == "POST" and path == "/v1/ocr":
            items = self._payload().get("items")
            if not isinstance(items, list) or not 1 <= len(items) <= 500 or not all(isinstance(i, dict) for i in items):
                raise HTTPError(400, "invalid_request", "items must be a list of 1-500 objects")
            for item in items:
                item["timestamp"] = parse_time(item.get("timestamp"))
            return call(_sync(s.ingest_ocr, items))
        match = _IMAGE_PATH.match(path)
        if match and method == "PUT":
            data = self._body(MAX_IMAGE)
            return call(_sync(s.ingest_image, match.group(1), parse_time(query.get("timestamp")), data))
        if match and method == "GET":
            image = call(_sync(s.image_path, match.group(1)))
            if image is None:
                raise HTTPError(404, "not_found", "image unavailable or expired")
            data = image.read_bytes()
            self._send(200, data, "image/jpeg" if data.startswith(b"\xff\xd8\xff") else "image/png")
            return None
        if method == "POST" and path == "/v1/capture":
            body = self._payload()
            if type(body.get("integrity")) is not bool or not isinstance(body.get("capture", ""), str) or not isinstance(body.get("reason", ""), str):
                raise HTTPError(400, "invalid_request", "integrity (bool), capture and reason (strings) required")
            return call(s.report_capture(body.get("capture", ""), body.get("reason", ""), body["integrity"]))
        if method == "POST" and path == "/v1/ask":
            record = call(_sync(s.ask, self._payload().get("question")))
            return {"turn": record.public()}
        match = _TURN_PATH.match(path)
        if match and method == "GET":
            after = _int(query.get("after", "-1"), -1, 1 << 31)
            wait = _int(query.get("wait_ms", "0"), 0, 30_000)
            return {"turn": call(s.wait_turn(match.group(1), after, wait), timeout=40)}
        if method == "POST" and path == "/v1/cancel":
            call(s.cancel())
            return {}
        if method == "GET" and path == "/v1/history":
            cursor = query.get("cursor") or None
            return {"history": call(s.history(cursor))}
        if method == "GET" and path == "/v1/batches":
            return {"batches": call(_sync(s.batches, query.get("after", "")))}
        if method == "POST" and path == "/v1/batches/retry":
            return {"requeued": call(s.retry_batches(), timeout=300)}
        if method == "POST" and path == "/v1/batches/verify":
            return {"verified": call(s.verify(), timeout=300)}
        if method == "GET" and path == "/v1/models":
            return call(s.models())
        if method == "PUT" and path == "/v1/model":
            provider, model = self._route_pair()
            call(s.select_model(provider, model))
            return {"status": call(_sync(s.status))}
        if method == "PUT" and path == "/v1/model/default":
            provider, model = self._route_pair()
            call(s.set_default_model(provider, model))
            return {"status": call(_sync(s.status))}
        if method == "PUT" and path == "/v1/session/visibility":
            visible = self._payload().get("visible")
            if type(visible) is not bool:
                raise HTTPError(400, "invalid_request", "visible must be a boolean")
            call(s.set_visible(visible))
            return {"status": call(_sync(s.status))}
        if method == "POST" and path == "/v1/connection":
            call(s.connection(self._payload().get("action")))
            return {"status": call(_sync(s.status))}
        if method == "GET" and path == "/v1/config":
            return {"config": call(_sync(s.config.public))}
        if method == "PUT" and path == "/v1/config":
            return {"config": call(s.configure(self._payload()))}
        if method == "POST" and path == "/v1/config/autodetect":
            return {"config": call(s.autodetect())}
        raise HTTPError(404, "not_found", f"no route for {method} {path}")

    def _route_pair(self) -> tuple[str, str]:
        body = self._payload()
        provider, model = body.get("provider"), body.get("model")
        if not isinstance(provider, str) or not provider or len(provider) > 256 or not isinstance(model, str) or not model or len(model) > 512:
            raise HTTPError(400, "invalid_request", "provider and model are required")
        return provider, model


def _int(value: str, low: int, high: int) -> int:
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise HTTPError(400, "invalid_request", "expected an integer") from None
    return max(low, min(number, high))


def serve(service: XCreenService, loop: asyncio.AbstractEventLoop, token: str, bind: str, port: int) -> Server:
    server = Server((bind, port), service, loop, token)
    thread = threading.Thread(target=server.serve_forever, name="xcreen-http", daemon=True)
    thread.start()
    return server
