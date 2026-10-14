# xCreen implementation progress

What is implemented, what is verified, and what still needs an on-device run.
This file contains no observations, vault content, Hermes configuration or model replies.

## Pipeline

```
foreground window ──1 s──▶ Vision OCR ──(<90 % similar to last saved)──▶ ocr/*.json
        └────────────every 10 active s─────▶ images/*.png
                 300 active s / 30 images ──▶ pending batch
pending batch ──image.attach_bytes ×30 + prompt.submit──▶ xCreen Hermes session
xCreen session ──tool_call──▶ xcreen_search_ocr · xcreen_images_near · xcreen_view_image · xcreen_daily_note
```

- **Evidence store** (`EvidenceStore`): private `0700` directories and `0600` atomic writes, with
  ISO-timestamped file names and a JSON index. Paths are confined to the store, and symlinks are
  rejected. The seven-day TTL is applied when the store opens, once a minute (also while
  Integrity is on) and on every query. When evidence expires, batches and checkpoint entries that
  reference it are removed too.
- **Active clock** (`ActiveCaptureClock`): each eligible sample adds at most one second. Paused,
  locked, excluded or failed periods are skipped, not caught up. A three-minute pause makes that
  batch take eight wall-clock minutes.
- **Integrity mode**: when it is on, xCreen takes no screenshots and runs no OCR. Turning it on cancels the
  capture loop, drops queued automatic batches and cancels an automatic turn in flight. Manual
  questions still work.
- **Hermes session** (`HermesGateway`, `HermesSessionRuntime`): one persisted xCreen-only session over
  the real `tui_gateway` newline JSON-RPC. It uses `session.resume`, `gateway.capabilities`,
  `model.options`, `image.attach_bytes`, `prompt.submit`, `session.interrupt` and compression. A turn
  stays current until a terminal event arrives. Manual questions take priority over automatic batches.
  Compression starts at 500k tokens, or earlier for smaller windows. Model switches apply only to this
  session. Gateway events are broadcast, so the runtime and the UI each receive every event.
- **Bundled runtime** (`runtime/xcreen_gateway.py`): performs the same bootstrap as the official
  `hermes` launcher. It registers the six `xcreen` tools through `tools.registry`, pins
  `HERMES_TUI_TOOLSETS=xcreen` for this child process only, then starts `tui_gateway.entry`.
  See [toolkit-contract.md](toolkit-contract.md).
- **Daily writer**: active only when a vault is configured. It writes only to an existing
  `Daily/YYYY-MM-DD.md` and only with validated source IDs from the same capture date. Each write
  takes a shared `fcntl` lock, adds an idempotency marker and is checked by reading it back.
- **Reply appendix**: the tray extracts only `xcreen-image:<id>` references, resolves them through
  the store and shows them as thumbnails under the answer. Arbitrary paths and remote URLs are never
  loaded.

## CLI / tray control

- `AppState.control` is the shared MainActor action surface; CLI reads live state through a private same-UID Unix socket rather than cached log/defaults state. The installer copies the standalone CLI.
- `SharedSessionController` orders connection/settings/discovery/model/history actions across awaits and freezes launch settings. Integrity transitions retain their individual values in a separate ordered lane. Runtime and UI observers are connection-generation-bound. Manual question identities support cancellation before admission, while queued behind automatic work, and during compaction; waited replies come from terminal turn-owned output, not the independent UI stream.
- Implemented commands: status, Integrity get/on/off through real capture gates, connect/disconnect/reconnect, models/select, settings/show/set/autodetect, ask/history/cancel, reply images/list/open, panel/show/hide, graceful quit/start/stop/restart and logs. See [parity contract](cli-parity.md).
- Integrity now preserves explicit user intent across launch. Automatic safety suspensions do not mutate the switch; transmission is separately blocked until capture safety passes. Model picker changes apply only to the dedicated session and do not recursively switch when IPC/session-info updates arrive.
- Synthetic IPC tests exercise the real Python client and native socket, permissions, exclusive lock, symlink rejection and malformed requests. Fake-gateway history tests use the exact runtime-session ID.
- Capture-disabled live smoke verification: startup reports running/connected/Integrity true/capture paused; settings access, panel hide, disconnect/reconnect and model inventory succeeded without inference. The inventory returned 137 routes on the verification machine; this is not a shipped fixed catalog.
- Live reconnect exposed stale old-process EOF/termination callbacks disconnecting a replacement gateway. A delayed-exit regression first failed, then passed after process-generation tokens guarded both frames and disconnect callbacks.
- Development did not enable capture, request screen permission, submit inference or write a real vault. The app was run from the built `dist` bundle; installation into Applications remains a parent-review step. Ask/cancel/image-open behavior against actual AppKit/provider state is not claimed verified by the socket tests alone.

## Verified

- `swift test`: synthetic fixtures only.
- `runtime/tests` and `bridge/tests` pass. Set `XCREEN_HERMES_ROOT` to also check the real registry.
- Checked against the installed Hermes with no inference: the four tools register, and the toolset pin
  resolves to `['xcreen']` only (no terminal, browser, file-editing or messaging tools). The bundled
  launcher answers `gateway.ready` and `gateway.capabilities`.

## Known limits / not yet verified on device

- Evidence retrieval regression fixes are synthetic-tested: Swift percent-encoded file URLs, unsafe URL/path rejection, Unicode full bounded OCR matching beyond the returned snippet, keyword-free latest/range listing and timestamped coverage. No personal evidence was read for these tests.
- Missing foreground windows and ScreenCaptureKit acquisition error -3811 leave retryable clock gaps. Other OCR/storage/unknown failures conservatively block until explicit retry/restart. No automatic failure mutates desired Integrity. Wake/unlock signals clear notification blocks only; fresh permission/session/foreground checks still gate acquisition and automatic transmission.
- The current lock compatibility check requires a present `CGSSessionScreenIsLocked=false` value. If macOS omits it while unlocked, capture remains blocked rather than guessing. This stricter signal and AppKit lifecycle wiring require separately authorized on-device verification; core policy tests do not prove notification delivery.

- Hermes defers plugin tools behind `tool_search`/`tool_call`. Every xCreen prompt names the tools
  explicitly (`XCreenPrompts`), but a weak model can still fail to call them.
- `model.options` carries no vision flag, so the picker cannot warn about text-only models yet.
- macOS has no documented synchronous "screen is unlocked" API. `MacSessionState` treats the session
  dictionary as a compatibility signal and denies capture when a value is missing or contradictory.
- No real capture, provider inference or live vault write has been run. The first on-device run
  needs Screen Recording permission (granted by the user) and Integrity turned off.
- The JSON index is rewritten on every save. That is fine for seven days of deduplicated OCR;
  larger volumes would need sharding or SQLite.
