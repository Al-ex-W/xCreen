# Integration contract between native evidence and chat

These are internal Swift APIs to implement now, not claims of current capability. Coordinate via this file and actual core source. Native store avoids a Python dependency for capture.

## Capture owner

Own `CaptureService.swift`, `MacSessionState.swift`, core files `EvidenceStore.swift`, `ActiveCaptureClock.swift` (or similar) and their unit tests. Do not edit main.swift/HermesGateway/SessionCoordinator. Expose:

- `EvidenceImage`: public Codable/Identifiable/Sendable value `id: String`, `timestamp: Date`, `fileURL: URL`.
- `OCREvidence`: public Codable/Identifiable/Sendable `id`, `timestamp`, `text`, `app`, `title`.
- `CaptureBatch`: public Codable/Identifiable/Sendable `id`, `images: [EvidenceImage]`, `startedAt: Date`, `completedAt: Date`, `ocr: [OCREvidence]`, with explicit timestamped image manifest.
- `EvidenceStore` public actor with `init(root: URL) throws`, defaultRoot static URL, `searchOCR(query:String, limit:Int=20) throws -> [OCREvidence]`, `imagesNear(timestamp:Date, seconds:Double=30) throws -> [EvidenceImage]`, `image(id:String) throws -> EvidenceImage?`, `pendingBatches() throws -> [CaptureBatch]`, `markBatch(id:String, status:String) throws`, and `cleanup(now:Date=Date()) throws`. Store timestamps in actual files with full ISO time and indexed lookup; validate IDs and confined paths/symlinks.
- `CaptureService` @MainActor class init(store: EvidenceStore, status:@escaping (String)->Void, integrityChanged:@escaping (Bool)->Void, batchReady:@escaping (CaptureBatch)->Void); `enableAfterExplicitConsent() -> Bool`, `pause(reason:String=...)`. Defaults paused. Every 1-second successful eligible sample, time advance at most 1s; OCR >=90% similarity vs last persisted OCR skipped; separate image each10 active secs. Five-minute batch normally30 images; pauses/no permissions/unknown unsafe state/failures no active time; no catchup. Persist checkpoints. On batch completion call batchReady, retain pending marker for retries; callbacks never themselves submit to Hermes.

Capture compatibility: do NOT permanently hardcode `.unknown` lock state and pretend implementation complete. Research practical macOS session gating from current public session dictionary/foreground/loginwindow and lock/sleep invalidation. If using a platform compatibility lock indicator, isolate and document it as not an Apple-guaranteed universal contract; absence/errors/contradiction must reject. User explicitly enables capture with System permission; no capture in tests. No silent consent or granting permissions.

## Chat/session owner

Own `main.swift`, `HermesGateway.swift`, `SessionCoordinator.swift`, new session/tool/vault bridge files and related tests. Do not edit CaptureService/evidence core owned by other worker. Use declared core API above; wait only on compilation if files not yet available, don't overwrite/delete sibling work.

One persisted xCreen session owns manual/batch/model/compress work. Use ACTUAL installed Hermes JSON-RPC stdio process entry, NOT blindly `hermes --tui` which normally launches the Ink client rather than raw server. Inspect installed source startup and contracts. Preserve host auth/model catalogue. Actual screenshot bytes attached with timestamp/ID every batch. Scoped read-only tool wiring with metadata timestamps and safe evidence paths; optional bounded daily writer with configured vault local path and shared flock, no outbound message/calendar actions. Native thumbnail appendix ID resolver, full model/provider picker and within-session switch. Streaming/cancel errors/timeouts/reconnect safe, no infinite pending continuation. Do not let app UI alter default model/global config. Persistence IDs distinguish runtime session ID from stored ID per actual contracts.

Both workers: strict TDD, synthetic fixtures only, no private vault reads/real capture/cloud inference/config mutation/commits/push. Run focused tests, parent reruns entire suite and independent review before publishing. Update progress with reality. Retain compatibility with old tests if safe; deprecate broken fake assumptions with explicit real protocol tests.
