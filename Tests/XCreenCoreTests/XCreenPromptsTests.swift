import XCTest
@testable import XCreenCore

final class XCreenPromptsTests: XCTestCase {
    func testManualPromptNamesEveryXCreenTool() {
        let text = XCreenPrompts.manual(question: "what was I reading?")
        for tool in ["xcreen_search_ocr", "xcreen_images_near", "xcreen_view_image", "xcreen_daily_note", "tool_call"] {
            XCTAssertTrue(text.contains(tool), tool)
        }
        XCTAssertTrue(text.hasSuffix("what was I reading?"))
    }

    func testBatchPromptListsEveryImageAndStaysUnderSubmitLimit() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let images = (0..<30).map { EvidenceImage(id: "image-\($0)", timestamp: start.addingTimeInterval(Double($0) * 10), fileURL: URL(fileURLWithPath: "/x/\($0).png")) }
        let ocr = (0..<300).map { OCREvidence(id: "ocr-\($0)", timestamp: start, text: String(repeating: "a", count: 5_000), app: "A", title: "T") }
        let text = XCreenPrompts.batch(CaptureBatch(id: "batch-1", images: images, startedAt: start, completedAt: start.addingTimeInterval(300), ocr: ocr))
        XCTAssertEqual(images.filter { text.contains("image_id=\($0.id) ") }.count, 30)
        XCTAssertLessThanOrEqual(text.utf8.count, 32_000)
        XCTAssertTrue(text.contains("nothing saved"))
    }
}
