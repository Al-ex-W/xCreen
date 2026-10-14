import XCTest
@testable import XCreenCore

@MainActor final class SharedSessionControllerTests: XCTestCase {
    func testOldAutomaticTransmissionClosureCannotAuthorizeReplacementTurn() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        let launch = HermesGatewayLaunch.command(executable: "/usr/bin/true", arguments: [])
        try await controller.connect(launch: launch)
        await controller.setIntegrity(false).value
        let first = Task { try await controller.runtime.submitAutomatic(manifest: "first", images: []) }
        await gateway.waitForSubmits(1)
        await controller.disconnect()
        try await controller.connect(launch: launch)
        let second = Task { try await controller.runtime.submitAutomatic(manifest: "second", images: []) }
        await gateway.waitForSubmits(2)
        let oldAllowed = await gateway.transmissionAllowed(at: 0)
        let newAllowed = await gateway.transmissionAllowed(at: 1)
        XCTAssertFalse(oldAllowed)
        XCTAssertTrue(newAllowed)
        do { try await first.value; XCTFail("old automatic turn survived") } catch {}
        await gateway.emit("message.complete")
        try await second.value
    }
    func testCancellationWhileCompactingDoesNotSubmitOrInterruptUnsubmittedManual() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        let launch = HermesGatewayLaunch.command(executable: "/usr/bin/true", arguments: [])
        try await controller.connect(launch: launch)
        await controller.runtime.updateContextUsage(tokens: 500_000, limit: nil)
        await gateway.holdNextCompression()
        let question = try controller.admitManual("manual", launch: launch)
        await gateway.waitForCompression()
        try await controller.cancelManual()
        await gateway.releaseCompression()
        do { _ = try await question.value; XCTFail("cancelled compacting question submitted") } catch {}
        let submissions = await gateway.submitCount
        let cancellations = await gateway.cancelCount
        XCTAssertEqual(submissions, 0)
        XCTAssertEqual(cancellations, 0)
    }

    func testCancellationInterruptsOnlySubmittedManualAndReturnsFailure() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        let question = try controller.admitManual("manual", launch: .command(executable: "/usr/bin/true", arguments: []))
        await gateway.waitForSubmits(1)
        try await controller.cancelManual()
        await gateway.emit("message.complete", text: "late answer")
        do { _ = try await question.value; XCTFail("cancelled turn returned success") } catch {}
        let cancellations = await gateway.cancelCount
        XCTAssertEqual(cancellations, 1)
    }

    func testAwaitedResultCollectsAllDeltasBeforeEmptyTerminalEvent() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        let question = try controller.admitManual("manual", launch: .command(executable: "/usr/bin/true", arguments: []))
        await gateway.waitForSubmits(1)
        await gateway.emit("message.delta", text: "one ")
        await gateway.emit("message.delta", text: "two")
        await gateway.emit("message.complete")
        let result = try await question.value
        XCTAssertEqual(result, "one two")
    }
    func testAsyncSettingsPreparationIsInsideLifecycleTransaction() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        var preparing = false
        var release: CheckedContinuation<Void, Never>?
        var writes: [String] = []
        let detect = Task {
            try await controller.configure(prepare: {
                preparing = true
                await withCheckedContinuation { release = $0 }
                return (.command(executable: "/usr/bin/true", arguments: ["detected"]), { writes.append("detected") })
            })
        }
        while !preparing { await Task.yield() }
        let explicit = Task { try await controller.configure(launch: .command(executable: "/usr/bin/true", arguments: ["explicit"])) { writes.append("explicit") } }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(writes, [])
        release?.resume()
        try await detect.value; try await explicit.value
        XCTAssertEqual(writes, ["detected", "explicit"])
        let operations = await gateway.operations
        XCTAssertEqual(operations.last, "start:explicit")
    }

    func testRapidIntegrityDropsQueuedAutomaticButLeavesManualCurrent() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        let launch = HermesGatewayLaunch.command(executable: "/usr/bin/true", arguments: [])
        let question = try controller.admitManual("manual", launch: launch)
        await gateway.waitForSubmits(1)
        await controller.setIntegrity(false).value
        let batch = Task { try await controller.runtime.submitAutomatic(manifest: "queued automatic", images: []) }
        try await Task.sleep(for: .milliseconds(20))
        let on = controller.setIntegrity(true)
        let off = controller.setIntegrity(false)
        await on.value; await off.value
        do { try await batch.value; XCTFail("queued automatic survived") } catch {}
        await gateway.emit("message.complete", text: "manual answer")
        let result = try await question.value
        XCTAssertEqual(result, "manual answer")
        let cancels = await gateway.cancelCount
        XCTAssertEqual(cancels, 0)
        let submissions = await gateway.submitCount
        XCTAssertEqual(submissions, 1)
    }
    func testModelReadAndUIApplyCannotStraddleDisconnect() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        let launch = HermesGatewayLaunch.command(executable: "/usr/bin/true", arguments: [])
        try await controller.connect(launch: launch)
        await gateway.holdNextModels()
        var appliedWhileConnected = false
        let models = Task { try await controller.readModelOptions(launch: launch) { _ in appliedWhileConnected = controller.connected } }
        await gateway.waitForModels()
        let disconnect = Task { await controller.disconnect() }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(controller.connected)
        await gateway.releaseModels()
        try await models.value; await disconnect.value
        XCTAssertTrue(appliedWhileConnected)
        XCTAssertFalse(controller.connected)
    }
    func testConfigurationFailureIsReportedAfterPersistenceAndNextOperationRecovers() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        await gateway.failNextStart()
        var persisted = false
        do {
            try await controller.configure(launch: .command(executable: "/usr/bin/true", arguments: ["failed"])) { persisted = true }
            XCTFail("reconnect failure suppressed")
        } catch { XCTAssertEqual(error as? HermesGatewayError, .invalidLaunch) }
        XCTAssertTrue(persisted)
        XCTAssertFalse(controller.connected)
        try await controller.connect(launch: .command(executable: "/usr/bin/true", arguments: ["old-draft"]))
        XCTAssertTrue(controller.connected)
        let operations = await gateway.operations
        XCTAssertEqual(operations.last, "start:failed", "retry must use committed settings, not an old UI draft")
    }

    func testGatewayEOFWhileInventoryAwaitsCannotPublishStaleConnected() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        await gateway.holdNextModels()
        let connect = Task { try await controller.connect(launch: .command(executable: "/usr/bin/true", arguments: [])) }
        await gateway.waitForModels()
        await gateway.finishStreams()
        try await Task.sleep(for: .milliseconds(20))
        await gateway.releaseModels()
        do { try await connect.value; XCTFail("stopped gateway connected") } catch {}
        XCTAssertFalse(controller.connected)
    }

    func testDisconnectInvalidatesAdmittedQuestionInsteadOfMovingItToNewSession() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        let launch = HermesGatewayLaunch.command(executable: "/usr/bin/true", arguments: [])
        try await controller.connect(launch: launch)
        let question = try controller.admitManual("synthetic", launch: launch)
        await gateway.waitForSubmits(1)
        await controller.disconnect()
        try await controller.connect(launch: launch)
        do { _ = try await question.value; XCTFail("old turn succeeded") } catch {}
        XCTAssertTrue(controller.connected)
        let submissions = await gateway.submitCount
        XCTAssertEqual(submissions, 1)
    }
    func testAwaitedManualResultUsesTerminalOutputNotIndependentUIObserver() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        var uiOutput = "unrelated automatic output"
        controller.eventReceived = { _ in uiOutput = "deliberately not synchronized" }
        let answer = try controller.admitManual("question", launch: .command(executable: "/usr/bin/true", arguments: []))
        await gateway.waitForSubmits(1)
        await gateway.emit("message.delta", text: "partial ")
        await gateway.emit("message.complete", text: "complete answer")
        let result = try await answer.value
        XCTAssertEqual(result, "complete answer")
        XCTAssertNotEqual(result, uiOutput)
    }

    func testControllerCancelBeforeSubmissionTaskAdmission() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        await gateway.holdNextStart()
        let question = try controller.admitManual("cancel before admission", launch: .command(executable: "/usr/bin/true", arguments: []))
        await gateway.waitForStarts(1)
        try await controller.cancelManual()
        await gateway.releaseStart()
        do { _ = try await question.value; XCTFail("cancelled question admitted") } catch {}
        let submitted = await gateway.submitCount
        XCTAssertEqual(submitted, 0)
    }

    func testControllerCancelQueuedQuestionDoesNotInterruptAutomatic() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        let launch = HermesGatewayLaunch.command(executable: "/usr/bin/true", arguments: [])
        try await controller.connect(launch: launch)
        await controller.setIntegrity(false).value
        let automatic = Task { try await controller.runtime.submitAutomatic(manifest: "automatic", images: []) }
        await gateway.waitForSubmits(1)
        let question = try controller.admitManual("queued", launch: launch)
        try await Task.sleep(for: .milliseconds(20))
        try await controller.cancelManual()
        do { _ = try await question.value; XCTFail("queued question not cancelled") } catch {}
        let cancellations = await gateway.cancelCount
        XCTAssertEqual(cancellations, 0)
        await gateway.emit("message.complete")
        try await automatic.value
        let submissions = await gateway.submitCount
        XCTAssertEqual(submissions, 1)
    }
    func testDisconnectCannotOvertakeSuspendedConnectAndOldObserverCannotDisconnectReplacement() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        await gateway.holdNextStart()
        let first = Task { try await controller.connect(launch: .command(executable: "/usr/bin/true", arguments: ["first"])) }
        await gateway.waitForStarts(1)
        let disconnect = Task { await controller.disconnect() }
        await Task.yield()
        let reconnect = Task { try await controller.connect(launch: .command(executable: "/usr/bin/true", arguments: ["second"])) }
        try await Task.sleep(for: .milliseconds(20))
        let before = await gateway.operations
        XCTAssertEqual(before, ["start:first"])
        await gateway.releaseStart()
        try await first.value; await disconnect.value; try await reconnect.value
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(controller.connected)
        let after = await gateway.operations
        XCTAssertEqual(after, ["start:first", "stop", "start:second"])
    }

    func testOverlappingConfigurationChangesFreezeLaunchAndPersistInOrder() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        await gateway.holdNextStart()
        var persisted: [String] = []
        let a = Task { try await controller.configure(launch: .command(executable: "/usr/bin/true", arguments: ["A"])) { persisted.append("A") } }
        await gateway.waitForStarts(1)
        let b = Task { try await controller.configure(launch: .command(executable: "/usr/bin/true", arguments: ["B"])) { persisted.append("B") } }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(persisted, ["A"])
        await gateway.releaseStart()
        try await a.value; try await b.value
        XCTAssertEqual(persisted, ["A", "B"])
        let operations = await gateway.operations
        XCTAssertEqual(operations, ["stop", "start:A", "stop", "start:B"])
        XCTAssertTrue(controller.connected)
    }
    func testRapidIntegrityTransitionsInvalidateAutomaticTurnEvenAfterOff() async throws {
        let gateway = ControlledGateway()
        let controller = SharedSessionController(gateway: gateway, records: ControllerRecords())
        try await controller.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
        await controller.setIntegrity(false).value
        let batch = Task { try await controller.runtime.submitAutomatic(manifest: "synthetic", images: []) }
        await gateway.waitForSubmits(1)
        let on = controller.setIntegrity(true)
        let off = controller.setIntegrity(false)
        await on.value; await off.value
        await gateway.emit("message.complete")
        do { try await batch.value; XCTFail("old epoch completed") } catch {}
        let count = await gateway.cancelCount
        XCTAssertEqual(count, 1)
    }
}

