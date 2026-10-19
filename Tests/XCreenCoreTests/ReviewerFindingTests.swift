import Foundation
import XCTest
@testable import XCreenCore

final class ReviewerFindingTests: XCTestCase {
    func testInputBoundsCountUnicodeScalarsLikePythonCodePoints() {
        let family = "👨‍👩‍👧‍👦"
        let source = String(repeating: family, count: 2)
        let bounded = InputBounds.prefix(source, maxUnicodeScalars: 8)
        XCTAssertEqual(bounded.unicodeScalars.count, 8)
        XCTAssertEqual(bounded, family + "👨")
    }
}
