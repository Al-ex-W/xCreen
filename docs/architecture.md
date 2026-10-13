# xCreen architecture

## Principle: eyes for an existing brain

xCreen observes a permitted foreground window, extracts text locally, and keeps a short-lived searchable evidence index. A harness adapter answers an explicit user query with relevant observations, timestamps and source IDs. Hermes remains responsible for identity, models, credentials, project instructions and personal context. Other harnesses can implement the same adapter contract later.

Do not equate a screenshot with intent, completion, reading comprehension or hidden content. An observation proves only that something was visible at a particular time. Show observation coverage and gaps rather than claiming full knowledge.

## Data flow

```text
Explicit opt-in + screen permission
  -> foreground-window ScreenCaptureKit image (memory only)
  -> Apple Vision OCR (on-device)
  -> bounded/deduplicated local SQLite + FTS5 evidence
User query
  -> relevant evidence + recent fallback, within a token budget
  -> selected model through existing Hermes config/auth
  -> cited answer in the menu-bar panel
Useful durable fact (separate future reviewed action)
  -> vault metadata + distilled note with source references
```

The initial shell is macOS-native SwiftUI/AppKit. Capture policy is independently testable. The Python bridge provides local storage, model inventory and the first Hermes adapter without an exposed TCP port or another service.

## Harness integration

The initial integration uses the installed Hermes CLI with an argument array and query over stdin, no shell interpolation. It starts a separate bounded xCreen query, preserving the selected profile's rules and memory. It must never resume or write concurrently to the user's active conversation. A configured vault directory scopes project context without copying the vault into app storage. Model selection overrides only that invocation, never the main profile defaults.

The main supported long-term transport is Hermes' documented JSON-RPC gateway: per-session model/provider overrides, `model.options`, streaming, cancellation, and explicit approval channels. ACP is suitable for a general harness adapter. The OpenAI-compatible API server is a viable alternative when already enabled and authenticated. A subscription inference proxy alone is NOT a context-aware harness: it has model access but not the personal agent loop/memory.

Do not silently create another gateway, expose a local unauthenticated API, copy API keys, or edit the user's Hermes configuration. Inventory existing configured models. Recommend a small model such as Haiku or Luna only if actually available through that user's provider; don't pretend those are installed.

## Vault boundary

The vault is a knowledge store, not an activity dump. Keep screenshots, raw OCR, SQLite, model credentials and debugging logs outside it. In the initial app, no automatic vault writes are performed. The optional vault path loads existing project rules into a user-initiated query.

Proposed durable integration, after a separate reviewed consent step:

- `Agent/xCreen.md`: source policy, consent, retention and local resolver instructions.
- `Daily/YYYY-MM-DD.md`: optional short sourced activity distillation, only if useful.
- Existing project/entity notes: link decisions to `xcreen://observation/<id>` and timestamp; distinguish observed facts from inferences.
- Shared vault-write lock: use the existing harness writer, not a second independent writer.

Expired observations make links unresolved; a durable note must contain enough useful distillation to stand alone. Screen content cannot create calendar events, send messages or change operating rules by itself. Existing email/message intake jobs remain untouched.

## Privacy policy design

Start with Integrity mode ON (capture paused). Capture only after explicit opt-in; foreground-window-only capture reduces accidental background exposure but is not a perfect secret filter. Exclude known credential apps and system surfaces, pause on inactivity/lock, discard late captures after pause, process OCR locally and keep no durable pixels. Raw OCR is still sensitive; use a private app-data directory, a rolling retention bound, and purge controls. File permissions are not encryption; FileVault is recommended. SQLite deletion does not guarantee forensic erasure or deletion of backups.

Cloud answer consent is separate from capture consent. Only retrieved text is sent to the model, but Hermes transcripts may retain it beyond the local index's TTL. Provider retention is governed by that provider, not xCreen. Integrity mode stops new capture; it does not erase history or revoke earlier cloud transmissions.

Future context improvements: opt-in Accessibility window metadata, browser URL/document identity and user bookmarks. Never request full Accessibility permissions just to imitate a complete memory system, read password fields, log keystrokes, inspect clipboard content automatically or bypass private browsing.

## Delivery boundaries

This is a developer MVP, not a notarized consumer release. Dynamic arbitrary-query Spotlight invocation, semantic embeddings, live gateway streaming, reviewed vault writes, signed distribution and stronger content redaction require explicit follow-up work. Research records distinguish supported APIs from proposed paths.

## Primary Hermes references

- https://hermes-agent.nousresearch.com/docs/developer-guide/programmatic-integration
- https://hermes-agent.nousresearch.com/docs/user-guide/features/context-files
- https://hermes-agent.nousresearch.com/docs/user-guide/features/memory
- https://hermes-agent.nousresearch.com/docs/user-guide/security
