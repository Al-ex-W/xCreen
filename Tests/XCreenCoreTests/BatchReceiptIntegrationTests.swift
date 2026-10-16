import XCTest
@testable import XCreenCore

final class BatchReceiptIntegrationTests: XCTestCase {
    func testInstalledHermesPrepareManualContextReceiptHistoryStdio() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let hermes = env["XCREEN_HERMES_ROOT"], let python = env["XCREEN_HERMES_PYTHON"] else {
            throw XCTSkip("Set XCREEN_HERMES_ROOT and XCREEN_HERMES_PYTHON for installed no-inference stdio integration")
        }
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scratch = URL(fileURLWithPath: env["TMPDIR"] ?? NSHomeDirectory() + "/.hermes/cache/scratch")
        let root = scratch.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let gateway = HermesGateway(defaultDeadline: 10)
        try await gateway.start(launch: .command(executable: python, arguments: [project.appendingPathComponent("runtime/tests/stdio_contract_fixture.py").path, hermes, project.path, root.path]))
        let prepared = try await gateway.prepareBatch(sessionID: "synthetic-runtime", batchID: "batch-a", sourceIDs: ["ocr-a"])
        XCTAssertTrue(String(decoding: prepared, as: UTF8.self).contains("prepared"))
        try await gateway.manualContext(sessionID: "synthetic-runtime")
        let bytes = try await gateway.batchReceipt(sessionID: "synthetic-runtime", batchID: "batch-a", sourceIDs: ["ocr-a"])
        let receipt = try BatchReceipt(data: bytes, batchID: "batch-a", sourceIDs: ["ocr-a"], sessionID: "synthetic-runtime")
        XCTAssertTrue(receipt.completesProcessing)
        var cursor: String?; var count = 0
        repeat {
            let data = try await gateway.historyPage(sessionID: "synthetic-runtime", cursor: cursor)
            XCTAssertLessThanOrEqual(data.count, 48_000)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            count += try XCTUnwrap(object["messages"] as? [[String: Any]]).count
            cursor = object["next_cursor"] as? String
        } while cursor != nil
        XCTAssertEqual(count, 90)
        await gateway.stop()
    }
    private func fixture() throws -> (URL, EvidenceStore, CaptureBatch) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = try EvidenceStore(root: root)
        let now = Date()
        let batch = CaptureBatch(id: "batch-test", images: [], startedAt: now, completedAt: now, ocr: [OCREvidence(id: "ocr-test", timestamp: now, text: "synthetic-private-raw", app: "synthetic", title: "")])
        return (root, store, batch)
    }
    func testSavedAndSkippedRequireVerifiedReceiptsAfterTerminal() async throws {
        for status in ["saved", "skipped", "missing"] {
            let (root, store, batch) = try fixture()
            defer { try? FileManager.default.removeItem(at: root) }
            try await store.savePendingBatch(batch)
            let gateway = ReceiptGateway(status: status)
            let runtime = HermesSessionRuntime(gateway: gateway, records: ReceiptRecords())
            try await runtime.connect(launch: .command(executable: "/usr/bin/true", arguments: []))
            await runtime.setIntegrity(false)
            let task = Task {
                try await runtime.submitAutomatic(manifest: "synthetic batch", images: [], binding: .init(batchID: batch.id, sourceIDs: ["ocr-test"]), prepared: { session in
                    try await store.bindBatch(id: batch.id, sessionID: session)
                }, receiptChanged: { receipt in try await store.reconcile(receipt) }, phaseChanged: { phase in try await store.transitionBatch(id: batch.id, to: phase) })
            }
            try await gateway.waitForSubmission()
            let before = await store.batchPage()
            XCTAssertEqual(before.first?.state, .admitted)
            await gateway.terminal()
            do { try await task.value; XCTAssertNotEqual(status, "missing") }
            catch { XCTAssertEqual(status, "missing") }
            let rows = await store.batchPage()
            XCTAssertEqual(rows.first?.state, status == "missing" ? .uncertain : .completed)
            let calls = await gateway.calls
            XCTAssertEqual(calls, ["prepare", "submit", "receipt"])
            await runtime.disconnect()
        }
    }
    @MainActor func testInterruptedStartupReconciliationAfterRawExpiryNeverResends() async throws {
        let (root, store, batch) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try await store.savePendingBatch(batch)
        try await store.transitionBatch(id: batch.id, to: .submitting)
        try await store.bindBatch(id: batch.id, sessionID: "runtime")
        try await store.transitionBatch(id: batch.id, to: .admitted)
        try await store.cleanup(now: Date().addingTimeInterval(8 * 86_400))
        let reopened = try EvidenceStore(root: root)
        let rows = await reopened.batchPage()
        XCTAssertEqual(rows.first?.state, .uncertain)
        let json = try String(contentsOf: root.appendingPathComponent("index.json"), encoding: .utf8)
        XCTAssertFalse(json.contains("synthetic-private-raw"))
        let gateway = ReceiptGateway(status: "saved", runtimeID: "new-runtime-after-crash")
        let controller = SharedSessionController(gateway: gateway, records: ReceiptRecords())
        let first = try await controller.verifyBatches(launch: .command(executable: "/usr/bin/true", arguments: []), store: reopened)
        let second = try await controller.verifyBatches(launch: .command(executable: "/usr/bin/true", arguments: []), store: reopened)
        XCTAssertEqual(first, 1); XCTAssertEqual(second, 1)
        let pending = try await reopened.pendingBatches()
        XCTAssertTrue(pending.isEmpty)
        let calls = await gateway.calls
        XCTAssertEqual(calls, ["receipt", "receipt"])
        let sessions = await gateway.receiptSessions
        XCTAssertEqual(sessions, ["runtime", "runtime"])
        await controller.disconnect()
    }
    @MainActor func testHistoryUsesOnlyHostPagedRPCAndPreservesCursor() async throws {
        let gateway = ReceiptGateway(status: "skipped")
        let controller = SharedSessionController(gateway: gateway, records: ReceiptRecords())
        let launch = HermesGatewayLaunch.command(executable: "/usr/bin/true", arguments: [])
        let first = try await controller.historyPage(launch: launch)
        let second = try await controller.historyPage(launch: launch, cursor: "stable-cursor")
        XCTAssertLessThan(first.count, 48_001); XCTAssertLessThan(second.count, 48_001)
        let cursors = await gateway.cursors
        XCTAssertEqual(cursors, ["root", "stable-cursor"])
        await controller.disconnect()
    }
    func testRejectsBindingMismatchAndInvalidSkipEffects() throws {
        let valid: [String: Any] = ["batch_id": "batch-test", "source_ids": ["ocr-test"], "session_id": "runtime", "status": "skipped", "verified": true, "effects": []]
        let bytes = try JSONSerialization.data(withJSONObject: valid)
        XCTAssertThrowsError(try BatchReceipt(data: bytes, batchID: "other", sourceIDs: ["ocr-test"], sessionID: "runtime"))
        var bad = valid; bad["effects"] = [["entry_id": "unexpected"]]
        XCTAssertThrowsError(try BatchReceipt(data: JSONSerialization.data(withJSONObject: bad), batchID: "batch-test", sourceIDs: ["ocr-test"], sessionID: "runtime"))
    }
    func testActualGatewayFramesPageMultiMiBHistoryBeforeStdout() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("gateway.py")
        let runtimePath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("runtime").path
        let source = #"""
        import sys,json
        sys.path.insert(0,sys.argv[1])
        from xcreen_rpc import HistoryPager
        pager=HistoryPager()
        history=[{'role':'assistant','content':'x'*12000,'id':str(i)} for i in range(280)]
        assert len(json.dumps(history)) > 1048576
        print(json.dumps({'method':'event','params':{'type':'gateway.ready'}}),flush=True)
        for line in sys.stdin:
            r=json.loads(line); m=r['method']; p=r.get('params',{})
            if m == 'client.capabilities': result={}
            elif m == 'xcreen.history.page': result=pager.page(p['session_id'], history, cursor=p.get('cursor'), max_bytes=p['max_bytes'],limit=p['limit'])
            else: raise AssertionError('unexpected full-history or inference RPC: '+m)
            frame=json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result})
            assert len(frame.encode()) < 49000
            print(frame,flush=True)
        """#
        try source.write(to: script, atomically: true, encoding: .utf8)
        let gateway = HermesGateway(defaultDeadline: 2)
        try await gateway.start(launch: .command(executable: "/usr/bin/python3", arguments: [script.path, runtimePath]))
        var cursor: String?; var ids: [String] = []
        repeat {
            let data = try await gateway.historyPage(sessionID: "synthetic", cursor: cursor)
            XCTAssertLessThanOrEqual(data.count, 48_000)
            let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
            ids += messages.compactMap { $0["id"] as? String }
            cursor = object["next_cursor"] as? String
        } while cursor != nil
        XCTAssertEqual(ids, (0..<280).map(String.init))
        await gateway.stop()
    }
}

private final class ReceiptRecords: HermesSessionRecordStore, @unchecked Sendable {
    func load() -> HermesSessionRecord? { nil }
    func save(_ record: HermesSessionRecord) {}
}
private actor ReceiptGateway: HermesGatewayTransport {
    let status: String
    let runtimeID: String
    var calls: [String] = []
    var receiptSessions: [String] = []
    var cursors: [String] = []
    var submitted = false
    let pair = AsyncStream<HermesGatewayEvent>.makeStream()
    init(status: String, runtimeID: String = "runtime") { self.status = status; self.runtimeID = runtimeID }
    func start(launch: HermesGatewayLaunch) async throws {}
    func events() -> AsyncStream<HermesGatewayEvent> { pair.stream }
    func gatewayCapabilities() async throws -> HermesGatewayCapabilities { .init(perSessionExclusiveSubmit: true) }
    func open(storedSessionID: String?) async throws -> HermesSessionIdentity { .init(storedID: "stored", runtimeID: runtimeID) }
    func models(sessionID: String) async throws -> Data { Data("{\"providers\":[]}".utf8) }
    func switchModel(sessionID: String, model: String, provider: String) async throws -> Data { Data() }
    func compress(sessionID: String) async throws -> Data { Data() }
    func submit(sessionID: String, text: String) async throws -> Data { XCTFail("not a manual test"); return Data() }
    func history(sessionID: String) async throws -> Data { XCTFail("full history must never be read"); throw HermesGatewayError.protocolFailure }
    func historyPage(sessionID: String, cursor: String?) async throws -> Data {
        cursors.append(cursor ?? "root")
        return Data("{\"messages\":[],\"next_cursor\":null}".utf8)
    }
    func prepareBatch(sessionID: String, batchID: String, sourceIDs: [String]) async throws -> Data {
        calls.append("prepare")
        return try JSONSerialization.data(withJSONObject: ["batch_id": batchID, "source_ids": sourceIDs, "session_id": sessionID, "prepared": true])
    }
    func batchReceipt(sessionID: String, batchID: String, sourceIDs: [String]) async throws -> Data {
        calls.append("receipt")
        receiptSessions.append(sessionID)
        return try JSONSerialization.data(withJSONObject: ["batch_id": batchID, "source_ids": sourceIDs, "session_id": sessionID, "status": status, "verified": status != "missing", "effects": status == "saved" ? [["entry_id": "effect-test", "state": "completed"]] : []])
    }
    func submitBatch(sessionID: String, text: String, images: [HermesEvidenceAttachment], transmissionAllowed: @escaping @Sendable () async -> Bool) async throws {
        guard await transmissionAllowed() else { throw HermesGatewayError.cancelled }
        calls.append("submit"); submitted = true
    }
    func cancel(sessionID: String) async throws -> Data { Data() }
    func stop() {}
    func terminal() { pair.continuation.yield(.init(type: "message.complete", payload: Data("{}".utf8))) }
    func waitForSubmission() async throws {
        for _ in 0..<1000 { if submitted { try await Task.sleep(for: .milliseconds(2)); return }; try await Task.sleep(for: .milliseconds(1)) }
        throw HermesGatewayError.deadlineExceeded
    }
}
