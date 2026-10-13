# xCreen

**Local screen context for your personal AI harness.** macOS-first, native menu-bar UI, Hermes-first integration.

> **Developer preview — not a finished or security-audited screen-memory app.** The native shell includes capture-policy wiring, local retrieval, configured Hermes model discovery, and citation-requested answers. Live screenshot capture is unavailable: this preview has no public, synchronous source that can positively establish the current unlocked-session state. Capture policy and builds are tested, but live Screen Recording, lock transitions, OCR quality, Spotlight discovery, and provider-backed inference have not been exercised in this repository checkout.

## Design

xCreen supplies the eyes; your existing harness remains the brain. The intended pipeline is filtered foreground-window screenshots → local Apple Vision OCR → short-lived SQLite retrieval → an explicit answer that requests citations through your existing Hermes profile. No second credentials store, no wholesale vault copy and no passive LLM call on every frame.

Screenshots alone cannot establish what you intended, whether an operation completed or what happened off-screen. Planned opt-in app/window/document metadata improves retrieval. Never advertise "full knowledge": show coverage, gaps, timestamps and evidence.

The native silver mini-panel uses a placeholder monitor symbol inspired by classic macOS utility popovers. A final logo can replace it later.

## Build and run

Requires macOS 14+, Xcode/Swift 5.9+, Python 3.10+ with PyYAML and an installed Hermes CLI supporting `--query-file`, `--run-budget`, per-invocation model/provider and toolset selection.

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r bridge/requirements.txt
swift test
.venv/bin/python -m unittest discover -s bridge/tests -v
bash scripts/build-app.sh
open dist/xCreen.app
```

In **Harness settings**, set the absolute Python path (your venv interpreter), absolute Hermes executable, and optional personal vault directory. Save and refresh models. Draft settings are not saved by the automatic model refresh. Nothing changes your main Hermes model configuration. The app is ad-hoc signed for local development, not notarized for distribution.

Capture starts paused and remains unavailable in this preview. macOS Screen Recording permission is never requested by xCreen; its preflight is non-prompting. The UI keeps Integrity mode ON because opt-in and asynchronous lock notifications cannot prove the session is currently unlocked. No screenshot call or OCR ingestion is attempted unless a future implementation adds a public, reliable current-state source. Browsers remain app-wide excluded in the policy until private-window detection can be made reliable and separately consented.

The bundled bridge reads the current `HERMES_HOME` or default `~/.hermes` configuration locally. GUI apps may not inherit your shell's environment; default-profile support is the initial target. Configured inventory, not the entire provider catalog, appears in the picker. Use a light **Haiku or Luna** route if actually configured and suitable; these names are recommendations, not claimed installed models or invented model IDs.

## What works / what remains

| Feature | Status |
|---|---|
| Native menu-bar mini UI, placeholder icon, query and answer | Build-verified developer implementation |
| Existing Hermes model inventory and per-query selection | Local bridge implementation |
| Bounded local OCR-text ingestion, FTS search, expiry and purge | Local bridge; command-line ingestion |
| Integrity defaults ON, exclusions and stale-result policy | Unit-tested core and app lifecycle wiring |
| 30-second foreground-window ScreenCaptureKit + Vision OCR | Capture-state and foreground-race wiring compile-verified; **live capture unavailable and not tested** |
| `xcreen://ask?query=...` | Opens panel and fills input; never auto-submits |
| Native Spotlight arbitrary-query suggestion | **Not claimed or implemented** |
| macOS 26+ Spotlight App Intent with question parameter | Compiles; opens reviewed question handoff, discovery **not system-tested** |
| Hermes access to activity from normal conversations via MCP | Proposed read-only adapter, pending |
| Vault read/write integration | Optional project-context directory only; no automatic note writes |
| Signed/notarized releases, semantic search, universal secret filtering | Pending |

The current CLI query adapter is tool-disabled for safety. It inherits Hermes personal memory and project instructions but does not autonomously search arbitrary vault files or attach to your current Desktop conversation. A future authenticated JSON-RPC adapter plus read-only xCreen MCP server is the proper fully integrated path.

The Python ask tests use executables explicitly named `fake-hermes` and synthetic answers. They verify routing, arguments, evidence boundaries, cancellation, and prompt construction only; they are not presented as real model inference. Answers request citations from the model, but xCreen currently returns raw model output and does not validate, resolve, or render those citations as verified evidence. The prior provider-backed attempt was blocked by quota and was not retried here.

## Spotlight: honest UX

Apple documents macOS 26+ Spotlight app actions. The feasible path is **⌘Space → select Ask xCreen → enter the question parameter → run**. This does not establish a catch-all live result provider for arbitrary text. Core Spotlight query continuation is a separate documented handoff worth testing, not a guaranteed suggestion row. No silent ⌘Space hijacking or Accessibility scraping of Spotlight.

On macOS 26+, the included `AskXCreenIntent` has a required question parameter and opens `xcreen://ask` with that text. The URL handoff clears any previous cloud consent and never submits automatically. Actual Spotlight discovery/ranking still requires a signed installed-app test. On older systems, launch the app and enter the question in its panel. See [platform research](docs/platform-research.md) for Apple references and OS availability.

## Your vault

Keep the local index under Application Support, **outside your knowledge vault**. No pixels, raw OCR, database or credentials in notes. The optional vault setting supplies existing project rules to Hermes; it does not copy or write the vault.

Later, reviewed useful facts can become short source-linked distillations in existing entity/project notes, through your harness's existing serialized writer. Screen evidence does not expand message-sending or calendar authorization. Existing email/message intake stays unchanged. See [architecture](docs/architecture.md).

## Privacy

Capture is OFF by default and live screenshot capture is unavailable in this preview. Integrity mode ON stops the periodic task, cancels local ingestion, advances the capture generation, and rejects older in-flight image/OCR results; old-history deletion remains a separate operation. Session resignation, sleep/display sleep, permission loss, unsafe idle state, and capture/OCR/index failures return to Integrity ON. Notifications are supplemental invalidation signals only; they never establish that a session is currently unlocked. Password managers, security/system surfaces, xCreen itself, and common browsers are excluded. Browser-wide exclusion is intentionally conservative.

Local OCR does not mean local inference: an explicit question sends only matching retrieved text to the chosen provider after one-shot consent. Consent resets when the question, selected model, or vault changes, on URL handoff, and when an ask begins. A no-match question sends an empty evidence list rather than unrelated recent history. Hermes transcripts and provider records may retain submitted content beyond the local index's TTL.

Expiry and purge rebuild/optimize FTS and checkpoint the WAL after commit. The local index is private-file-permission protected, **not database-encrypted**. Recommend FileVault. These operations make no promise of forensic erasure, backup deletion, universal incognito detection, or perfect credential redaction. Read [SECURITY.md](SECURITY.md) before using sensitive context.

## Research and license

- [Platform research: Goldfish, Retrace, Apple APIs, Spotlight and Hermes](docs/platform-research.md)
- [Harness and vault architecture](docs/architecture.md)
- [License comparison and attribution limits](docs/licensing-research.md)
- [Contributing](CONTRIBUTING.md)

**Apache-2.0 + NOTICE**, copyright Alexander Wahlström. Free personal and commercial use, including proprietary derivatives. Distributed forks must meet Apache's attribution/notice obligations. This is notice preservation, **not mandatory prominent UI/advertising credit**; a custom publicity requirement would change the license. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Goldfish and Retrace are research references, not dependencies; no implementation code was copied from them.
