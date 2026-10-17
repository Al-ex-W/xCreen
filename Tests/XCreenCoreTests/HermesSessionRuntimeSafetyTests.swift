import XCTest
@testable import XCreenCore

final class HermesSessionRuntimeSafetyTests: XCTestCase {
    func testHardCompactionRunsWhenIdleAboveThreshold() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        await gateway.emit(type: "session.info", payload: #"{"payload":{"usage":{"context_used":510000,"context_max":1000000}}}"#)
        _ = await TestTiming.eventually { await gateway.hardCompactions() == 1 }
        let calls = await gateway.hardCompactions(), keep = await gateway.lastKeep()
        XCTAssertEqual(calls, 1); XCTAssertEqual(keep, 2)
        await gateway.emit(type: "session.info", payload: #"{"payload":{"usage":{"context_used":400000,"context_max":1000000}}}"#)
        try await Task.sleep(for: .milliseconds(50))
        let after = await gateway.hardCompactions()
        XCTAssertEqual(after, 1)
        await runtime.disconnect()
    }
    func testHardCompactionWaitsForInFlightTurnAndPrecedesNextTurn() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        let ask = Task { try await runtime.submitManual("first") }
        await gateway.waitForSubmission(count: 1)
        await gateway.emit(type: "session.usage", payload: #"{"payload":{"usage":{"context_used":520000,"context_max":1000000}}}"#)
        try await Task.sleep(for: .milliseconds(50))
        let during = await gateway.hardCompactions()
        XCTAssertEqual(during, 0, "never compact while a turn is in flight")
        let second = Task { try await runtime.submitManual("second") }
        try await Task.sleep(for: .milliseconds(20))
        await gateway.emit(type: "message.complete")
        try await ask.value
        await gateway.waitForSubmission(count: 2)
        let order = await gateway.log
        XCTAssertEqual(order, ["submit", "compact", "submit"])
        await gateway.emit(type: "message.complete")
        try await second.value
        await runtime.disconnect()
    }
    func testCancelInFlightManualInterruptsAndFails() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        let id = UUID()
        let ask = Task { try await runtime.submitManualResult("slow", turnID: id) }
        await gateway.waitForSubmission(count: 1)
        try await runtime.cancelManual(turnID: id)
        await gateway.emit(type: "message.cancelled")
        do { _ = try await ask.value; XCTFail("expected cancel") } catch { XCTAssertEqual(error as? HermesGatewayError, .cancelled) }
        let cancels = await gateway.cancelCount()
        XCTAssertEqual(cancels, 1)
        await runtime.disconnect()
    }
    func testIntegrityFencedBatchReconcilesAlreadyTerminalReceipt() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        await runtime.setIntegrity(false)
        let binding = BatchBinding(batchID: "batch-x", sourceIDs: ["image-1"])
        await gateway.setReceipt(status: "skipped", verified: true)
        let batch = Task { try await runtime.submitAutomatic(manifest: "m", images: [], binding: binding) }
        await gateway.waitForSubmission(count: 1)
        await runtime.setIntegrity(true) // tray opened: foreground became xCreen, capture unsafe
        await gateway.emit(type: "message.complete")
        try await batch.value // durable skipped receipt proves completion
        await runtime.disconnect()
    }
    func testIntegrityFencedBatchWithoutReceiptStaysCancelled() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        await runtime.setIntegrity(false)
        await gateway.setReceipt(status: "uncertain", verified: false)
        let batch = Task { try await runtime.submitAutomatic(manifest: "m", images: [], binding: BatchBinding(batchID: "batch-x", sourceIDs: ["image-1"])) }
        await gateway.waitForSubmission(count: 1)
        await runtime.setIntegrity(true)
        await gateway.emit(type: "message.complete")
        do { try await batch.value; XCTFail("expected cancel") } catch { XCTAssertEqual(error as? HermesGatewayError, .cancelled) }
        await runtime.disconnect()
    }
    func testManualContextFailureNeverSubmits() async throws {
        let gateway = FakeGateway()
        await gateway.failManualContext()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        await XCTAssertThrowsErrorAsync(try await runtime.submitManual("denied context"))
        let count = await gateway.submissionCount()
        XCTAssertEqual(count, 0)
        await runtime.disconnect()
    }
    func testManualRevokesAutomaticContextEvenAfterNoToolsTurn() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        await runtime.setIntegrity(false)
        let batch = Task { try await runtime.submitAutomatic(manifest: "automatic", images: []) }
        await gateway.waitForSubmission(count: 1)
        let manual = Task { try await runtime.submitManual("manual") }
        await gateway.emit(type: "message.complete")
        try await batch.value
        await gateway.waitForSubmission(count: 2)
        let contexts = await gateway.contextCount()
        XCTAssertEqual(contexts, 1)
        await gateway.emit(type: "message.complete")
        try await manual.value
        await runtime.disconnect()
    }
    func testAdmissionIntentAndAcknowledgmentArePersistedBeforeTerminalResult() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        await runtime.setIntegrity(false)
        let phases = PhaseLog()
        let work = Task { try await runtime.submitAutomatic(manifest: "synthetic", images: [], phaseChanged: { await phases.append($0) }) }
        await gateway.waitForSubmission(count: 1)
        _ = await TestTiming.eventually { await phases.values.count >= 2 }
        let recorded = await phases.values
        XCTAssertEqual(recorded, [.submitting, .admitted])
        await gateway.emit(type: "message.complete")
        try await work.value
    }

    func testDefaultCancelTargetsQueuedManualNotAutomaticCurrent() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        await runtime.setIntegrity(false)
        let automatic = Task { try await runtime.submitAutomatic(manifest: "automatic", images: []) }
        await gateway.waitForSubmission(count: 1)
        let manual = Task { try await runtime.submitManual("queued") }
        try await Task.sleep(for: .milliseconds(20))
        try await runtime.cancel()
        let cancellations = await gateway.cancelCount()
        XCTAssertEqual(cancellations, 0)
        await gateway.emit(type: "message.complete")
        try await automatic.value
        try await Task.sleep(for: .milliseconds(20))
        let submissions = await gateway.submissionCount()
        XCTAssertEqual(submissions, 1)
        await gateway.emit(type: "message.complete")
        await XCTAssertThrowsErrorAsync(try await manual.value)
    }

    func testQueuedManualCancellationDoesNotInterruptAutomaticOrSubmitLater() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        await runtime.setIntegrity(false)
        let automatic = Task { try await runtime.submitAutomatic(manifest: "automatic", images: []) }
        await gateway.waitForSubmission(count: 1)
        let id = UUID()
        let manual = Task { try await runtime.submitManual("queued", turnID: id) }
        try await Task.sleep(for: .milliseconds(20))
        try await runtime.cancelManual(turnID: id)
        await XCTAssertThrowsErrorAsync(try await manual.value)
        let cancels = await gateway.cancelCount()
        XCTAssertEqual(cancels, 0)
        await gateway.emit(type: "message.complete")
        try await automatic.value
        try await Task.sleep(for: .milliseconds(20))
        let submits = await gateway.submissionCount()
        XCTAssertEqual(submits, 1)
    }

    func testManualCancellationBeforeAdmissionRejectsTheExactTurn() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        let id = UUID()
        try await runtime.cancelManual(turnID: id)
        await XCTAssertThrowsErrorAsync(try await runtime.submitManual("too late", turnID: id))
        let submits = await gateway.submissionCount()
        XCTAssertEqual(submits, 0)
    }

    func testDoesNotDrainNextJobUntilTerminalCompletion() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        let first = Task { try await runtime.submitManual("first") }
        await gateway.waitForSubmission(count: 1)
        let second = Task { try await runtime.submitManual("second") }
        try await Task.sleep(for: .milliseconds(40))
        let submitted = await gateway.submissionCount()
        XCTAssertEqual(submitted, 1)
        await gateway.emit(type: "message.complete")
        try await first.value
        await gateway.waitForSubmission(count: 2)
        await gateway.emit(type: "message.complete")
        try await second.value
    }

    func testFailedAndCancelledTerminalEventsFailTheTurn() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        let failed = Task { try await runtime.submitManual("fails") }
        await gateway.waitForSubmission(count: 1)
        await gateway.emit(type: "message.failed")
        await XCTAssertThrowsErrorAsync(try await failed.value)
        let cancelled = Task { try await runtime.submitManual("cancelled") }
        await gateway.waitForSubmission(count: 2)
        await gateway.emit(type: "message.cancelled")
        await XCTAssertThrowsErrorAsync(try await cancelled.value)
    }

    func testIntegrityPauseDropsQueuedAutomaticWorkAndRejectsActiveAutomaticTurn() async throws {
        let gateway = FakeGateway()
        let runtime = HermesSessionRuntime(gateway: gateway, records: MemoryRecords())
        try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        await runtime.setIntegrity(false)
        let batch = Task { try await runtime.submitAutomatic(manifest: "batch", images: []) }
        await gateway.waitForSubmission(count: 1)
        await runtime.setIntegrity(true)
        await gateway.emit(type: "message.complete")
        await XCTAssertThrowsErrorAsync(try await batch.value)
        let cancels = await gateway.cancelCount()
        XCTAssertEqual(cancels, 1)
    }
}

