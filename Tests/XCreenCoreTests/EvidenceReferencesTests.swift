import XCTest
@testable import XCreenCore

final class EvidenceReferencesTests: XCTestCase {
    func testExtractsUniqueIDsInOrder() {
        let reply = "See `xcreen-image:image-abc-1` and (xcreen-image:image-def-2). Again xcreen-image:image-abc-1."
        XCTAssertEqual(EvidenceReferences.imageIDs(in: reply), ["image-abc-1", "image-def-2"])
    }

    func testIgnoresPathsURLsAndTraversal() {
        let reply = "xcreen-image:../../etc/passwd xcreen-image:/tmp/x.png ![](https://example.com/a.png) /Users/me/a.png"
        XCTAssertEqual(EvidenceReferences.imageIDs(in: reply), [])
    }

    func testCapsReferenceCount() {
        let reply = (0..<50).map { "xcreen-image:image-\($0)" }.joined(separator: " ")
        XCTAssertEqual(EvidenceReferences.imageIDs(in: reply).count, EvidenceReferences.maximum)
    }
}
