# xCreen

**A disconnected macOS menu-bar UI preview for a future personal AI harness.**

> **Developer preview — not a finished or security-audited screen-memory app.** The built native app is intentionally disconnected: it does not discover model configuration, run the bridge or Hermes, request permissions, instantiate capture, or touch SQLite or a vault. It only stores a few UI preferences locally. The independent bridge, capture, and storage code remains in this repository for future reviewed wiring.

## Design

xCreen's current app is a polished, disconnected tray preview. Its monitor placeholder, Integrity control, recommendation picker, compact local settings, and question field are usable without granting access to any data or service. Questions are never sent and explicitly report that they were not sent.

The independent backend code documents a future intended pipeline: filtered foreground-window screenshots → local Apple Vision OCR → short-lived SQLite retrieval → an explicit answer through an existing harness. That code is retained for later reviewed wiring; the preview UI never calls it. Dormant Swift backend types may remain linked into the executable, but the Python bridge is not bundled.

Screenshots alone cannot establish what you intended, whether an operation completed or what happened off-screen. Planned opt-in app/window/document metadata improves retrieval. Never advertise "full knowledge": show coverage, gaps, timestamps and evidence.

The native silver mini-panel uses a placeholder monitor symbol inspired by classic macOS utility popovers. A final logo can replace it later.

## Build and run

Requires macOS 14+ and Xcode/Swift 5.9+. The disconnected preview has no Python, Hermes, model-provider, capture, or permission requirement.

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
| Native menu-bar mini UI, placeholder icon, local preferences and question field | Disconnected UI preview; question submissions are never sent |
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

For the retained future backend only, local OCR does not mean local inference: an explicit question would send only matching retrieved text to the chosen provider after one-shot consent. The disconnected preview has no OCR, consent, provider submission, or transcripts.

Expiry and purge rebuild/optimize FTS and checkpoint the WAL after commit. The local index is private-file-permission protected, **not database-encrypted**. Recommend FileVault. These operations make no promise of forensic erasure, backup deletion, universal incognito detection, or perfect credential redaction. Read [SECURITY.md](SECURITY.md) before using sensitive context.

## Research and license

- [Platform research: Goldfish, Retrace, Apple APIs, Spotlight and Hermes](docs/platform-research.md)
- [Harness and vault architecture](docs/architecture.md)
- [License comparison and attribution limits](docs/licensing-research.md)
- [Contributing](CONTRIBUTING.md)

**Apache-2.0 + NOTICE**, copyright Alexander Wahlström. Free personal and commercial use, including proprietary derivatives. Distributed forks must meet Apache's attribution/notice obligations. This is notice preservation, **not mandatory prominent UI/advertising credit**; a custom publicity requirement would change the license. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Goldfish and Retrace are research references, not dependencies; no implementation code was copied from them.
