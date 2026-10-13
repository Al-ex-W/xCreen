# xCreen: macOS platform and architecture research

Research date: 2026-10-13. Scope: public primary sources, documentation and selected source inspection only; no app execution, screen capture, permission changes, production code, or repository creation. **API-documented feasibility is not a tested xCreen implementation.** Recommendations below are explicitly design proposals.

> Implementation update: the repository now contains a compile-verified filtered single-window `SCScreenshotManager` path, Vision OCR, a tested fail-closed policy generation, and a macOS 26 `AskXCreenIntent` question handoff. No screenshot was taken and no TCC prompt was requested during development. Live capture, lifecycle transitions, OCR performance, and installed Spotlight discovery remain unverified; the research claims below remain scoped to their original review.

## Executive decisions

- **Build a context supplier, not another autonomous agent:** a native menu-bar app captures selected screen context locally; the personal Hermes harness retrieves it through a narrowly scoped local adapter. Hermes retains model credentials, conversations, tools and reasoning.
- **Goldfish is an AX-text/MCP reference, not a screenshot recorder.** Its current documentation explicitly says no screenshots or screen recording. Its local-memory claim does not mean local-only inference.[3][4][5]
- **Retrace is the screenshot/OCR/storage reference**, but its legacy capture route, unfinished encryption and very-early-development status are reasons not to adopt it wholesale.[2][7]
- **Native screenshot MVP: macOS 14+**, using filtered `SCScreenshotManager.captureImage`; optional richer screenshot API on macOS 26+. Modern Spotlight action invocation is a **macOS 26+ enhancement**, not a reason to require 26 for capture.[10][27][22]
- **Integrity mode ON must prohibit screenshots before capture**, not merely hide history or disable uploads. Enforce locally, independently of Hermes and of any model response.
- **Cmd+Space → select “Ask xCreen” → fill a question parameter → run** is a documented direction on modern Spotlight. **Cmd+Space → arbitrary question → always show a custom live “Ask xCreen” answer row** is not established by the reviewed public APIs.[18][20][22]

## 1. Goldfish: what is actually documented

The website presents a context-aware writing assistant, an Option-key invocation, local memory, and other-AI integration.[1] Its current privacy policy, updated September 22, 2026, supplies the architectural detail: it reads text from the active app through OS accessibility APIs, stores captured text and generated summaries/wiki/profile in local SQLite and related files, and does **not** capture screenshots.[3] Documentation confirms foreground-window text rather than pixels.[4]

**Local-first, not offline:** selected text leaves the device for explicit requests **and background memory organization/personalization**. Goldfish says requests pass through Cloudflare to private Azure OpenAI with zero retention; these are vendor policy assertions, not independently audited implementation guarantees. Event-only product analytics and account/billing providers are also disclosed.[3][4]

Its on-device masking excludes password fields, skips banking/password-manager/private-browser contexts by default, and masks recognizable credentials and financial identifiers before storage. The policy admits imperfect pattern detection and explicitly says names, email addresses and phone numbers are not removed.[3]

Goldfish documents a **local stdio MCP executable**, manual registration and automatic registration into supported AI apps. Connected apps can search captured context and read activity summaries; retrieved content subsequently falls under the client app's privacy terms. Its local service is documented as local-machine-only and protected by a per-install token.[4][5]

**Borrow:** capture-time filtering, explicit pause/exclusions, sourced local memory, and a small read-only context interface. **Do not borrow:** silent background cloud processing, automatic modification of every AI client's configuration, or “no one can see your data” wording without the cloud-processing qualifications. This review inspected public policy/docs, not Goldfish's application source or binary.

## 2. Retrace: implementation lessons and limitations

The README describes screenshot sampling every two seconds by default, frame deduplication, Apple's Vision OCR, SQLite FTS5 search, and a parallel HEVC/MP4 history pipeline. It marks those as working and audio transcription, embeddings and stored-data encryption as not yet active/finished.[2] Default storage is under `~/Library/Application Support/Retrace/`; its README's performance and storage figures are self-reported, not measurements performed for this research.[2]

Selected source inspection corroborates a `CGWindowListCapture` actor, per-frame exclusion calculation and capture blocking, browser-specific private-window heuristics, and a separate lock/screensaver monitor.[6][7][8] The capture source deliberately uses the legacy path, with a comment about avoiding the purple indicator; **this is not a recommendation for xCreen** and does not establish future OS compatibility.[7]

