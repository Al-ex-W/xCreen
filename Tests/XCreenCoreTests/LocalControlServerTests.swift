import XCTest
import Darwin
@testable import XCreenCore

final class LocalControlServerTests: XCTestCase {
    func testRealSocketRoundTripAndMalformedRequest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LocalControlServer(directory: root) { _ in .ok(.init(app: "synthetic", connected: false, integrity: true, capture: "paused", settings: .init())) }
        defer { server.stop() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import socket,json,sys,importlib.machinery,importlib.util
loader=importlib.machinery.SourceFileLoader('cli', 'bin/xcreen')
spec=importlib.util.spec_from_loader(loader.name,loader)
cli=importlib.util.module_from_spec(spec); loader.exec_module(cli)
assert cli.request({'command':'status'}, directory=sys.argv[1].rsplit('/',1)[0])['snapshot']['app']=='synthetic'
for frame,expected in [(b'{"command":"status"}\\n',True),(b'bad\\n',False)]:
    with socket.socket(socket.AF_UNIX) as s:
        s.settimeout(5); s.connect(sys.argv[1]); s.sendall(frame)
        data=b''
        while b'\\n' not in data: data += s.recv(8192)
        result=json.loads(data)
        assert result['ok'] == expected, result
        if expected: assert result['snapshot']['integrity'] is True
""", root.appendingPathComponent("control.sock").path]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    func testPrivateEndpointAndExclusiveInstance() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let server = try LocalControlServer(directory: root) { _ in .ok(.init(app: "synthetic", connected: false, integrity: true, capture: "paused", settings: .init())) }
        defer { server.stop() }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("control.sock").path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertThrowsError(try LocalControlServer(directory: root) { _ in .failure(LocalControlError.failed("unexpected")) })
    }
    func testRejectsSymlinkDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(atPath: root.path, withDestinationPath: FileManager.default.temporaryDirectory.path)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try LocalControlServer(directory: root) { _ in .failure(LocalControlError.failed("unexpected")) })
    }
}
