# Client and server

Status: accepted, implemented in 2.0.

## Why

Until 1.x the Mac app did everything: capture, OCR, evidence storage, batching, driving the Hermes session, receipts. It launched Hermes's Python as a child process, so Hermes had to run on the same Mac. People increasingly run Hermes on a home server or VM (always on, more memory, reachable from every device) while capture can only happen on the Mac.

## Decision

xCreen is always two programs that talk over one versioned HTTP interface ([protocol](protocol.md)):

```text
 Mac (client)                                   Hermes host (server)
 ┌──────────────────────────┐   HTTPS/HTTP +    ┌──────────────────────────────────────┐
 │ capture · Vision OCR     │   bearer token    │ xcreen-server                         │
 │ upload outbox            │ ───────────────▶  │  evidence store (7 days, JPEG after   │
 │ tray · CLI · Spotlight   │   /v1/...         │   digest) · batching · batch state    │
 └──────────────────────────┘                   │  session runtime ─▶ xcreen_gateway.py │
                                                │                     (Hermes + tools)  │
                                                │  vault writes · receipts journal      │
                                                └──────────────────────────────────────┘
```

- **Client** (Swift, macOS): captures the display holding the focused window (minus excluded apps), runs local OCR, keeps captured items in a durable outbox until the server acknowledges them, and shows the tray, CLI and Spotlight surfaces. It holds no Hermes, vault or batch logic.
- **Server** (Python 3.10+, standard library only, runs with Hermes's own Python): owns the evidence store, forms batches, owns the dedicated Hermes session (digests and questions), the receipts journal and the vault.

The **complete install** is the same two programs on one Mac: the server runs as a LaunchAgent bound to `127.0.0.1`. The **split install** runs the server next to Hermes (for example a Debian VM) and the client points at it, typically over Tailscale. Both installs run identical code; only the server URL differs.

## Interfaces and patterns

| Seam | Pattern | Implementations |
|---|---|---|
| Client ↔ server | versioned HTTP+JSON API (`/v1`), the stable contract | `HTTPXCreenServer` (Swift), `api.py` (Python) |
| Client upload | outbox: items persist locally until acknowledged, idempotent `PUT` by id | `EvidenceStore` outbox + `Uploader` |
| Server operations | facade: one service object behind the HTTP layer, used by tests directly | `XCreenService` |
| Evidence | repository with the existing on-disk format (`index.json`), so the Hermes tools read it unchanged | `EvidenceStore` (Python) ↔ `EvidenceReader` |
| Batches | explicit state machine (`pending → submitting → admitted → completed`, `uncertain`, `deadletter`) | `EvidenceStore` |
| Hermes | adapter over Hermes's stdio JSON-RPC gateway | `HermesGateway` → `runtime/xcreen_gateway.py` |
| Image compression | strategy, chosen at startup | mozjpeg `cjpeg`, Pillow |
| Swift client API | protocol, so the app and tests share one interface | `XCreenServerAPI` |

The server deliberately keeps the Hermes gateway as a separate child process (the existing `runtime/xcreen_gateway.py`): Hermes crashes and upgrades don't take the API down, and the scoped tools, receipts and vault writer keep their tested code paths.

## What moved

| 1.x (Swift, in the app) | 2.0 |
|---|---|
| `HermesGateway`, `HermesSessionRuntime`, `SharedSessionController` | server `gateway.py`, `session.py` |
| batch state in `EvidenceStore`, retry/backoff, verify/recover | server `store.py`, `pipeline.py` |
| `XCreenPrompts`, `BatchReceipt` | server `prompts.py`, `receipts.py` |
| `ImageCompactor` (mozjpeg) | server `images.py` |
| `LocalSetupDetector` (Hermes + vault discovery) | `xcreen-server init` |
| Settings `python`/`root`/`vault`, session id, model default | server config and state, edited through the API or `xcreen-server` |

The client keeps capture, OCR, the active-time clock, the outbox, the tray and the local control socket the `xcreen` CLI uses. Every CLI command keeps working; commands that concern Hermes are forwarded to the server.

## Batching

Images are captured every ten active seconds, so the server forms a batch from every 30 consecutive images plus the OCR captured up to the last of them. That is the same five active minutes as before, computed from what has arrived rather than from the client's clock. A batch only forms once all 30 images have arrived, so an offline client simply delays batches.

## Integrity

Integrity stays a client control. The client reports it to the server immediately on every change and with each status update; the server blocks automatic digests while it is ON (or before any client has reported), drops queued automatic turns and interrupts a running one, exactly as before. Changes from 1.x:

- Digests of evidence that has already been uploaded continue while the Mac is locked or asleep. They used to pause until the Mac was unlocked.
- Evidence leaves the Mac for the server you configured. With the split install, raw screenshots and OCR are stored on that server, not on the Mac.

## Security

- The server listens on `127.0.0.1` by default. For a split install bind it to a private interface such as the Tailscale address; WireGuard then encrypts the traffic. Anything else should go through `tailscale serve`, an SSH tunnel or another TLS terminator.
- Every request except `/v1/health` needs `Authorization: Bearer <token>`. The token is 256 random bits, stored `0600` on the server and in the macOS Keychain on the client, and compared in constant time.
- Request sizes, ids, timestamps and image formats are validated before anything is written. Evidence and token values are never logged.
- On Linux the systemd unit runs as the Hermes user with `NoNewPrivileges`, a read-only system and write access only to the xCreen data directory, Hermes's home and the vault.

## Upgrading from 1.x

A complete install upgrades in place: the server opens the existing evidence store and imports the session id, model default, Hermes paths and vault from the app's preferences. For a split install, existing local evidence stays on the Mac and expires; new captures go to the server.

## Alternatives considered

- **Run the 1.x app's gateway over SSH** (`ssh host python xcreen_gateway.py`). Smallest change, but the Mac would still own batching and the session, and the tools on the server would need the Mac's evidence over a reverse channel.
- **Server asks the Mac for evidence on demand** (Hermes server-to-client requests). Keeps evidence on the Mac, but every historical question and digest would depend on the Mac being awake.
- **Expose Hermes's own WebSocket gateway.** It runs inside the dashboard process, where the xCreen tools and RPC methods aren't registered.
