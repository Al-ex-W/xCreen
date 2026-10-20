import Foundation
import XCTest
@testable import XCreenCore

/// In-memory server for uploader tests.
private actor FakeServer: XCreenServerAPI {
    var ocr: [String] = []
    var images: [String] = []
    var order: [String] = []
    var captures: [(String, Bool)] = []
    var failNext: ServerAPIError?
    var rejectImage: String?

    func setFailNext(_ error: ServerAPIError?) { failNext = error }
    func setRejectImage(_ id: String?) { rejectImage = id }
    private func check() throws { if let error = failNext { failNext = nil; throw error } }

    func health() async throws -> Int { 1 }
    func status() async throws -> ServerStatus { throw ServerAPIError.invalidResponse }
    func uploadOCR(_ items: [OCREvidence]) async throws { try check(); ocr += items.map(\.id); order += items.map(\.id) }
    func uploadImage(_ image: EvidenceImage, data: Data) async throws {
        try check()
        if image.id == rejectImage { throw ServerAPIError.rejected(status: 400, code: "invalid_request", message: "image must be PNG or JPEG") }
        images.append(image.id); order.append(image.id)
    }
    func image(id: String) async throws -> ServerImage { ServerImage(data: Data(), capturedAt: nil) }
    func reportCapture(state: String, reason: String, integrity: Bool) async throws { try check(); captures.append((state, integrity)) }
    func ask(_ question: String) async throws -> ServerTurn { throw ServerAPIError.invalidResponse }
    func turn(id: String, after: Int, waitMilliseconds: Int) async throws -> ServerTurn { throw ServerAPIError.invalidResponse }
    func cancel() async throws {}
    func history(cursor: String?) async throws -> Data { Data() }
    func batches(after: String) async throws -> [ServerBatch] { [] }
    func retryBatches() async throws -> Int { 0 }
    func verifyBatches() async throws -> Int { 0 }
    func models() async throws -> [HermesModelRoute] { [] }
    func selectModel(_ route: HermesModelRoute) async throws {}
    func setDefaultModel(_ route: HermesModelRoute) async throws {}
    func setSessionVisible(_ visible: Bool) async throws {}
    func connection(_ action: String) async throws {}
    func config() async throws -> ServerConfigValues { throw ServerAPIError.invalidResponse }
    func updateConfig(_ changes: [String: String]) async throws -> ServerConfigValues { throw ServerAPIError.invalidResponse }
    func autodetect() async throws -> ServerConfigValues { throw ServerAPIError.invalidResponse }
}

final class UploaderTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws { root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-upload-\(UUID().uuidString)") }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testDrainsInCaptureOrderReportsStatusAndEmptiesTheOutbox() async throws {
        let store = try EvidenceStore(root: root)
        let t0 = Date().addingTimeInterval(-60)
        let a = try await store.saveOCR(text: "a", app: "A", title: "", timestamp: t0)
        let image = try await store.saveImage(data: Data([1]), timestamp: t0.addingTimeInterval(1))
        let b = try await store.saveOCR(text: "b", app: "A", title: "", timestamp: t0.addingTimeInterval(2))
        try await store.saveCaptureStatus(state: "running", reason: "", integrity: false)
        let server = FakeServer()
        let uploader = Uploader(store: store)
        await uploader.setServerForTest(server)
        let sent = await uploader.drain()
        XCTAssertEqual(sent, 3)
        let order = await server.order
        XCTAssertEqual(order, [a.id, image.id, b.id])
        let captures = await server.captures
        XCTAssertEqual(captures.map(\.0), ["running"])
        XCTAssertEqual(captures.map(\.1), [false])
        let left = await store.pendingUploads()
        XCTAssertTrue(left.isEmpty)
        let reachable = await uploader.state.reachable
        XCTAssertTrue(reachable)
    }

    func testTransportFailureKeepsItemsForRetry() async throws {
        let store = try EvidenceStore(root: root)
        let image = try await store.saveImage(data: Data([1]))
        let server = FakeServer()
        await server.setFailNext(.unreachable("offline"))
        let uploader = Uploader(store: store)
        await uploader.setServerForTest(server)
        let none = await uploader.drain()
        XCTAssertEqual(none, 0)
        let kept = await store.pendingUploads()
        XCTAssertEqual(kept, [.image(image)])
        let state = await uploader.state
        XCTAssertFalse(state.reachable)
        let retried = await uploader.drain()
        XCTAssertEqual(retried, 1)
    }

    func testPermanentlyRejectedItemIsDroppedSoItCannotBlockTheQueue() async throws {
        let store = try EvidenceStore(root: root)
        let bad = try await store.saveImage(data: Data([1]), timestamp: Date().addingTimeInterval(-2))
        let good = try await store.saveImage(data: Data([2]), timestamp: Date().addingTimeInterval(-1))
        let server = FakeServer()
        await server.setRejectImage(bad.id)
        let uploader = Uploader(store: store)
        await uploader.setServerForTest(server)
        await uploader.drain()
        let images = await server.images
        XCTAssertEqual(images, [good.id])
        let left = await store.pendingUploads()
        XCTAssertTrue(left.isEmpty)
    }

    func testWithoutServerNothingLeavesTheOutbox() async throws {
        let store = try EvidenceStore(root: root)
        _ = try await store.saveImage(data: Data([1]))
        let uploader = Uploader(store: store)
        let sent = await uploader.drain()
        XCTAssertEqual(sent, 0)
        let count = await store.pendingUploads().count
        XCTAssertEqual(count, 1)
    }
}

extension Uploader {
    /// Sets the server without starting the background loop, so tests drive `drain()` directly.
    func setServerForTest(_ server: any XCreenServerAPI) { setServerWithoutLoop(server) }
}

