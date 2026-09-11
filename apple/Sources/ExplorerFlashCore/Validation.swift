import CryptoKit
import Foundation

public enum DeviceParser {
    public static func validate(serial: String) throws {
        guard serial.range(of: "^[A-Za-z0-9._:-]+$", options: .regularExpression) != nil else {
            throw ExplorerFlashError.invalidDevice("Invalid device serial.")
        }
    }

    public static func adbDevices(_ output: String) -> [Device] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count >= 2, fields[0] != "List", !fields[0].hasPrefix("*") else { return nil }
            return Device(serial: String(fields[0]), mode: .adb, state: String(fields[1]))
        }
    }

    public static func fastbootDevices(_ output: String) -> [Device] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard fields.count >= 2, fields[1] == "fastboot" else { return nil }
            return Device(serial: String(fields[0]), mode: .fastboot, state: String(fields[1]))
        }
    }

    public static func select(serial: String, mode: Device.Mode, from devices: [Device]) throws -> Device {
        try validate(serial: serial)
        let matching = devices.filter { $0.mode == mode && $0.serial == serial }
        guard matching.count == 1 else {
            let visible = devices.filter { $0.mode == mode }.map(\.serial)
            if visible.count > 1 { throw ExplorerFlashError.ambiguousDevices(visible) }
            throw ExplorerFlashError.invalidDevice("Selected \(mode.rawValue) device is absent.")
        }
        guard matching[0].state == (mode == .adb ? "device" : "fastboot") else {
            throw ExplorerFlashError.unauthorizedDevice("Device \(serial) state is \(matching[0].state); authorize/reconnect before continuing.")
        }
        return matching[0]
    }
}

public enum FlashPreflight {
    public static let allowedPartitions: Set<String> = ["boot", "system", "recovery"]

    public static func validate(manifest: FlashManifest, at manifestURL: URL, expectedProduct: String? = nil) throws {
        guard manifest.product.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw ExplorerFlashError.invalidManifest("Manifest product is invalid.") }
        if let expectedProduct, manifest.product != expectedProduct { throw ExplorerFlashError.productMismatch(expected: expectedProduct, actual: manifest.product) }
        guard !manifest.images.isEmpty else { throw ExplorerFlashError.invalidManifest("Manifest has no images.") }
        var partitions = Set<String>()
        for image in manifest.images {
            guard allowedPartitions.contains(image.partition), partitions.insert(image.partition).inserted else { throw ExplorerFlashError.invalidManifest("Partition \(image.partition) is forbidden or duplicated.") }
            guard image.sha256.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil, image.size > 0 else { throw ExplorerFlashError.invalidManifest("Invalid hash or size for \(image.file).") }
            let url = try safeImageURL(file: image.file, manifestURL: manifestURL)
            try verify(image: image, at: url)
        }
    }

    public static func safeImageURL(file: String, manifestURL: URL) throws -> URL {
        guard !file.isEmpty, !file.hasPrefix("/"), !file.split(separator: "/").contains("..") else { throw ExplorerFlashError.unsafePath("Unsafe image path: \(file)") }
        let root = manifestURL.deletingLastPathComponent().resolvingSymlinksInPath()
        let url = root.appendingPathComponent(file).standardizedFileURL
        guard url.path.hasPrefix(root.path + "/"), url.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { throw ExplorerFlashError.unsafePath("Image escapes manifest directory: \(file)") }
        var componentURL = root
        for component in file.split(separator: "/") {
            componentURL.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: componentURL.path)) != nil {
                throw ExplorerFlashError.unsafePath("Image path contains a symlink: \(file)")
            }
        }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values?.isRegularFile == true, values?.isSymbolicLink != true else { throw ExplorerFlashError.unsafePath("Image must be a regular non-symlink file: \(file)") }
        return url
    }

    public static func verify(image: FlashImage, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ExplorerFlashError.missingFile("Missing image: \(image.file)") }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.uint64Value == image.size else { throw ExplorerFlashError.checksumMismatch("Size mismatch: \(image.file)") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hash.update(data: data)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(image.sha256) == .orderedSame else { throw ExplorerFlashError.checksumMismatch("SHA-256 mismatch: \(image.file)") }
    }
}
