import XCTest
@testable import XCreenCore

final class LocalControlProtocolTests: XCTestCase {
    func testCommandDecodesAndBoundsAsk() throws {
        let command = try LocalControlCommand.decode(Data(#"{"id":"a","command":"ask","question":"hello","wait_ms":2000}"#.utf8))
        XCTAssertEqual(command.name, .ask)
        XCTAssertEqual(command.question, "hello")
        XCTAssertEqual(command.waitMilliseconds, 2_000)
    }

    func testRejectsMalformedAndOversizedRequests() {
        XCTAssertThrowsError(try LocalControlCommand.decode(Data("not json".utf8)))
        XCTAssertThrowsError(try LocalControlCommand.decode(Data(repeating: 65, count: LocalControlProtocol.maximumFrameBytes + 1)))
        XCTAssertThrowsError(try LocalControlCommand.decode(Data(#"{"command":"ask","question":""}"#.utf8)))
    }

    func testResponseNeverSerializesReplyIntoLogsSnapshot() throws {
        let snapshot = LocalControlSnapshot(app: "running", connected: true, integrity: true, capture: "paused", message: "private reply", models: [], settings: .init())
        let data = try JSONEncoder().encode(LocalControlResponse.ok(snapshot))
        let decoded = try JSONDecoder().decode(LocalControlResponse.self, from: data)
        XCTAssertEqual(decoded.snapshot?.message, "private reply")
        XCTAssertNil(decoded.reply)
    }
}
