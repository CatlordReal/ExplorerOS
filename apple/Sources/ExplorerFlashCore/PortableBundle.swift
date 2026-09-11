import Foundation

/// A relocatable, checksummed resource inventory. It never describes a flash sequence.
public struct PortableFile: Codable, Equatable, Sendable {
    public let role: String
    public let path: String
    public let sha256: String
    public let size: UInt64
    public let source: String

    public init(role: String, path: String, sha256: String, size: UInt64, source: String) {
        self.role = role
        self.path = path
        self.sha256 = sha256
        self.size = size
        self.source = source
    }
}

/// Portable package metadata. `cwm-backup` remains metadata only and is never a FlashManifest.
public struct PortableBundle: Codable, Equatable, Sendable {
    public let version: Int
    public let title: String
    public let firmwareFormat: String
    public let files: [PortableFile]

    public init(version: Int = 1, title: String, firmwareFormat: String, files: [PortableFile]) {
        self.version = version
        self.title = title
        self.firmwareFormat = firmwareFormat
        self.files = files
    }

    public static func load(from url: URL) throws -> PortableBundle {
        do { return try JSONDecoder().decode(PortableBundle.self, from: Data(contentsOf: url)) }
        catch { throw ExplorerFlashError.invalidManifest("Cannot decode portable bundle: \(error.localizedDescription)") }
    }

    /// Validates all inventory metadata and paths, then streams only the requested file.
    public func validatedURL(role: String, manifestURL: URL) throws -> URL {
        guard version == 1 else { throw ExplorerFlashError.invalidManifest("Unsupported portable bundle version.") }
        guard validLabel(title), validLabel(firmwareFormat), !files.isEmpty else {
            throw ExplorerFlashError.invalidManifest("Portable bundle metadata is invalid.")
        }
        var roles = Set<String>()
        var paths = Set<String>()
        var selected: (file: PortableFile, url: URL)?
        for file in files {
            guard validLabel(file.role), validLabel(file.source), roles.insert(file.role).inserted,
                  paths.insert(file.path).inserted else {
                throw ExplorerFlashError.invalidManifest("Portable bundle has duplicate or invalid roles, paths, or sources.")
            }
            guard file.sha256.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil, file.size > 0 else {
                throw ExplorerFlashError.invalidManifest("Invalid hash or size for portable file: \(file.path)")
            }
            let fileURL = try FlashPreflight.safeImageURL(file: file.path, manifestURL: manifestURL)
            if file.role == role { selected = (file, fileURL) }
        }
        guard let selected else { throw ExplorerFlashError.missingFile("Portable bundle role is absent: \(role)") }
        let image = FlashImage(partition: "boot", file: selected.file.path, sha256: selected.file.sha256, size: selected.file.size)
        try FlashPreflight.verify(image: image, at: selected.url)
        return selected.url
    }

    /// CWM backups may be verified as files, but must not be transformed into raw-partition commands.
    public var isCWMBackup: Bool { firmwareFormat == "cwm-backup" }

    private func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
    }
}
