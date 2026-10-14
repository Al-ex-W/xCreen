# xCreen

**A privacy-first macOS menu-bar foundation for a personal AI harness.**

> **Developer build — not security audited.** Capture starts paused and fails closed; development verification never requests macOS screen permission, captures pixels, reads a vault, or sends personal evidence to Hermes. See [implementation progress](docs/implementation-progress.md) for verified behavior and remaining integration work.

## Design

xCreen's current app is a native tray foundation. Its Integrity control starts paused, its local settings can hold an explicit Hermes executable path, and the chat control uses a single xCreen-only Hermes session when that gateway is available. It does not request capture permission or claim an answer when the gateway is unavailable.

The independent backend code documents a future intended pipeline: filtered foreground-window screenshots → local Apple Vision OCR → short-lived SQLite retrieval → an explicit answer through an existing harness. That code is retained for later reviewed wiring; the preview UI never calls it. Dormant Swift backend types may remain linked into the executable, but the Python bridge is not bundled.

Screenshots alone cannot establish what you intended, whether an operation completed or what happened off-screen. Planned opt-in app/window/document metadata improves retrieval. Never advertise "full knowledge": show coverage, gaps, timestamps and evidence.

The native silver mini-panel uses a placeholder monitor symbol inspired by classic macOS utility popovers. A final logo can replace it later.

## Install

Agents and humans: follow [INSTALL.md](INSTALL.md). In short, `bash scripts/install.sh` builds the app, auto-detects Hermes and your Obsidian vault, and pre-fills Local settings.

## Build and run

Requires macOS 14+ and Xcode/Swift 5.9+. The menu app has no Hermes, model-provider, capture, or permission requirement until the user deliberately configures a local Hermes executable and asks a question.

```sh
swift test
bash scripts/build-app.sh
```

The preview uses `UserDefaults` only for Integrity mode, demo recommendation, and interval selections. Its recommendation picker labels Haiku and Luna as **DEMO** recommendations; it does not claim either is configured or available. The app is ad-hoc signed for local development, not notarized for distribution.

The preview does not start capture at all. Integrity mode defaults ON; changing it OFF still cannot start capture. macOS Screen Recording permission is never requested by the preview. No screenshot call or OCR ingestion is attempted unless future reviewed wiring adds a public, reliable current-state source. Browsers remain app-wide excluded in the retained policy until private-window detection can be made reliable and separately consented.

The retained bridge code reads the current `HERMES_HOME` or default `~/.hermes` configuration locally when run independently. It is not included in the preview bundle. Configured inventory, not the entire provider catalog, is a future integration concern; the preview picker contains no discovered models. Haiku and Luna are labelled demo recommendations, not claimed installed models or invented model IDs.

## What works / what remains

| Feature | Status |
|---|---|
| Native menu-bar mini UI, local preferences and question field | Hermes transport is available only after deliberate local executable configuration; otherwise no question is sent |
| Existing Hermes model inventory and per-query selection | Independent backend code retained; not called by the preview app; Python bridge not bundled |
| Bounded local OCR-text ingestion, FTS search, expiry and purge | Local bridge; command-line ingestion |
| Integrity defaults ON, exclusions and stale-result policy | Unit-tested core and app lifecycle wiring |
| 30-second foreground-window ScreenCaptureKit + Vision OCR | Capture-state and foreground-race wiring compile-verified; **live capture unavailable and not tested** |
| `xcreen://ask?query=...` | Opens panel and fills input; never auto-submits or sends |
| Native Spotlight arbitrary-query suggestion | **Not claimed or implemented** |
| macOS 26+ Spotlight App Intent with question parameter | Compiles; opens reviewed question handoff, discovery **not system-tested** |
| Hermes access to activity from normal conversations via MCP | Proposed read-only adapter, pending |
| Vault read/write integration | Optional project-context directory only; no automatic note writes |
| Signed/notarized releases, semantic search, universal secret filtering | Pending |

The current CLI query adapter is tool-disabled for safety. It inherits Hermes personal memory and project instructions but does not autonomously search arbitrary vault files or attach to your current Desktop conversation. A future authenticated JSON-RPC adapter plus read-only xCreen MCP server is the proper fully integrated path.

The Python ask tests use executables explicitly named `fake-hermes` and synthetic answers. They verify routing, arguments, evidence boundaries, cancellation, and prompt construction only; they are not presented as real model inference. Answers request citations from the model, but xCreen currently returns raw model output and does not validate, resolve, or render those citations as verified evidence. The prior provider-backed attempt was blocked by quota and was not retried here.

## Spotlight: honest UX

Apple documents macOS 26+ Spotlight app actions. The feasible path is **⌘Space → select Ask xCreen → enter the question parameter → run**. This does not establish a catch-all live result provider for arbitrary text. Core Spotlight query continuation is a separate documented handoff worth testing, not a guaranteed suggestion row. No silent ⌘Space hijacking or Accessibility scraping of Spotlight.

On macOS 26+, the included `AskXCreenIntent` has a required question parameter and opens `xcreen://ask` with that text. The URL handoff only fills the preview field; it never submits or connects. Actual Spotlight discovery/ranking still requires a signed installed-app test. On older systems, launch the app and enter the question in its panel. See [platform research](docs/platform-research.md) for Apple references and OS availability.

## Your vault

Keep the local index under Application Support, **outside your knowledge vault**. No pixels, raw OCR, database or credentials in notes. The optional vault setting supplies existing project rules to Hermes; it does not copy or write the vault.

Later, reviewed useful facts can become short source-linked distillations in existing entity/project notes, through your harness's existing serialized writer. Screen evidence does not expand message-sending or calendar authorization. Existing email/message intake stays unchanged. See [architecture](docs/architecture.md).

## Privacy

Capture is OFF by default and live screenshot capture is unavailable in this preview. Integrity mode ON stops the periodic task, cancels local ingestion, advances the capture generation, and rejects older in-flight image/OCR results; old-history deletion remains a separate operation. Session resignation, sleep/display sleep, permission loss, unsafe idle state, and capture/OCR/index failures return to Integrity ON. Notifications are supplemental invalidation signals only; they never establish that a session is currently unlocked. Password managers, security/system surfaces, xCreen itself, and common browsers are excluded. Browser-wide exclusion is intentionally conservative.

For the retained local backend, local OCR does not mean local inference: evidence remains local until a configured Hermes session accepts an explicit request. Development verification has no OCR, consent, provider submission, vault reads, or real transcripts.

Expiry and purge rebuild/optimize FTS and checkpoint the WAL after commit. The local index is private-file-permission protected, **not database-encrypted**. Recommend FileVault. These operations make no promise of forensic erasure, backup deletion, universal incognito detection, or perfect credential redaction. Read [SECURITY.md](SECURITY.md) before using sensitive context.

## Research and license

- [Platform research: Goldfish, Retrace, Apple APIs, Spotlight and Hermes](docs/platform-research.md)
- [Harness and vault architecture](docs/architecture.md)
- [License comparison and attribution limits](docs/licensing-research.md)
- [Contributing](CONTRIBUTING.md)

**Apache-2.0 + NOTICE**, copyright Alexander Wahlström. Free personal and commercial use, including proprietary derivatives. Distributed forks must meet Apache's attribution/notice obligations. This is notice preservation, **not mandatory prominent UI/advertising credit**; a custom publicity requirement would change the license. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Goldfish and Retrace are research references, not dependencies; no implementation code was copied from them.