final class ServerEndpointTests: XCTestCase {
    func testAcceptsLoopbackPrivateAndTailscaleOverHTTPAndAnythingOverHTTPS() throws {
        for url in ["http://127.0.0.1:8765", "http://localhost:8765", "http://100.125.168.59:8765", "http://192.168.0.201:8765",
                    "http://10.1.2.3:8765", "http://hermes.tail1234.ts.net:8765", "https://xcreen.example.com"] {
            XCTAssertNoThrow(try ServerEndpoint.validate(url), url)
        }
    }

    func testRejectsPublicHTTPCredentialsInURLAndOtherSchemes() {
        for url in ["http://203.0.113.5:8765", "http://example.com", "ftp://127.0.0.1", "http://user:pw@127.0.0.1:8765", "http://100.200.1.1:8765", "not a url"] {
            XCTAssertThrowsError(try ServerEndpoint.validate(url), url)
        }
    }
}

/// The stable contract: the real Swift client against the real Python server.
final class ServerContractTests: XCTestCase {
    private var process: Process?
    private var directory: URL!

    override func tearDown() {
        process?.terminate(); process?.waitUntilExit()
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private static func python() -> String? {
        var candidates = [ProcessInfo.processInfo.environment["XCREEN_TEST_PYTHON"], "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                          "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"].compactMap { $0 }
        if let path = ProcessInfo.processInfo.environment["PATH"] { candidates += path.split(separator: ":").map { "\($0)/python3" } }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            let probe = Process(); probe.executableURL = URL(fileURLWithPath: candidate)
            probe.arguments = ["-c", "import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)"]
            if (try? probe.run()) != nil { probe.waitUntilExit(); if probe.terminationStatus == 0 { return candidate } }
        }
        return nil
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func startServer() throws -> HTTPXCreenServer {
        guard let python = Self.python() else { throw XCTSkip("no Python 3.10+ available for the server") }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcreen-contract-\(UUID().uuidString)")
        let config = directory.appendingPathComponent("server.json").path, port = Self.freePort()
        func run(_ arguments: [String]) throws -> Process {
            let child = Process(); child.executableURL = URL(fileURLWithPath: python)
            child.arguments = ["-m", "xcreen_server", "--config", config] + arguments
            child.currentDirectoryURL = repo.appendingPathComponent("server")
            child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
            try child.run(); return child
        }
        let initialize = try run(["init", "--bind", "127.0.0.1", "--port", String(port), "--data-dir", directory.appendingPathComponent("evidence").path, "--no-detect"])
        initialize.waitUntilExit()
        XCTAssertEqual(initialize.terminationStatus, 0)
        let token = try String(contentsOf: directory.appendingPathComponent("server.token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        process = try run(["serve"])
        let client = HTTPXCreenServer(endpoint: ServerEndpoint(url: URL(string: "http://127.0.0.1:\(port)")!, token: token))
        return client
    }

    private func waitForHealth(_ client: HTTPXCreenServer) async throws {
        for _ in 0..<100 {
            if (try? await client.health()) == HTTPXCreenServer.protocolVersion { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("server did not become healthy")
    }

    func testClientAndServerAgreeOnUploadsStatusImagesAndCapture() async throws {
        let client = try startServer()
        try await waitForHealth(client)
        let images = directory.appendingPathComponent("images-src")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        // Smallest valid PNG header; the server checks the signature only.
        let png = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) + Data(repeating: 1, count: 16)
        let t0 = Date().addingTimeInterval(-120)
        try await client.uploadOCR([OCREvidence(id: "ocr-1", timestamp: t0, text: "contract text", app: "com.app", title: "T")])
        try await client.uploadOCR([OCREvidence(id: "ocr-1", timestamp: t0, text: "contract text", app: "com.app", title: "T")]) // idempotent
        let image = EvidenceImage(id: "image-1", timestamp: t0.addingTimeInterval(1), fileURL: images.appendingPathComponent("x.png"))
        try await client.uploadImage(image, data: png)
        try await client.reportCapture(state: "running", reason: "", integrity: false)
        let status = try await client.status()
        XCTAssertEqual(status.protocol, HTTPXCreenServer.protocolVersion)
        XCTAssertFalse(status.integrity)
        XCTAssertEqual(status.unbatched?["images"], 1)
        XCTAssertEqual(status.unbatched?["ocr"], 1)
        XCTAssertFalse(status.hermes.configured)
        let downloaded = try await client.image(id: "image-1")
        XCTAssertEqual(downloaded.data, png)
        let captured = try XCTUnwrap(downloaded.capturedAt)
        XCTAssertEqual(captured.timeIntervalSince1970, image.timestamp.timeIntervalSince1970, accuracy: 0.002)
        do { try await client.uploadOCR([OCREvidence(id: "ocr-1", timestamp: t0, text: "changed", app: "com.app", title: "T")]); XCTFail("conflict accepted") }
        catch let error as ServerAPIError { XCTAssertTrue(error.isPermanentRejection) }
        let batches = try await client.batches(after: "")
        XCTAssertTrue(batches.isEmpty)
        do { _ = try await client.models(); XCTFail("models without Hermes") }
        catch let error as ServerAPIError { if case .rejected(let code, _, _) = error { XCTAssertEqual(code, 503) } else { XCTFail("\(error)") } }
    }

    func testWrongTokenIsRejected() async throws {
        let client = try startServer()
        try await waitForHealth(client)
        let port = client.endpointURL.port!
        let wrong = HTTPXCreenServer(endpoint: ServerEndpoint(url: URL(string: "http://127.0.0.1:\(port)")!, token: String(repeating: "x", count: 43)))
        do { _ = try await wrong.status(); XCTFail("wrong token accepted") }
        catch let error as ServerAPIError { XCTAssertEqual(error, .unauthorized) }
    }
}
