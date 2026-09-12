import CryptoKit
import Foundation
import XCTest
@testable import ExplorerFlashCore

final class RecoveryInstallTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("recovery-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    private func installer(_ fake: RecoveryFake) throws -> RecoveryInstaller {
        let adb = directory.appendingPathComponent("adb")
        if !FileManager.default.fileExists(atPath: adb.path) { try Data("synthetic executable never run".utf8).write(to: adb); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path) }
        fake.adbPath = adb.path
        return try RecoveryInstaller(adb: adb, serial: "GLASS123", runner: fake,
                              fixtureRecoveryHash: sha(RecoveryFake.recovery), fixtureFstabHash: sha(RecoveryFake.fstab))
    }
    private func session(_ fake: RecoveryFake) async throws -> (RecoveryInstaller, RecoveryAndroidObservation, RecoveryObservation) {
        let installer = try installer(fake)
        let android = try await installer.inspectAndroid()
        fake.inRecovery = true
        return (installer, android, try await installer.inspectRecovery(after: android))
    }
    private func archive(_ items: [(String, Data)]? = nil, mode: UInt32 = 0x81a40000) throws -> URL {
        let path = directory.appendingPathComponent(UUID().uuidString + ".zip")
        try makeZIP(items ?? backupFiles().sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }, mode: mode).write(to: path)
        return path
    }
    private func prepare(_ fake: RecoveryFake) async throws -> RecoveryPreparation {
        let (installer, android, recovery) = try await session(fake)
        let file = try archive()
        return try await installer.prepare(firmwareURL: file, expectedSHA256: RecoveryArchive.hash(file), android: android,
                                           recovery: recovery, offDeviceBackupConfirmed: true)
    }
    func testValidPreparationChecksEveryFileAndPublishesOnlyAfterAllHashes() async throws {
        let fake = RecoveryFake(); let result = try await prepare(fake)
        XCTAssertEqual(result.status, "Prepared"); XCTAssertEqual(result.verifiedFileCount, 10)
        XCTAssertTrue(result.recoveryFolder.hasPrefix("/data/media/0/clockworkmod/backup/explorerlink-"))
        XCTAssertTrue(fake.published); XCTAssertEqual(fake.pushCount, 10)
        XCTAssertEqual(fake.hashesBeforePublish, 20)
        XCTAssertFalse(fake.commands.contains { $0.executable.lastPathComponent == "fastboot" || $0.arguments.contains { $0.contains("nandroid restore") || $0.contains("rm ") || $0.contains("flash ") || $0.contains("extendedcommand") || $0.contains("oem unlock") } })
    }
    func testWrongAndroidIdentityAndBatteryRejectWithoutMutation() async throws {
        for fault in ["identity", "battery", "unknown-battery"] {
            let fake = RecoveryFake(); fake.fault = fault; let installer = try installer(fake)
            do { _ = try await installer.inspectAndroid(); XCTFail("accepted \(fault)") } catch { }
            XCTAssertEqual(fake.mutations, 0)
        }
    }
    func testRebootRequiresFreshSameIdentityAndInstallerObservation() async throws {
        let fake = RecoveryFake(); let installer = try installer(fake); let observation = try await installer.inspectAndroid()
        fake.fault = "identity"
        do { try await installer.rebootToRecovery(from: observation); XCTFail("rebooted wrong device") } catch { }
        XCTAssertFalse(fake.commands.contains { $0.arguments.contains("reboot") })
        fake.fault = ""
        let other = try self.installer(fake)
        do { try await other.rebootToRecovery(from: observation); XCTFail("accepted another instance") } catch { }
        try await installer.rebootToRecovery(from: observation)
        XCTAssertTrue(fake.inRecovery)
    }
    func testUnknownRecoveryStopsBeforeStaging() async throws {
        let fake = RecoveryFake(); fake.fault = "recovery"
        do { _ = try await prepare(fake); XCTFail("accepted unknown recovery") } catch { }
        XCTAssertEqual(fake.mutations, 0)
    }
    func testLowSpaceAndCollisionStopBeforeAnyFileCopy() async throws {
        for fault in ["space", "collision", "symlink"] {
            let fake = RecoveryFake(); fake.fault = fault
            do { _ = try await prepare(fake); XCTFail("accepted \(fault)") } catch { }
            XCTAssertEqual(fake.pushCount, 0); XCTAssertFalse(fake.published)
        }
    }
    func testDisconnectPathDriftAndChecksumFailurePreservePartialWithoutPublish() async throws {
        for fault in ["disconnect-after-push", "path-drift", "remote-hash", "recovery-after-push"] {
            let fake = RecoveryFake(); fake.fault = fault
            do { _ = try await prepare(fake); XCTFail("accepted \(fault)") } catch { }
            XCTAssertEqual(fake.pushCount, 1); XCTAssertFalse(fake.published)
            XCTAssertTrue(fake.hasPartial); XCTAssertFalse(fake.commands.contains { $0.arguments.joined(separator: " ").contains("rm ") })
        }
    }
    func testArchiveHashAndBackupConfirmationFailBeforeStaging() async throws {
        let fake = RecoveryFake(); let (installer, android, recovery) = try await session(fake); let file = try archive()
        for confirmed in [false, true] {
            do { _ = try await installer.prepare(firmwareURL: file, expectedSHA256: String(repeating: "0", count: 64), android: android, recovery: recovery, offDeviceBackupConfirmed: confirmed); XCTFail("accepted") } catch { }
        }
        XCTAssertEqual(fake.mutations, 0)
    }
    func testStrictZIPRejectsTraversalLinksDuplicateAndLocalHeaderMismatch() throws {
        var items = backupFiles().sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) }
        let valid = try archive(items); XCTAssertEqual(try RecoveryArchive.inspectZIP(valid).count, 10)
        items[0].0 = "../boot.img"; XCTAssertThrowsError(try RecoveryArchive.inspectZIP(archive(items)))
        items[0].0 = items[1].0; XCTAssertThrowsError(try RecoveryArchive.inspectZIP(archive(items)))
        XCTAssertThrowsError(try RecoveryArchive.inspectZIP(archive(mode: 0xa1ff0000)))
        var bytes = try Data(contentsOf: valid); bytes[30] ^= 1; let changed = directory.appendingPathComponent("changed.zip"); try bytes.write(to: changed)
        XCTAssertThrowsError(try RecoveryArchive.inspectZIP(changed))
    }
    func testLocalFirmwareLayoutWhenRequested() async throws {
        guard let path = ProcessInfo.processInfo.environment["EXPLORER_RECOVERY_ARCHIVE"] else { throw XCTSkip("Optional local firmware layout check") }
        let source = URL(fileURLWithPath: path)
        XCTAssertEqual(try RecoveryArchive.inspectZIP(source).count, 10)
        // Exercise the production snapshot, extraction and MD5/SHA verification
        // against the real local ZIP. ProcessRunner runs archive tools only;
        // this test never creates an installer or invokes ADB/Fastboot.
        let archive = try await RecoveryArchive.open(source, expectedSHA256: RecoveryArchive.hash(source), runner: ProcessRunner())
        defer { archive.cleanup() }
        XCTAssertEqual(archive.entries.count, 10)
        XCTAssertGreaterThan(archive.totalBytes, 0)
    }
    func testSplitTarMarkerChecksumsRequireEmptyMarkersAndCompletePayloads() async throws {
        for variant in ["valid", "bad-marker-md5", "nonempty-marker", "unchecked-nonempty-marker", "duplicate", "missing-payload", "unexpected"] {
            var files = backupFiles()
            let empty = "d41d8cd98f00b204e9800998ecf8427e"
            var lines = String(decoding: files["nandroid.md5"]!, as: UTF8.self).split(separator: "\n").map(String.init)
            if variant != "unchecked-nonempty-marker" {
                lines += ["cache.ext4.tar", "data.ext4.tar", "system.ext4.tar"].map { empty + "  " + $0 }
            }
            if variant == "bad-marker-md5" { lines[lines.count - 1] = String(repeating: "0", count: 32) + "  system.ext4.tar" }
            if variant == "nonempty-marker" || variant == "unchecked-nonempty-marker" { files["system.ext4.tar"] = Data("unexpected payload".utf8) }
            if variant == "duplicate" { lines.append(lines[0]) }
            if variant == "missing-payload" { lines.removeAll { $0.hasSuffix("  boot.img") } }
            if variant == "unexpected" { lines.append(empty + "  recovery.log") }
            files["nandroid.md5"] = Data((lines.joined(separator: "\n") + "\n").utf8)
            let source = try archive(files.sorted(by: { $0.key < $1.key }).map { ($0.key, $0.value) })
            do {
                let opened = try await RecoveryArchive.open(source, expectedSHA256: RecoveryArchive.hash(source), runner: ProcessRunner())
                defer { opened.cleanup() }
                XCTAssertEqual(variant, "valid", "Accepted \(variant)")
            } catch {
                XCTAssertNotEqual(variant, "valid", "Rejected real CWM marker layout: \(error)")
            }
        }
    }
    func testOffDeviceBackupSupportsSplitPartsAndVerifiesAllFiles() async throws {
        let fake = RecoveryFake(); let (installer, _, recovery) = try await session(fake)
        fake.addBackup(name: "2026-09-12.12.30.00", files: backupFiles(extraPart: true))
        let backups = try await installer.listBackups(recovery: recovery)
        XCTAssertEqual(backups, ["2026-09-12.12.30.00"])
        let destination = directory.appendingPathComponent("off-device")
        let result = try await installer.copyBackup(named: "2026-09-12.12.30.00", recovery: recovery, to: destination)
        XCTAssertEqual(result.verifiedFileCount, 11)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("data.ext4.tar.b")), Data("second part".utf8))
        XCTAssertEqual(fake.mutations, 0)
    }
    func testOffDeviceBackupRejectsTraversalUnknownFilesAndMD5Mismatch() async throws {
        for fault in ["traversal", "extra-file", "bad-md5"] {
            let fake = RecoveryFake(); let (installer, _, recovery) = try await session(fake)
            var files = backupFiles()
            if fault == "extra-file" { files["unknown.bin"] = Data([1]) }
            if fault == "bad-md5" { files["boot.img"] = Data("changed".utf8) }
            fake.addBackup(name: "current", files: files)
            do { _ = try await installer.copyBackup(named: fault == "traversal" ? "../current" : "current", recovery: recovery, to: directory.appendingPathComponent(fault)); XCTFail("accepted \(fault)") } catch { }
            XCTAssertEqual(fake.mutations, 0)
        }
    }
    func testBackupRevalidationRejectsCorruptDeletedReplacedAndLinkedFilesBeforeStaging() async throws {
        for fault in ["corrupt", "delete", "replace", "symlink", "directory", "extra"] {
            let fake = RecoveryFake(); let (installer, android, recovery) = try await session(fake)
            fake.addBackup(name: "current", files: backupFiles())
            let destination = directory.appendingPathComponent(fault)
            let copy = try await installer.copyBackup(named: "current", recovery: recovery, to: destination)
            try await installer.revalidateBackup(copy)
            let file = destination.appendingPathComponent("boot.img")
            switch fault {
            case "corrupt": try Data("changed contents".utf8).write(to: file)
            case "delete": try FileManager.default.removeItem(at: file)
            case "replace":
                let data = try Data(contentsOf: file)
                try FileManager.default.removeItem(at: file); try data.write(to: file)
            case "symlink":
                let elsewhere = directory.appendingPathComponent("elsewhere")
                try FileManager.default.moveItem(at: file, to: elsewhere)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
            case "directory":
                try FileManager.default.moveItem(at: destination, to: directory.appendingPathComponent("old-copy"))
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
            default: try Data([1]).write(to: destination.appendingPathComponent("unexpected"))
            }
            do { try await installer.revalidateBackup(copy); XCTFail("accepted \(fault)") } catch { }
            let zip = try archive()
            do { _ = try await installer.prepare(firmwareURL: zip, expectedSHA256: RecoveryArchive.hash(zip), android: android,
                                                recovery: recovery, offDeviceBackupConfirmed: true, backupCopy: copy)
                XCTFail("staged after \(fault)")
            } catch { }
            XCTAssertEqual(fake.pushCount, 0); XCTAssertFalse(fake.published)
        }
    }
    func testBackupReceiptIsOwnerBoundAndAllowsUnchangedPreparation() async throws {
        let fake = RecoveryFake(); let (installer, android, recovery) = try await session(fake)
        fake.addBackup(name: "current", files: backupFiles())
        let copy = try await installer.copyBackup(named: "current", recovery: recovery, to: directory.appendingPathComponent("copy"))
        let other = try self.installer(fake)
        do { try await other.revalidateBackup(copy); XCTFail("accepted another owner") } catch { }
        let zip = try archive()
        let result = try await installer.prepare(firmwareURL: zip, expectedSHA256: RecoveryArchive.hash(zip), android: android,
                                                recovery: recovery, offDeviceBackupConfirmed: true, backupCopy: copy)
        XCTAssertEqual(result.status, "Prepared"); XCTAssertEqual(fake.pushCount, 10)
    }
    func testADBReplacementStopsBeforeAnyFurtherCommand() async throws {
        for replacement in [false, true] {
            let fake = RecoveryFake(); let installer = try installer(fake)
            let android = try await installer.inspectAndroid(); let before = fake.commands.count
            let adb = directory.appendingPathComponent("adb")
            if replacement {
                let data = try Data(contentsOf: adb)
                try FileManager.default.removeItem(at: adb); try data.write(to: adb)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
            } else { try Data("changed executable".utf8).write(to: adb) }
            do { try await installer.rebootToRecovery(from: android); XCTFail("executed changed adb") } catch { }
            XCTAssertEqual(fake.commands.count, before); XCTAssertFalse(fake.inRecovery)
        }
    }
    func testCapacityParserRejectsMalformedAndOverflow() throws {
        XCTAssertEqual(try RecoveryInstaller.freeBytes("Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/block/mmcblk0p12 100 20 80 20% /data"), 80 * 1024)
        for bad in ["", "header\nunknown", "header\n/dev/x 1 1 18446744073709551615 1% /data"] { XCTAssertThrowsError(try RecoveryInstaller.freeBytes(bad)) }
    }
}