Its lock monitor listens to distributed notification names `com.apple.screenIsLocked`, `com.apple.screenIsUnlocked`, `com.apple.screensaver.didstart` and `.didstop`, with boolean initial state. Source existence proves the implementation uses these names; it does **not** prove Apple publicly guarantees them or that launch-while-locked is handled safely.[6] Private browsing detection uses AX attributes and title/description patterns across browsers; this is heuristic behavior, not a universal browser privacy contract.[8]

The repository's MIT license permits reuse subject to retaining its copyright/license notice; attribution is required if code is copied.[9] Scope caveat: README and selected source files were reviewed at moving `main`, not a pinned release or a full audit. No tests/builds were run.

## 3. Native capture and OCR: verified API boundary

| Capability | Publicly documented availability | xCreen implication |
|---|---|---|
| `SCContentFilter` | macOS 12.3+ | Select/filter shareable windows, displays and apps; refresh selections as windows/processes change.[13] |
| `SCScreenshotManager` / filtered `captureImage` | macOS 14+ | Obtain individual frames; do not set up a continuous video recorder merely to obtain occasional screenshots.[10] |
| `captureImage(in:)` | macOS 15.2+ | Rectangle in display-space points, display-agnostic/multiple-display support. A rectangle alone is not an application-exclusion policy.[26] |
| `captureScreenshot(contentFilter:configuration:)` | macOS 26+ | Uses `SCScreenshotConfiguration`, returns `SCScreenshotOutput` containing requested CGImages.[27] |
| `VNRecognizeTextRequest` | macOS 10.15+ | Native image OCR with language selection and recognized-text observations.[15] |

Apple's ScreenCaptureKit sample demonstrates selecting shareable content, excluding the capture app, configuring output, permission prompting, and checking stream-frame status. Its current sample project requires macOS 15; **that sample deployment minimum is not the introduction version of every API**.[14]

**Proposal:** filtered single-window capture by default, with explicit per-display capture as an advanced choice; exclude xCreen itself to avoid recursive UI capture. Downscale for OCR only when legibility survives; retain timestamps, app identity, source window and OCR confidence/bounding boxes. Deduplicate locally before OCR/model work. Bound concurrency and drop superseded frames instead of accumulating a queue. A continuous `SCStream` is an optional optimization requiring energy/memory measurements, not a default necessity.

**Permission policy:** screen capture requires Screen Recording consent; Apple's sample describes granting permission and restarting its app.[14] Never bypass TCC, suppress system indicators as a product goal, or claim old capture APIs eliminate consent. Revocation/error must stop new ingestion and expose an actionable state. This review did not test permission persistence, protected-content behavior or prompt frequency on the actual macOS 27 host.

Vision OCR is suitable for a native OCR stage, but no benchmark here establishes accuracy, latency or energy on the user's screen. OCR cannot reliably reconstruct every UI hierarchy or detect every secret; AX should remain optional enhancement, not a hidden mandatory permission.

## 4. Accessibility, exclusions and lock safety

Apple's `AXIsProcessTrustedWithOptions` reports whether the current process is a trusted accessibility client; its prompt is asynchronous and does not change the returned trust result.[16] **Separate permission boundaries:** AX trust is not Screen Recording permission. An app can use image OCR without AX; optional AX extraction should be independently visible and independently revocable.

**Proposed exclusion order:** integrity gate → session/sleep/display gate → permitted app/window gate → privacy-context gate → capture → local sanitization/OCR → retention gate → context egress gate. Prefer source-level selection over capturing a whole desktop and redacting afterward. App exclusions need to cover visible background windows, not just the frontmost app. Do not log private window titles, URLs or raw text while deciding exclusions.

There is no universal private-browsing indicator demonstrated by these sources: Retrace's AX/title strategies show browser-specific heuristics.[8] Therefore never promise “incognito is always excluded.” Offer conservative app-wide browser exclusion or pause when private-state determination is unavailable; browser URL extraction may itself require AX and/or Automation consent depending on the approach.

**Lock distinction:** Apple's `NSWorkspace.sessionDidResignActiveNotification` is documented for a user session switching out, not as a blanket screen-lock guarantee.[17] Combine documented session/sleep/display lifecycle handling with fail-closed capture errors and a tested initial-state strategy. Treat Retrace's lock notification names as a compatibility technique requiring OS testing, not a stable public API guarantee.[6] Acceptance tests must cover launching while locked, manual lock/unlock, screensaver, sleep/wake, fast user switching, display detach, and an in-flight capture during each transition.

