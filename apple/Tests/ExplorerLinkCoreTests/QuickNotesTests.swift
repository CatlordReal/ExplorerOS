import XCTest
@testable import ExplorerLinkCore

final class QuickNotesTests: XCTestCase {
    func testStoredNotesEnforceTheSameLimitsAsCreation() throws {
        let note = QuickNote(title: "Local", body: "Saved note")
        XCTAssertEqual(try QuickNotesData.decode(JSONEncoder().encode([note])), [note])
        for notes in [[note, note], [QuickNote(title: "Oversize", body: String(repeating: "x", count: 4097))],
                      (0..<501).map { QuickNote(title: "\($0)", body: "") }] {
            XCTAssertThrowsError(try QuickNotesData.decode(JSONEncoder().encode(notes)))
        }
        XCTAssertThrowsError(try QuickNotesData.decode(Data("invalid json".utf8)))
        XCTAssertThrowsError(try QuickNotesData.decode(Data(repeating: 32, count: QuickNotesData.maximumBytes + 1)))
    }
}