private actor ControlledGateway: HermesGatewayTransport {
    private var streams: [AsyncStream<HermesGatewayEvent>.Continuation] = []
    var submitCount = 0
    var cancelCount = 0
    private var transmissions: [@Sendable () async -> Bool] = []
    func transmissionAllowed(at index: Int) async -> Bool { await transmissions[index]() }
    var operations: [String] = []
    private var held = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    private var failStart = false
    private var holdModels = false
    private var modelWaiter: CheckedContinuation<Void, Never>?
    private var holdCompression = false
    private var compressionWaiter: CheckedContinuation<Void, Never>?
    func holdNextCompression() { holdCompression = true }
    func waitForCompression() async { while compressionWaiter == nil { await Task.yield() } }
    func releaseCompression() { compressionWaiter?.resume(); compressionWaiter = nil }
    func failNextStart() { failStart = true }
    func holdNextModels() { holdModels = true }
    func waitForModels() async { while modelWaiter == nil { await Task.yield() } }
    func releaseModels() { modelWaiter?.resume(); modelWaiter = nil }
    func finishStreams() { streams.forEach { $0.finish() }; streams.removeAll() }
    func holdNextStart() { held = true }
    func releaseStart() { startWaiter?.resume(); startWaiter = nil }
    func waitForStarts(_ count: Int) async { while operations.filter({ $0.hasPrefix("start:") }).count < count { await Task.yield() } }
    func start(launch: HermesGatewayLaunch) async throws {
        if case .command(_, let args, _) = launch { operations.append("start:" + (args.first ?? "")) }
        if failStart { failStart = false; throw HermesGatewayError.invalidLaunch }
        if held { held = false; await withCheckedContinuation { startWaiter = $0 } }
    }
    func stop() async { operations.append("stop"); streams.forEach { $0.finish() }; streams.removeAll() }
    func events() async -> AsyncStream<HermesGatewayEvent> { let pair = AsyncStream<HermesGatewayEvent>.makeStream(); streams.append(pair.continuation); return pair.stream }
    func gatewayCapabilities() async throws -> HermesGatewayCapabilities { .init(perSessionExclusiveSubmit: true) }
    func open(storedSessionID: String?) async throws -> HermesSessionIdentity { .init(storedID: "synthetic", runtimeID: "synthetic-runtime") }
    func models(sessionID: String) async throws -> Data { if holdModels { holdModels = false; await withCheckedContinuation { modelWaiter = $0 } }; return Data("{\"providers\":[]}".utf8) }
    func switchModel(sessionID: String, model: String, provider: String) async throws -> Data { Data() }
    func compress(sessionID: String) async throws -> Data { if holdCompression { holdCompression = false; await withCheckedContinuation { compressionWaiter = $0 } }; return Data() }
    func submit(sessionID: String, text: String) async throws -> Data { submitCount += 1; return Data() }
    func submitBatch(sessionID: String, text: String, images: [HermesEvidenceAttachment], transmissionAllowed: @escaping @Sendable () async -> Bool) async throws { transmissions.append(transmissionAllowed); guard await transmissionAllowed() else { throw HermesGatewayError.cancelled }; submitCount += 1 }
    func cancel(sessionID: String) async throws -> Data { cancelCount += 1; return Data() }
    func emit(_ type: String, text: String = "") { let event = HermesGatewayEvent(type: type, payload: try! JSONSerialization.data(withJSONObject: ["payload": ["text": text]])); streams.forEach { $0.yield(event) } }
    func waitForSubmits(_ count: Int) async { while submitCount < count { await Task.yield() } }
}
private final class ControllerRecords: HermesSessionRecordStore, @unchecked Sendable {
    func load() -> HermesSessionRecord? { nil }
    func save(_ record: HermesSessionRecord) {}
}
