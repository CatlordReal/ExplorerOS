import Foundation

/// Strict wire validation for the v1, one-at-a-time media stream. File I/O stays with the host app.
public enum MediaTransfer {
    public static let chunkBytes = 3_072
    public static let maximumImageBytes: UInt64 = 50 * 1024 * 1024
    public static let maximumVideoBytes: UInt64 = 250 * 1024 * 1024
    public static let maximumSessionBytes: UInt64 = 500 * 1024 * 1024
    public static let mediaTypes: Set<String> = ["image/jpeg", "image/png", "video/mp4", "video/3gpp"]
    public static let cancelCodes: Set<String> = ["disabled", "unsupported", "quota", "storage", "state", "integrity", "timeout"]

    public static func validateBegin(_ p: [String: String]) throws {
        try exact(p, ["id", "sha256", "bytes", "chunks", "chunk_bytes", "mime", "captured_ms"])
        guard id(p["id"]), hex64(p["sha256"]), let bytes = unsigned(p["bytes"]), bytes > 0,
              let chunks = unsigned(p["chunks"]), chunks > 0, p["chunk_bytes"] == "3072",
              mediaTypes.contains(p["mime"] ?? ""), let captured = unsigned(p["captured_ms"]), captured <= UInt64(Int64.max),
              bytes <= limit(for: p["mime"]!), chunks == bytes / UInt64(chunkBytes) + (bytes % UInt64(chunkBytes) == 0 ? 0 : 1) else { throw LinkFailure.invalidMessage }
    }
    public static func validateAccept(_ p: [String: String]) throws { try exact(p, ["id"]); guard id(p["id"]) else { throw LinkFailure.invalidMessage } }
    public static func validateChunk(_ p: [String: String]) throws {
        try exact(p, ["id", "index", "data"])
        guard id(p["id"]), let index = unsigned(p["index"]), index <= (maximumVideoBytes + UInt64(chunkBytes) - 1) / UInt64(chunkBytes),
              let encoded = p["data"], let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded, !data.isEmpty, data.count <= chunkBytes else { throw LinkFailure.invalidMessage }
    }
    public static func validateAck(_ p: [String: String]) throws { try exact(p, ["id", "next"]); guard id(p["id"]), let next = unsigned(p["next"]), next > 0, next <= (maximumVideoBytes + UInt64(chunkBytes) - 1) / UInt64(chunkBytes) else { throw LinkFailure.invalidMessage } }
    public static func validateFinish(_ p: [String: String]) throws { try exact(p, ["id"]); guard id(p["id"]) else { throw LinkFailure.invalidMessage } }
    public static func validateComplete(_ p: [String: String]) throws {
        try exact(p, ["id", "sha256", "bytes", "state"])
        guard id(p["id"]), hex64(p["sha256"]), let bytes = unsigned(p["bytes"]), bytes > 0, bytes <= maximumVideoBytes, ["staged", "deduplicated"].contains(p["state"] ?? "") else { throw LinkFailure.invalidMessage }
    }
    public static func validateCancel(_ p: [String: String]) throws { try exact(p, ["id", "code"]); guard id(p["id"]), cancelCodes.contains(p["code"] ?? "") else { throw LinkFailure.invalidMessage } }

    public static func cancel(id: String, code: String) -> LinkMessage { .init(type: "media.cancel", payload: ["id": id, "code": code]) }
    private static func exact(_ p: [String: String], _ keys: Set<String>) throws { guard Set(p.keys) == keys else { throw LinkFailure.invalidMessage } }
    private static func id(_ value: String?) -> Bool { guard let value else { return false }; return value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func hex64(_ value: String?) -> Bool { guard let value else { return false }; return value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func unsigned(_ value: String?) -> UInt64? { guard let value, !value.isEmpty, (value == "0" || value.first != "0"), value.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }; return UInt64(value) }
    private static func limit(for mime: String) -> UInt64 { mime.hasPrefix("image/") ? maximumImageBytes : maximumVideoBytes }
}

/// Pure receiver ordering guard. Hosts still own storage, hashing and acknowledgements.
public struct MediaReceiveState: Equatable, Sendable {
    public let id: String
    public let bytes: UInt64
    public let chunks: UInt64
    public private(set) var next: UInt64 = 0
    public private(set) var written: UInt64 = 0
    public init(begin: [String: String]) throws {
        try MediaTransfer.validateBegin(begin)
        id = begin["id"]!; bytes = UInt64(begin["bytes"]!)!; chunks = UInt64(begin["chunks"]!)!
    }
    public mutating func append(id receivedID: String, index: UInt64, count: Int) throws {
        guard receivedID == id, index == next, next < chunks, count > 0 else { throw LinkFailure.invalidMessage }
        let amount = UInt64(count), remaining = bytes - written
        guard amount <= UInt64(MediaTransfer.chunkBytes), amount <= remaining,
              next + 1 < chunks ? amount == UInt64(MediaTransfer.chunkBytes) : amount == remaining else { throw LinkFailure.invalidMessage }
        written += amount; next += 1
    }
    public var readyToFinish: Bool { next == chunks && written == bytes }
}
