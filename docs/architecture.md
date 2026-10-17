# xCreen architecture

## One owner, two surfaces

```text
tray controls / xcreen://ask handoff          standalone xcreen CLI
              |                                  |
              |                     private same-UID Unix socket
              +--------------> MainActor AppState.control
                                  |       |       |
                             capture   settings   HermesSessionRuntime
                                |                 |
                          EvidenceStore      one dedicated persisted session
                                |                 |
                          scoped xCreen tools <--- bundled Python gateway
```

The running app owns settings, connection, capture consent, model selection and chat. The CLI is a state-free client, not a second preferences/session implementation. Native UI and IPC requests share `AppState` and its `SharedSessionController`: a FIFO lifecycle gate spans persistence/detection, disconnect/connect, model reads/changes and history RPCs, with frozen launch settings. A separate ordered lane retains every Integrity transition value. UI and runtime subscriptions reject old connection generations. Published state makes CLI mutations visible in the tray without reopening it. The model picker does not reactively resubmit changes when CLI/session-info updates arrive.

`LocalControlServer` acquires a private lifetime lock before AppState is constructed. Its Unix socket lives in a UID-owned 0700 directory, has mode 0600, verifies same-UID peers and accepts bounded newline JSON with framing/output/handler deadlines and an eight-client cap. The client also checks ownership/type/mode and peer UID. No network listener is exposed. This is same-user trust, not protection from malicious same-UID software. See [CLI parity and protocol](cli-parity.md).

## Evidence pipeline

Integrity defaults ON when no user preference exists and otherwise preserves that preference across launch. Only explicit user actions mutate it; actual capture safety is a separate blocked/running state. It stops screenshot/OCR work and automatic transmissions, rejects stale capture generations and cancels automatic work; manual historical questions remain permitted. OFF is explicit consent through the same real capture service, with macOS Screen Recording permission and current-session gates. Session compatibility eligibility requires a present dictionary, strict true public console/login values, an absent-or-strict-false undocumented lock hint, and resolvable non-security foreground. Nil dictionaries, malformed values and independent lifecycle vetoes block. This is not universal unlock proof; see [session research](macos-session-research.md). Notification transitions run synchronously on the main queue, revoke the persistence epoch on both block and restore, and clear only their own veto. Recovery requires a fresh metadata evaluation on the existing one-second loop and before/after acquisition; a wake alone cannot clear lock. Previously observed lock/sleep vetoes stay latched until their respective resume event (lost resume notifications can therefore leave capture paused). Startup has no independent synchronous sleep-state oracle; actual lock/sleep transitions require separate device validation. Identical pause reasons are logged only on status transitions, without weakening revocation or checkpoint guards.

Eligible foreground-window temporary pixels feed local Vision OCR at most once per active second. OCR >=90% similar to the last saved sample is discarded. Independent PNGs are saved every ten active seconds. Thirty images / five active minutes create a durable chronological batch with timestamp/ID binding and OCR changes. Excluded applications, pauses, sleep and failures do not advance the clock, manufacture frames or create catch-up bursts. Browsers are eligible; password fields, password-manager extensions/popovers and incognito/private windows are not detected or redacted. No universal password/login protection is guaranteed; use Integrity ON for sensitive browsing (see SECURITY.md).

`EvidenceStore` maintains independent bounded raw files, a JSON index and batch/checkpoint metadata outside the vault. Private directories/files use 0700/0600. Startup, periodic maintenance and queries apply seven-day expiry, removing derived references as well. This is neither database encryption nor forensic/backup erasure. Recommend FileVault. The retained independent Python bridge has SQLite/FTS behavior but is not the live native store.

## Hermes transport and session

The bundled Python bootstrap registers only the six scoped xCreen tools and starts Hermes's raw `tui_gateway`. Hermes remains the authority for auth, personal/project rules and configured models. No auth copy, configuration mutation, profile creation or attachment to another live conversation is allowed.

