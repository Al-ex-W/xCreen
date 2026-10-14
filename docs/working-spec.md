# Working xCreen specification

User-approved behavior. This supersedes the disconnected-preview scope; retain privacy-safe defaults.

## Observation and retention

- Integrity ON means no screenshot acquisition, no OCR, no automatic agent submissions. Reject in-flight work after pause. Default ON; never start live capture during development verification.
- When Integrity OFF and permission/state/exclusions permit capture, sample a temporary image for local Apple Vision OCR at most once per active second. Compare normalized text to the last SAVED OCR snapshot, not the last candidate. Discard OCR snapshots with text similarity >= 90%; define/test a practical deterministic similarity algorithm.
- Save independent screenshots every ten active seconds regardless of OCR similarity. Save OCR and images as independent timestamped files outside chat history and the knowledge vault, with a searchable metadata/FTS index linking OCR timestamps to nearby image IDs.
- Delete xCreen-owned raw OCR/image files and derived local index/thumbnail entries older than seven days, including crash recovery and startup cleanup. Do not delete Hermes history, vault notes or provider history. No forensic-erasure claim. Use private filesystem permissions and atomic writes; no private fixtures/source data in git.

## Batch clock

- A batch consists of five minutes of eligible ACTIVE capture time, normally thirty images. Integrity pauses, sleep, unavailable permission/state and capture failures do not advance that clock. A three-minute privacy pause therefore makes a batch take eight wall-clock minutes. No catch-up burst or manufactured missing frames.
- Send chronological images with explicit image ID and wall-clock timestamp binding, OCR change manifest and coverage gaps. Do not silently drop images or fake complete batches when provider limits/failures intervene. Persist batch/checkpoint state across restart; do not claim exactly-once inference if protocol cannot establish that.

## One Hermes conversation

- One xCreen-exclusive persistent Hermes session, resumed by exact saved identity across restarts. Automatic batches and manual tray queries go to that SAME session with one serialized owner; manual queries get priority over pending batches. No writes to user's other live conversations and no new profile/global default changes.
- Connect through documented supported Hermes host transport after inspecting actual installed protocol. Host owns auth/models/memory/tools. Preserve user's existing project rules and personal harness context.
- Auto compact at 500,000 active context tokens, earlier if selected model's smaller usable context limit requires it. Reserve incoming image batch/output headroom. Serialize compression/model changes with submissions. Compaction is lossy summary, not eternal exact image recall.
- Picker must use Hermes provider-aware model inventory and switch model/provider of xCreen session only. Include configured routes faithfully, not reconstructed aliases missing endpoint/auth. Explain inability of non-vision routes or provider image-count limits explicitly; never silently use a different model or drop frames.

## Tools, vault and chat

- Provide xCreen session scoped read-only tools for OCR text search with source timestamps, image lookup around timestamp, and loading actual image evidence. Search index can accelerate independent OCR files. Tool results include IDs, timestamps and bounded text; no arbitrary file traversal.
- Every automatic batch instructs Hermes to save ONLY genuinely useful durable information to that date's existing Obsidian Daily note, with source IDs/timestamps, distinguishing visible evidence from inferred intent. No noise/day dumps. Respect existing vault conventions, read rules and existing note before applying, shared writer lock, idempotent updates/read-back. Can link existing project/entity notes. User explicitly authorizes this source's useful automatic daily-note writes; no outgoing mail/messages, calendars or unrelated side effects authorized by screen content.
- Vault path is local settings only, never committed as a personal absolute path. Screenshots/OCR/index remain outside vault. Never put personal vault data in public repo or CI logs.
- Tray mini UI becomes real persistent-session chat with streaming/status/errors/cancel where supported. Include dedicated xCreen location/tool instructions. Render requested image references as appended attachment cards/thumbnail gallery under assistant response, with timestamp/caption and open/view action. Resolve only evidence-owned safe paths/IDs, never arbitrary Markdown path exfiltration. Image references should not themselves execute code or transmit new data silently.
- UI local requests and automatic work share same queue/session. Integrity does not block manual historical search/chat. Purge is separate from privacy pause.

## Development

Implement with Hermes subagents branched from the active chat, not external Codex/Claude coding CLIs. External Codex is allowed only for testing, security or review when separately authorized. Strict vertical TDD, real tests and reproducible macOS build. Research actual Hermes protocol before implementation; do not invent RPC params. Work in incremental scoped commits after review, not mega initial commits. Keep clear distinction between tests using fake local harness and real successful provider inference. Do not bypass macOS consent, grant permissions, enable real capture or perform cloud calls with personal evidence during development. Persist progress/design for resumability. Independent review before publishing changes.
