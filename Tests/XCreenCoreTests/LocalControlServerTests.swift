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

    func testRejectedPeerIsCheckedBeforeSlotAndNeverReachesHandler() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = DispatchSemaphore(value: 0)
        let checks = Counter(), handled = Counter()
        // First 8 peers are authorized and parked in the handler (filling every slot); later peers are rejected.
        let server = try LocalControlServer(directory: root, peerAuthorized: { _ in checks.next() <= 8 }) { _ in
            handled.next(); gate.wait()
            return .ok(.init(app: "synthetic", connected: false, integrity: true, capture: "paused", settings: .init()))
        }
        defer { server.stop(); for _ in 0..<8 { gate.signal() } }
        let path = root.appendingPathComponent("control.sock").path
        var parked: [Int32] = []
        defer { parked.forEach { close($0) } }
        for _ in 0..<8 { let fd = try Self.connect(path); _ = "{\"command\":\"status\"}\n".withCString { write(fd, $0, strlen($0)) }; parked.append(fd) }
        let deadline = Date().addingTimeInterval(5)
        while handled.value < 8 && Date() < deadline { usleep(10_000) }
        XCTAssertEqual(handled.value, 8)
        for _ in 0..<5 {
            let fd = try Self.connect(path); defer { close(fd) }
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var byte: UInt8 = 0
            XCTAssertEqual(read(fd, &byte, 1), 0, "rejected peer must be closed")
        }
        XCTAssertEqual(checks.value, 13, "peer check must run even when all slots are busy")
        XCTAssertEqual(handled.value, 8)
    }

    private static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8) + [0]
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { close(fd); throw LocalControlError.unavailable("connect failed") }
        return fd
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    @discardableResult func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}