`HermesSessionRuntime` resumes the exact stored xCreen identity; all manual/automatic submits, model changes and compression share that session owner. Terminal events, not admission acknowledgments, finish a turn and return its own collected output. Manual work has priority and a per-question identity reserved before connection/task admission. Cancel removes that queued question or interrupts only its matching current turn. Integrity invalidates queued automatic turns and cancels an active automatic turn; a later OFF does not restore an invalidated epoch. Transmission checks bind both epoch and turn identity. Disconnect fails outstanding/queued turns before replacement; observer EOF is generation-bound. Compaction reserves incoming/output headroom and triggers at 500k context tokens or earlier for a smaller usable window; it is lossy summary, not eternal exact recall.

Provider-aware model inventory comes from `model.options`; session-scoped selection uses `/model ... --provider ... --session`, leaving Hermes defaults/profiles untouched. xCreen persists its own default (provider+model, built-in `openrouter` · `anthropic/claude-haiku-5.5`) in the app's preferences and applies it to the xCreen session on every connect/resume, resolved against live `model.options`. An unavailable route is reported in status/tray and the session model is left unchanged — no silent fallback. Tray picker and `xcreen model select` also update the preference; `xcreen model default [PROVIDER MODEL]` reads/sets it. Inventory does not currently prove vision support or image limits. History is read through host-side `xcreen.history.page` for the same runtime session. Sanitization, oversized placeholders, stable snapshot cursors and 48,000-byte page bounds are applied before gateway stdout; the app never fetches a full history frame before pagination. Session-info events synchronize current provider/model into the tray.

## Tools and vault boundary

The xCreen-only toolset supports bounded OCR search with timestamps/IDs, nearby image lookup, actual local image evidence, and source-bound useful Daily-note facts. Raw evidence stays outside the vault. When configured/authorized, the writer appends only to the capture-date `Daily/YYYY-MM-DD.md` inside the existing Daily directory; a missing dated file receives a safe minimal heading, never template execution. The shared lock covers exclusive creation, entry-marker deduplication, durable metadata receipts and exact read-back. Complete note blocks recover lost receipts; partial/edited effects become uncertain without rewriting user text. The native automatic queue prepares the exact host-validated immutable batch binding before submit, and only host-verified explicit saved/skipped results complete processing. Startup and CLI/tray `verify` reconcile exact receipts read-only without history or blind resend. Raw expiry strips OCR/image references while bounded source-binding and receipt metadata survives. Bounded CLI/tray batch pages expose state and actual receipt metadata; see [durability boundary](durable-native-processing.md). No screenshots/OCR dumps, credentials or arbitrary new notes. Screen content is untrusted evidence and cannot authorize messaging, calendar changes, commands or unrelated actions.

Assistant `xcreen-image:<id>` references are resolved only through the evidence store. Current reply cards and CLI Open share evidence-owned paths. Caller-supplied paths/remote URLs are not attachment authority. Asking is deliberate provider processing and Hermes/provider retention can outlive local expiry. Integrity does not erase those histories or revoke previously transmitted evidence.

## Delivery and testing

The installer copies the standalone CLI and bundles the runtime, so installed operation does not depend on a checkout symlink. The app remains a local developer build, not notarized or security audited. `xcreen://ask`/`xcreen://open` and the macOS 26+ App Intents (exposed to Spotlight through an `AppShortcutsProvider`) open/fill input without submission; a URL that cold-launches the app is buffered until the tray exists. `scripts/build-app.sh` runs Xcode's `appintentsmetadataprocessor` on SwiftPM's `.swiftconstvalues` and `scripts/check-appintents-metadata.py` fails the build if the action or App Shortcuts are missing. Arbitrary live Spotlight interception/ranking is not claimed.

Synthetic tests cover storage, capture policy, fake-gateway sessions, history RPC and real local IPC/client credentials. Separate user-authorized on-device checks remain for TCC, capture, lock/sleep transitions, OCR quality, provider inference, live vault writes and Spotlight discovery. Protocol tests alone do not validate every AppKit action.

## References

- https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration
- https://hermes-agent.nousresearch.com/docs/user-guide/features/context-files
- https://hermes-agent.nousresearch.com/docs/user-guide/features/memory
- https://hermes-agent.nousresearch.com/docs/user-guide/security