**Integrity mode ON invariant (proposal):** no screenshot API invocation, no new frame/OCR job, no screenshot persistence or screenshot transfer. Increment a policy epoch and discard every older in-flight result before processing, saving or sending. Stop active streams and release queued pixel buffers. Reject agent-triggered “capture now” while ON. Old history deletion is a separate explicit choice. If AX-only collection remains allowed, state that clearly; a screenshot-off switch must not imply all observation is off. Failures/crash recovery must not silently restore capture.

## 5. Local storage and Hermes boundary

**Proposal, not an existing implementation:** keep xCreen's database and optional artifacts in its own Application Support directory, outside the personal notes vault and outside any public repository. Start with SQLite metadata + OCR/full-text retrieval, a bounded ephemeral screenshot buffer, and **no retained raw screenshots by default**. A history opt-in needs byte/age limits, visible disk usage, full deletion and per-app purge. Retrace demonstrates why persistent video history is a materially different storage commitment.[2]

Do not call SQLite “encrypted” merely because encryption exists elsewhere in dependencies: Retrace specifically says stored-data encryption is in progress.[2] Define an at-rest threat model; use OS account/disk protection plus explicit database/artifact encryption if required, with keys stored separately in Keychain. Deletion must include derived OCR, thumbnails, embeddings, WAL/backups and any Spotlight donations; filesystem deletion is not a guarantee of physical secure erasure. Treat these as requirements to implement/test, not current assurances.

Hermes officially supports local stdio and remote HTTP MCP servers, startup discovery, filtering, and optional server-initiated sampling.[25] **Recommended first boundary:** an xCreen read-only MCP service with bounded `search_context`, `get_context` and `capture_status` capabilities (proposed names). Prefer stdio or authenticated local IPC; if using loopback HTTP, loopback alone is not authentication. Bind permissions to the intended local user and restrict file access to xCreen-owned artifacts.

Use the personal Hermes harness as the primary consumer. Passive capture should not automatically start a new agent conversation every interval. MCP retrieval lets Hermes pull relevant records; a separate explicit query bridge is required when the popover initiates a conversation. **Neither a documented MCP client nor a provider proxy proves an app-to-existing-desktop-session ingress API exists.** That exact bridge remains integration work.

Local capture/OCR/storage does not make a cloud-routed Hermes model local. Preview/limit outbound context, redact before egress, and disclose provider/transcript retention. Screen text is untrusted evidence, never authorization to run commands or change privacy policy. Model picker: discover configured routes; recommend an available light Haiku/Luna route as a UX preference, not an invented model identifier, universal vision capability, pricing claim or automatic fallback. Verify modalities and cost for the exact selected route.

## 6. Spotlight: precise feasible UX versus unsupported promise

### macOS 26+ action invocation — API-documented feasible

Apple's WWDC25 session explicitly introduces running app actions directly from Spotlight on Mac. The user searches for/selects an intent and fills its required parameter fields.[22] An `AskXCreenIntent` can therefore take a **String question parameter**, with a summary such as “Ask xCreen [question]”, and hand an explicit request to the local query bridge. `AppIntent` supports parameter wrappers and a `perform()` method.[18]

Requirements from Apple: include **all required parameters without defaults in `parameterSummary`**; do not mark the intent undiscoverable or assistant-only; configuration-only widget intents without `perform()` are not eligible.[22] `supportedModes` is available on macOS 26+ for foreground/background policy.[19] For v1, show answers in xCreen's native popover/window; a rich inline Spotlight answer/snippet requires separate implementation and UX verification, not a guarantee of arbitrary custom result rendering.

**Honest advertised sequence:** Cmd+Space → find/select Ask xCreen → enter question in its parameter field → run. Ranking, action discovery, text-field experience, response presentation and actual integration on macOS 26/27 need a signed-app spike. The docs do not promise a global catch-all query provider or the ability to intercept every Spotlight keystroke.

### macOS 13–15 / Core Spotlight — different mechanism

`AppIntent` itself exists on macOS 13+, but that does not backdate the macOS 26 Spotlight action UI.[18][22] Core Spotlight `CSSearchableItem` is available on macOS 10.11+ and indexes concrete app content/metadata; indexed records may be updated, so “static” here means **pre-indexed content**, not permanently immutable data.[20] It is not a documented live LLM-result provider for every arbitrary query.

**Important nuance:** Apple also documents `CSQueryContinuationActionType` on macOS 10.12+ and `CoreSpotlightContinuation = true`, delivering a query through user activity when the user continues a Spotlight search.[21] This is a legitimate search-handoff avenue, so “Spotlight can never pass a query” is too strong. It does **not** establish that an always-visible “Ask xCreen <anything>” row can be forced for all queries on macOS. The documentation includes UIKit-style delegate examples; actual AppKit delivery and current system presentation need a spike. Do not base the primary UX on an untested continuation row.

