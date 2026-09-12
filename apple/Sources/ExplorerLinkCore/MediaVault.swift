import CryptoKit
import Foundation

public struct MediaVaultItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String // locally generated UUID, never a peer transfer ID
    public let sha256: String
    public let bytes: UInt64
    public let mime: String
    public let capturedMS: UInt64
    public let filename: String
    public init(id: String, sha256: String, bytes: UInt64, mime: String, capturedMS: UInt64, filename: String) { self.id = id; self.sha256 = sha256; self.bytes = bytes; self.mime = mime; self.capturedMS = capturedMS; self.filename = filename }
}

public enum MediaVault {
    public static let maximumIndexBytes = 1_024 * 1_024
    public static let maximumVaultBytes: UInt64 = 1 * 1024 * 1024 * 1024
    public static func filename(id: String, mime: String) -> String { "explorer-\(id).\(extensionFor(mime))" }
    public static func load(vault: URL, index: URL) throws -> (items: [MediaVaultItem], orphanBytes: UInt64) {
        var indexed: [MediaVaultItem] = []
        if FileManager.default.fileExists(atPath: index.path) {
            guard try regularSize(index) <= maximumIndexBytes else { throw LinkFailure.oversizedFrame }
            indexed = try JSONDecoder().decode([MediaVaultItem].self, from: Data(contentsOf: index))
            guard indexed.count <= 1_000, Set(indexed.map(\.id)).count == indexed.count, indexed.allSatisfy(validItem), indexed.reduce(0, { $0 + $1.bytes }) <= maximumVaultBytes else { throw LinkFailure.invalidMessage }
        }
        var valid: [MediaVaultItem] = []
        var known = Set<String>()
        for item in indexed {
            let url = vault.appendingPathComponent(item.filename)
            do {
                guard try regularSize(url) == item.bytes, try hash(url) == item.sha256 else { continue }
                valid.append(item); known.insert(item.filename)
            } catch { continue }
        }
        var orphan: UInt64 = 0
        for url in try FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil) where url.lastPathComponent.range(of: "^explorer-[0-9a-f-]{36}\\.(jpg|png|mp4|3gp)$", options: .regularExpression) != nil && !known.contains(url.lastPathComponent) {
            let size = try regularSize(url); guard orphan <= maximumVaultBytes - size else { throw LinkFailure.oversizedFrame }; orphan += size
        }
        return (valid, orphan)
    }
    public static func save(_ items: [MediaVaultItem], to index: URL) throws {
        guard items.count <= 1_000,
              items.allSatisfy(validItem),
              items.reduce(0, { $0 + $1.bytes }) <= maximumVaultBytes else { throw LinkFailure.invalidMessage }
        try JSONEncoder().encode(items).write(to: index, options: [.atomic, .completeFileProtection])
    }
    public static func hash(_ url: URL) throws -> String {
        _ = try regularSize(url); let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var digest = SHA256(); while let data = try input.read(upToCount: 1_024 * 1_024), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func regularSize(_ url: URL) throws -> UInt64 {
        let v = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard v.isRegularFile == true, v.isSymbolicLink != true, let size = v.fileSize, size >= 0 else { throw LinkFailure.invalidMessage }; return UInt64(size)
    }
    private static func validItem(_ item: MediaVaultItem) -> Bool {
        item.id.range(of: "^[0-9a-f-]{36}$", options: .regularExpression) != nil && item.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil && item.bytes > 0 && item.bytes <= MediaTransfer.maximumVideoBytes && MediaTransfer.mediaTypes.contains(item.mime) && item.filename == filename(id: item.id, mime: item.mime)
    }
    private static func extensionFor(_ mime: String) -> String { switch mime { case "image/jpeg": return "jpg"; case "image/png": return "png"; case "video/mp4": return "mp4"; default: return "3gp" } }
}
