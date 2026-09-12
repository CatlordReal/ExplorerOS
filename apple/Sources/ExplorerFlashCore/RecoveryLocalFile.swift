import CryptoKit
import Darwin
import Foundation

/// A local file identity and content receipt, never an executable or device operation.
struct RecoveryLocalFile: Sendable, Equatable {
    struct Identity: Sendable, Equatable {
        let device: Int32
        let inode: UInt64
        let mode: UInt16
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanos: Int
        let changedSeconds: Int
        let changedNanos: Int

        init(_ value: stat) {
            device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
            modifiedSeconds = value.st_mtimespec.tv_sec; modifiedNanos = value.st_mtimespec.tv_nsec
            changedSeconds = value.st_ctimespec.tv_sec; changedNanos = value.st_ctimespec.tv_nsec
        }
    }
    let identity: Identity
    let sha256: String

    static func directory(_ url: URL) throws -> Identity {
        var value = stat()
        guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFDIR else { throw invalid() }
        return Identity(value)
    }

    static func read(_ url: URL, maximumBytes: UInt64 = 8 * 1024 * 1024 * 1024) throws -> RecoveryLocalFile {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw invalid() }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, UInt64(before.st_size) <= maximumBytes else { throw invalid() }
        let identity = Identity(before)
        var digest = SHA256(); var readCount: UInt64 = 0
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            readCount += UInt64(data.count)
            guard readCount <= maximumBytes else { throw invalid() }
            digest.update(data: data)
        }
        var after = stat(), path = stat()
        guard fstat(descriptor, &after) == 0, lstat(url.path, &path) == 0,
              identity == Identity(after), identity == Identity(path), readCount == UInt64(identity.size) else { throw invalid() }
        return RecoveryLocalFile(identity: identity, sha256: digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private static func invalid() -> ExplorerFlashError { .invalidDevice("Local file changed or is not a supported regular file. Check it again.") }
}
