import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ExplorerFlashCore

/// Host-only device model. Only zipinfo/ditto may reach ProcessRunner; synthetic ADB is never executed.
final class RecoveryFaultTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-faults-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private struct Context {
        let installer: RecoveryInstaller
        let android: RecoveryAndroidObservation
        let recovery: RecoveryObservation
        let firmware: URL
        let backup: RecoveryBackupCopy
    }
    private func context(_ runner: FaultRunner) async throws -> Context {
        let root = directory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let adb = root.appendingPathComponent("adb")
        try Data("inert synthetic ADB fixture".utf8).write(to: adb)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
        runner.base.adbPath = adb.path
        let installer = try RecoveryInstaller(adb: adb, serial: "GLASS123", runner: runner,
                                              fixtureRecoveryHash: sha(RecoveryFake.recovery), fixtureFstabHash: sha(RecoveryFake.fstab))
        let android = try await installer.inspectAndroid(); runner.base.inRecovery = true
        let recovery = try await installer.inspectRecovery(after: android)
        runner.base.addBackup(name: "current", files: backupFiles(extraPart: true))
        let backup = try await installer.copyBackup(named: "current", recovery: recovery, to: root.appendingPathComponent("copy"))
        let firmware = root.appendingPathComponent("firmware.zip")
        try makeZIP(backupFiles().sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, mode: 0x81a40000).write(to: firmware)
        runner.originalBackup = runner.base.files.filter { $0.key.contains("/current/") }
        runner.armed = true
        return Context(installer: installer, android: android, recovery: recovery, firmware: firmware, backup: backup)
    }
    private func prepare(_ context: Context) async throws -> RecoveryPreparation {
        try await context.installer.prepare(firmwareURL: context.firmware, expectedSHA256: RecoveryArchive.hash(context.firmware),
                                           android: context.android, recovery: context.recovery,
                                           offDeviceBackupConfirmed: true, backupCopy: context.backup)
    }
    private func assertSafe(_ runner: FaultRunner, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(runner.base.files.filter { $0.key.contains("/current/") }, runner.originalBackup, "Existing backup changed", file: file, line: line)
        for command in runner.commands {
            XCTAssertNotEqual(command.executable.lastPathComponent, "fastboot", file: file, line: line)
            let args = FaultRunner.arguments(command)
            guard command.executable.path == runner.base.adbPath else {
                XCTAssertTrue(["/usr/bin/zipinfo", "/usr/bin/ditto"].contains(command.executable.path), file: file, line: line); continue
            }
            XCTAssertFalse(args.contains { arg in ["flash", "erase", "unlock", "format", "nandroid", "extendedcommand", "reboot"].contains(arg) }, file: file, line: line)
            if args.first == "push" {
                XCTAssertNotNil(args.last?.range(of: "^/data/media/0/clockworkmod/backup/\\.explorerlink-[a-f0-9-]{36}\\.partial/[a-z0-9.]+$", options: .regularExpression), file: file, line: line)
            }
            if args.first == "shell" {
                let script = args[1]
                let knownPrefixes = ["getprop ", "dumpsys battery", "/sbin/id -u", "/sbin/readlink -f ", "/sbin/cat /proc/mounts", "/sbin/df -k ", "/sbin/ls -1 ", "/sbin/ls -1A ", "/sbin/stat -c %s ", "/sbin/sha256sum ", "[ ", "/sbin/mkdir -p ", "/sbin/mv "]
                XCTAssertTrue(knownPrefixes.contains { script.hasPrefix($0) }, "Unknown shell operation: \(script)", file: file, line: line)
                if script.hasPrefix("/sbin/mkdir -p ") {
                    XCTAssertNotNil(script.range(of: "^/sbin/mkdir -p /data/media/0/clockworkmod/backup && /sbin/mkdir /data/media/0/clockworkmod/backup/\\.explorerlink-[a-f0-9-]{36}\\.partial && echo EXPLORER_OK$", options: .regularExpression), file: file, line: line)
                }
                XCTAssertFalse(["rm ", "dd ", "nandroid ", "flash ", "erase ", "mkfs", "mount "].contains { script.contains($0) }, file: file, line: line)
                if script.hasPrefix("/sbin/mv ") {
                    XCTAssertTrue(script.contains("/clockworkmod/backup/.explorerlink-") && script.contains(".partial /data/media/0/clockworkmod/backup/explorerlink-"), file: file, line: line)
                }
            }
        }
    }
    private func expectFailure(_ context: Context, runner: FaultRunner, file: StaticString = #filePath, line: UInt = #line) async {
        do { let result = try await prepare(context); XCTFail("Unexpected \(result.status)", file: file, line: line) } catch { }
        assertSafe(runner, file: file, line: line)
    }

    func testSerialDisconnectReplacementAndUnauthorizedAfterUploadStopBeforeSecondPush() async throws {
        for state in ["missing", "other", "unauthorized", "duplicate"] {
            let runner = FaultRunner(); let context = try await context(runner)
            runner.override = { command in
                guard runner.base.pushCount > 0, FaultRunner.arguments(command) == ["devices"] else { return nil }
                let rows = state == "missing" ? "" : state == "other" ? "OTHER123\trecovery\n" : state == "duplicate" ? "GLASS123\trecovery\nGLASS123\trecovery\n" : "GLASS123\tunauthorized\n"
                return runner.result(command, "List of devices attached\n" + rows)
            }
            await expectFailure(context, runner: runner)
            XCTAssertEqual(runner.base.pushCount, 1); XCTAssertFalse(runner.base.published)
        }
    }
    func testStorageRecoveryAndRootChangesAfterUploadStopBeforeSecondPush() async throws {
        for fault in ["free", "mount-device", "mount-ro", "mount-duplicate", "root", "fstab", "recovery", "storage"] {
            let runner = FaultRunner(); let context = try await context(runner)
            runner.override = { command in
                guard runner.base.pushCount > 0 else { return nil }
                let args = FaultRunner.arguments(command), script = FaultRunner.arguments(command).last ?? ""
                if args.first == "pull", args[1] == (fault == "fstab" ? "/etc/recovery.fstab" : "/sbin/recovery"), ["fstab", "recovery"].contains(fault) {
                    try Data("changed recovery file".utf8).write(to: URL(fileURLWithPath: args[2])); return runner.result(command)
                }
                if fault == "free", script.hasPrefix("/sbin/df ") { return runner.result(command, "Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/block/mmcblk0p12 100 99 1 99% /data") }
                if fault.hasPrefix("mount"), script == "/sbin/cat /proc/mounts" {
                    return runner.result(command, fault == "mount-device" ? "/dev/block/mmcblk0p13 /data ext4 rw 0 0" : fault == "mount-ro" ? "/dev/block/mmcblk0p12 /data ext4 ro 0 0" : "/dev/block/mmcblk0p12 /data ext4 rw 0 0\n/dev/block/mmcblk0p12 /data ext4 rw 0 0")
                }
                if fault == "root", script == "/sbin/id -u" { return runner.result(command, "2000") }
                if fault == "storage", script == "/sbin/readlink -f /sdcard" { return runner.result(command, "/data/media") }
                return nil
            }
            await expectFailure(context, runner: runner)
            XCTAssertEqual(runner.base.pushCount, 1); XCTAssertFalse(runner.base.published)
        }
    }
    func testTimeoutAndCancellationAtEveryUploadAndPublicationBoundaryFailClosed() async throws {
        // Ten distinct file copies, plus directory creation and publication: each has independent partial state.
        for mode in ["timeout", "cancel"] {
            for boundary in 0...11 {
                let runner = FaultRunner(); let context = try await context(runner)
                var index = 0
                runner.override = { command in
                    let args = FaultRunner.arguments(command), script = args.last ?? ""
                    let write = args.first == "push" || script.hasPrefix("/sbin/mkdir -p ") || script.hasPrefix("/sbin/mv ")
                    guard write else { return nil }; defer { index += 1 }
                    guard index == boundary else { return nil }
                    if mode == "timeout" { throw ExplorerFlashError.timedOut(command) }
                    throw CancellationError()
                }
                await expectFailure(context, runner: runner)
                XCTAssertEqual(index, boundary + 1); XCTAssertFalse(runner.base.published)
                XCTAssertEqual(runner.base.pushCount, max(0, min(10, boundary - 1)))
            }
        }
    }
    func testInterruptedPushAndPublishFailuresNeverReturnPrepared() async throws {
        for fault in ["push-partial", "publish-no-marker", "publish-error", "published-corrupt"] {
            let runner = FaultRunner(); let context = try await context(runner)
            runner.override = { command in
                let args = FaultRunner.arguments(command)
                if args.first == "shell", args[1].hasPrefix("/sbin/mv "), fault.hasPrefix("publish-") {
                    return runner.result(command, "", fault == "publish-error" ? 1 : 0)
                }
                return nil
            }
            runner.after = { command in
                let args = FaultRunner.arguments(command)
                if fault == "push-partial", args.first == "push" { runner.base.files[args[2]] = Data("partial".utf8) }
                if fault == "published-corrupt", args.first == "shell", args[1].hasPrefix("/sbin/mv ") {
                    let final = args[1].split(separator: " ")[2]
                    runner.base.files[String(final) + "/boot.img"] = Data("corrupt".utf8)
                }
            }
            await expectFailure(context, runner: runner)
            XCTAssertEqual(runner.base.published, fault == "published-corrupt")
            XCTAssertEqual(runner.base.pushCount, fault == "push-partial" ? 1 : 10)
        }
    }
    func testChangedExecutableDuringFirstUploadPreventsFurtherCommands() async throws {
        let runner = FaultRunner(); let context = try await context(runner)
        var atReplacement = 0
        runner.after = { command in
            if FaultRunner.arguments(command).first == "push" {
                atReplacement = runner.base.commands.count
                try Data("replaced adb".utf8).write(to: URL(fileURLWithPath: runner.base.adbPath))
            }
        }
        await expectFailure(context, runner: runner)
        XCTAssertEqual(runner.base.commands.count, atReplacement); XCTAssertEqual(runner.base.pushCount, 1)
    }
    func testActualTaskCancellationUnblocksStalledProbeUploadAndPublish() async throws {
        for boundary in ["probe", "upload", "publish"] {
            let runner = FaultRunner(); let context = try await context(runner)
            let reached = expectation(description: "stalled \(boundary)")
            runner.stall = { command in
                let args = FaultRunner.arguments(command)
                return boundary == "probe" ? args == ["devices"] : boundary == "upload" ? args.first == "push" : (args.last?.hasPrefix("/sbin/mv ") ?? false)
            }
            runner.didStall = { reached.fulfill() }
            let task = Task { try await self.prepare(context) }
            await fulfillment(of: [reached], timeout: 3)
            task.cancel()
            do { _ = try await task.value; XCTFail("stalled task returned Prepared") } catch is CancellationError { } catch { XCTFail("Unexpected cancellation error: \(error)") }
            XCTAssertFalse(runner.base.published); assertSafe(runner)
        }
    }
    func testCancelledPreparationCanRetryOnlyInANewOwnedPartialFolder() async throws {
        let runner = FaultRunner(); let context = try await context(runner)
        let reached = expectation(description: "first upload blocked")
        runner.stall = { FaultRunner.arguments($0).first == "push" }
        runner.didStall = { reached.fulfill() }
        let task = Task { try await self.prepare(context) }
        await fulfillment(of: [reached], timeout: 3); task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled preparation succeeded") } catch { }
        runner.stall = nil; runner.didStall = nil
        let result = try await prepare(context)
        XCTAssertEqual(result.status, "Prepared")
        let folders = runner.base.commands.compactMap { command -> String? in
            let args = FaultRunner.arguments(command)
            guard args.first == "shell", args[1].hasPrefix("/sbin/mkdir -p ") else { return nil }
            return args[1].split(separator: " ").first(where: { $0.hasSuffix(".partial") }).map(String.init)
        }
        XCTAssertEqual(folders.count, 2); XCTAssertEqual(Set(folders).count, 2)
        assertSafe(runner)
    }
    func testUnknownBatteryFieldsAndBoundsRejectWithoutDeviceMutation() throws {
        let good = "present: true\nhealth: 2\nlevel: 90\nscale: 100\ntemperature: 250"
        for value in [good.replacingOccurrences(of: "health: 2", with: "health: 3"),
                      good.replacingOccurrences(of: "level: 90", with: "level: 69"),
                      good.replacingOccurrences(of: "scale: 100", with: "scale: 200"),
                      good.replacingOccurrences(of: "temperature: 250", with: "temperature: 451"),
                      good.replacingOccurrences(of: "temperature: 250", with: "temperature: -1"),
                      good.replacingOccurrences(of: "present: true", with: "present: false"), good + "\nlevel: 90"] {
            XCTAssertThrowsError(try RecoveryInstaller.batteryPercent(value))
        }
    }
    func testRawSparseImageAndAdversarialZIPHeadersRejectedBeforeExtractor() throws {
        let valid = makeZIP(backupFiles().sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, mode: 0x81a40000)
        let central = try XCTUnwrap(valid.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
        var bad: [Data] = [Data([0x3a, 0xff, 0x26, 0xed]) + Data(repeating: 0, count: 64), Data("MZ".utf8) + valid, valid + Data([1])]
        // Encryption, streaming descriptor, unsupported codec, ZIP64, nonregular mode,
        // overlapping local headers, and local/central size or name disagreements.
        for (offset, value, length) in [(central + 8, UInt32(1), 2), (central + 8, 8, 2), (central + 10, 93, 2),
                                        (central + 24, UInt32.max, 4), (central + 38, 0xa1ff0000, 4),
                                        (central + 42, 1, 4), (22, 0, 4), (30, 0, 1)] {
            var bytes = valid
            for j in 0..<length { bytes[offset + j] = UInt8((value >> (8 * j)) & 255) }
            bad.append(bytes)
        }
        for (index, bytes) in bad.enumerated() {
            let file = directory.appendingPathComponent("bad-\(index).zip"); try bytes.write(to: file)
            XCTAssertThrowsError(try RecoveryArchive.inspectZIP(file), "Accepted archive case \(index)")
        }
        for name in ["../boot.img", "/boot.img", "a/boot.img", "boot.img\u{0}", "boot.img ", "boot.img;id"] {
            var entries = backupFiles().sorted { $0.key < $1.key }.map { ($0.key, $0.value) }; entries[0].0 = name
            let file = directory.appendingPathComponent(UUID().uuidString + ".zip")
            try makeZIP(entries, mode: 0x81a40000).write(to: file)
            XCTAssertThrowsError(try RecoveryArchive.inspectZIP(file))
        }
    }
    func testLocalFileBoundsDirectoriesAndLinksRejectWithoutReadingSparsePayload() throws {
        let sparse = directory.appendingPathComponent("oversized")
        XCTAssertTrue(FileManager.default.createFile(atPath: sparse.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sparse); try handle.truncate(atOffset: 1025); try handle.close()
        XCTAssertThrowsError(try RecoveryLocalFile.read(sparse, maximumBytes: 1024))
        XCTAssertThrowsError(try RecoveryLocalFile.read(directory))
        let link = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sparse)
        XCTAssertThrowsError(try RecoveryLocalFile.read(link))
    }
    func testFIFOReplacementRejectsWithoutBlocking() throws {
        let fifo = directory.appendingPathComponent("replaced-backup.fifo")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        // Regression fail-safe: an unfixed blocking open is released after 0.5 s,
        // so a test failure never strands the test process waiting on a FIFO.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let descriptor = Darwin.open(fifo.path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
            if descriptor >= 0 { Darwin.close(descriptor) }
        }
        let start = ContinuousClock.now
        XCTAssertThrowsError(try RecoveryLocalFile.read(fifo))
        XCTAssertLessThan(start.duration(to: .now), .milliseconds(250))
    }
    func testMissingBackupPartitionAndArchivePayloadDamageStopBeforeStaging() async throws {
        let runner = FaultRunner(); let context = try await context(runner)
        var incomplete = backupFiles(); incomplete.removeValue(forKey: "data.ext4.tar.a")
        runner.base.addBackup(name: "incomplete", files: incomplete)
        do { _ = try await context.installer.copyBackup(named: "incomplete", recovery: context.recovery, to: directory.appendingPathComponent("incomplete-copy")); XCTFail("Accepted missing data partition") } catch { }
        XCTAssertEqual(runner.base.pushCount, 0)
        for damage in ["crc", "md5"] {
            var files = backupFiles()
            if damage == "md5" { files["boot.img"] = Data("changed boot with stale nandroid.md5".utf8) }
            var bytes = makeZIP(files.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }, mode: 0x81a40000)
            if damage == "crc" { bytes[38] ^= 1 } // First entry boot.img data; local/central CRC is unchanged.
            try bytes.write(to: context.firmware)
            await expectFailure(context, runner: runner)
            XCTAssertEqual(runner.base.pushCount, 0); XCTAssertFalse(runner.base.published)
        }
    }
    func testBackupRemovedDuringUploadMustNotPublishPreparedFolder() async throws {
        let runner = FaultRunner(); let context = try await context(runner)
        runner.after = { command in
            if FaultRunner.arguments(command).first == "push", runner.base.pushCount == 1 {
                try FileManager.default.removeItem(at: context.backup.localDirectory.appendingPathComponent("data.ext4.tar.a"))
            }
        }
        await expectFailure(context, runner: runner)
        XCTAssertFalse(runner.base.published)
    }
    func testCancelledFinalVerificationMustNotReturnPrepared() async throws {
        let runner = FaultRunner(); let context = try await context(runner)
        runner.after = { command in
            let args = FaultRunner.arguments(command)
            if runner.base.published, args.last?.hasSuffix("/system.ext4.tar.a") == true,
               args.last?.hasPrefix("/sbin/sha256sum ") == true { withUnsafeCurrentTask { $0?.cancel() } }
        }
        // Isolate cancellation from XCTest's task and cleanup.
        let task = Task { try await self.prepare(context) }
        do { _ = try await task.value; XCTFail("Prepared returned after cancellation") } catch { }
        assertSafe(runner)
    }
}

private final class FaultRunner: ProcessRunning, @unchecked Sendable {
    let base = RecoveryFake()
    var commands: [ProcessCommand] = []
    var armed = false
    var originalBackup: [String: Data] = [:]
    var override: ((ProcessCommand) throws -> ProcessResult?)?
    var after: ((ProcessCommand) throws -> Void)?
    var stall: ((ProcessCommand) -> Bool)?
    var didStall: (() -> Void)?
    static func arguments(_ command: ProcessCommand) -> [String] {
        command.arguments.first == "-s" ? Array(command.arguments.dropFirst(2)) : command.arguments
    }
    func result(_ command: ProcessCommand, _ output: String = "", _ status: Int32 = 0) -> ProcessResult {
        .init(command: command, exitCode: status, stdout: output, stderr: "")
    }
    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        commands.append(command)
        if armed, stall?(command) == true { didStall?(); try await Task.sleep(for: .seconds(30)) }
        if armed, let result = try override?(command) { return result }
        let result = try await base.run(command)
        if armed { try after?(command) }
        return result
    }
}
