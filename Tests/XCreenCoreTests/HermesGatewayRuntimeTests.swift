import XCTest
@testable import XCreenCore

final class HermesGatewayRuntimeTests: XCTestCase {
    func testVisibilityRPCUsesExplicitBooleanAndSameActiveSession() async throws {
        let script = try makeGatewayScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent().deletingLastPathComponent()) }
        let gateway = HermesGateway(defaultDeadline: 1)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        let hidden = try await gateway.setHidden(sessionID: "runtime-xcreen", hidden: true)
        let shown = try await gateway.setHidden(sessionID: "runtime-xcreen", hidden: false)
        XCTAssertTrue(hidden)
        XCTAssertFalse(shown)
        await gateway.stop()
    }
    func testOldProcessExitCannotDisconnectReplacement() async throws {
        let script = try makeGatewayScript(terminationDelay: 0.3)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent().deletingLastPathComponent()) }
        let gateway = HermesGateway(defaultDeadline: 1)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        await gateway.stop()
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        try await Task.sleep(for: .milliseconds(500))
        _ = try await gateway.history(sessionID: "runtime-xcreen")
        await gateway.stop()
    }
    func testReadsDurableHistoryFromExactRuntimeSession() async throws {
        let script = try makeGatewayScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent().deletingLastPathComponent()) }
        let gateway = HermesGateway(defaultDeadline: 1)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        let data = try await gateway.history(sessionID: "runtime-xcreen")
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(value?["count"] as? Int, 1)
        await gateway.stop()
    }
    func testGatewayStartsRawPythonEntryAndPerformsReadinessHandshake() async throws {
        let script = try makeGatewayScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent().deletingLastPathComponent()) }
        let gateway = HermesGateway(defaultDeadline: 1)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        let identity = try await gateway.open(storedSessionID: "stored-xcreen")
        XCTAssertEqual(identity.storedID, "stored-xcreen")
        XCTAssertEqual(identity.runtimeID, "runtime-xcreen")
        let capabilities = try await gateway.gatewayCapabilities()
        XCTAssertTrue(capabilities.perSessionExclusiveSubmit)
        await gateway.stop()
    }

    /// A long session's resume transcript exceeds the 1 MiB frame cap; xCreen must not request it.
    func testResumeOmitsTranscriptSoLongSessionsStillConnect() async throws {
        let script = try makeGatewayScript(resumeResult: #"{"session_id":"eb085cde","resumed":"stored-xcreen","message_count":219}"#)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent().deletingLastPathComponent()) }
        let gateway = HermesGateway(defaultDeadline: 2)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        let identity = try await gateway.open(storedSessionID: "stored-xcreen")
        XCTAssertEqual(identity.runtimeID, "eb085cde")
        await gateway.stop()
    }

    /// The session-scoped switch must use config.set (works without a live agent) and verify its ack.
    func testSwitchModelUsesConfigSetAndVerifiesSessionScope() async throws {
        let script = try makeGatewayScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent().deletingLastPathComponent()) }
        let gateway = HermesGateway(defaultDeadline: 2)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        let session = try await gateway.open(storedSessionID: "stored-xcreen")
        _ = try await gateway.switchModel(sessionID: session.runtimeID, model: "anthropic/claude-haiku-5.5", provider: "openrouter")
        do {
            _ = try await gateway.switchModel(sessionID: session.runtimeID, model: "unknown/model", provider: "openrouter")
            XCTFail("rejected switch must throw")
        } catch {}
        await gateway.stop()
    }

    /// Real `session.resume` (tui_gateway/methods_session.py) reports the stored id as `resumed`.
    func testResumeAcceptsRealResumedKey() async throws {
        let script = try makeGatewayScript(resumeResult: #"{"session_id":"eb085cde","resumed":"stored-xcreen","message_count":15}"#)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent().deletingLastPathComponent()) }
        let gateway = HermesGateway(defaultDeadline: 1)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        let identity = try await gateway.open(storedSessionID: "stored-xcreen")
        XCTAssertEqual(identity.storedID, "stored-xcreen")
        XCTAssertEqual(identity.runtimeID, "eb085cde")
        await gateway.stop()
    }

    func testEverySubscriberReceivesGatewayEvents() async throws {
        let script = try makeGatewayScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent().deletingLastPathComponent()) }
        let gateway = HermesGateway(defaultDeadline: 1)
        let first = await gateway.events()
        let second = await gateway.events()
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        _ = try await gateway.open(storedSessionID: "stored-xcreen")
        await gateway.stop()
        var firstTypes: [String] = [], secondTypes: [String] = []
        for await event in first { firstTypes.append(event.type) }
        for await event in second { secondTypes.append(event.type) }
        XCTAssertTrue(firstTypes.contains("gateway.ready"))
        XCTAssertEqual(firstTypes, secondTypes)
    }

    func testBatchAttachesEveryEvidenceImageBeforeSameSessionSubmission() async throws {
        let script = try makeGatewayScript()
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent().deletingLastPathComponent()) }
        let image = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-test-image-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: image)
        defer { try? FileManager.default.removeItem(at: image) }

        let gateway = HermesGateway(defaultDeadline: 1)
        try await gateway.start(launch: .python(executable: "/usr/bin/python3", gatewayEntry: script.path))
        let session = try await gateway.open(storedSessionID: "stored-xcreen")
        try await gateway.submitBatch(sessionID: session.runtimeID, text: "manifest", images: [
            HermesEvidenceAttachment(id: "img-1", timestamp: Date(timeIntervalSince1970: 1), fileURL: image)
        ], transmissionAllowed: { true })
        await gateway.stop()
    }

    private func makeGatewayScript(resumeResult: String = #"{"session_id":"runtime-xcreen","stored_session_id":"stored-xcreen"}"#, terminationDelay: Double = 0) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-fake-gateway-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("tui_gateway", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("__init__.py"))
        let url = package.appendingPathComponent("entry.py")
        let source = #"""
import json, sys, signal, time
def terminate(*args):
    time.sleep(\#(terminationDelay)); sys.exit(0)
signal.signal(signal.SIGTERM, terminate)
RESUME = '''\#(resumeResult)'''
print(json.dumps({"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":True}}}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    rid = request.get("id")
    if method == "session.resume":
        result = json.loads(RESUME)
        # Real Hermes returns the whole transcript unless omit_messages is set;
        # a long xCreen session exceeds the 1 MiB stdout frame cap.
        if not request['params'].get('omit_messages'):
            result["messages"] = [{"role": "user", "text": "x" * 1100000}]
    elif method == "gateway.capabilities": result = {"per_session_exclusive_submit":True}
    elif method == "config.set":
        # Real tui_gateway/methods_config_set.py: a lazy resumed session has no live agent, so
        # only config.set pins a session model_override; slash.exec /model is a silent no-op.
        value = request['params']['value']
        model = value.split(' --')[0]
        if model == "unknown/model": print(json.dumps({"jsonrpc":"2.0","id":rid,"error":{"code":5001,"message":"model not found"}}), flush=True); continue
        result = {"key":"model","value":model,"warning":"","confirm_required":False,"confirm_message":"","scope":"session"}
    elif method == "session.set_hidden":
        assert request['params']['session_id'] == 'runtime-xcreen'
        assert type(request['params']['hidden']) is bool
        result = {"hidden":request['params']['hidden'],"session_key":"stored-xcreen"}
    elif method == "session.history":
        assert request['params']['session_id'] == 'runtime-xcreen'
        result = {"count":1,"messages":[{"role":"assistant","content":"synthetic durable reply"}]}
    elif method == "image.attach_bytes": result = {"attached":True}
    elif method == "prompt.submit": result = {"status":"streaming"}
    elif method == "client.capabilities": result = {"server_requests":[],"declines_not_shown":True}
    else: result = {}
    print(json.dumps({"jsonrpc":"2.0","id":rid,"result":result}), flush=True)
"""#
        try source.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
