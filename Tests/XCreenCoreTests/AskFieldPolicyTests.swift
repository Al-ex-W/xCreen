import XCTest
@testable import XCreenCore

final class AskFieldPolicyTests: XCTestCase {
    func testAdmittedQuestionClearsField() {
        XCTAssertEqual(AskFieldPolicy.fieldAfterAdmission(current: "  what did I do?\n", submitted: "what did I do?"), "")
    }

    func testTextTypedAfterSubmitIsKept() {
        XCTAssertEqual(AskFieldPolicy.fieldAfterAdmission(current: "next question", submitted: "what did I do?"), "next question")
    }

    func testSpotlightPrefillIsBoundedAndClearedAfterAdmission() {
        let long = String(repeating: "a", count: AskShortcut.maxQuestionScalars + 10)
        let filled = AskFieldPolicy.prefill(long)
        XCTAssertEqual(filled.unicodeScalars.count, AskShortcut.maxQuestionScalars)
        XCTAssertEqual(AskFieldPolicy.fieldAfterAdmission(current: filled, submitted: filled), "")
    }

    func testHandoffFromIntentQuestionAndSearchTerm() {
        XCTAssertEqual(PanelHandoff(question: " hi "), .ask(" hi "))
        XCTAssertEqual(PanelHandoff(question: "   "), .open)
        let long = String(repeating: "b", count: AskShortcut.maxQuestionScalars + 5)
        guard case .ask(let bounded) = PanelHandoff(question: long) else { return XCTFail() }
        XCTAssertEqual(bounded.unicodeScalars.count, AskShortcut.maxQuestionScalars)
    }
}
