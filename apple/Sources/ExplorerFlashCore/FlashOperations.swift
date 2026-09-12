import Foundation

public enum FlashPlanner {
    public static func review(manifest: FlashManifest, manifestURL: URL, fastboot: URL, device: Device) throws -> FlashPlan {
        guard device.mode == .fastboot, device.state == "fastboot" else { throw ExplorerFlashError.invalidDevice("Flashing requires one selected fastboot device.") }
        try FlashPreflight.validate(manifest: manifest, at: manifestURL)
        let imageCommands = try manifest.images.map { image in
            let imageURL = try FlashPreflight.safeImageURL(file: image.file, manifestURL: manifestURL)
            return ProcessCommand(executable: fastboot, arguments: ["-s", device.serial, "flash", image.partition, imageURL.path], timeout: 300)
        }
        let commands = [ProcessCommand(executable: fastboot, arguments: ["-s", device.serial, "getvar", "product"])] + imageCommands
        return FlashPlan(device: device, manifestURL: manifestURL, commands: commands)
    }
}

public protocol ProcessRunning: Sendable {
    func run(_ command: ProcessCommand) async throws -> ProcessResult
}

public struct FlashExecutor: Sendable {
    public init() {}
    public func execute(plan: FlashPlan, manifest: FlashManifest, manifestURL: URL, fastboot: URL, runner: any ProcessRunning, acknowledgement: String, currentDevices: [Device]) async throws -> [ProcessResult] {
        throw ExplorerFlashError.invalidManifest("Raw partition execution is unavailable until a validated device, image, and recovery profile is available.")
    }
}

public enum APKInstaller {
    public static func plan(adb: URL, device: Device, apk: URL) throws -> ProcessCommand {
        guard device.mode == .adb, device.state == "device" else { throw ExplorerFlashError.invalidDevice("APK installation requires one authorized adb device.") }
        try DeviceParser.validate(serial: device.serial)
        let values = try apk.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, apk.pathExtension.lowercased() == "apk" else { throw ExplorerFlashError.unsafePath("APK must be a regular non-symlink .apk file.") }
        return ProcessCommand(executable: adb, arguments: ["-s", device.serial, "install", "-r", apk.path], timeout: 180)
    }
}