private actor PhaseLog {
    var values: [EvidenceStore.BatchState] = []
    func append(_ state: EvidenceStore.BatchState) { values.append(state) }
}

private actor FakeGateway: HermesGatewayTransport {
    private let pair = AsyncStream<HermesGatewayEvent>.makeStream()
    private var submits = 0
    private var cancels = 0

    func start(launch: HermesGatewayLaunch) async throws {}
    func events() async -> AsyncStream<HermesGatewayEvent> { pair.stream }
    func gatewayCapabilities() async throws -> HermesGatewayCapabilities { .init(perSessionExclusiveSubmit: true) }
    func open(storedSessionID: String?) async throws -> HermesSessionIdentity { .init(storedID: "stored", runtimeID: "runtime") }
    func models(sessionID: String) async throws -> Data { Data("{\"providers\":[]}".utf8) }
    func switchModel(sessionID: String, model: String, provider: String) async throws -> Data { Data() }
    func compress(sessionID: String) async throws -> Data { Data() }
    private var hard = 0, keep = 0
    private(set) var log: [String] = []
    func compactHard(sessionID: String, keepLast: Int) async throws -> Data { hard += 1; keep = keepLast; log.append("compact"); return Data() }
    func hardCompactions() -> Int { hard }
    private var receiptStatus = "missing", receiptVerified = false
    func setReceipt(status: String, verified: Bool) { receiptStatus = status; receiptVerified = verified }
    func prepareBatch(sessionID: String, batchID: String, sourceIDs: [String]) async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["prepared": true, "batch_id": batchID, "session_id": sessionID, "source_ids": sourceIDs])
    }
    func batchReceipt(sessionID: String, batchID: String, sourceIDs: [String]) async throws -> Data {
        try JSONSerialization.data(withJSONObject: ["batch_id": batchID, "session_id": sessionID, "source_ids": sourceIDs, "status": receiptStatus, "verified": receiptVerified, "effects": []])
    }
    func lastKeep() -> Int { keep }
    private var contexts = 0
    private var manualSubmits = 0
    private var contextFailure = false
    func failManualContext() { contextFailure = true }
    func contextCount() -> Int { contexts }
    func manualContext(sessionID: String) async throws { if contextFailure { throw HermesGatewayError.protocolFailure }; contexts += 1 }
    func submit(sessionID: String, text: String) async throws -> Data { XCTAssertEqual(contexts, manualSubmits + 1); manualSubmits += 1; submits += 1; log.append("submit"); return Data() }
    func submitBatch(sessionID: String, text: String, images: [HermesEvidenceAttachment], transmissionAllowed: @escaping @Sendable () async -> Bool) async throws { guard await transmissionAllowed() else { throw HermesGatewayError.cancelled }; submits += 1; return }
    func cancel(sessionID: String) async throws -> Data { cancels += 1; return Data() }
    func stop() async {}
    func submissionCount() -> Int { submits }
    func cancelCount() -> Int { cancels }
    func emit(type: String, payload: String = "{\"payload\":{}}") { pair.continuation.yield(.init(type: type, payload: Data(payload.utf8))) }
    func waitForSubmission(count: Int) async { while submits < count { await Task.yield() } }
}

private final class MemoryRecords: HermesSessionRecordStore, @unchecked Sendable {
    private var record: HermesSessionRecord?
    func load() -> HermesSessionRecord? { record }
    func save(_ record: HermesSessionRecord) { self.record = record }
}

private func XCTAssertThrowsErrorAsync<T>(_ expression: @autoclosure () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async {
    do { _ = try await expression(); XCTFail("Expected an error", file: file, line: line) } catch {}
}
