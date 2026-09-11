import Foundation

public enum ExplorerFlashError: Error, Equatable, LocalizedError {
    case invalidManifest(String)
    case unsafePath(String)
    case checksumMismatch(String)
    case missingFile(String)
    case invalidDevice(String)
    case ambiguousDevices([String])
    case unauthorizedDevice(String)
    case productMismatch(expected: String, actual: String)
    case confirmationRequired
    case processFailed(ProcessResult)
    case timedOut(ProcessCommand)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let value), .unsafePath(let value), .checksumMismatch(let value), .missingFile(let value), .invalidDevice(let value), .unauthorizedDevice(let value): return value
        case .ambiguousDevices(let serials): return "Select exactly one device; found: \(serials.joined(separator: ", "))."
        case .productMismatch(let expected, let actual): return "Expected fastboot product \(expected), received \(actual)."
        case .confirmationRequired: return "Typed serial acknowledgement is required before flashing."
        case .processFailed(let result): return "Command failed (\(result.exitCode)): \(result.command.arguments.joined(separator: " "))"
        case .timedOut(let command): return "Command timed out: \(command.arguments.joined(separator: " "))"
        }
    }
}

public struct FlashImage: Codable, Equatable, Sendable {
    public let partition: String
    public let file: String
    public let sha256: String
    public let size: UInt64
}

public struct FlashManifest: Codable, Equatable, Sendable {
    public let product: String
    public let images: [FlashImage]

    public init(product: String, images: [FlashImage]) {
        self.product = product
        self.images = images
    }

    public static func load(from url: URL) throws -> FlashManifest {
        let data = try Data(contentsOf: url)
        do { return try JSONDecoder().decode(FlashManifest.self, from: data) }
        catch { throw ExplorerFlashError.invalidManifest("Cannot decode flash manifest: \(error.localizedDescription)") }
    }
}

public struct Device: Equatable, Sendable {
    public enum Mode: String, Sendable { case adb, fastboot }
    public let serial: String
    public let mode: Mode
    public let state: String
    public init(serial: String, mode: Mode, state: String) {
        self.serial = serial; self.mode = mode; self.state = state
    }
}

public struct ProcessCommand: Equatable, Sendable {
    public let executable: URL
    public let arguments: [String]
    public let timeout: TimeInterval
    public init(executable: URL, arguments: [String], timeout: TimeInterval = 60) {
        self.executable = executable; self.arguments = arguments; self.timeout = timeout
    }
}

public struct ProcessResult: Equatable, Sendable {
    public let command: ProcessCommand
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public struct FlashPlan: Equatable, Sendable {
    public let device: Device
    public let manifestURL: URL
    public let commands: [ProcessCommand]
    public init(device: Device, manifestURL: URL, commands: [ProcessCommand]) {
        self.device = device; self.manifestURL = manifestURL; self.commands = commands
    }
}
