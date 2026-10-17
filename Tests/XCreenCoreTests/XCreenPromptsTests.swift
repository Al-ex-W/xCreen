import XCTest
@testable import XCreenCore

final class XCreenPromptsTests: XCTestCase {
    func testManualPromptNamesEveryXCreenTool() {
        let text = XCreenPrompts.manual(question: "what was I reading?")
        for tool in ["xcreen_recent_ocr", "xcreen_coverage", "UTC", "local", "not proof", "xcreen_search_ocr", "xcreen_images_near", "xcreen_view_image", "xcreen_note_write", "xcreen_vault_read", "xcreen_vault_list", "xcreen_recent_writes", "tool_call"] {
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
        XCTAssertTrue(text.contains("batch_id=batch-1"))
        XCTAssertTrue(text.contains("entry_id"))
        XCTAssertTrue(text.contains("not confirmed intent"))
        XCTAssertTrue(text.contains("Never save raw OCR"))
        XCTAssertTrue(text.contains("Agent/Vault Conventions.md"))
        XCTAssertTrue(text.contains("[[wikilinks]]"))
        XCTAssertTrue(text.contains("Writing nothing is a good outcome"))
        XCTAssertTrue(text.contains("revises"))
        XCTAssertTrue(text.contains("chat answers only, never inside notes"), "evidence citations stay out of notes")
    }

    func testNotePromptForbidsMarkupAndActivityLogging() {
        let rules = XCreenPrompts.noteStyle
        for phrase in ["No HTML comments", "never write evidence ids", "Do not log apps, sites or pages", "Screen shows", "Prefer revising", "State the takeaway itself", "appears to"] {
            XCTAssertTrue(rules.contains(phrase), phrase)
        }
    }

    func testBatchOCRManifestStaysCompactForPersistentHistory() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let images = (0..<30).map { EvidenceImage(id: "image-\($0)", timestamp: start, fileURL: URL(fileURLWithPath: "/x/\($0).png")) }
        let ocr = (0..<95).map { OCREvidence(id: "ocr-\($0)", timestamp: start, text: "same   window\n\n" + String(repeating: "word ", count: 1_000), app: "A", title: "T") }
        let text = XCreenPrompts.batch(CaptureBatch(id: "batch-1", images: images, startedAt: start, completedAt: start, ocr: ocr))
        let manifest = text.components(separatedBy: "OCR change manifest")[1].components(separatedBy: "Task:")[0]
        XCTAssertLessThan(manifest.utf8.count, 6_000)
        XCTAssertTrue(manifest.contains("71 more not listed"))
        XCTAssertTrue(manifest.contains("xcreen_recent_ocr"))
        XCTAssertTrue(manifest.contains("same preview as an earlier entry"))
        XCTAssertFalse(manifest.contains("\n\nword"))
    }
}
