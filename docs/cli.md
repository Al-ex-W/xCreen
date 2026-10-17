# xCreen CLI reference

The `xcreen` command is a thin, state-free client of the running xCreen app. The installer copies it to `~/.local/bin/xcreen` (a standalone copy, not a checkout symlink). Run `xcreen` with no arguments for the built-in usage text.

## One state owner, two interfaces

The running app's `MainActor` state and shared session controller own Integrity, paths, model selection, connection, query, response and reply attachments. Lifecycle transactions are ordered across awaits; launch settings and observers are bound to their connection generation. The CLI sends private, same-user Unix-socket requests to that same owner. It does not read cached status as live truth, edit defaults, spawn a separate inference process, or create another conversation.

## Commands

```text
usage: xcreen [--json] COMMAND
  status                         live app-owned state (never cached status.json)
  integrity [get|on|off]          off is explicit capture consent, subject to macOS gates
  session visibility [get|on|off]  show/hide the same Hermes session (default off)
  connection connect|disconnect|reconnect  (also accepted as top-level commands)
  models [list] | model select PROVIDER MODEL   (select also saves the xCreen default)
  model default [get] | model default PROVIDER MODEL  xCreen-session default only
  settings [show] | settings set python|root|vault VALUE
  settings autodetect | autodetect
  ask QUESTION [--wait-ms 0..30000]  explicit submission to the existing xCreen session
  history [--after CURSOR]        bounded sanitized history pages
  batches [--after BATCH_ID]      up to 20 durable batch metadata records
  batches retry                   verify, then re-queue only receipt-proven zero-effect batches
  verify                         read-only receipt reconciliation; no inference/note writes
  cancel
  images [list|open ID]           reply attachment metadata/open through the app
  panel [show|hide]
  start | stop | restart | quit
  logs [-n N] [--no-follow] [--gateway]
```

Examples:

```sh
xcreen status
xcreen --json status
xcreen integrity get
xcreen integrity on
xcreen session visibility get
xcreen connection reconnect
xcreen models list
xcreen model default
xcreen model select PROVIDER EXACT_MODEL_ID
xcreen settings show
xcreen settings set vault ""        # disables Daily-note writing
xcreen settings autodetect
xcreen ask "Summarize my recent context" --wait-ms 30000
xcreen history
xcreen batches
xcreen verify
xcreen cancel
xcreen images list
xcreen images open IMAGE_ID
xcreen panel show
xcreen logs --no-follow
xcreen start
xcreen stop
xcreen restart
```

## Semantics

**Integrity.** `xcreen integrity off` is an explicit user capture-consent action, equivalent to the tray switch. A denied safety gate leaves the requested switch OFF but capture suspended/blocked with its reason. Lock, sleep and errors never change the user's switch. Startup does not request permissions. Never run OFF as an automated installation/test step. Integrity ON does not erase history or block deliberate historical questions.

**ask.** Submits once to the existing xCreen session. Waiting is bounded to 30 seconds; expiry does **not** cancel an admitted turn. Use `history` or `cancel`. Ask, history and model inventory may reconnect the dedicated session; connection failures are explicit.

**cancel.** Targets the admitted manual question, including a question queued behind automatic work, not an unrelated automatic turn.

**history.** Comes from the host's `xcreen.history.page` for the exact resumed runtime session, not a second transcript database. `history [--after CURSOR]` returns sanitized stable snapshot pages bounded before gateway stdout, flags oversized messages and removes image pixels. Evicted/restarted host cursors fail explicitly.

**batches / verify.** `batches [--after BATCH_ID]` lists up to 20 byte-bounded processing-state and actual receipt metadata records, also visible in the tray; continue from the last ID until an empty page. `xcreen verify` and the tray's Verify receipts action reconcile exact host receipts without inference or note writes. `batches retry` verifies first and re-queues only batches whose host receipt proves zero effects; it does not send inference itself. See [native durability](durable-native-processing.md).

**images.** `images list|open` covers the current answer's resolved attachment IDs, not arbitrary paths or a general filesystem browser.

**model.** `models list` shows Hermes's provider-aware configured routes. `model select` and `model default PROVIDER MODEL` set the xCreen session default only (built-in default: `openrouter` / `anthropic/claude-haiku-5.5`); Hermes's global default is unchanged. An unavailable model is reported; there is no silent fallback.

**settings.** Changes are persisted by the running app and report persistence and reconnect failure separately. Do not use `defaults write` as a parallel live control surface.

**session visibility.** The tray's **Show session in Hermes** switch and `xcreen session visibility [get|on|off]` share one app-owned persisted preference, default **OFF (hidden)**. They update the existing active session, never create another conversation or change profile defaults. Connect/resume reapplies the saved preference. Offline changes are saved and reported **pending**, separately from gateway-confirmed visibility; they do not connect automatically. `xcreen --json status` separates desired `sessionVisible`, last gateway-confirmed `actualSessionVisible` (absent when unknown), and `sessionVisibilityPending`. This switch does not affect Integrity or capture.

**Argument handling.** Global `--json` goes before the command; option-shaped question/setting values stay literal.

**start / stop.** Start launches the installed app without enabling capture; stop/quit request graceful app-owned teardown. No process-name kill is used by the CLI.

**URL scheme and Spotlight.** `xcreen://ask?query=...` and the macOS 26+ Ask xCreen App Intent only open/fill the panel, never submit automatically. Arbitrary-query Spotlight interception is not claimed.

See [CLI/tray parity](cli-parity.md) for acknowledgment, lineage and security limits.
