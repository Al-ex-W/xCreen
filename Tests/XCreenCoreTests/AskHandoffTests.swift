import XCTest
@testable import XCreenCore

/// Spotlight / URL handoff: open or fill the panel, never submit, and never act before launch finishes.
final class AskHandoffTests: XCTestCase {
    func testAskURLRoundTripsQuestionWithReservedCharacters() throws {
        let question = "What was I doing at 3pm? 1+1 a&b=c #tag 100% ✓"
        let url = try XCTUnwrap(AskShortcut.url(question: question))
        XCTAssertEqual(url.scheme, "xcreen")
        XCTAssertEqual(url.host, "ask")
        XCTAssertEqual(AskShortcut.query(url), question)
        XCTAssertEqual(PanelHandoff(url: url), .ask(question))
    }

    func testAskURLRejectsBlankQuestionAndBoundsLength() throws {
        XCTAssertNil(AskShortcut.url(question: "  \n\t"))
        let url = try XCTUnwrap(AskShortcut.url(question: String(repeating: "x", count: 9_000)))
        XCTAssertEqual(AskShortcut.query(url)?.unicodeScalars.count, 8_000)
    }

    func testSpotlightSearchTermFillsQuestionOrJustOpensPanel() throws {
        let term = "invoice from acme 1+1"
        XCTAssertEqual(PanelHandoff(url: AskShortcut.searchURL(term: term)), .ask(term))
        XCTAssertEqual(AskShortcut.searchURL(term: " \n"), AskShortcut.openURL)
        let long = AskShortcut.searchURL(term: String(repeating: "y", count: 9_000))
        XCTAssertEqual(AskShortcut.query(long)?.unicodeScalars.count, 8_000)
    }

    func testOpenURLAndUnknownURLs() {
        XCTAssertEqual(PanelHandoff(url: AskShortcut.openURL), .open)
        XCTAssertEqual(PanelHandoff(url: URL(string: "XCREEN://open")!), .open)
        XCTAssertNil(PanelHandoff(url: URL(string: "xcreen://ask")!))
        XCTAssertNil(PanelHandoff(url: URL(string: "xcreen://capture")!))
        XCTAssertNil(PanelHandoff(url: URL(string: "https://open")!))
    }

    func testColdLaunchBuffersHandoffUntilAppIsReady() {
        var inbox = AskHandoffInbox()
        XCTAssertNil(inbox.receive(.ask("first")), "must not touch UI before launch finishes")
        XCTAssertNil(inbox.receive(.ask("second")))
        XCTAssertEqual(inbox.markReady(), .ask("second"), "latest pending question wins")
        XCTAssertNil(inbox.markReady(), "pending handoff is delivered once")
    }

    func testColdOpenDoesNotDiscardPendingQuestion() {
        var inbox = AskHandoffInbox()
        XCTAssertNil(inbox.receive(.ask("keep me")))
        XCTAssertNil(inbox.receive(.open))
        XCTAssertEqual(inbox.markReady(), .ask("keep me"))
    }

    func testWarmDeliveryIsImmediate() {
        var inbox = AskHandoffInbox()
        XCTAssertNil(inbox.markReady())
        XCTAssertEqual(inbox.receive(.ask("hello")), .ask("hello"))
        XCTAssertEqual(inbox.receive(.open), .open)
        XCTAssertNil(inbox.markReady())
    }

    func testURLBatchesBufferColdAndIgnoreInvalidURLs() {
        var inbox = AskHandoffInbox()
        let urls = [URL(string: "xcreen://ask?query=one")!, URL(string: "https://ask?query=evil")!, URL(string: "xcreen://ask")!]
        XCTAssertNil(inbox.receive(urls: urls))
        XCTAssertEqual(inbox.markReady(), .ask("one"))
        XCTAssertEqual(inbox.receive(urls: [URL(string: "xcreen://ask?query=two")!, URL(string: "xcreen://ask?query=three")!]), .ask("three"))
        XCTAssertNil(inbox.receive(urls: [URL(string: "xcreen://capture?query=x")!]))
    }
}
