# xCreen CLI reference

The `xcreen` command is a thin, state-free client of the running xCreen app, which in turn talks to `xcreen-server` (on the same Mac or on another machine; see [client and server](client-server.md)). The installer copies it to `~/.local/bin/xcreen` (a standalone copy, not a checkout symlink). Run `xcreen` with no arguments for the built-in usage text.

## One state owner, two interfaces

The running app owns Integrity, capture, the upload outbox, the server URL and token, the current question and reply attachments. The server owns the Hermes session, model selection, batches, history and settings, and the app forwards those commands to it over the [v1 protocol](protocol.md). The CLI sends private, same-user Unix-socket requests to the app. It does not read cached status as live truth, edit defaults, talk to Hermes itself or create another conversation.

## Commands

```text
usage: xcreen [--json] COMMAND
  status                         live app-owned state (never cached status.json)
  integrity [get|on|off]          off is explicit capture consent, subject to macOS gates
  session visibility [get|on|off]  show/hide the same Hermes session (default off)
  connection connect|disconnect|reconnect  (also accepted as top-level commands)
  models [list] | model select PROVIDER MODEL   (select also saves the xCreen default)
  model default [get] | model default PROVIDER MODEL  xCreen-session default only
  server [show]                   xCreen server URL, reachability and upload queue
  server set URL [--token-stdin | --token-file PATH]   token is stored in the Keychain
  flush                          upload everything still queued now
  settings [show] | settings set python|root|vault|timezone VALUE   (paths on the server)
  settings autodetect | autodetect   find Hermes and the vault on the server
  ask QUESTION [--wait-ms 0..30000]  explicit submission to the existing xCreen session
  history [--after CURSOR]        bounded sanitized history pages
  batches [--after BATCH_ID]      up to 20 durable batch metadata records
  batches retry                   verify, then re-queue only receipt-proven zero-effect batches
  verify                         read-only receipt reconciliation; no inference/note writes
  cancel
  images [list|open ID]           reply attachment metadata/open through the app
  panel [show|hide]
  start | stop | restart | quit
  logs [-n N] [--no-follow] [--gateway | --server]   (server logs only for a local server)
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
xcreen server
xcreen server set http://100.64.0.10:8765 --token-stdin < token.txt
xcreen flush
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

**server.** `server` shows the configured URL, whether the server answered, its version, the upload queue and batch counts. `server set URL` saves the URL and, with `--token-stdin` or `--token-file PATH`, stores the token in the login Keychain; the token is never accepted as an argument and never shown. HTTP is allowed only for loopback, private networks, Tailscale and `*.ts.net`/`*.local` names.

**flush.** Uploads everything still queued in the outbox now (it otherwise uploads within seconds of capture, and retries with backoff while the server is unreachable).

**ask.** Submits once to the existing xCreen session. Waiting is bounded to 30 seconds; expiry does **not** cancel an admitted turn. Use `history` or `cancel`. Ask, history and model inventory may reconnect the dedicated session; connection failures are explicit.

**cancel.** Targets the admitted manual question, including a question queued behind automatic work, not an unrelated automatic turn.

**history.** Comes from the server, which reads the host's `xcreen.history.page` for the exact resumed runtime session, not a second transcript database. `history [--after CURSOR]` returns sanitized stable snapshot pages bounded before gateway stdout, flags oversized messages and removes image pixels. Evicted/restarted host cursors fail explicitly.

**batches / verify.** `batches [--after BATCH_ID]` lists up to 20 byte-bounded processing-state and actual receipt metadata records, also visible in the tray; continue from the last ID until an empty page. `xcreen verify` and the tray's Verify receipts action reconcile exact host receipts without inference or note writes. `batches retry` verifies first and re-queues only batches whose host receipt proves zero effects; it does not send inference itself. See [native durability](durable-native-processing.md).

**images.** `images list|open` covers the current answer's resolved attachment IDs, not arbitrary paths or a general filesystem browser.

**model.** `models list` shows Hermes's provider-aware configured routes. `model select` and `model default PROVIDER MODEL` set the xCreen session default only (built-in default: `anthropic` / `claude-haiku-5-5`); Hermes's global default is unchanged. An unavailable model is reported; there is no silent fallback.

**settings.** `python`, `root`, `vault` and `timezone` are paths and values **on the server**; the server saves them and reconnects Hermes. `settings autodetect` looks for Hermes and the Obsidian vault on the server. Bind address, port and token change only on the server (`xcreen-server config`, `xcreen-server token --rotate`).

**session visibility.** The tray's **Show session in Hermes** switch and `xcreen session visibility [get|on|off]` share one server-owned persisted preference, default **OFF (hidden)**. They update the existing active session, never create another conversation or change profile defaults. Connect/resume reapplies the saved preference. Offline changes are saved and reported **pending**, separately from gateway-confirmed visibility; they do not connect automatically. `xcreen --json status` separates desired `sessionVisible`, last gateway-confirmed `actualSessionVisible` (absent when unknown), and `sessionVisibilityPending`. This switch does not affect Integrity or capture.

**Argument handling.** Global `--json` goes before the command; option-shaped question/setting values stay literal.

**start / stop.** Start launches the installed app without enabling capture; stop/quit request graceful app-owned teardown (the app first tries to upload what's queued). They don't stop the server. No process-name kill is used by the CLI.

**logs.** `logs` tails the app log; `--gateway` and `--server` tail the Hermes gateway and server logs of a server on the same Mac. For a Linux server use `journalctl --user -u xcreen-server` there.

## Server commands

`xcreen-server` runs on the server machine:

```text
xcreen-server init [--bind ADDR] [--port N] [--vault PATH] [--data-dir PATH] [--timezone TZ]
                   [--import-mac-app] [--session-id ID] [--no-detect]
xcreen-server serve [-v]
xcreen-server token [--rotate]
xcreen-server doctor
xcreen-server config [KEY=VALUE ...]
xcreen-server migrate-journal (--from-vault OLD_PATH | --from-key KEY)
```

`scripts/install-server.sh` runs `init`, installs the service and finishes with `doctor`.

**URL scheme and Spotlight.** `xcreen://ask?query=...`, `xcreen://open` and the macOS 26+ "Ask xCreen"/"Open xCreen" App Shortcuts only open/fill the panel, never submit automatically. They work whether xCreen is already running or is launched by the URL. Arbitrary-query Spotlight interception is not claimed.

See [CLI/tray parity](cli-parity.md) for acknowledgment, lineage and security limits.
