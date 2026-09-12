import CryptoKit
import Foundation

public struct RecoveryAndroidObservation: Sendable {
    public let serial: String
    public let model: String
    public let device: String
    public let apiLevel: Int
    public let glassVersion: String
    public let batteryPercent: Int
    public let observedAt: Date
    fileprivate let owner: UUID
}

public struct RecoveryObservation: Sendable {
    public let serial: String
    public let storagePath: String
    public let freeBytes: UInt64
    public let observedAt: Date
    fileprivate let owner: UUID
    fileprivate let dataDevice: String
}

public struct RecoveryPreparation: Sendable {
    public let status = "Prepared"
    public let recoveryFolder: String
    public let verifiedFileCount: Int
}

public struct RecoveryBackupCopy: Sendable {
    public let localDirectory: URL
    public let verifiedFileCount: Int
    fileprivate let owner: UUID
    fileprivate let directoryIdentity: RecoveryLocalFile.Identity
    fileprivate let inventory: [String: RecoveryLocalFile]
}

/// Preparation only. No restore, recovery-image write, unlock, or persistent script API exists.
public actor RecoveryInstaller {
    public let adb: URL
    public let serial: String
    private let runner: any ProcessRunning
    private let adbReceipt: RecoveryLocalFile
    private let owner = UUID()
    private let recoveryHash: String
    private let fstabHash: String
    private var operationActive = false
    private static let reserveBytes: UInt64 = 256 * 1024 * 1024
    private static let maximumObservationAge: TimeInterval = 30 * 60
    private static let userdata = "/dev/block/platform/omap/omap_hsmmc.1/by-name/userdata"
    private static let stockRecoveryHash = "c5f2c522a5c8f2569828470bb8d67c6ae6082ca91964713b0904df1df991315c"
    private static let stockFstabHash = "f735746b62e92ad2c98824319e230e32a290910f7385dec6eece94d39de3703c"

    public init(adb: URL, serial: String, runner: any ProcessRunning = ProcessRunner()) throws {
        try DeviceParser.validate(serial: serial)
        guard FileManager.default.isExecutableFile(atPath: adb.path) else { throw Self.failure("ADB must be an executable regular file.") }
        self.adb = adb; self.serial = serial; self.runner = runner
        adbReceipt = try RecoveryLocalFile.read(adb, maximumBytes: 128 * 1024 * 1024)
        recoveryHash = Self.stockRecoveryHash; fstabHash = Self.stockFstabHash
    }

    // Internal fixture seam; the public initializer always uses the audited stock hashes.
    init(adb: URL, serial: String, runner: any ProcessRunning, fixtureRecoveryHash: String, fixtureFstabHash: String) throws {
        try DeviceParser.validate(serial: serial)
        guard FileManager.default.isExecutableFile(atPath: adb.path) else { throw Self.failure("ADB must be an executable regular file.") }
        self.adb = adb; self.serial = serial; self.runner = runner
        adbReceipt = try RecoveryLocalFile.read(adb, maximumBytes: 128 * 1024 * 1024)
        recoveryHash = fixtureRecoveryHash; fstabHash = fixtureFstabHash
    }

    public func inspectAndroid() async throws -> RecoveryAndroidObservation {
        try begin(); defer { operationActive = false }
        return try await androidObservation()
    }

    /// Explicit UI step; repeats identity and battery checks before sending the reboot.
    public func rebootToRecovery(from observation: RecoveryAndroidObservation) async throws {
        try begin(); defer { operationActive = false }
        try validate(observation)
        let current = try await androidObservation()
        guard current.model == observation.model, current.device == observation.device,
              current.apiLevel == observation.apiLevel, current.glassVersion == observation.glassVersion else {
            throw failure("Glass identity changed. Inspect it again.")
        }
        _ = try await runADB(["reboot", "recovery"], timeout: 30)
    }

    public func inspectRecovery(after android: RecoveryAndroidObservation) async throws -> RecoveryObservation {
        try begin(); defer { operationActive = false }
        try validate(android)
        return try await recoveryObservation()
    }

    /// Lists existing completed-looking folders; each selected backup is fully checked before copying.
    public func listBackups(recovery: RecoveryObservation) async throws -> [String] {
        try begin(); defer { operationActive = false }
        try validateRecoveryOwner(recovery)
        _ = try await recheck(recovery, requiredBytes: 0, enforceReserve: false)
        return try await backupNames(recovery)
    }

    /// The user creates the backup in CWM. This method only reads it into a new host directory.
    public func copyBackup(named name: String, recovery: RecoveryObservation, to destination: URL) async throws -> RecoveryBackupCopy {
        try begin(); defer { operationActive = false }
        try validateRecoveryOwner(recovery)
        guard Self.safeBackupName(name), !FileManager.default.fileExists(atPath: destination.path),
              (try? FileManager.default.destinationOfSymbolicLink(atPath: destination.path)) == nil else {
            throw failure("Choose a listed backup and a new, nonexistent local directory.")
        }
        _ = try await recheck(recovery, requiredBytes: 0, enforceReserve: false)
        guard try await backupNames(recovery).contains(name) else { throw failure("Backup selection changed.") }
        let remote = recovery.storagePath + "/clockworkmod/backup/" + name
        try await requireDirectory(remote)
        let listing = try await shell("/sbin/ls -1A " + remote)
        let names = listing.split(separator: "\n").map(String.init)
        guard !names.isEmpty, names.count <= 128, Set(names).count == names.count,
              names.contains("nandroid.md5"), names.allSatisfy(Self.safeBackupFile) else {
            throw failure("Requires a flat CWM tar backup. Links, deduplicated backups, and unknown files are not supported.")
        }
        var sizes: [String: UInt64] = [:]; var total: UInt64 = 0
        for file in names {
            let path = remote + "/" + file
            try await check("[ -f \(path) ] && [ ! -L \(path) ]")
            guard let size = UInt64(try await shell("/sbin/stat -c %s " + path)), size <= 8 * 1024 * 1024 * 1024 else { throw failure("Unknown or excessive backup file size.") }
            if file == "nandroid.md5", size > 16_384 { throw failure("Backup checksum file is too large.") }
            total += size; guard total <= 32 * 1024 * 1024 * 1024 else { throw failure("Backup exceeds 32 GiB.") }
            sizes[file] = size
        }
        let parent = destination.deletingLastPathComponent()
        let capacity = try FileManager.default.attributesOfFileSystem(forPath: parent.path)
        guard let free = capacity[.systemFreeSize] as? NSNumber, free.uint64Value >= total + Self.reserveBytes else { throw failure("Not enough Mac storage for the backup plus a 256 MiB reserve.") }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let directoryIdentity = try RecoveryLocalFile.directory(destination)
        var inventory: [String: RecoveryLocalFile] = [:]
        // A failed copy intentionally remains visible for diagnosis; never delete existing/partial backups.
        for file in ["nandroid.md5"] + names.filter({ $0 != "nandroid.md5" }).sorted() {
            _ = try await recheck(recovery, requiredBytes: 0, enforceReserve: false)
            try await requireDirectory(remote)
            let path = remote + "/" + file
            try await check("[ -f \(path) ] && [ ! -L \(path) ]")
            guard UInt64(try await shell("/sbin/stat -c %s " + path)) == sizes[file] else { throw failure("Backup file changed during copying.") }
            let before = try await remoteHash(path)
            let local = destination.appendingPathComponent(file)
            _ = try await runADB(["pull", path, local.path], timeout: 900)
            guard try RecoveryArchive.fileSize(local) == sizes[file], try RecoveryArchive.hash(local) == before,
                  try await remoteHash(path) == before else { throw failure("Backup copy verification failed. Partial local files were preserved.") }
            let receipt = try RecoveryLocalFile.read(local)
            guard receipt.sha256 == before else { throw failure("Local backup changed during verification.") }
            inventory[file] = receipt
            if file == "nandroid.md5" { try Self.validateBackupChecksums(local, names: Set(names), sizes: sizes, verifyFiles: false) }
        }
        try Self.validateBackupChecksums(destination.appendingPathComponent("nandroid.md5"), names: Set(names), sizes: sizes, verifyFiles: true)
        guard try await remoteHash(remote + "/nandroid.md5") == RecoveryArchive.hash(destination.appendingPathComponent("nandroid.md5")),
              Set(try await shell("/sbin/ls -1A " + remote).split(separator: "\n").map(String.init)) == Set(names) else {
            throw failure("Backup changed before verification completed. Local files were preserved.")
        }
        // Directory size/timestamps legitimately change while receiving entries; pin its inode and device below.
        let completedIdentity = try RecoveryLocalFile.directory(destination)
        guard completedIdentity.device == directoryIdentity.device, completedIdentity.inode == directoryIdentity.inode else { throw failure("Backup destination changed during copying.") }
        let copy = RecoveryBackupCopy(localDirectory: destination, verifiedFileCount: names.count, owner: owner,
                                      directoryIdentity: completedIdentity, inventory: inventory)
        try validateBackupCopy(copy)
        return copy
    }

    /// Revalidates the exact local directory, inventory, regular-file identities and copied hashes.
    public func revalidateBackup(_ copy: RecoveryBackupCopy) async throws {
        try begin(); defer { operationActive = false }
        try validateBackupCopy(copy)
    }

    private func validateBackupCopy(_ copy: RecoveryBackupCopy) throws {
        guard copy.owner == owner, !copy.inventory.isEmpty,
              try RecoveryLocalFile.directory(copy.localDirectory) == copy.directoryIdentity,
              Set(try FileManager.default.contentsOfDirectory(atPath: copy.localDirectory.path)) == Set(copy.inventory.keys) else {
            throw failure("Verified local backup changed. Copy and verify a current backup again.")
        }
        for (name, expected) in copy.inventory {
            try Task.checkCancellation()
            guard try RecoveryLocalFile.read(copy.localDirectory.appendingPathComponent(name)) == expected else {
                throw failure("Verified local backup changed: \(name). Copy it again.")
            }
        }
        guard try RecoveryLocalFile.directory(copy.localDirectory) == copy.directoryIdentity else { throw failure("Backup directory changed during revalidation.") }
    }

    /// Copies a verified ten-file CWM backup. Success means prepared, never installed.
    public func prepare(firmwareURL: URL, expectedSHA256: String,
                        android: RecoveryAndroidObservation, recovery: RecoveryObservation,
                        offDeviceBackupConfirmed: Bool, backupCopy: RecoveryBackupCopy? = nil) async throws -> RecoveryPreparation {
        try begin(); defer { operationActive = false }
        guard offDeviceBackupConfirmed else { throw failure("Confirm a separate off-device backup before preparation.") }
        if let backupCopy { try validateBackupCopy(backupCopy) }
        try validate(android)
        try validateRecoveryOwner(recovery)
        let archive = try await RecoveryArchive.open(firmwareURL, expectedSHA256: expectedSHA256, runner: runner)
        defer { archive.cleanup() }
        let root = recovery.storagePath + "/clockworkmod"
        let backups = root + "/backup"
        let name = "explorerlink-" + UUID().uuidString.lowercased()
        let partial = backups + "/." + name + ".partial"
        let final = backups + "/" + name
        var remaining = archive.totalBytes
        _ = try await recheck(recovery, requiredBytes: remaining)
        try await safeParents(root: root, backups: backups)
        if let backupCopy { try validateBackupCopy(backupCopy) }
        // mkdir without -p on the new leaf makes collision a failure. Existing paths are never removed.
        try await mutation("/sbin/mkdir -p \(backups) && /sbin/mkdir \(partial)")
        for entry in archive.entries {
            try Task.checkCancellation()
            _ = try await recheck(recovery, requiredBytes: remaining)
            try await safeParents(root: root, backups: backups)
            try await requireDirectory(partial)
            try await absent(partial + "/" + entry.name)
            let file = archive.directory.appendingPathComponent(entry.name)
            guard try RecoveryArchive.hash(file) == entry.sha256 else { throw failure("Prepared local file changed: \(entry.name)") }
            _ = try await runADB(["push", file.path, partial + "/" + entry.name], timeout: 600)
            try await verifyRemote(partial + "/" + entry.name, sha256: entry.sha256)
            remaining -= entry.size
        }
        // Rehash all files immediately before publishing; no partial backup becomes the final folder.
        _ = try await recheck(recovery, requiredBytes: 0)
        try await safeParents(root: root, backups: backups)
        try await requireDirectory(partial)
        for entry in archive.entries { try await verifyRemote(partial + "/" + entry.name, sha256: entry.sha256) }
        _ = try await recheck(recovery, requiredBytes: 0)
        try await safeParents(root: root, backups: backups)
        try await requireDirectory(partial)
        try await absent(final)
        try await mutation("/sbin/mv \(partial) \(final)")
        try await requireDirectory(final)
        for entry in archive.entries { try await verifyRemote(final + "/" + entry.name, sha256: entry.sha256) }
        return RecoveryPreparation(recoveryFolder: final, verifiedFileCount: archive.entries.count)
    }

    private func begin() throws {
        guard !operationActive else { throw failure("Another recovery step is running.") }
        operationActive = true
    }
    private func validate(_ observation: RecoveryAndroidObservation) throws {
        let age = Date().timeIntervalSince(observation.observedAt)
        guard observation.owner == owner, observation.serial == serial, age >= 0,
              age <= Self.maximumObservationAge else { throw failure("Inspect Glass in Android again; the identity or battery observation expired.") }
    }
    private func validateRecoveryOwner(_ observation: RecoveryObservation) throws {
        guard observation.owner == owner, observation.serial == serial else { throw failure("Recovery selection changed. Inspect it again.") }
    }
    private func backupNames(_ recovery: RecoveryObservation) async throws -> [String] {
        let root = recovery.storagePath + "/clockworkmod", path = root + "/backup"
        try await safeParents(root: root, backups: path)
        try await requireDirectory(path)
        let names = try await shell("/sbin/ls -1 " + path).split(separator: "\n").map(String.init)
        guard names.count <= 128, Set(names).count == names.count else { throw failure("Too many or ambiguous backup folders.") }
        var completed: [String] = []
        for name in names where Self.safeBackupName(name) {
            let folder = path + "/" + name
            let check = try await shell("[ -d \(folder) ] && [ ! -L \(folder) ] && [ -f \(folder)/nandroid.md5 ] && [ ! -L \(folder)/nandroid.md5 ] && echo EXPLORER_OK")
            if check == "EXPLORER_OK" { completed.append(name) }
        }
        return completed.sorted()
    }
    private static func safeBackupName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$", options: .regularExpression) != nil
    }
    private static func safeBackupFile(_ name: String) -> Bool {
        if ["nandroid.md5", "recovery.log", "boot.img", "recovery.img"].contains(name) { return true }
        return name.range(of: "^(system|data|cache)\\.ext4\\.tar(\\.[a-z])?$", options: .regularExpression) != nil
    }
    private static func validateBackupChecksums(_ url: URL, names: Set<String>, sizes: [String: UInt64], verifyFiles: Bool) throws {
        let data = try Data(contentsOf: url)
        guard data.count <= 16_384, let text = String(data: data, encoding: .ascii) else { throw failure("Invalid backup checksum file.") }
        var checked = Set<String>()
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count == 2, safeBackupFile(fields[1]), names.contains(fields[1]),
                  fields[1] != "nandroid.md5", fields[1] != "recovery.log", checked.insert(fields[1]).inserted,
                  fields[0].range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else { throw failure("Unsafe or duplicate backup checksum entry.") }
            if verifyFiles {
                let file = try FileHandle(forReadingFrom: url.deletingLastPathComponent().appendingPathComponent(fields[1])); defer { try? file.close() }
                var md5 = Insecure.MD5()
                while let part = try file.read(upToCount: 1024 * 1024), !part.isEmpty { md5.update(data: part) }
                guard md5.finalize().map({ String(format: "%02x", $0) }).joined() == fields[0].lowercased() else { throw failure("Backup MD5 verification failed.") }
            }
        }
        let required: Set<String> = ["boot.img", "recovery.img", "system.ext4.tar.a", "data.ext4.tar.a", "cache.ext4.tar.a"]
        guard required.isSubset(of: checked) else { throw failure("Backup does not cover boot, recovery, system, data, and cache.") }
        for name in names.subtracting(checked).subtracting(["nandroid.md5", "recovery.log"]) {
            guard name.hasSuffix(".tar"), sizes[name] == 0 else { throw failure("Backup contains an unchecked payload.") }
        }
    }
    private func androidObservation() async throws -> RecoveryAndroidObservation {
        try await requireSerial(recovery: false)
        let model = try await shell("getprop ro.product.model")
        let device = try await shell("getprop ro.product.device")
        let api = try await shell("getprop ro.build.version.sdk")
        let version = try await shell("getprop ro.build.version.glass")
        let recoveryState = try await shell("getprop init.svc.recovery")
        guard model == "Glass 1", device == "glass-1", api == "19", version == "XE24", recoveryState != "running" else {
            throw failure("Requires Explorer Edition Glass 1, glass-1, API 19, running XE24 Android. Unknown, older, and Enterprise firmware are not accepted.")
        }
        let battery = try Self.batteryPercent(try await shell("dumpsys battery"))
        try await requireSerial(recovery: false)
        return RecoveryAndroidObservation(serial: serial, model: model, device: device, apiLevel: 19,
                                          glassVersion: version, batteryPercent: battery, observedAt: Date(), owner: owner)
    }
    private func recoveryObservation() async throws -> RecoveryObservation {
        try await requireSerial(recovery: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        for (remote, hash) in [("/sbin/recovery", recoveryHash), ("/etc/recovery.fstab", fstabHash)] {
            let local = temporary.appendingPathComponent(URL(fileURLWithPath: remote).lastPathComponent)
            _ = try await runADB(["pull", remote, local.path], timeout: 30)
            guard try RecoveryArchive.hash(local) == hash else { throw failure("Running recovery does not match the audited CWM binary and partition table.") }
        }
        guard try await shell("getprop init.svc.recovery") == "running",
              try await shell("/sbin/id -u") == "0" else { throw failure("Requires running CWM with root ADB access.") }
        let storage = try await shell("/sbin/readlink -f /sdcard")
        guard ["/data/media", "/data/media/0"].contains(storage) else { throw failure("Unknown recovery storage path.") }
        let dataDevice = try await shell("/sbin/readlink -f " + Self.userdata)
        guard dataDevice.range(of: "^/dev/block/mmcblk[0-9]+p[0-9]+$", options: .regularExpression) != nil else { throw failure("Unknown userdata block mapping.") }
        let mounts = try await shell("/sbin/cat /proc/mounts")
        let matching = mounts.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }.filter { $0.count >= 4 && $0[1] == "/data" }
        guard matching.count == 1, matching[0][0] == dataDevice, matching[0][2] == "ext4",
              matching[0][3].split(separator: ",").contains("rw") else { throw failure("Userdata is not mounted read-write at the expected device.") }
        try await requireDirectory("/data/media")
        if storage.hasSuffix("/0") { try await requireDirectory(storage) }
        let free = try Self.freeBytes(try await shell("/sbin/df -k " + storage))
        try await requireSerial(recovery: true)
        return RecoveryObservation(serial: serial, storagePath: storage, freeBytes: free,
                                   observedAt: Date(), owner: owner, dataDevice: dataDevice)
    }
    private func recheck(_ expected: RecoveryObservation, requiredBytes: UInt64, enforceReserve: Bool = true) async throws -> RecoveryObservation {
        let current = try await recoveryObservation()
        guard current.storagePath == expected.storagePath, current.dataDevice == expected.dataDevice else {
            throw failure("Recovery storage changed. Nothing further was copied.")
        }
        guard !enforceReserve || current.freeBytes >= requiredBytes + Self.reserveBytes else {
            throw failure("Not enough recovery storage for the backup plus a 256 MiB reserve.")
        }
        return current
    }
    private func requireSerial(recovery: Bool) async throws {
        let result = try await runADB(["devices"], selected: false)
        let matches = DeviceParser.adbDevices(result.stdout).filter { $0.serial == serial }
        guard matches.count == 1, recovery ? ["device", "recovery"].contains(matches[0].state) : matches[0].state == "device" else {
            throw failure("Selected Glass disconnected, is unauthorized, or changed mode.")
        }
    }
    private func safeParents(root: String, backups: String) async throws {
        try await check("[ ! -L \(root) ] && [ ! -L \(backups) ] && { [ ! -e \(root) ] || [ -d \(root) ]; } && { [ ! -e \(backups) ] || [ -d \(backups) ]; }")
    }
    private func requireDirectory(_ path: String) async throws { try await check("[ -d \(path) ] && [ ! -L \(path) ]") }
    private func absent(_ path: String) async throws { try await check("[ ! -e \(path) ] && [ ! -L \(path) ]") }
    private func check(_ expression: String) async throws {
        guard try await shell(expression + " && echo EXPLORER_OK") == "EXPLORER_OK" else { throw failure("Recovery path check failed; existing files were preserved.") }
    }
    private func mutation(_ expression: String) async throws {
        // Legacy adb shell may not propagate the remote exit code; require an explicit success marker.
        guard try await shell(expression + " && echo EXPLORER_OK") == "EXPLORER_OK" else { throw failure("Recovery staging stopped. Partial files were left in place.") }
    }
    private func verifyRemote(_ path: String, sha256: String) async throws {
        try await check("[ -f \(path) ] && [ ! -L \(path) ]")
        guard try await remoteHash(path) == sha256 else { throw failure("Copied file checksum mismatch. Partial files were left in place.") }
    }
    private func remoteHash(_ path: String) async throws -> String {
        let line = try await shell("/sbin/sha256sum " + path, timeout: 300)
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count == 2, fields[0].count == 64, fields[0].allSatisfy({ $0.isHexDigit }), fields[1] == path else { throw failure("Invalid recovery checksum response.") }
        return fields[0].lowercased()
    }
    private func shell(_ script: String, timeout: TimeInterval = 30) async throws -> String {
        let result = try await runADB(["shell", script], timeout: timeout)
        guard result.stdout.utf8.count <= 65_536 else { throw failure("Unexpectedly large recovery response.") }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private func runADB(_ arguments: [String], selected: Bool = true, timeout: TimeInterval = 30) async throws -> ProcessResult {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: adb.path),
              try RecoveryLocalFile.read(adb, maximumBytes: 128 * 1024 * 1024) == adbReceipt else {
            throw failure("ADB changed since inspection. Select and check the tool again.")
        }
        let result = try await runner.run(ProcessCommand(executable: adb, arguments: (selected ? ["-s", serial] : []) + arguments, timeout: timeout))
        guard result.exitCode == 0 else { throw ExplorerFlashError.processFailed(result) }
        return result
    }
    static func batteryPercent(_ output: String) throws -> Int {
        var fields: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let values = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if values.count == 2 { guard fields[values[0]] == nil else { throw failure("Ambiguous battery status.") }; fields[values[0]] = values[1] }
        }
        guard fields["present"] == "true", fields["health"] == "2", let level = Int(fields["level"] ?? ""),
              let scale = Int(fields["scale"] ?? ""), scale == 100, (70...100).contains(level),
              let temperature = Int(fields["temperature"] ?? ""), (0...450).contains(temperature) else {
            throw failure("Requires a reported healthy battery at least 70%, between 0 and 45°C. Unknown readings are not accepted.")
        }
        return level
    }
    static func freeBytes(_ output: String) throws -> UInt64 {
        let lines = output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard lines.count >= 2, lines.count <= 3 else { throw failure("Unknown storage capacity response.") }
        let fields = lines.last!.split(whereSeparator: { $0.isWhitespace })
        let index = fields.count == 6 ? 3 : fields.count == 5 ? 2 : -1
        guard index >= 0, let kilobytes = UInt64(fields[index]), kilobytes <= UInt64.max / 1024 else { throw failure("Unknown storage capacity response.") }
        return kilobytes * 1024
    }
    private func failure(_ message: String) -> ExplorerFlashError { Self.failure(message) }
    private static func failure(_ message: String) -> ExplorerFlashError { .invalidDevice(message) }
}
