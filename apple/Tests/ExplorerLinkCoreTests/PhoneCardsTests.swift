import XCTest
@testable import ExplorerLinkCore

final class PhoneCardsTests: XCTestCase {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testStatusMakesUnknownBatteryExplicit() {
        XCTAssertEqual(PhoneCards.statusBody(batteryLevel: -1, batteryState: nil, now: now, timeZone: utc), "Battery: unavailable\nLocal time: Tue 22:13")
        XCTAssertEqual(PhoneCards.statusBody(batteryLevel: 0.42, batteryState: "charging", now: now, timeZone: utc), "Battery: 42% · charging\nLocal time: Tue 22:13")
    }

    func testEventsIncludeOverlappingAllDayWindowAndStayBounded() {
        let long = String(repeating: "x", count: 200)
        let body = PhoneCards.nextEventsBody([
            .init(title: "tomorrow", start: now.addingTimeInterval(24 * 60 * 60), isAllDay: false),
            .init(title: "later", start: now.addingTimeInterval(5 * 60 * 60), isAllDay: false),
            .init(title: "all\nday", start: now.addingTimeInterval(-10 * 60 * 60), end: now.addingTimeInterval(10 * 60 * 60), isAllDay: true),
            .init(title: long, start: now.addingTimeInterval(2 * 60 * 60), isAllDay: false),
            .init(title: "past", start: now.addingTimeInterval(-2 * 60 * 60), end: now.addingTimeInterval(-1), isAllDay: false)
        ], now: now, timeZone: utc)
        XCTAssertEqual(body.components(separatedBy: "\n").count, 3)
        XCTAssertTrue(body.hasPrefix("All day · all day\nWed 00:13 · "))
        XCTAssertTrue(body.contains("…"))
        XCTAssertFalse(body.contains("tomorrow"))
        XCTAssertFalse(body.contains("past"))
    }

    func testRemindersSortDueItemsBeforeUndatedAndLimitFive() {
        let body = PhoneCards.remindersBody([
            .init(title: "undated", due: nil),
            .init(title: "third", due: now.addingTimeInterval(3)),
            .init(title: "first", due: now.addingTimeInterval(1)),
            .init(title: "second", due: now.addingTimeInterval(2)),
            .init(title: "fourth", due: now.addingTimeInterval(4)),
            .init(title: "sixth", due: now.addingTimeInterval(6)),
            .init(title: "seventh", due: now.addingTimeInterval(7))
        ], now: now, timeZone: utc)
        XCTAssertEqual(body.components(separatedBy: "\n").count, 5)
        XCTAssertTrue(body.contains("first"))
        XCTAssertFalse(body.contains("undated"))
        XCTAssertFalse(body.contains("seventh"))
        XCTAssertEqual(PhoneCards.remindersBody([], now: now, timeZone: utc), "No incomplete reminders.")
    }
}
