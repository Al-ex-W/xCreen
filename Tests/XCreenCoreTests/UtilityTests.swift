import XCTest
@testable import XCreenCore
final class UtilityTests: XCTestCase {
    func testShortcutOnlyDecodesAskURLs() {
        XCTAssertEqual(AskShortcut.query(URL(string: "xcreen://ask?query=hello%20world%26more")!), "hello world&more")
        XCTAssertNil(AskShortcut.query(URL(string: "https://ask?query=oops")!))
        XCTAssertNil(AskShortcut.query(URL(string: "xcreen://capture?query=oops")!))
        XCTAssertNil(AskShortcut.query(URL(string: "xcreen://ask")!))
    }
    func testDedupIsBoundedAndDoesNotRetainPlainOCR() {
        var cache = OCRDedup(capacity: 2)
        XCTAssertTrue(cache.insert("a", app: "editor"))
        XCTAssertFalse(cache.insert("a", app: "editor"))
        XCTAssertTrue(cache.insert("b", app: "editor"))
        XCTAssertTrue(cache.insert("c", app: "editor"))
        XCTAssertTrue(cache.insert("a", app: "editor"))
        XCTAssertTrue(cache.insert("a", app: "browser"))
        XCTAssertFalse(cache.insert("  \n", app: "editor"))
        XCTAssertLessThanOrEqual(cache.count, 2)
    }
}
