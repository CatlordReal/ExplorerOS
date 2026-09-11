import Foundation
import ExplorerFlashCore

/// Locates app-relative resources without starting tools or trusting their contents.
struct PortableResources: Sendable {
    let root: URL
    let manifestURL: URL
    let bundle: PortableBundle

    init(root: URL) throws {
        self.root = root.standardizedFileURL
        manifestURL = root.appendingPathComponent("bundle.json")
        bundle = try PortableBundle.load(from: manifestURL)
        guard bundle.version == 1 else { throw ExplorerFlashError.invalidManifest("Unsupported bundle version. Choose your own files.") }
        guard !bundle.files.isEmpty, Set(bundle.files.map(\.role)).count == bundle.files.count else { throw ExplorerFlashError.invalidManifest("Invalid bundle inventory. Choose your own files.") }
        // Path validation is cheap. Hash verification happens explicitly before use.
        for file in bundle.files { _ = try FlashPreflight.safeImageURL(file: file.path, manifestURL: manifestURL) }
    }

    func candidate(role: String) -> URL? {
        guard let file = bundle.files.first(where: { $0.role == role }) else { return nil }
        return try? FlashPreflight.safeImageURL(file: file.path, manifestURL: manifestURL)
    }

    func validated(role: String) throws -> URL { try bundle.validatedURL(role: role, manifestURL: manifestURL) }

    static func contains(_ url: URL, root: URL) -> Bool {
        let prefix = root.standardizedFileURL.path + "/"
        let resolvedPrefix = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(prefix) || url.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(resolvedPrefix)
    }

    func checkedSelection(_ url: URL, role: String) throws -> URL {
        let checked = try validated(role: role)
        guard checked.resolvingSymlinksInPath().standardizedFileURL == url.resolvingSymlinksInPath().standardizedFileURL else {
            throw ExplorerFlashError.invalidManifest("Selected bundled file does not match its role: \(role).")
        }
        return checked
    }
}
