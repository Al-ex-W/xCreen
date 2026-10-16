import XCTest
@testable import XCreenCore

final class HistoryPagerTests: XCTestCase {
    func testOversizedMessageDoesNotBlockFollowingPagesAndPixelsAreRemoved() throws {
        var pager = HistoryPager()
        let rows: [[String: Any]] = [
            ["role": "user", "content": String(repeating: "secret", count: 20000)],
            ["role": "assistant", "content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,AAAA"]], ["type": "text", "text": "hello"]]],
            ["role": "assistant", "content": "tail"]]
        let raw = try JSONSerialization.data(withJSONObject: ["messages": rows])
        let first = try pager.page(data: raw, cursor: nil, limit: 1)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        let messages = try XCTUnwrap(object["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["oversized"] as? Bool, true)
        let cursor = try XCTUnwrap(object["next_cursor"] as? String)
        _ = try pager.page(data: raw, cursor: nil, limit: 1) // another caller must not invalidate this cursor
        let next = try pager.page(data: nil, cursor: cursor, limit: 2)
        XCTAssertLessThanOrEqual(next.count, 48000)
        let text = String(decoding: next, as: UTF8.self)
        XCTAssertFalse(text.contains("AAAA"))
        XCTAssertTrue(text.contains("tail"))
        XCTAssertTrue(text.contains("hello"))
    }
}
