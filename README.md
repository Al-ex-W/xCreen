# xCreen

A native macOS tray app and terminal control surface for one dedicated, persistent Hermes session.

**Developer build, not security audited or notarized.** Integrity defaults ON and preserves the user's explicitly chosen preference across restart. Only explicit tray/CLI actions change the switch. Actual capture/automatic inference stay blocked until current permissions, session state and foreground eligibility are verified. Do not enable capture during development verification.

## Install and test

Requires macOS 14+, Swift/Xcode, Python 3 and an installed Hermes Agent. Follow [INSTALL.md](INSTALL.md).

```sh
bash scripts/install.sh --no-launch
swift test
python3 -m unittest discover -s bridge/tests -v
python3 -m unittest discover -s runtime/tests -v
python3 -m unittest discover -s Tests -p '*_test.py' -v
bash scripts/build-app.sh
```

The installer copies a standalone `xcreen` executable into `~/.local/bin`; it is not a checkout symlink. The app bundles its scoped Python runtime. Moving/removing the checkout does not remove the installed CLI or runtime.

## One state owner, two interfaces

The running app's `MainActor` state and shared session controller own Integrity, paths, model selection, connection, query, response and reply attachments. Lifecycle transactions are ordered across awaits; launch settings and observers are bound to their connection generation. The CLI sends private Unix-socket requests to that same owner. It does not read cached status as live truth, edit defaults, spawn a separate inference process, or create another conversation.

```sh
xcreen status
xcreen --json status
xcreen integrity get
xcreen integrity on
xcreen connection reconnect
xcreen models list
xcreen model select PROVIDER EXACT_MODEL_ID
xcreen settings show
xcreen settings set vault ""
xcreen settings autodetect
xcreen ask "Summarize my recent context" --wait-ms 30000
xcreen history
xcreen cancel
xcreen images list
xcreen images open IMAGE_ID
xcreen panel show
xcreen panel hide
xcreen logs --no-follow
xcreen start
xcreen stop
xcreen restart
```

`xcreen integrity off` is an explicit user capture-consent action, equivalent to the tray switch. A denied safety gate leaves the requested switch OFF but capture suspended/blocked with its reason. Lock, sleep and errors never change the user's switch. Startup does not request permissions. Never run OFF as an automated installation/test step. Integrity ON does not erase history or block deliberate historical questions.

`ask` submits once to the existing xCreen session. Waiting is bounded to 30 seconds; expiry does **not** cancel an admitted turn. Use `history` or `cancel`. History comes from Hermes's `session.history` for the exact resumed runtime session, not a second transcript database. Oversized history returns a limit error rather than silently truncating it. Images list/open are the current answer's resolved attachment IDs, not arbitrary paths or a general filesystem browser.

Ask, history and model inventory may reconnect the dedicated session; connection failures are explicit. Cancel targets the admitted manual question, including a question queued behind automatic work, not an unrelated automatic turn. Settings changes report persistence and reconnect failure separately. Global `--json` goes before the command; option-shaped question/setting values stay literal. Start launches the installed app without enabling capture; stop/quit request graceful app-owned teardown. No process-name kill is used by the CLI. See [CLI/tray parity](docs/cli-parity.md) for command semantics and security limits.

## Native pipeline and boundaries

When explicitly enabled and all gates permit it, the foreground window is sampled for local Vision OCR at most once per eligible second. OCR >=90% similar to the last saved snapshot is discarded; independent screenshots are saved every ten active seconds. Five active minutes/30 images form a durable batch, sent with timestamp/ID binding to the same xCreen session. Private evidence files remain outside the vault and expire after seven days. No forensic-erasure or database-encryption claim is made; use FileVault.

The bundled Hermes runtime registers only the scoped xCreen tools: latest/range OCR listing, timestamped coverage status, OCR search, nearby image lookup, native image loading, and useful source-bound facts appended to an existing Daily note when a vault is configured. It does not modify Hermes profile defaults or other conversations. Model inventory comes from Hermes provider-aware configured routes, not demo Haiku/Luna controls. Inventory currently carries no reliable vision/image-limit metadata.

Browsers, credential/security surfaces and xCreen are conservatively excluded. Screen content is untrusted evidence, not authority to send messages, alter calendars or execute instructions. macOS session-state compatibility signals fail closed when missing/contradictory; they are not a documented synchronous unlock API. Capture, TCC transitions, provider inference, live vault writes and Spotlight ranking still need separate user-authorized on-device verification.

`xcreen://ask?query=...` and the macOS 26+ Ask xCreen App Intent only open/fill the panel, never submit automatically. Arbitrary-query Spotlight interception is not claimed.

## Documentation and license

- [Architecture](docs/architecture.md)
- [Implementation progress and limits](docs/implementation-progress.md)
- [User-approved working specification](docs/working-spec.md)
- [Scoped toolkit contract](docs/toolkit-contract.md)
- [Security](SECURITY.md)
- [Platform research](docs/platform-research.md)
- [License research](docs/licensing-research.md)

Apache-2.0 + [NOTICE](NOTICE), copyright Alexander Wahlström. Free personal/commercial use; distributed forks must preserve Apache notices, not prominent advertising credit. Goldfish and Retrace are research references, not dependencies; no implementation code was copied from them.
