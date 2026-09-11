import CryptoKit
import Foundation
import XCTest
@testable import ExplorerFlashCore

final class ExplorerFlashCoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    func testManifestAcceptsVerifiedAllowedImage() throws {
        let file = directory.appendingPathComponent("boot.img")
        let data = Data("verified".utf8); try data.write(to: file)
        let manifest = FlashManifest(product: "glass_1", images: [FlashImage(partition: "boot", file: "boot.img", sha256: SHA256.hash(data: data).hex, size: UInt64(data.count))])
        try FlashPreflight.validate(manifest: manifest, at: directory.appendingPathComponent("flash.json"))
    }

    func testManifestRejectsTraversalSymlinkAndForbiddenPartition() throws {
        XCTAssertThrowsError(try FlashPreflight.safeImageURL(file: "../boot.img", manifestURL: directory.appendingPathComponent("flash.json")))
        let outside = directory.deletingLastPathComponent().appendingPathComponent("outside.img"); try Data([1]).write(to: outside)
        let link = directory.appendingPathComponent("link.img"); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try FlashPreflight.safeImageURL(file: "link.img", manifestURL: directory.appendingPathComponent("flash.json")))
        let bad = FlashManifest(product: "glass_1", images: [FlashImage(partition: "userdata", file: "boot.img", sha256: String(repeating: "0", count: 64), size: 1)])
        XCTAssertThrowsError(try FlashPreflight.validate(manifest: bad, at: directory.appendingPathComponent("flash.json")))
    }

    func testBadSerialAndMultipleDevicesFailClosed() throws {
        let devices = [Device(serial: "one", mode: .fastboot, state: "fastboot"), Device(serial: "two", mode: .fastboot, state: "fastboot")]
        XCTAssertThrowsError(try DeviceParser.select(serial: "bad serial", mode: .fastboot, from: devices))
        XCTAssertThrowsError(try DeviceParser.select(serial: "missing", mode: .fastboot, from: devices)) { XCTAssertEqual($0 as? ExplorerFlashError, .ambiguousDevices(["one", "two"])) }
    }

    func testAPKPlanPreservesSpaceAsSingleArgument() throws {
        let apk = directory.appendingPathComponent("Explorer Link.apk"); try Data([0]).write(to: apk)
        let command = try APKInstaller.plan(adb: URL(fileURLWithPath: "/tools/adb"), device: Device(serial: "ABC", mode: .adb, state: "device"), apk: apk)
        XCTAssertEqual(command.arguments, ["-s", "ABC", "install", "-r", apk.path])
    }

    func testExecutorStopsAfterFirstFlashFailure() async throws {
        let image = directory.appendingPathComponent("boot.img"); let data = Data([8]); try data.write(to: image)
        let manifest = FlashManifest(product: "glass_1", images: [FlashImage(partition: "boot", file: "boot.img", sha256: SHA256.hash(data: data).hex, size: 1)])
        let device = Device(serial: "ABC", mode: .fastboot, state: "fastboot")
        let plan = try FlashPlanner.review(manifest: manifest, manifestURL: directory.appendingPathComponent("flash.json"), fastboot: URL(fileURLWithPath: "/tools/fastboot"), device: device)
        let probe = ProcessCommand(executable: plan.commands[1].executable, arguments: ["devices"])
        let runner = StubRunner(results: [result(plan.commands[0], output: "product: glass_1"), result(probe, output: "ABC\tfastboot\n"), result(plan.commands[1], code: 1)])
        do { _ = try await FlashExecutor().execute(plan: plan, manifest: manifest, manifestURL: directory.appendingPathComponent("flash.json"), fastboot: URL(fileURLWithPath: "/tools/fastboot"), runner: runner, acknowledgement: "ABC", currentDevices: [device]); XCTFail("expected failure") }
        catch { XCTAssertEqual(runner.commands.count, 3) }
    }

    func testExecutorRejectsTamperedOrEmptyPlanBeforeRunner() async throws {
        let image = directory.appendingPathComponent("boot.img"); let data = Data([8]); try data.write(to: image)
        let manifestURL = directory.appendingPathComponent("flash.json")
        let manifest = FlashManifest(product: "glass_1", images: [FlashImage(partition: "boot", file: "boot.img", sha256: SHA256.hash(data: data).hex, size: 1)])
        let device = Device(serial: "ABC", mode: .fastboot, state: "fastboot")
        let runner = StubRunner(results: [])
        let empty = FlashPlan(device: device, manifestURL: manifestURL, commands: [])
        do { _ = try await FlashExecutor().execute(plan: empty, manifest: manifest, manifestURL: manifestURL, fastboot: URL(fileURLWithPath: "/tools/fastboot"), runner: runner, acknowledgement: "ABC", currentDevices: [device]); XCTFail("expected rejection") }
        catch { XCTAssertTrue(runner.commands.isEmpty) }
        let tampered = FlashPlan(device: device, manifestURL: manifestURL, commands: [ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo unsafe"])])
        do { _ = try await FlashExecutor().execute(plan: tampered, manifest: manifest, manifestURL: manifestURL, fastboot: URL(fileURLWithPath: "/tools/fastboot"), runner: runner, acknowledgement: "ABC", currentDevices: [device]); XCTFail("expected rejection") }
        catch { XCTAssertTrue(runner.commands.isEmpty) }
    }

    func testTimeoutKillsTermIgnoringExactChild() async throws {
        let command = ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "trap '' TERM; exec /bin/sleep 30"], timeout: 0.1)
        let clock = ContinuousClock(); let start = clock.now
        do { _ = try await ProcessRunner().run(command); XCTFail("expected timeout") }
        catch let error as ExplorerFlashError {
            XCTAssertEqual(error, .timedOut(command))
            XCTAssertLessThan(clock.now - start, .seconds(3))
        }
    }

    func testFailingExecutableReturnsPromptly() async {
        let clock = ContinuousClock(); let start = clock.now
        do {
            _ = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/definitely/missing-explorer-tool"), arguments: [], timeout: 1))
            XCTFail("expected launch failure")
        } catch {
            XCTAssertLessThan(clock.now - start, .seconds(1))
        }
    }

    func testQuickChildFinalOutputIsCaptured() async throws {
        let result = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf final; printf diagnostic >&2"], timeout: 1))
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout, "final")
        XCTAssertEqual(result.stderr, "diagnostic")
    }

    func testInheritedPipeDoesNotDelayDirectChildResult() async throws {
        let clock = ContinuousClock(); let start = clock.now
        let result = try await ProcessRunner().run(ProcessCommand(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "sleep 1 & printf parent"], timeout: 1))
        XCTAssertEqual(result.stdout, "parent")
        XCTAssertLessThan(clock.now - start, .seconds(0.5))
    }

    func testPortableBundleValidatesRelocatedCheckedFile() throws {
        let portable = directory.appendingPathComponent("relocated/Portable")
        try FileManager.default.createDirectory(at: portable, withIntermediateDirectories: true)
        let data = Data("bridge payload".utf8)
        let file = portable.appendingPathComponent("bin/bridge")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        let bundle = PortableBundle(title: "ExplorerOS", firmwareFormat: "cwm-backup", files: [PortableFile(role: "bridge", path: "bin/bridge", sha256: SHA256.hash(data: data).hex, size: UInt64(data.count), source: "upstream")])
        let manifestURL = portable.appendingPathComponent("bundle.json")
        try JSONEncoder().encode(bundle).write(to: manifestURL)
        XCTAssertTrue(bundle.isCWMBackup)
        XCTAssertEqual(try PortableBundle.load(from: manifestURL).validatedURL(role: "bridge", manifestURL: manifestURL), file)
    }

    func testPortableBundleRejectsTamperedAbsentAndUnsafeFiles() throws {
        let data = Data("known".utf8)
        let file = directory.appendingPathComponent("tool")
        try data.write(to: file)
        let manifestURL = directory.appendingPathComponent("bundle.json")
        let good = PortableFile(role: "adb", path: "tool", sha256: SHA256.hash(data: data).hex, size: UInt64(data.count), source: "upstream")
        let bundle = PortableBundle(title: "ExplorerOS", firmwareFormat: "unknown", files: [good])
        try Data("tampered".utf8).write(to: file)
        XCTAssertThrowsError(try bundle.validatedURL(role: "adb", manifestURL: manifestURL))
        let absent = PortableBundle(title: "ExplorerOS", firmwareFormat: "unknown", files: [PortableFile(role: "fastboot", path: "absent", sha256: good.sha256, size: good.size, source: "upstream")])
        XCTAssertThrowsError(try absent.validatedURL(role: "fastboot", manifestURL: manifestURL))
        let unsafe = PortableBundle(title: "ExplorerOS", firmwareFormat: "unknown", files: [PortableFile(role: "recovery", path: "../outside", sha256: good.sha256, size: good.size, source: "upstream")])
        XCTAssertThrowsError(try unsafe.validatedURL(role: "recovery", manifestURL: manifestURL))
        let outside = directory.deletingLastPathComponent().appendingPathComponent("portable-outside")
        try data.write(to: outside)
        let link = directory.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let symlink = PortableBundle(title: "ExplorerOS", firmwareFormat: "unknown", files: [PortableFile(role: "bridge", path: "linked", sha256: good.sha256, size: good.size, source: "upstream")])
        XCTAssertThrowsError(try symlink.validatedURL(role: "bridge", manifestURL: manifestURL))
    }

    func testPortableBundleRejectsDuplicateMetadata() throws {
        let data = Data([1])
        try data.write(to: directory.appendingPathComponent("one"))
        try data.write(to: directory.appendingPathComponent("two"))
        let hash = SHA256.hash(data: data).hex
        let bundle = PortableBundle(title: "ExplorerOS", firmwareFormat: "unknown", files: [
            PortableFile(role: "adb", path: "one", sha256: hash, size: 1, source: "upstream"),
            PortableFile(role: "adb", path: "two", sha256: hash, size: 1, source: "upstream")
        ])
        XCTAssertThrowsError(try bundle.validatedURL(role: "adb", manifestURL: directory.appendingPathComponent("bundle.json")))
    }

    func testPortableBundleOnlyHashesSelectedRole() throws {
        let adbData = Data("adb".utf8), firmwareData = Data("original firmware".utf8)
        let adb = directory.appendingPathComponent("adb"), firmware = directory.appendingPathComponent("firmware.zip")
        try adbData.write(to: adb)
        try Data("tampered firmware".utf8).write(to: firmware)
        let bundle = PortableBundle(title: "ExplorerOS", firmwareFormat: "cwm-backup", files: [
            PortableFile(role: "adb", path: "adb", sha256: SHA256.hash(data: adbData).hex, size: UInt64(adbData.count), source: "platform-tools"),
            PortableFile(role: "firmware", path: "firmware.zip", sha256: SHA256.hash(data: firmwareData).hex, size: UInt64(firmwareData.count), source: "upstream")
        ])
        let manifestURL = directory.appendingPathComponent("bundle.json")
        XCTAssertEqual(try bundle.validatedURL(role: "adb", manifestURL: manifestURL), adb)
        XCTAssertThrowsError(try bundle.validatedURL(role: "firmware", manifestURL: manifestURL))
    }

    private func result(_ command: ProcessCommand, code: Int32 = 0, output: String = "") -> ProcessResult { ProcessResult(command: command, exitCode: code, stdout: output, stderr: "") }
}

private final class StubRunner: ProcessRunning, @unchecked Sendable {
    var commands: [ProcessCommand] = []; private var results: [ProcessResult]
    init(results: [ProcessResult]) { self.results = results }
    func run(_ command: ProcessCommand) async throws -> ProcessResult { commands.append(command); return results.removeFirst() }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
