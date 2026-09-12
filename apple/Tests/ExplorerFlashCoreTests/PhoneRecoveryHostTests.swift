import CryptoKit
import Foundation
import XCTest
@testable import ExplorerFlashCore
@testable import ExplorerLinkCore

@MainActor
final class PhoneRecoveryHostTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("phone-recovery-host-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func makeHost() throws -> (PhoneRecoveryHost, RecoveryFake, URL) {
        let fake = RecoveryFake()
        return try makeHost(fake: fake, runner: fake)
    }

    private func makeHost(fake: RecoveryFake, runner: any ProcessRunning) throws -> (PhoneRecoveryHost, RecoveryFake, URL) {
        let workspace = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: false)
        let adb = workspace.appendingPathComponent("adb")
        try Data("synthetic ADB fixture".utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        fake.adbPath = adb.path
        let installer = try RecoveryInstaller(adb: adb, serial: "GLASS123", runner: runner,
                                              fixtureRecoveryHash: sha(RecoveryFake.recovery), fixtureFstabHash: sha(RecoveryFake.fstab))
        let firmware = workspace.appendingPathComponent("firmware.zip")
        try makeZIP(backupFiles().sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, mode: 0x81a40000).write(to: firmware)
        let root = workspace.appendingPathComponent("off-device", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let host = PhoneRecoveryHost(installer: installer, firmware: firmware, sha256: try RecoveryArchive.hash(firmware),
                                     backupRoot: root, firmwareName: "ExplorerOS.zip", serial: "GLASS123")
        return (host, fake, root)
    }

    private func request(_ host: PhoneRecoveryHost, _ action: InstallerAction, value: String = "", id: String = UUID().uuidString) -> InstallerRequest {
        InstallerRequest(id: id, hostSession: host.snapshot.hostSession, revision: host.snapshot.revision, action: action, value: value)
    }

    private func wait(_ host: PhoneRecoveryHost, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<300 {
            if !host.snapshot.busy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Host operation did not finish", file: file, line: line)
    }

    func testSuccessPathPreparesOnlyAndKeepsMacBackup() async throws {
        let (host, fake, root) = try makeHost()
        var revisions: [Int] = []
        host.onChange = { revisions.append($0.revision) }

        try host.submit(request(host, .inspectAndroid)); await wait(host)
        XCTAssertEqual(host.snapshot.step, .recovery); XCTAssertEqual(host.snapshot.battery, 90)
        try host.submit(request(host, .rebootRecovery)); await wait(host)
        XCTAssertTrue(fake.inRecovery)
        try host.submit(request(host, .inspectRecovery)); await wait(host)
        XCTAssertEqual(host.snapshot.step, .backup)

        fake.addBackup(name: "2026-09-12.12.30.00", files: backupFiles())
        try host.submit(request(host, .listBackups)); await wait(host)
        XCTAssertEqual(host.snapshot.backupNames, ["2026-09-12.12.30.00"])
        try host.submit(request(host, .copyBackup, value: "2026-09-12.12.30.00")); await wait(host)
        XCTAssertEqual(host.snapshot.step, .prepare); XCTAssertTrue(host.snapshot.backupSaved)
        let saved = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        XCTAssertTrue(saved.lastPathComponent.hasPrefix("Glass-Backup-"))

        try host.submit(request(host, .prepare)); await wait(host)
        XCTAssertEqual(host.snapshot.step, .prepared)
        XCTAssertNotNil(host.snapshot.preparedFolder)
        XCTAssertTrue(host.snapshot.status.contains("not been restored"))
        XCTAssertFalse(host.snapshot.status.localizedCaseInsensitiveContains("installed"))
        XCTAssertTrue(fake.published)
        XCTAssertFalse(fake.commands.contains { $0.arguments.contains("fastboot") || $0.arguments.contains("restore") })
        XCTAssertEqual(revisions, revisions.sorted())

        try host.submit(request(host, .reset))
        XCTAssertEqual(host.snapshot.step, .check); XCTAssertFalse(host.snapshot.backupSaved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: saved.path))
    }

    func testRejectsWrongHostStaleReplayAndWrongStep() throws {
        let (host, _, _) = try makeHost()
        let original = host.snapshot
        let wrong = InstallerRequest(hostSession: UUID().uuidString, revision: original.revision, action: .inspectAndroid)
        XCTAssertThrowsError(try host.submit(wrong))
        let stale = InstallerRequest(hostSession: original.hostSession, revision: original.revision + 1, action: .inspectAndroid)
        XCTAssertThrowsError(try host.submit(stale))
        XCTAssertThrowsError(try host.submit(request(host, .prepare)))
        let id = UUID().uuidString
        try host.submit(request(host, .status, id: id))
        XCTAssertThrowsError(try host.submit(request(host, .status, id: id)))
        try host.submit(request(host, .reset))
        XCTAssertGreaterThan(host.snapshot.revision, 0)
        let bootstrap = InstallerRequest(hostSession: "", revision: 0, action: .status)
        try host.submit(bootstrap)
        XCTAssertThrowsError(try host.submit(bootstrap))
    }

    func testInvalidFixedHostConfigurationCannotStartOperation() throws {
        let fake = RecoveryFake()
        let (_, _, root) = try makeHost(fake: fake, runner: fake)
        let firmware = directory.appendingPathComponent("invalid.zip")
        try Data("not firmware".utf8).write(to: firmware)
        let installer = try RecoveryInstaller(adb: URL(fileURLWithPath: fake.adbPath), serial: "GLASS123", runner: fake,
                                              fixtureRecoveryHash: sha(RecoveryFake.recovery), fixtureFstabHash: sha(RecoveryFake.fstab))
        let host = PhoneRecoveryHost(installer: installer, firmware: firmware, sha256: "invalid",
                                     backupRoot: root, firmwareName: "ExplorerOS.zip", serial: "GLASS123")
        XCTAssertNotNil(host.snapshot.error)
        XCTAssertThrowsError(try host.submit(request(host, .inspectAndroid)))
        XCTAssertFalse(host.snapshot.busy)
    }

    func testMismatchedFixedSerialCannotStartOperation() throws {
        let fake = RecoveryFake()
        let (_, _, root) = try makeHost(fake: fake, runner: fake)
        let firmware = directory.appendingPathComponent("serial-mismatch.zip")
        try Data("not firmware".utf8).write(to: firmware)
        let installer = try RecoveryInstaller(adb: URL(fileURLWithPath: fake.adbPath), serial: "GLASS123", runner: fake,
                                              fixtureRecoveryHash: sha(RecoveryFake.recovery), fixtureFstabHash: sha(RecoveryFake.fstab))
        let host = PhoneRecoveryHost(installer: installer, firmware: firmware, sha256: String(repeating: "a", count: 64),
                                     backupRoot: root, firmwareName: "ExplorerOS.zip", serial: "OTHER456")
        XCTAssertNotNil(host.snapshot.error)
        XCTAssertThrowsError(try host.submit(request(host, .inspectAndroid)))
        XCTAssertTrue(fake.commands.isEmpty)
    }

    func testBusyAllowsStatusAndCancelOnly() async throws {
        let (host, _, _) = try makeHost()
        try host.submit(request(host, .inspectAndroid))
        let busyRevision = host.snapshot.revision
        try host.submit(InstallerRequest(hostSession: host.snapshot.hostSession, revision: busyRevision, action: .status))
        XCTAssertThrowsError(try host.submit(InstallerRequest(hostSession: host.snapshot.hostSession, revision: host.snapshot.revision, action: .reset)))
        try host.submit(request(host, .cancel))
        await wait(host)
        XCTAssertEqual(host.snapshot.step, .check)
        XCTAssertTrue(host.snapshot.status.contains("Cancellation requested"))
        XCTAssertNil(host.snapshot.preparedFolder)
    }

    func testDisconnectCancelsAndNeverPublishesPrepared() async throws {
        let (host, _, _) = try makeHost()
        try host.submit(request(host, .inspectAndroid))
        host.disconnect()
        await wait(host)
        XCTAssertEqual(host.snapshot.step, .check)
        XCTAssertFalse(host.snapshot.busy)
        XCTAssertNil(host.snapshot.preparedFolder)
        XCTAssertTrue(host.snapshot.status.contains("Disconnected"))
    }

    func testSynchronousBusyCallbackDisconnectsBeforeAnyRunnerCommand() async throws {
        let (host, fake, _) = try makeHost()
        var didDisconnect = false
        host.onChange = { snapshot in
            if snapshot.busy, !didDisconnect { didDisconnect = true; host.disconnect() }
        }
        try host.submit(request(host, .inspectAndroid))
        await wait(host)
        XCTAssertTrue(didDisconnect)
        XCTAssertTrue(fake.commands.isEmpty)
        XCTAssertFalse(host.snapshot.busy)
        XCTAssertEqual(host.snapshot.step, .check)
    }

    func testFailedBackupRevalidationClearsReceiptAndAllowsNewCopy() async throws {
        let (host, fake, root) = try makeHost()
        try host.submit(request(host, .inspectAndroid)); await wait(host)
        try host.submit(request(host, .rebootRecovery)); await wait(host)
        try host.submit(request(host, .inspectRecovery)); await wait(host)
        let name = "2026-09-12.12.30.00"
        fake.addBackup(name: name, files: backupFiles())
        try host.submit(request(host, .listBackups)); await wait(host)
        try host.submit(request(host, .copyBackup, value: name)); await wait(host)
        let saved = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        try Data("corrupted".utf8).write(to: saved.appendingPathComponent("system.ext4.tar"))
        try host.submit(request(host, .prepare)); await wait(host)
        XCTAssertEqual(host.snapshot.step, .backup)
        XCTAssertFalse(host.snapshot.backupSaved)
        XCTAssertNil(host.snapshot.preparedFolder)
        XCTAssertNotNil(host.snapshot.error)
        try host.submit(request(host, .copyBackup, value: name)); await wait(host)
        XCTAssertEqual(host.snapshot.step, .prepare)
    }

    func testCancelAndDisconnectAfterRunnerStartsNeverPrepare() async throws {
        for disconnect in [false, true] {
            let fake = RecoveryFake(); let runner = StallingRunner(fake)
            let (host, _, _) = try makeHost(fake: fake, runner: runner)
            try host.submit(request(host, .inspectAndroid))
            for _ in 0..<100 where !runner.entered { try? await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(runner.entered)
            if disconnect { host.disconnect() } else { try host.submit(request(host, .cancel)) }
            await wait(host)
            XCTAssertEqual(host.snapshot.step, .check)
            XCTAssertNil(host.snapshot.preparedFolder)
            XCTAssertFalse(host.snapshot.status.localizedCaseInsensitiveContains("prepared"))
        }
    }
}

private final class StallingRunner: ProcessRunning, @unchecked Sendable {
    let base: RecoveryFake
    private let lock = NSLock(); private var didEnter = false
    init(_ base: RecoveryFake) { self.base = base }
    var entered: Bool { lock.withLock { didEnter } }
    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        let shouldStall = lock.withLock { () -> Bool in
            guard !didEnter, command.executable.path == base.adbPath else { return false }
            didEnter = true; return true
        }
        if shouldStall { try await Task.sleep(for: .seconds(30)) }
        return try await base.run(command)
    }
}
