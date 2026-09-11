import XCTest
@testable import ExplorerLinkCore

final class IntegrationPolicyTests: XCTestCase {
    func testShortcutURLIsNamedAndEscaped() throws {
        let url = try IntegrationPolicy.shortcutRunURL(named: "Focus & Quiet")
        XCTAssertEqual(url.scheme, "shortcuts")
        XCTAssertEqual(url.host, "run-shortcut")
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "Focus & Quiet")
    }

    func testShortcutNameRejectsEmptyControlAndOversizedValues() {
        XCTAssertThrowsError(try IntegrationPolicy.shortcutRunURL(named: "  "))
        XCTAssertThrowsError(try IntegrationPolicy.shortcutRunURL(named: "Focus\nOff"))
        XCTAssertThrowsError(try IntegrationPolicy.shortcutRunURL(named: String(repeating: "a", count: 129)))
    }

    func testQueueDeduplicatesAndClearsWithoutExecuting() throws {
        var queue = PhoneActionQueue()
        queue.enqueue(.focusOn); queue.enqueue(.focusOn)
        XCTAssertEqual(queue.pending.count, 1)
        XCTAssertNil(PhoneIntegrationAction(rawValue: "arbitrary-command"))
        queue.clear(); XCTAssertTrue(queue.pending.isEmpty)
        XCTAssertNil(PhoneIntegrationAction(rawValue: "mail.open"))
    }

    func testExternalTextIsBoundedAndCannotCarryCommands() throws {
        var parts = URLComponents(string: "explorerlink://preview")!
        parts.queryItems = [URLQueryItem(name: "text", value: "A note & a second line\nこんにちは")]
        XCTAssertEqual(try IntegrationPolicy.previewText(from: parts.url!), "A note & a second line\nこんにちは")
        for value in ["explorerlink://send?text=Hello", "explorerlink://preview?text=Hi&action=send",
                      "explorerlink://preview?text=Hi&text=Again", "explorerlink://user@preview?text=Hi",
                      "explorerlink://preview/path?text=Hi", "explorerlink://preview?text=Hi#send"] {
            XCTAssertThrowsError(try IntegrationPolicy.previewText(from: URL(string: value)!))
        }
        parts.queryItems = [URLQueryItem(name: "text", value: String(repeating: "📝", count: 1025))]
        XCTAssertThrowsError(try IntegrationPolicy.previewText(from: parts.url!))
    }
}
