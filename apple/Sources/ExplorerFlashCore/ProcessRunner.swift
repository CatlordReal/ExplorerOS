import Darwin
import Foundation

public final class ProcessRunner: ProcessRunning, @unchecked Sendable {
    public static let maximumCapturedBytes = 1_048_576
    private static let pollInterval: Duration = .milliseconds(25)
    private static let terminationGrace: Duration = .seconds(1)
    public init() {}

    public func run(_ command: ProcessCommand) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process(); process.executableURL = command.executable; process.arguments = command.arguments
        let out = Pipe(); let err = Pipe(); process.standardOutput = out; process.standardError = err
        let collector = OutputCollector(limit: Self.maximumCapturedBytes)
        try Self.setNonBlocking(out.fileHandleForReading)
        try Self.setNonBlocking(err.fileHandleForReading)
        defer {
            try? out.fileHandleForReading.close()
            try? err.fileHandleForReading.close()
        }
        try process.run()
        do {
            try await withTaskCancellationHandler(operation: {
                let deadline = ContinuousClock.now + .seconds(command.timeout)
                while process.isRunning {
                    Self.drain(out.fileHandleForReading, into: collector, stdout: true)
                    Self.drain(err.fileHandleForReading, into: collector, stdout: false)
                    if ContinuousClock.now >= deadline { await Self.stopAndWait(process); throw ExplorerFlashError.timedOut(command) }
                    try await Task.sleep(for: Self.pollInterval)
                }
                Self.drain(out.fileHandleForReading, into: collector, stdout: true)
                Self.drain(err.fileHandleForReading, into: collector, stdout: false)
            }, onCancel: { Self.stop(process) })
        } catch {
            await Self.stopAndWait(process)
            Self.drain(out.fileHandleForReading, into: collector, stdout: true)
            Self.drain(err.fileHandleForReading, into: collector, stdout: false)
            throw error
        }
        return ProcessResult(command: command, exitCode: process.terminationStatus, stdout: collector.stdout, stderr: collector.stderr)
    }

    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGTERM)
    }

    private static func stopAndWait(_ process: Process) async {
        stop(process)
        let termDeadline = ContinuousClock.now + terminationGrace
        while process.isRunning, ContinuousClock.now < termDeadline { try? await Task.sleep(for: pollInterval) }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        let killDeadline = ContinuousClock.now + terminationGrace
        while process.isRunning, ContinuousClock.now < killDeadline { try? await Task.sleep(for: pollInterval) }
    }

    private static func setNonBlocking(_ handle: FileHandle) throws {
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0, Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ExplorerFlashError.invalidManifest("Cannot configure nonblocking subprocess output.")
        }
    }

    private static func drain(_ handle: FileHandle, into collector: OutputCollector, stdout: Bool) {
        let descriptor = handle.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 65_536)
        // A continuously writing child must not starve stderr, cancellation, or the deadline.
        for _ in 0..<16 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                let data = Data(buffer.prefix(Int(count)))
                if stdout { collector.append(stdout: data) } else { collector.append(stderr: data) }
                continue
            }
            if count == 0 || errno == EAGAIN || errno == EWOULDBLOCK { return }
            return
        }
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock(); private let limit: Int; private var out = Data(); private var err = Data()
    init(limit: Int) { self.limit = limit }
    var stdout: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
    var stderr: String { lock.withLock { String(decoding: err, as: UTF8.self) } }
    func append(stdout: Data) { lock.withLock { append(stdout, to: &out) } }
    func append(stderr: Data) { lock.withLock { append(stderr, to: &err) } }
    private func append(_ data: Data, to destination: inout Data) {
        let available = limit - destination.count
        guard available > 0 else { return }
        destination.append(data.prefix(available))
    }
}
