# xCreen

**Local screen context for your personal AI harness.** macOS-first, native menu-bar UI, Hermes-first integration.

> **Developer preview — not a finished screen-memory app.** The current native shell queries the local evidence bridge, discovers configured Hermes models and shows answers. **Automatic screenshot capture is not wired up; Integrity mode is locked ON. Spotlight App Intent is not implemented.** Research and tested capture-policy primitives are included, not a claim of production recording.

## Design

xCreen supplies the eyes; your existing harness remains the brain. The intended pipeline is filtered foreground-window screenshots → local Apple Vision OCR → short-lived SQLite retrieval → an explicit, cited answer through your existing Hermes profile. No second credentials store, no wholesale vault copy and no passive LLM call on every frame.

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

In **Harness settings**, set the absolute Python path (your venv interpreter), absolute Hermes executable, and optional personal vault directory. Save and refresh models. Nothing changes your main Hermes model configuration. The app is ad-hoc signed for local development, not notarized for distribution.

The bundled bridge reads the current `HERMES_HOME` or default `~/.hermes` configuration locally. GUI apps may not inherit your shell's environment; default-profile support is the initial target. Configured inventory, not the entire provider catalog, appears in the picker. Use a light **Haiku or Luna** route if actually configured and suitable; these names are recommendations, not claimed installed models or invented model IDs.

## What works / what remains

| Feature | Status |
|---|---|
| Native menu-bar mini UI, placeholder icon, query and answer | Developer implementation |
| Existing Hermes model inventory and per-query selection | Local bridge implementation |
| Bounded local OCR-text ingestion, FTS search, expiry and purge | Local bridge; command-line ingestion |
| Integrity defaults ON, exclusions and stale-result policy | Unit-tested core; no live capture yet |
| Periodic ScreenCaptureKit + Vision OCR | **Not wired up** |
| `xcreen://ask?query=...` | Opens panel and fills input; never auto-submits |
| Native Spotlight arbitrary-query suggestion | **Not verified / not implemented** |
| macOS 26+ Spotlight App Intent with question parameter | Researched supported direction; pending implementation |
| Hermes access to activity from normal conversations via MCP | Proposed read-only adapter, pending |
| Vault read/write integration | Optional project-context directory only; no automatic note writes |
| Signed/notarized releases, semantic search, universal secret filtering | Pending |

The current CLI query adapter is tool-disabled for safety. It inherits Hermes personal memory and project instructions but does not autonomously search arbitrary vault files or attach to your current Desktop conversation. A future authenticated JSON-RPC adapter plus read-only xCreen MCP server is the proper fully integrated path.

## Spotlight: honest UX

Apple documents macOS 26+ Spotlight app actions. The feasible path is **⌘Space → select Ask xCreen → enter the question parameter → run**. This does not establish a catch-all live result provider for arbitrary text. Core Spotlight query continuation is a separate documented handoff worth testing, not a guaranteed suggestion row. No silent ⌘Space hijacking or Accessibility scraping of Spotlight.

For this preview, launch the app from Spotlight and enter your question in its panel. URL handoff can support a later Shortcut/Raycast integration. See [platform research](docs/platform-research.md) for Apple references and OS availability.

## Your vault

Keep the local index under Application Support, **outside your knowledge vault**. No pixels, raw OCR, database or credentials in notes. The optional vault setting supplies existing project rules to Hermes; it does not copy or write the vault.

Later, reviewed useful facts can become short source-linked distillations in existing entity/project notes, through your harness's existing serialized writer. Screen evidence does not expand message-sending or calendar authorization. Existing email/message intake stays unchanged. See [architecture](docs/architecture.md).

## Privacy

Capture is OFF in this preview. Future Integrity mode ON must stop capture itself and invalidate in-flight work; old-history deletion is a separate operation. Local OCR would not mean local inference: an explicit question sends retrieved text to the chosen provider. Hermes transcripts and provider records may retain it beyond the local index's TTL.

The local index is private-file-permission protected, **not database-encrypted**. Recommend FileVault. No claim of secure physical erasure, universal incognito detection or perfect credential redaction. Read [SECURITY.md](SECURITY.md) before using sensitive context.

## Research and license

- [Platform research: Goldfish, Retrace, Apple APIs, Spotlight and Hermes](docs/platform-research.md)
- [Harness and vault architecture](docs/architecture.md)
- [License comparison and attribution limits](docs/licensing-research.md)
- [Contributing](CONTRIBUTING.md)

**Apache-2.0 + NOTICE**, copyright Alexander Wahlström. Free personal and commercial use, including proprietary derivatives. Distributed forks must meet Apache's attribution/notice obligations. This is notice preservation, **not mandatory prominent UI/advertising credit**; a custom publicity requirement would change the license. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

Goldfish and Retrace are research references, not dependencies; no implementation code was copied from them.
