import CryptoKit
import Foundation

/// Strict flat ZIP admission before invoking the system extractor. Never executes archive content.
struct RecoveryArchive {
    struct Entry { let name: String; let size: UInt64; let sha256: String }
    let directory: URL
    let entries: [Entry]
    var totalBytes: UInt64 { entries.reduce(0) { $0 + $1.size } }
    static let names: Set<String> = ["boot.img", "cache.ext4.tar", "cache.ext4.tar.a", "data.ext4.tar", "data.ext4.tar.a", "nandroid.md5", "recovery.img", "recovery.log", "system.ext4.tar", "system.ext4.tar.a"]
    private static let maximumZIP: UInt64 = 1024 * 1024 * 1024
    private static let maximumExpanded: UInt64 = 2 * 1024 * 1024 * 1024

    static func open(_ source: URL, expectedSHA256: String, runner: any ProcessRunning) async throws -> RecoveryArchive {
        guard expectedSHA256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil else { throw invalid("Invalid firmware SHA-256.") }
        let size = try regularSize(source)
        guard size > 0, size <= maximumZIP else { throw invalid("Firmware ZIP exceeds the supported size.") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("explorer-backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let copy = root.appendingPathComponent("firmware.zip")
            // Work from a private snapshot, avoiding changes to the selected file after verification.
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            FileManager.default.createFile(atPath: copy.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let output = try FileHandle(forWritingTo: copy)
            do {
                var copied: UInt64 = 0
                while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                    try Task.checkCancellation()
                    copied += UInt64(data.count)
                    guard copied <= maximumZIP else { throw invalid("Firmware changed or exceeds the size bound.") }
                    try output.write(contentsOf: data)
                }
                try output.close()
                guard copied == size, try hash(copy) == expectedSHA256.lowercased() else { throw invalid("Firmware SHA-256 mismatch.") }
            } catch { try? output.close(); throw error }
            let metadata = try inspectZIP(copy)
            let listing = try await runner.run(.init(executable: URL(fileURLWithPath: "/usr/bin/zipinfo"), arguments: ["-1", copy.path]))
            let listed = listing.stdout.split(separator: "\n").map(String.init)
            guard listing.exitCode == 0, listed.count == 10, Set(listed) == names else { throw invalid("ZIP entry listing does not match the ten-file CWM layout.") }
            let files = root.appendingPathComponent("files")
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            let extraction = try await runner.run(.init(executable: URL(fileURLWithPath: "/usr/bin/ditto"), arguments: ["-x", "-k", copy.path, files.path], timeout: 300))
            guard extraction.exitCode == 0 else { throw ExplorerFlashError.processFailed(extraction) }
            guard Set(try FileManager.default.contentsOfDirectory(atPath: files.path)) == names else { throw invalid("Unexpected extracted files.") }
            var entries: [Entry] = []
            for name in names.sorted() {
                let url = files.appendingPathComponent(name)
                guard try regularSize(url) == metadata[name] else { throw invalid("Extracted file size or type changed: \(name)") }
                entries.append(Entry(name: name, size: metadata[name]!, sha256: try hash(url)))
            }
            try verifyMD5(at: files)
            return RecoveryArchive(directory: files, entries: entries)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }

    static func hash(_ url: URL) throws -> String {
        _ = try regularSize(url)
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func fileSize(_ url: URL) throws -> UInt64 { try regularSize(url) }
    private static func regularSize(_ url: URL) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size >= 0 else { throw invalid("Requires a regular non-symlink file.") }
        return UInt64(size)
    }
    private static func verifyMD5(at directory: URL) throws {
        let url = directory.appendingPathComponent("nandroid.md5")
        guard try regularSize(url) <= 4096, let text = String(data: try Data(contentsOf: url), encoding: .ascii) else { throw invalid("Invalid CWM checksum file.") }
        let required: Set<String> = ["boot.img", "cache.ext4.tar.a", "data.ext4.tar.a", "recovery.img", "system.ext4.tar.a"]
        let markers: Set<String> = ["cache.ext4.tar", "data.ext4.tar", "system.ext4.tar"]
        for name in markers {
            guard try regularSize(directory.appendingPathComponent(name)) == 0 else { throw invalid("CWM split-tar markers must be empty.") }
        }
        var seen = Set<String>()
        for line in text.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard fields.count == 2, required.union(markers).contains(fields[1]), seen.insert(fields[1]).inserted,
                  fields[0].range(of: "^[a-fA-F0-9]{32}$", options: .regularExpression) != nil else { throw invalid("Unexpected CWM checksum entry.") }
            let file = try FileHandle(forReadingFrom: directory.appendingPathComponent(fields[1])); defer { try? file.close() }
            var md5 = Insecure.MD5()
            while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { md5.update(data: data) }
            guard md5.finalize().map({ String(format: "%02x", $0) }).joined() == fields[0].lowercased() else { throw invalid("CWM checksum mismatch: \(fields[1])") }
        }
        guard required.isSubset(of: seen) else { throw invalid("CWM checksum entries are incomplete.") }
    }

    /// Rejects ZIP64, encryption, links, special files, duplicate/local-only members, and ZIP bombs.
    static func inspectZIP(_ url: URL) throws -> [String: UInt64] {
        let size = try regularSize(url)
        guard size >= 22, size <= maximumZIP else { throw invalid("Invalid ZIP size.") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        func read(_ offset: UInt64, _ length: Int) throws -> Data {
            guard offset <= size, UInt64(length) <= size - offset else { throw invalid("Truncated ZIP.") }
            if length == 0 { return Data() }
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: length), data.count == length else { throw invalid("Truncated ZIP.") }
            return data
        }
        let tailSize = Int(min(size, 65_557)); let tailOffset = size - UInt64(tailSize)
        let tail = try read(tailOffset, tailSize)
        var end: Int?
        for i in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.u32(i) == 0x06054b50, i + 22 + Int(tail.u16(i + 20)) == tail.count { end = i; break }
        }
        guard let end, tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              tail.u16(end + 8) == 10, tail.u16(end + 10) == 10 else { throw invalid("Requires a single-volume ten-file ZIP.") }
        let centralSize = Int(tail.u32(end + 12)), centralOffset = UInt64(tail.u32(end + 16))
        guard centralSize <= 65_536, centralOffset + UInt64(centralSize) == tailOffset + UInt64(end) else { throw invalid("Unsupported ZIP directory.") }
        let central = try read(centralOffset, centralSize)
        var position = 0; var result: [String: UInt64] = [:]; var total: UInt64 = 0
        var spans: [(UInt64, UInt64)] = []
        for _ in 0..<10 {
            guard position + 46 <= central.count, central.u32(position) == 0x02014b50 else { throw invalid("Invalid ZIP directory entry.") }
            let flags = central.u16(position + 8), compression = central.u16(position + 10)
            let compressed = UInt64(central.u32(position + 20)), expanded = UInt64(central.u32(position + 24))
            let nameLength = Int(central.u16(position + 28)), extraLength = Int(central.u16(position + 30)), commentLength = Int(central.u16(position + 32))
            let next = position + 46 + nameLength + extraLength + commentLength
            let mode = central.u32(position + 38) >> 16
            guard next <= central.count, flags & ~0x0800 == 0, [UInt16(0), 8].contains(compression),
                  central.u16(position + 34) == 0, central.u32(position + 38) & 0x10 == 0,
                  mode & 0xf000 == 0x8000, expanded <= maximumZIP else { throw invalid("Unsupported ZIP flags, type, or size.") }
            let nameData = central.subdata(in: position + 46..<position + 46 + nameLength)
            guard let name = String(data: nameData, encoding: .ascii), names.contains(name), result[name] == nil else { throw invalid("Unexpected, duplicate, or unsafe ZIP filename.") }
            try extras(central.subdata(in: position + 46 + nameLength..<position + 46 + nameLength + extraLength))
            total += expanded; guard total <= maximumExpanded else { throw invalid("Expanded backup exceeds 2 GiB.") }
            let localOffset = UInt64(central.u32(position + 42)); let local = try read(localOffset, 30)
            guard local.u32(0) == 0x04034b50, local.u16(6) == flags, local.u16(8) == compression,
                  local.u32(14) == central.u32(position + 16), UInt64(local.u32(18)) == compressed,
                  UInt64(local.u32(22)) == expanded, Int(local.u16(26)) == nameLength else { throw invalid("Local ZIP header differs from its directory.") }
            let localExtraLength = Int(local.u16(28))
            guard try read(localOffset + 30, nameLength) == nameData else { throw invalid("Local ZIP filename differs.") }
            try extras(try read(localOffset + 30 + UInt64(nameLength), localExtraLength))
            let dataEnd = localOffset + 30 + UInt64(nameLength + localExtraLength) + compressed
            guard dataEnd <= centralOffset else { throw invalid("ZIP entry overlaps its directory.") }
            spans.append((localOffset, dataEnd)); result[name] = expanded; position = next
        }
        guard position == central.count, Set(result.keys) == names else { throw invalid("ZIP has extra directory entries.") }
        var cursor: UInt64 = 0
        for span in spans.sorted(by: { $0.0 < $1.0 }) { guard span.0 == cursor else { throw invalid("ZIP contains overlapping or unlisted local entries.") }; cursor = span.1 }
        guard cursor == centralOffset else { throw invalid("ZIP contains unlisted content before its directory.") }
        return result
    }
    private static func extras(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            guard offset + 4 <= data.count else { throw invalid("Truncated ZIP extra field.") }
            let kind = data.u16(offset), length = Int(data.u16(offset + 2))
            guard [UInt16(0x5455), 0x7875].contains(kind), offset + 4 + length <= data.count else { throw invalid("Unsupported ZIP extra field.") }
            offset += 4 + length
        }
    }
    private static func invalid(_ message: String) -> ExplorerFlashError { .invalidManifest(message) }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}
