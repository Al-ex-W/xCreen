# xCreen protocol v1

The contract between the xCreen client (the Mac app) and `xcreen-server`. It's the same for the complete install (server on `127.0.0.1`) and the split install (server on another machine). See [client and server](client-server.md) for the design.

## Transport

- HTTP/1.1, JSON bodies (UTF-8), base path `/v1`. Images are raw bytes.
- Every request except `GET /v1/health` carries `Authorization: Bearer <token>`. Missing or wrong token: `401`.
- Use it over loopback, a private network such as Tailscale (WireGuard-encrypted), or behind TLS (`tailscale serve`, a reverse proxy, an SSH tunnel). The server refuses to bind `0.0.0.0`/`::`.
- Responses: `{"ok": true, ...}` on success, otherwise `{"ok": false, "error": {"code", "message"}}`.

| Status | Code | Meaning |
|---|---|---|
| 400 | `invalid_request` | Malformed or out-of-range input |
| 401 | `unauthorized` | Missing or invalid token |
| 404 | `not_found` | Unknown route, or an image that's unavailable or expired |
| 409 | `conflict` | Same id uploaded with different content |
| 413 | `too_large` | JSON body over 2 MB or image over 30 MB |
| 502 | `remote_failure`, `provider_failure`, `protocol_failure`, `cancelled` | Hermes rejected or failed the operation |
| 503 | `unavailable` | Hermes is not connected or not configured |

Timestamps are ISO-8601 with an offset (`2026-10-20T09:15:02.120Z`). Ids match `^[A-Za-z0-9-]{1,100}$`.

## Versioning

`GET /v1/health` (no auth) returns `{"ok": true, "protocol": 1, "version": "2.0.0"}`. The client refuses a server whose `protocol` differs. Additive changes (new fields, new routes) keep `protocol: 1`; clients ignore unknown fields.

## Uploads

Uploads are idempotent by id. The client keeps each item in its outbox until the server acknowledges it, and replays in capture order after a failure.

### `POST /v1/ocr`

```json
{"items": [{"id": "ocr-…", "timestamp": "…", "text": "…", "app": "com.example.app", "title": "Window title"}]}
```

1–500 items. `text` 1–12,000 characters; `app` and `title` are truncated to 256 and 1,024 characters. Timestamps must be within the last seven days and not more than five minutes in the future. Returns `{"accepted": n, "duplicates": m}`.

### `PUT /v1/images/{id}?timestamp=…`

Body: PNG or JPEG bytes, at most 30 MB. Returns `{"accepted": 1|0, "duplicates": 0|1}`. Re-uploading an id with the same timestamp is a duplicate, a different timestamp is `409`.

Every 30th image completes a batch (images and the OCR captured up to the last of them), which the server digests when Integrity is OFF.

### `GET /v1/images/{id}`

The stored image (`image/png`, or `image/jpeg` once recompressed after its digest), with its capture time in `X-Xcreen-Captured-At`. Used for screenshots cited in answers (`xcreen-image:<id>`).

### `POST /v1/capture`

```json
{"capture": "running", "reason": "", "integrity": false}
```

Reports capture state and the Integrity switch. Sent immediately on every change and periodically. While `integrity` is `true` (and before any client has reported) the server sends no automatic digests and interrupts a running one. Returns `{"integrity": bool}`.

## Status

### `GET /v1/status`

```json
{"status": {
  "protocol": 1, "version": "2.0.0", "uptime": 3600,
  "hermes": {"connected": true, "configured": true, "error": "", "session": "<stored session id>"},
  "model": {"current": {"provider": "anthropic", "model": "claude-haiku-5-5"},
            "default": {"provider": "anthropic", "model": "claude-haiku-5-5"}, "applied": true, "status": "Applied to the xCreen session."},
  "session_visible": false, "session_visible_confirmed": false, "visibility_pending": false,
  "integrity": false, "capture": "running", "capture_reason": "", "client_seen": "…",
  "batches": {"pending": 0, "submitting": 0, "admitted": 0, "completed": 12, "uncertain": 0, "deadletter": 0},
  "unbatched": {"images": 7, "ocr": 40}, "latest": {"image": "…", "ocr": "…"},
  "next_retry": null, "message": "", "digest_hold": "", "vault": true, "compression": "mozjpeg (…, quality 30)", "active_turn": null
}}
```

`digest_hold` is empty while automatic batches run, otherwise the reason they wait: Integrity ON (or no client has reported yet), or the xCreen default model isn't applied to the session. The server re-checks the model inventory every five minutes and resumes on its own.

## Questions

### `POST /v1/ask`

`{"question": "…"}` (1–32,000 characters). Starts a manual turn in the xCreen session and returns `{"turn": Turn}` immediately. One question at a time: a second one while another is active is `400`.

### `GET /v1/turns/{id}?after=VERSION&wait_ms=MS`

Long poll. Returns as soon as the turn's `version` exceeds `after`, the turn finishes, or `wait_ms` (at most 30,000) passes.

```json
{"turn": {"id": "…", "state": "running", "text": "partial answer so far", "error": null, "version": 7, "done": false}}
```

`state` is `queued`, `running`, `completed`, `failed` or `cancelled`. `text` is the whole answer so far, not a delta.

### `POST /v1/cancel`

Cancels the active question: a queued question is dropped; a running one is interrupted. Automatic digests are not affected.

## Session and batches

| Route | Body | Returns |
|---|---|---|
| `GET /v1/history?cursor=C` | — | `{"history": {"messages", "count", "has_more", "next_cursor"}}`, at most 48,000 bytes per page, images stripped |
| `GET /v1/batches?after=ID` | — | `{"batches": [{id, state, attempts, started_at, completed_at, images, ocr, receipt, retry_after}]}`, at most 20 |
| `POST /v1/batches/retry` | — | `{"requeued": n}`. Verifies receipts, then requeues only batches whose receipt proves zero effects |
| `POST /v1/batches/verify` | — | `{"verified": n}`. Reconciles receipts read-only; no inference, no note writes |
| `GET /v1/models` | — | `{"routes": [{provider, model}], "current": {provider, model}}` from Hermes's configured inventory |
| `PUT /v1/model` | `{provider, model}` | Switches the xCreen session and saves it as the xCreen default. Returns `{"status"}` |
| `PUT /v1/model/default` | `{provider, model}` | Saves the default; applied now if connected (must be in the inventory), otherwise on connect. No fallback |
| `PUT /v1/session/visibility` | `{"visible": bool}` | Shows or hides the xCreen session in Hermes's own session list |
| `POST /v1/connection` | `{"action": "connect"\|"disconnect"\|"reconnect"}` | Connecting starts the gateway and resumes the session; it runs no model |

## Server settings

| Route | Body | Notes |
|---|---|---|
| `GET /v1/config` | — | `{"config": {hermes_python, hermes_root, vault, timezone, data_dir, bind, port}}` |
| `PUT /v1/config` | any of `hermes_python`, `hermes_root`, `vault`, `timezone` | Paths are on the server. Saves, then reconnects Hermes |
| `POST /v1/config/autodetect` | — | Finds Hermes and the Obsidian vault on the server |

Bind address, port, data directory and token change only on the server (`xcreen-server config`, `xcreen-server token --rotate`).