Privacy recommendation: do not donate the entire OCR/screenshot history into Spotlight by default. That creates another system-managed search surface and another deletion obligation. Prefer action discovery on modern systems and optionally user-approved searchable records.

### Dependable fallback directions

- **Shortcuts:** expose the same App Intent and build an Ask xCreen shortcut that obtains text explicitly, then opens xCreen. Apple's command-line documentation supports text/document inputs and output handling; a named shortcut is not equivalent to automatically capturing the raw Spotlight query.[18][24]
- **Raycast:** a native Raycast extension command can define a required text argument and route it to xCreen; the manifest explicitly supports command arguments and view/no-view modes.[23] This offers a controlled “Ask xCreen + question” launcher experience, but is **Raycast**, not native Spotlight. Optional user remapping to Cmd+Space must be disclosed.
- **xCreen global hotkey/popover:** keep a nonconflicting configurable shortcut and native input field as the platform-independent baseline. Do not hijack Cmd+Space silently or read Spotlight's UI via AX as a workaround.

## 7. Proposed delivery boundary

**V1:** native silver Aqua-style mini popover; permission/status explanation; strict screenshot integrity toggle; filtered one-shot capture; Vision OCR; bounded local searchable context; read-only Hermes adapter; explicit Ask workflow; configurable light-model preference; exclusions and retention controls. These are design goals backed by the APIs above, not completed features.

**Conditional enhancement:** macOS 26+ Spotlight App Intent; optional Shortcuts/Raycast bridges. **Roadmap only:** validated inline Spotlight snippets, optional retained screenshot/video history, semantic embeddings, proactive cloud distillation, or universal browser-private/lock exclusion guarantees. Do not advertise roadmap items as shipping behavior.

**Release verification required:** signed/notarized distribution; TCC onboarding/revocation; integrity epoch races and restart behavior; exclusions across supported browsers; lock/sleep/user-switch races; scaled/multiple displays; OCR latency and energy; retention/deletion; no unauthenticated IPC; end-to-end Hermes retrieval/query routing; actual Spotlight action discovery and parameter handling. No evidence in this report replaces those acceptance tests.

## Retrieval notes

`web_extract` was unavailable because the configured backend was search-only. Public pages were recovered with `curl`; Python urllib encountered 403 responses on Goldfish pages while curl succeeded. Apple documentation was read through its public DocC JSON endpoints, and the WWDC25 transcript was read directly. A terminal working-directory validator rejected the workspace's combining accent; retrieval commands ran in the explicitly requested scratch directory instead. No private capture data, account content, tokens or personal configuration are reproduced here.

## Sources

[1] https://goldfish.sh
[2] https://github.com/haseab/retrace
[3] https://goldfish.sh/privacy
[4] https://docs.goldfish.sh/privacy.md
[5] https://docs.goldfish.sh/guides/ai-clients.md
[6] https://raw.githubusercontent.com/haseab/retrace/main/Capture/ScreenCapture/ScreenLockStateMonitor.swift
[7] https://raw.githubusercontent.com/haseab/retrace/main/Capture/ScreenCapture/CGWindowListCapture.swift
[8] https://raw.githubusercontent.com/haseab/retrace/main/Capture/ScreenCapture/PrivateWindowDetector.swift
[9] https://raw.githubusercontent.com/haseab/retrace/main/LICENSE
[10] https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager
[13] https://developer.apple.com/documentation/screencapturekit/sccontentfilter
[14] https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
[15] https://developer.apple.com/documentation/vision/vnrecognizetextrequest
[16] https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions
[17] https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification
[18] https://developer.apple.com/documentation/appintents/appintent
[19] https://developer.apple.com/documentation/appintents/appintent/supportedmodes
[20] https://developer.apple.com/documentation/corespotlight/cssearchableitem
[21] https://developer.apple.com/documentation/corespotlight/csquerycontinuationactiontype
[22] https://developer.apple.com/videos/play/wwdc2025/260
[23] https://developers.raycast.com/information/manifest
[24] https://support.apple.com/guide/shortcuts-mac/run-a-shortcut-from-the-command-line-apd455c82f02/mac
[25] https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp
[26] https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage%28in:completionhandler:%29
[27] https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/capturescreenshot%28contentfilter:configuration:completionhandler:%29
