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
        guard acknowledgement == plan.device.serial else { throw ExplorerFlashError.confirmationRequired }
        _ = try DeviceParser.select(serial: plan.device.serial, mode: .fastboot, from: currentDevices)
        let expected = try FlashPlanner.review(manifest: manifest, manifestURL: manifestURL, fastboot: fastboot, device: plan.device)
        guard plan == expected else { throw ExplorerFlashError.invalidManifest("Flash plan no longer matches the selected manifest, executable, and device.") }
        var results: [ProcessResult] = []
        let product = try await runner.run(plan.commands[0])
        results.append(product)
        guard product.exitCode == 0 else { throw ExplorerFlashError.processFailed(product) }
        let actualProduct = parseProduct(product.stdout + "\n" + product.stderr)
        guard actualProduct == manifest.product else { throw ExplorerFlashError.productMismatch(expected: manifest.product, actual: actualProduct ?? "unreported") }
        for command in plan.commands.dropFirst() {
            let probe = ProcessCommand(executable: command.executable, arguments: ["devices"])
            let enumerated = try await runner.run(probe)
            guard enumerated.exitCode == 0 else { throw ExplorerFlashError.processFailed(enumerated) }
            _ = try DeviceParser.select(serial: plan.device.serial, mode: .fastboot, from: DeviceParser.fastbootDevices(enumerated.stdout))
            try FlashPreflight.validate(manifest: manifest, at: plan.manifestURL) // revalidate immediately before each image
            let result = try await runner.run(command)
            results.append(result)
            guard result.exitCode == 0 else { throw ExplorerFlashError.processFailed(result) }
        }
        return results
    }

    private func parseProduct(_ output: String) -> String? {
        for line in output.split(separator: "\n") where line.lowercased().contains("product") {
            if let value = line.split(separator: ":", maxSplits: 1).last, value != line { return value.trimmingCharacters(in: .whitespaces) }
        }
        return nil
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
