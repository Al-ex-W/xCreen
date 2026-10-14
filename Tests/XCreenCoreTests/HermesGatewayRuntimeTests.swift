import XCTest
@testable import XCreenCore

final class HermesGatewayRuntimeTests: XCTestCase {
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

    private func makeGatewayScript() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-fake-gateway-\(UUID().uuidString)", isDirectory: true)
        let package = root.appendingPathComponent("tui_gateway", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data().write(to: package.appendingPathComponent("__init__.py"))
        let url = package.appendingPathComponent("entry.py")
        let source = #"""
import json, sys
print(json.dumps({"jsonrpc":"2.0","method":"event","params":{"type":"gateway.ready","payload":{"change_events":True}}}), flush=True)
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    rid = request.get("id")
    if method == "session.resume": result = {"session_id":"runtime-xcreen","stored_session_id":"stored-xcreen"}
    elif method == "gateway.capabilities": result = {"per_session_exclusive_submit":True}
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