final class RecoveryFake: ProcessRunning, @unchecked Sendable {
    static let recovery = Data("synthetic pinned recovery".utf8)
    static let fstab = Data("synthetic pinned fstab".utf8)
    var commands: [ProcessCommand] = []
    var adbPath = ""
    var inRecovery = false, published = false, hasPartial = false
    var fault = "", pushCount = 0, mutations = 0, hashesBeforePublish = 0
    var files: [String: Data] = [:]
    var backups: [String] = []
    func addBackup(name: String, files: [String: Data]) {
        backups.append(name)
        for (file, data) in files { self.files["/data/media/0/clockworkmod/backup/" + name + "/" + file] = data }
    }
    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        commands.append(command)
        if command.executable.path != adbPath {
            guard ["/usr/bin/zipinfo", "/usr/bin/ditto"].contains(command.executable.path) else { throw NSError(domain: "unexpected executable", code: 1) }
            return try await ProcessRunner().run(command)
        }
        var args = command.arguments
        if args.first == "-s" { guard args[1] == "GLASS123" else { throw NSError(domain: "wrong serial", code: 1) }; args.removeFirst(2) }
        func result(_ output: String = "", _ code: Int32 = 0) -> ProcessResult { .init(command: command, exitCode: code, stdout: output, stderr: "") }
        if args == ["devices"] { return result(fault == "disconnect-after-push" && pushCount > 0 ? "List of devices attached\n" : "List of devices attached\nGLASS123\t\(inRecovery ? "recovery" : "device")\n") }
        if args == ["reboot", "recovery"] { inRecovery = true; mutations += 1; return result() }
        if args.first == "pull" {
            let data: Data
            if args[1] == "/sbin/recovery" { data = fault == "recovery" || (fault == "recovery-after-push" && pushCount > 0) ? Data("wrong recovery".utf8) : Self.recovery }
            else if args[1] == "/etc/recovery.fstab" { data = Self.fstab }
            else { guard let found = files[args[1]] else { return result("", 1) }; data = found }
            try data.write(to: URL(fileURLWithPath: args[2])); return result()
        }
        if args.first == "push" { files[args[2]] = try Data(contentsOf: URL(fileURLWithPath: args[1])); pushCount += 1; mutations += 1; return result() }
        guard args.first == "shell", args.count == 2 else { throw NSError(domain: "unexpected adb", code: 1) }
        let script = args[1]
        switch script {
        case "getprop ro.product.model": return result(fault == "identity" ? "Enterprise Edition 2" : "Glass 1")
        case "getprop ro.product.device": return result("glass-1")
        case "getprop ro.build.version.sdk": return result("19")
        case "getprop ro.build.version.glass": return result("XE24")
        case "getprop init.svc.recovery": return result(inRecovery ? "running" : "stopped")
        case "dumpsys battery": return result(fault == "unknown-battery" ? "" : "present: true\nhealth: 2\nlevel: \(fault == "battery" ? 20 : 90)\nscale: 100\ntemperature: 250")
        case "/sbin/id -u": return result("0")
        case "/sbin/readlink -f /sdcard": return result(fault == "path-drift" && pushCount > 0 ? "/data/media" : "/data/media/0")
        case "/sbin/readlink -f /dev/block/platform/omap/omap_hsmmc.1/by-name/userdata": return result("/dev/block/mmcblk0p12")
        case "/sbin/cat /proc/mounts": return result("/dev/block/mmcblk0p12 /data ext4 rw,nosuid,nodev 0 0")
        default: break
        }
        if script.hasPrefix("/sbin/df -k ") { return result("Filesystem 1K-blocks Used Available Use% Mounted on\n/dev/block/mmcblk0p12 16000000 1000 \(fault == "space" ? 1 : 15000000) 1% /data") }
        if script.hasPrefix("/sbin/ls -1 ") { return result(backups.joined(separator: "\n")) }
        if script.hasPrefix("/sbin/ls -1A ") { let prefix = String(script.dropFirst("/sbin/ls -1A ".count)) + "/"; return result(files.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }.sorted().joined(separator: "\n")) }
        if script.hasPrefix("/sbin/stat -c %s ") { let path = String(script.dropFirst("/sbin/stat -c %s ".count)); return result(String(files[path]?.count ?? -1)) }
        if script.hasPrefix("/sbin/sha256sum ") {
            let path = String(script.dropFirst("/sbin/sha256sum ".count)); guard let data = files[path] else { return result("", 1) }
            if path.contains(".partial/") { hashesBeforePublish += 1 }
            return result((fault == "remote-hash" ? String(repeating: "0", count: 64) : sha(data)) + "  " + path)
        }
        if script.hasPrefix("/sbin/mkdir -p ") {
            mutations += 1
            if fault == "collision" { return result("") }
            hasPartial = true; return result("EXPLORER_OK")
        }
        if script.hasPrefix("/sbin/mv ") {
            mutations += 1; published = true
            let fields = script.split(separator: " "); let old = String(fields[1]), new = String(fields[2])
            for (path, data) in files where path.hasPrefix(old + "/") { files[new + path.dropFirst(old.count)] = data }
            return result("EXPLORER_OK")
        }
        if script.hasSuffix("&& echo EXPLORER_OK") { return result(fault == "symlink" ? "" : "EXPLORER_OK") }
        throw NSError(domain: "unexpected shell: " + script, code: 1)
    }
}

