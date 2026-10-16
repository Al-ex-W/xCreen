# Final integration review

Independent native subagent review of the runtime/native work; no external coder, commits, push, app installation, capture, permissions or inference.

## Findings fixed

- Native manual turns previously omitted mandatory `xcreen.batch.context`. The FIFO now awaits a validated manual acknowledgment after compaction and directly before submit. Failed context prevents submission. Cancellation during context setup does not interrupt an unsubmitted question; identity/cancellation/connection are rechecked afterward.
- The build script copied only three Python modules despite new receipt/RPC imports. It now includes all six runtime/migration modules before signing. Their built bytes were compared with source.
- Legacy top-level receipt ledgers previously had only an opaque startup block. An explicit offline metadata-only migration CLI now validates known schemas/values, preserves pending/uncertain states, retains the original backup, and refuses unknown schemas, unsafe files, sidecars and destination conflicts. It does not invent historic automatic session/source bindings or touch note bodies. See runtime-receipts.md for command and recovery limits.

## Reviewed action/security contract

- Automatic writer/final-result tools accept no model-supplied session, batch, date or path authority. Host-injected session/turn, exact live object and preparation history revision gate tools; exact native persisted source manifest is immutable and revalidated under the shared vault lock before append. Explicit manual context revokes automatic authority even after a no-tools turn. Manual writer cannot produce automatic batch effects.
- Saved final receipts require all and only verified effect IDs; skipped requires explicit no-useful-fact and zero effects. Terminal metadata is committed/read back; note blocks/digests/inode identity are reconciled read-only. Edited/missing/partial effects are uncertain, not repaired or reappended. Assistant terminal prose/history is not receipt authority.
- Cold lookup retains the original preparation session ID. Existing native persisted binding guards reject rebinding, and the restart test changes runtime ID while asserting both receipt requests use the original ID. Runtime receipt lookup intentionally does not require a live old session.
- Native submitting/admitted crashes become uncertain and cannot blindly resend. Raw expiry retains exact IDs/receipts; native archives are bounded. History is paged and sanitized by the host before stdout (20 messages / 48,000 result bytes), with frozen cursors, explicit eviction errors and oversized placeholders.
- Same-UID trust remains explicit. Private mode/inode checks are not a malicious same-user sandbox; hashes do not authenticate against same-UID actors. History pages are bounded but full host history/snapshots are still held in memory. No encryption, forensic erasure, browser-secret redaction or universal unlock proof is claimed.

## Executed verification

- Swift: **107 passed, 0 skipped, 0 failures**, including real installed-Hermes Swift/Python stdio prepare → manual-context → verified receipt → 90-message history traversal, synthetic Daily only, no prompt submission.
- Runtime Python under installed Hermes Python: **44 passed, 0 skipped, 0 failures**. Real `_execute_tool` host context, manual/automatic separation, cold receipt lookup and real gateway registration/stdio tested.
- Bridge Python: **15 passed**. CLI Python: **5 passed**.
- Release bundle built at `dist/xCreen.app`; ad-hoc signature verified with `codesign --verify --deep --strict`. All six bundled Python modules match source. AppIntents metadata generated; no discovery/ranking claim.
- `git diff --check` clean.

An initial combined fixture set a synthetic home before Hermes dependency activation, which triggered Hermes lazy dependency preparation in that synthetic home and failed. The fixture now disables lazy installs and activates installed dependencies read-only before selecting the synthetic home. Final verification passed without that preparation. No app was installed or launched.

## Remaining authorized deployment checks

The parent's deployment may encounter an actual legacy schema outside the supported metadata shapes, sidecars or interrupted migration conflicts; these remain explicit blocks requiring metadata review, not deletion. Real existing ledger contents were not inspected or migrated. Turn-isolation-enabled Hermes configurations are explicitly unsupported and never changed. Provider inference, automatic five-active-minute insight quality, real Daily writes, capture/TCC/lock/sleep behavior and UI/Spotlight discovery are not verified by these tests. Single persistent session ownership and user Integrity intent were not changed.
