import XCTest
@testable import XCreenCore

final class HermesSessionRuntimeSafetyTests: XCTestCase {
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
    func submit(sessionID: String, text: String) async throws -> Data { submits += 1; return Data() }
    func submitBatch(sessionID: String, text: String, images: [HermesEvidenceAttachment], transmissionAllowed: @escaping @Sendable () async -> Bool) async throws { guard await transmissionAllowed() else { throw HermesGatewayError.cancelled }; submits += 1; return }
    func cancel(sessionID: String) async throws -> Data { cancels += 1; return Data() }
    func stop() async {}
    func submissionCount() -> Int { submits }
    func cancelCount() -> Int { cancels }
    func emit(type: String) { pair.continuation.yield(.init(type: type, payload: Data("{\"payload\":{}}".utf8))) }
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