func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func backupFiles(extraPart: Bool = false) -> [String: Data] {
    var files = Dictionary(uniqueKeysWithValues: RecoveryArchive.names.map { ($0, Data(($0.hasSuffix(".tar") ? "" : "fixture " + $0).utf8)) })
    if extraPart { files["data.ext4.tar.b"] = Data("second part".utf8) }
    let checked = files.keys.filter { $0.hasSuffix(".img") || $0.hasSuffix(".a") || $0.hasSuffix(".b") }.sorted()
    files["nandroid.md5"] = Data(checked.map { name in Insecure.MD5.hash(data: files[name]!).map { String(format: "%02x", $0) }.joined() + "  " + name + "\n" }.joined().utf8)
    return files
}

func makeZIP(_ items: [(String, Data)], mode: UInt32) -> Data {
    var local = Data(), central = Data()
    func crc(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xffffffff
        for byte in data { value ^= UInt32(byte); for _ in 0..<8 { value = value & 1 != 0 ? (value >> 1) ^ 0xedb88320 : value >> 1 } }
        return value ^ 0xffffffff
    }
    for (name, contents) in items {
        let bytes = Data(name.utf8), offset = UInt32(local.count), checksum = crc(contents)
        local.le32(0x04034b50); local.le16(20); local.le16(0); local.le16(0); local.le16(0); local.le16(0)
        local.le32(checksum); local.le32(UInt32(contents.count)); local.le32(UInt32(contents.count)); local.le16(UInt16(bytes.count)); local.le16(0); local.append(bytes); local.append(contents)
        central.le32(0x02014b50); central.le16(0x0314); central.le16(20); central.le16(0); central.le16(0); central.le16(0); central.le16(0)
        central.le32(checksum); central.le32(UInt32(contents.count)); central.le32(UInt32(contents.count)); central.le16(UInt16(bytes.count)); central.le16(0); central.le16(0); central.le16(0); central.le16(0); central.le32(mode); central.le32(offset); central.append(bytes)
    }
    let start = UInt32(local.count); local.append(central)
    local.le32(0x06054b50); local.le16(0); local.le16(0); local.le16(UInt16(items.count)); local.le16(UInt16(items.count)); local.le32(UInt32(central.count)); local.le32(start); local.le16(0)
    return local
}
private extension Data {
    mutating func le16(_ n: UInt16) { append(UInt8(n & 255)); append(UInt8(n >> 8)) }
    mutating func le32(_ n: UInt32) { le16(UInt16(n & 65535)); le16(UInt16(n >> 16)) }
}
