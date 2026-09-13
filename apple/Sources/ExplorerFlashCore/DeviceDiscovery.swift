import Foundation

public struct DeviceDiscoveryFailure: Equatable, Sendable {
    public let mode: Device.Mode
    public let message: String
}

public struct DeviceDiscoveryResult: Equatable, Sendable {
    public let devices: [Device]
    public let failures: [DeviceDiscoveryFailure]
}

/// Each tool has its own resolver and command result. A broken optional tool
/// must not hide devices reported by the other tool. Discovery never selects.
public struct DeviceDiscovery: Sendable {
    private let runner: any ProcessRunning

    public init(runner: any ProcessRunning = ProcessRunner()) { self.runner = runner }

    public func scan(resolve: @escaping @Sendable (Device.Mode) async throws -> URL) async throws -> DeviceDiscoveryResult {
        try Task.checkCancellation()
        async let adb = scan(.adb, resolve: resolve)
        async let fastboot = scan(.fastboot, resolve: resolve)
        let results = try await [adb, fastboot]
        try Task.checkCancellation()
        return DeviceDiscoveryResult(devices: results.flatMap(\.devices), failures: results.flatMap(\.failures))
    }

    private func scan(_ mode: Device.Mode, resolve: @Sendable (Device.Mode) async throws -> URL) async throws -> DeviceDiscoveryResult {
        do {
            try Task.checkCancellation()
            let executable = try await resolve(mode)
            try Task.checkCancellation()
            let command = ProcessCommand(executable: executable,
                                         arguments: mode == .adb ? ["devices", "-l"] : ["devices"], timeout: 15)
            let result = try await runner.run(command)
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                let detail = Self.bounded(result.stderr.isEmpty ? result.stdout : result.stderr)
                return failure(mode, "\(mode.rawValue) failed (\(result.exitCode))." + (detail.isEmpty ? "" : " " + detail))
            }
            let devices = mode == .adb ? DeviceParser.adbDevices(result.stdout) : DeviceParser.fastbootDevices(result.stdout)
            return DeviceDiscoveryResult(devices: devices, failures: [])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            return failure(mode, "\(mode.rawValue): \(error.localizedDescription)")
        }
    }

    private func failure(_ mode: Device.Mode, _ message: String) -> DeviceDiscoveryResult {
        DeviceDiscoveryResult(devices: [], failures: [.init(mode: mode, message: Self.bounded(message))])
    }

    private static func bounded(_ text: String) -> String {
        var output = "", count = 0
        for scalar in text.unicodeScalars {
            let value = CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
            guard count + value.utf8.count <= 512 else { break }
            output += value; count += value.utf8.count
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
