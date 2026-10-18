# Durable native processing and host receipts

The native automatic queue now integrates host-issued immutable batch preparation, explicit model batch results, and read-back-verified note effect receipts. See [the exact RPC contract](runtime-receipts.md). This is crash fencing and reconciliation, **not exactly-once inference**.

## Submission and completion

- Stable batch ID and exact evidence manifest persist before enqueue. Re-finalizing cannot reset an existing admission; conflicting reuse fails.
- States are `pending`, `submitting`, `admitted`, `completed`, `uncertain`, `deadletter`.
- While the automatic item exclusively owns the native queue, native code persists `submitting`, the original session binding, then calls `xcreen.batch.prepare`. The host must validate the persisted batch's exact source IDs. Only after a matching preparation acknowledgment and a fresh Integrity/epoch/turn check may attachment/submission proceed.
- Awaited admission persistence precedes terminal handling. Terminal messages alone never complete processing. The queue remains occupied while `xcreen.batch.receipt` verifies the explicit saved/skipped result. Native verifies batch/session/source identity, strict boolean verification, saved nonempty unique completed effects, and skipped zero effects before persisting `completed`.
- A missing receipt, malformed reply, failed verification, disconnect, or interrupted send becomes uncertain. No history lookup or blind resend is used.
- Provider failures: stock Hermes closes provider errors (e.g. HTTP 429 usage limit) with `message.complete {status:"error", error_surface}`. Native classifies this (and `*.failed`/`error` frames) as a provider failure, still reconciles the host receipt first, and returns the batch to `pending` **only** when that exact-binding receipt has `retry_safe:true` (zero effects, no terminal). Effects present, unknown effects or an old host without `retry_safe` stay `uncertain`. Backoff: rate limits 15 min doubling to 4 h and throttle **all** automatic sends; other provider failures 2 min doubling to 1 h. A batch is deadlettered after 6 send attempts or raw-evidence expiry. The consumed receipt and session binding are cleared so a later attempt needs a fresh proof.
- Retries for work that never crossed send intent: pre-boundary Integrity cancellation, gateway unavailability and backoff deferral do not consume attempts; other pre-send failures deadletter after 3. A disconnected gateway is reconnected (no inference) before automatic submission instead of burning attempts.
- The prompt instructs the model to use `xcreen_batch_result`, including explicit skipped/no-useful-fact results; prose such as “nothing saved” is not a receipt.

## Startup and explicit verification

On dedicated-session connection, interrupted native submissions are fenced as uncertain and exact durable batch bindings reconcile against the host receipt ledger before pending work is considered. The original preparation session identity is retained across cold resumes: receipt lookup must not require the original process-local session to remain alive.

On every dedicated connection the app additionally re-queues stranded `uncertain` batches whose fresh receipt is `retry_safe:true` (this recovers batches stranded by provider failures before this classification existed). `xcreen batches retry` and tray **Retry zero-effect batches** run the same verify-then-requeue explicitly; they never submit inference themselves, and normal gated automatic submission then sends due work. Batches lacking a persisted session binding or with any effect stay fenced.

`xcreen verify` and tray **Batches → Verify receipts** call the same read-only reconciliation. They do not submit inference, append/repair notes, or enable capture. A connection made for verification suppresses the normal automatic pending-submit callback. Verification updates native metadata only; host note-readback verifies existing effects. A host error invalidates prior native verification and is surfaced rather than converted to success. Legacy records lacking a persisted session binding remain fenced.

`xcreen batches [--after BATCH_ID]` and tray Refresh/Next page show actual retained receipt metadata and processing state. Pages are at most 20 records and byte-bounded; continue from the last returned ID until an empty page (a short byte-limited page does not imply exhaustion). Receipt payloads contain host metadata, not OCR/facts/pixels.

Raw evidence still expires after seven days. Expiry strips OCR/image references from retained native batch records but preserves exact source IDs/session/receipts. The expired metadata archive retains the newest records within **128 records, 2 MB, and 180 days**; oldest entries are evicted at these explicit budgets. This is not indefinite archival or forensic erasure.

## History frames

The app uses `xcreen.history.page`, never full `session.history` followed by native slicing. The host sanitizes structured pixels/data-image URLs and bounds each encoded page to 48,000 bytes before gateway stdout. At most 20 messages are returned, oversized messages become explicit placeholders, and opaque host snapshot cursors remain stable across concurrent reads. Restart/eviction gives an explicit stale-cursor error. The native transport additionally rejects oversized page results.

## Verification boundaries

Synthetic Swift integration tests exercise saved/skipped/missing receipts, wrong bindings, interrupted admitted startup recovery after raw expiry, repeated verification without resend, host-page-only routing, and a real subprocess transport paging over 3 MB of synthetic history with bounded frames. Python tests exercise the host writer/result ledger separately. Build/protocol tests do not prove live TCC, capture, lock transitions, provider inference, personal vault writes, or Spotlight behavior.

No installation, app launch, permissions, capture, real inference, personal vault reads/writes, profile changes, commits or pushes are part of this verification.
