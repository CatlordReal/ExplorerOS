import Foundation
import XCTest
@testable import ExplorerFlashCore

final class DeviceDiscoveryTests: XCTestCase {
    private static let resolver: @Sendable (Device.Mode) async throws -> URL = {
        URL(fileURLWithPath: "/synthetic/" + $0.rawValue)
    }

    func testBrokenFastbootResolutionPreservesADBAndUnauthorizedDevices() async throws {
        let runner = DiscoveryRunner(adb: .reply(0, "List of devices attached\nGLASS device product:glass\nLOCKED unauthorized\n", ""))
        let result = try await DeviceDiscovery(runner: runner).scan { mode in
            if mode == .fastboot { throw ExplorerFlashError.missingFile("Choose a fastboot executable.") }
            return try await Self.resolver(mode)
        }
        XCTAssertEqual(result.devices, [.init(serial: "GLASS", mode: .adb, state: "device"),
                                        .init(serial: "LOCKED", mode: .adb, state: "unauthorized")])
        XCTAssertEqual(result.failures.map(\.mode), [.fastboot])
        XCTAssertTrue(result.failures[0].message.contains("Choose a fastboot executable"))
        let commands = await runner.commands
        XCTAssertEqual(commands.map(\.arguments), [["devices", "-l"]])
    }

    func testBrokenADBCommandPreservesFastboot() async throws {
        let runner = DiscoveryRunner(adb: .reply(1, "", "cannot connect to daemon"),
                                     fastboot: .reply(0, "BOOT\tfastboot\n", ""))
        let result = try await DeviceDiscovery(runner: runner).scan(resolve: Self.resolver)
        XCTAssertEqual(result.devices, [.init(serial: "BOOT", mode: .fastboot, state: "fastboot")])
        XCTAssertEqual(result.failures.map(\.mode), [.adb])
        XCTAssertTrue(result.failures[0].message.contains("cannot connect to daemon"))
        try await assertReadOnly(runner)
    }

    func testBothFailuresRemainSeparateAndBounded() async throws {
        let runner = DiscoveryRunner(adb: .reply(2, "", "\u{1b}[31m" + String(repeating: "é", count: 600)), fastboot: .timeout)
        let result = try await DeviceDiscovery(runner: runner).scan(resolve: Self.resolver)
        XCTAssertTrue(result.devices.isEmpty)
        XCTAssertEqual(result.failures.map(\.mode), [.adb, .fastboot])
        XCTAssertTrue(result.failures[1].message.contains("timed out"))
        for failure in result.failures {
            XCTAssertLessThanOrEqual(failure.message.utf8.count, 512)
            XCTAssertFalse(failure.message.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
        }
        try await assertReadOnly(runner)
    }

    func testHealthyResultsHaveDeterministicOrderWithoutSelection() async throws {
        let runner = DiscoveryRunner(adb: .reply(0, "A device\nB offline\n", ""),
                                     fastboot: .reply(0, "C fastboot\nD fastboot\n", ""))
        let result = try await DeviceDiscovery(runner: runner).scan(resolve: Self.resolver)
        XCTAssertEqual(result.devices.map(\.serial), ["A", "B", "C", "D"])
        XCTAssertTrue(result.failures.isEmpty)
        try await assertReadOnly(runner)
    }

    func testResolverCancellationPropagatesInsteadOfBecomingToolFailure() async {
        let runner = DiscoveryRunner()
        do {
            _ = try await DeviceDiscovery(runner: runner).scan { _ in throw CancellationError() }
            XCTFail("Cancellation returned a discovery result")
        } catch { XCTAssertTrue(error is CancellationError) }
        let commands = await runner.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func testCancellationStopsBothIndependentRunningScans() async throws {
        let runner = DiscoveryRunner(adb: .waitForCancellation, fastboot: .waitForCancellation)
        let task = Task { try await DeviceDiscovery(runner: runner).scan(resolve: Self.resolver) }
        for _ in 0..<100 {
            if await runner.commands.count == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = await runner.commands.count
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation returned success") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(started, 2, "Both tools should start independently")
        let cancelled = await runner.cancelled
        XCTAssertEqual(cancelled, 2)
        try await assertReadOnly(runner)
    }

    private func assertReadOnly(_ runner: DiscoveryRunner) async throws {
        let commands = await runner.commands
        XCTAssertEqual(commands.count, 2)
        for command in commands {
            XCTAssertEqual(command.timeout, 15)
            XCTAssertEqual(command.arguments, command.executable.lastPathComponent == "adb" ? ["devices", "-l"] : ["devices"])
        }
    }
}

private actor DiscoveryRunner: ProcessRunning {
    enum Outcome: Sendable {
        case reply(Int32, String, String), timeout, waitForCancellation
    }
    let adb: Outcome
    let fastboot: Outcome
    private(set) var commands: [ProcessCommand] = []
    private(set) var cancelled = 0
    init(adb: Outcome = .reply(0, "", ""), fastboot: Outcome = .reply(0, "", "")) {
        self.adb = adb; self.fastboot = fastboot
    }
    func run(_ command: ProcessCommand) async throws -> ProcessResult {
        commands.append(command)
        switch command.executable.lastPathComponent == "adb" ? adb : fastboot {
        case .reply(let code, let out, let err):
            return ProcessResult(command: command, exitCode: code, stdout: out, stderr: err)
        case .timeout: throw ExplorerFlashError.timedOut(command)
        case .waitForCancellation:
            do { try await Task.sleep(for: .seconds(30)); throw ExplorerFlashError.timedOut(command) }
            catch is CancellationError { cancelled += 1; throw CancellationError() }
        }
    }
}
