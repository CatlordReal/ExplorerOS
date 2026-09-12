import XCTest
@testable import ExplorerLinkCore

final class InstallerProtocolTests: XCTestCase {
    private let key = String(repeating: "ab", count: 32)
    private let session = "4a4653e6-1f71-4801-a5ef-56ab8f95ed48"

    private func snapshot(step: InstallerStep = .check, busy: Bool = false,
                          backupNames: [String] = [], backupSaved: Bool = false,
                          preparedFolder: String? = nil) -> InstallerSnapshot {
        InstallerSnapshot(hostSession: session, revision: 12, step: step, serial: "GLASS-123",
                          busy: busy, backupNames: backupNames, backupSaved: backupSaved,
                          preparedFolder: preparedFolder, firmwareName: "ExplorerOS.zip",
                          firmwareSHA256: String(repeating: "a", count: 64))
    }

    func testRequestRequiresBoundedTypedActionFields() throws {
        XCTAssertNoThrow(try InstallerRequest(hostSession: session, revision: 12, action: .copyBackup,
                                              value: "2026-09-12.12.30.00").validate())
        XCTAssertNoThrow(try InstallerRequest(hostSession: "", revision: 0, action: .status).validate())

        let invalid: [InstallerRequest] = [
            .init(id: "not-a-uuid", hostSession: session, revision: 0, action: .status),
            .init(hostSession: "", revision: 0, action: .prepare),
            .init(hostSession: session, revision: -1, action: .status),
            .init(hostSession: session, revision: 0, action: .status, value: "x"),
            .init(hostSession: session, revision: 0, action: .copyBackup, value: "../backup"),
            .init(hostSession: session, revision: 0, action: .copyBackup, value: "backup\n"),
            .init(hostSession: session, revision: 0, action: .copyBackup, value: String(repeating: "x", count: 97))
        ]
        for request in invalid { XCTAssertThrowsError(try request.validate()) }
    }

    func testRequestDecoderRejectsExtraAndMissingJSONFields() throws {
        let valid = "{\"id\":\"\(UUID())\",\"hostSession\":\"\(session)\",\"revision\":0,\"action\":\"status\",\"value\":\"\"}"
        XCTAssertNoThrow(try InstallerRequest.decode(.init(type: "installer.request", payload: ["json": valid])))
        let extra = valid.dropLast() + ",\"shell\":\"reboot\"}"
        XCTAssertThrowsError(try InstallerRequest.decode(.init(type: "installer.request", payload: ["json": String(extra)])))
        let missing = "{\"id\":\"\(UUID())\",\"hostSession\":\"\(session)\",\"revision\":0,\"action\":\"status\"}"
        XCTAssertThrowsError(try InstallerRequest.decode(.init(type: "installer.request", payload: ["json": missing])))
        XCTAssertThrowsError(try InstallerRequest.decode(.init(type: "installer.status", payload: ["json": valid])))
    }

    func testPairingParserRejectsPublicHostsAndMalformedURLs() throws {
        let code = try InstallerPairingCode(host: "192.168.1.4", port: 8766, key: key)
        XCTAssertEqual(try InstallerPairingCode.parse(code.text), code)
        for text in [
            "explorer-install://pair?host=8.8.8.8&port=8766&key=\(key)",
            "explorer-install://pair?host=192.168.1.4&port=0&key=\(key)",
            "explorer-install://pair?host=192.168.1.4&port=08766&key=\(key)",
            "explorer-install://pair/path?host=192.168.1.4&port=8766&key=\(key)",
            "explorer-install://pair?host=192.168.1.4&port=8766&key=\(key)&extra=x",
            "explorer-install://pair?host=192.168.1.4&host=127.0.0.1&port=8766&key=\(key)",
            "explorer-install://pair?host=192.168.1.4&port=8766&key=short"
        ] { XCTAssertThrowsError(try InstallerPairingCode.parse(text), text) }
    }

    func testSnapshotStateAndFieldBounds() throws {
        XCTAssertNoThrow(try snapshot().validate())
        XCTAssertNoThrow(try snapshot(step: .backup, backupNames: ["2026.09.12"]).validate())
        XCTAssertNoThrow(try snapshot(step: .prepare, backupSaved: true).validate())
        XCTAssertNoThrow(try snapshot(step: .prepared, backupSaved: true,
                                      preparedFolder: "/data/media/0/clockworkmod/backup/explorerlink-4a4653e6-1f71-4801-a5ef-56ab8f95ed48").validate())

        var bad = snapshot(backupSaved: true); XCTAssertThrowsError(try bad.validate())
        bad = snapshot(step: .backup, backupSaved: true); XCTAssertThrowsError(try bad.validate())
        bad = snapshot(step: .prepare); XCTAssertThrowsError(try bad.validate())
        bad = snapshot(step: .prepared, busy: true, backupSaved: true,
                       preparedFolder: "/data/media/clockworkmod/backup/explorerlink-4a4653e6-1f71-4801-a5ef-56ab8f95ed48")
        XCTAssertThrowsError(try bad.validate())
        bad = snapshot(); bad.serial = "bad serial"; XCTAssertThrowsError(try bad.validate())
        bad = snapshot(); bad.serial = "GLASS-123\n"; XCTAssertThrowsError(try bad.validate())
        bad = snapshot(); bad.firmwareSHA256 += "\n"; XCTAssertThrowsError(try bad.validate())
        bad = snapshot(); bad.firmwareName = "../ExplorerOS.zip"; XCTAssertThrowsError(try bad.validate())
        bad = snapshot(); bad.firmwareName = "Explorer\nOS.zip"; XCTAssertThrowsError(try bad.validate())
        bad = snapshot(); bad.status = String(repeating: "x", count: 513); XCTAssertThrowsError(try bad.validate())
    }

    func testReviewBindsTargetRevisionAndSafetyState() {
        let reviewed = snapshot(step: .prepare, backupSaved: true)
        XCTAssertTrue(reviewed.matchesReview(reviewed))
        var changed = reviewed; changed.revision += 1; XCTAssertFalse(changed.matchesReview(reviewed))
        changed = reviewed; changed.serial = "GLASS-OTHER"; XCTAssertFalse(changed.matchesReview(reviewed))
        changed = reviewed; changed.firmwareSHA256 = String(repeating: "b", count: 64); XCTAssertFalse(changed.matchesReview(reviewed))
        changed = reviewed; changed.step = .backup; XCTAssertFalse(changed.matchesReview(reviewed))
        changed = reviewed; changed.busy = true; XCTAssertFalse(changed.matchesReview(reviewed))
    }
}
