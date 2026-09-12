import ExplorerLinkCore
import Foundation

/// Fixed-path Mac host for authenticated phone control. It exposes only audited
/// recovery preparation; restore, shell, raw-flash, unlock, and erase APIs do not exist here.
@MainActor
public protocol InstallerServing: AnyObject {
    var snapshot: InstallerSnapshot { get }
    var onChange: ((InstallerSnapshot) -> Void)? { get set }
    func submit(_ request: InstallerRequest) throws
    func disconnect()
}

/// Serial, firmware and backup destination are selected by the local Mac UI.
/// The remote peer may choose only a listed backup name and a declared action.
@MainActor
public final class PhoneRecoveryHost: InstallerServing {
    public private(set) var snapshot: InstallerSnapshot
    public var onChange: ((InstallerSnapshot) -> Void)?

    private let installer: RecoveryInstaller
    private let firmware: URL
    private let sha256: String
    private let backupRoot: URL
    private let configurationValid: Bool
    private var android: RecoveryAndroidObservation?
    private var recovery: RecoveryObservation?
    private var backupCopy: RecoveryBackupCopy?
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var disconnecting = false
    private var seenIDs = Set<String>()
    private var idOrder: [String] = []
    private static let maximumSeenIDs = 128

    public init(installer: RecoveryInstaller, firmware: URL, sha256: String,
                backupRoot: URL, firmwareName: String, serial: String) {
        self.installer = installer
        self.firmware = firmware
        self.sha256 = sha256.lowercased()
        self.backupRoot = backupRoot.standardizedFileURL
        let validSHA = sha256.range(of: "^[a-fA-F0-9]{64}$", options: .regularExpression) != nil
        let validName = !firmwareName.isEmpty && firmwareName.utf8.count <= 128
        let validSerial = (try? DeviceParser.validate(serial: serial)) != nil
        configurationValid = validSHA && validName && validSerial && serial == installer.serial
        snapshot = InstallerSnapshot(serial: validSerial ? serial : "invalid", firmwareName: validName ? firmwareName : "firmware.zip",
                                     firmwareSHA256: validSHA ? sha256.lowercased() : String(repeating: "0", count: 64),
                                     status: configurationValid ? "Check Glass to begin." : "Host configuration is invalid.",
                                     error: configurationValid ? nil : "Host configuration is invalid.")
    }

    public func submit(_ request: InstallerRequest) throws {
        try request.validate()
        try validateRequest(request)
        remember(request.id)
        if request.action == .status { return }
        guard configurationValid else { throw LinkFailure.invalidMessage }
        if request.action == .cancel {
            requestCancellation()
            return
        }
        guard !snapshot.busy else { throw LinkFailure.invalidMessage }
        switch request.action {
        case .inspectAndroid:
            guard snapshot.step == .check else { throw LinkFailure.invalidMessage }
            begin("Checking Glass…") { [weak self] in
                guard let self else { return }
                let observation = try await self.installer.inspectAndroid()
                try Task.checkCancellation()
                self.android = observation; self.recovery = nil; self.backupCopy = nil
                self.snapshot.step = .recovery; self.snapshot.battery = observation.batteryPercent
                self.snapshot.backupNames = []; self.snapshot.backupSaved = false; self.snapshot.preparedFolder = nil
                self.snapshot.status = "Glass identity and battery checked."
            }
        case .rebootRecovery:
            guard snapshot.step == .recovery, let android else { throw LinkFailure.invalidMessage }
            begin("Requesting recovery restart…") { [weak self] in
                guard let self else { return }
                try await self.installer.rebootToRecovery(from: android)
                try Task.checkCancellation()
                self.snapshot.status = "Recovery restart requested. Check recovery when Glass is ready."
            }
        case .inspectRecovery:
            guard snapshot.step == .recovery, let android else { throw LinkFailure.invalidMessage }
            begin("Checking recovery…") { [weak self] in
                guard let self else { return }
                let observation = try await self.installer.inspectRecovery(after: android)
                try Task.checkCancellation()
                self.recovery = observation; self.backupCopy = nil
                self.snapshot.step = .backup; self.snapshot.backupNames = []; self.snapshot.backupSaved = false; self.snapshot.preparedFolder = nil
                self.snapshot.status = "Audited CWM recovery and storage matched."
            }
        case .listBackups:
            guard snapshot.step == .backup, let recovery else { throw LinkFailure.invalidMessage }
            begin("Listing recovery backups…") { [weak self] in
                guard let self else { return }
                let names = try await self.installer.listBackups(recovery: recovery)
                try Task.checkCancellation()
                self.snapshot.backupNames = Array(names.filter(InstallerRequest.safeBackupName).sorted(by: >).prefix(16))
                self.snapshot.status = self.snapshot.backupNames.isEmpty ? "No supported backups found." : "Select a backup to copy to Mac."
            }
        case .copyBackup:
            guard snapshot.step == .backup, let recovery, snapshot.backupNames.contains(request.value) else { throw LinkFailure.invalidMessage }
            let name = request.value
            begin("Copying verified backup to Mac…") { [weak self] in
                guard let self else { return }
                let destination = try self.newBackupDestination()
                let receipt = try await self.installer.copyBackup(named: name, recovery: recovery, to: destination)
                try Task.checkCancellation()
                self.backupCopy = receipt; self.snapshot.step = .prepare; self.snapshot.backupSaved = true
                self.snapshot.status = "Copied and verified \(receipt.verifiedFileCount) backup files."
            }
        case .prepare:
            guard snapshot.step == .prepare, let android, let recovery, let backupCopy else { throw LinkFailure.invalidMessage }
            begin("Copying and verifying firmware on Glass…") { [weak self] in
                guard let self else { return }
                do {
                    try await self.installer.revalidateBackup(backupCopy)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    self.backupCopy = nil; self.snapshot.step = .backup; self.snapshot.backupSaved = false
                    self.snapshot.preparedFolder = nil
                    throw error
                }
                let prepared = try await self.installer.prepare(firmwareURL: self.firmware, expectedSHA256: self.sha256,
                                                                 android: android, recovery: recovery,
                                                                 offDeviceBackupConfirmed: true, backupCopy: backupCopy)
                try Task.checkCancellation()
                self.snapshot.step = .prepared; self.snapshot.preparedFolder = prepared.recoveryFolder
                self.snapshot.status = "Prepared \(prepared.verifiedFileCount) verified files. Firmware has not been restored."
            }
        case .reset:
            clearTransient(status: "Check Glass to begin.")
            publish()
        case .status, .cancel:
            break
        }
    }

    public func disconnect() {
        disconnecting = true
        android = nil; recovery = nil; backupCopy = nil
        snapshot.step = .check; snapshot.battery = nil; snapshot.backupNames = []
        snapshot.backupSaved = false; snapshot.preparedFolder = nil
        if snapshot.busy {
            snapshot.status = "Cancellation requested. Recheck Glass before restoring."
            operation?.cancel()
        } else {
            snapshot.status = "Disconnected. Recheck Glass before restoring."
        }
        snapshot.error = nil
        publish()
    }

    private func validateRequest(_ request: InstallerRequest) throws {
        let bootstrapStatus = request.action == .status && request.hostSession.isEmpty
        if bootstrapStatus {
            // An authenticated peer may request its first snapshot without knowing this host session.
        } else {
            guard request.hostSession.lowercased() == snapshot.hostSession.lowercased() else { throw LinkFailure.invalidMessage }
        }
        if !bootstrapStatus { guard request.revision == snapshot.revision else { throw LinkFailure.replay } }
        guard !seenIDs.contains(request.id.lowercased()) else { throw LinkFailure.replay }
    }

    private func remember(_ id: String) {
        let canonical = id.lowercased(); seenIDs.insert(canonical); idOrder.append(canonical)
        if idOrder.count > Self.maximumSeenIDs { seenIDs.remove(idOrder.removeFirst()) }
    }

    private func requestCancellation() {
        guard snapshot.busy else {
            snapshot.status = "No host operation is running."
            snapshot.error = nil; publish(); return
        }
        snapshot.status = "Cancellation requested. Recheck Glass before restoring."
        snapshot.error = nil; operation?.cancel(); publish()
    }

    private func begin(_ status: String, work: @escaping @MainActor () async throws -> Void) {
        disconnecting = false
        let id = UUID(); operationID = id
        snapshot.busy = true; snapshot.status = status; snapshot.error = nil
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                try await work()
                try Task.checkCancellation()
                self.finish(id: id, error: nil)
            } catch is CancellationError {
                self.finish(id: id, error: nil)
            } catch {
                self.finish(id: id, error: error)
            }
        }
        publish()
    }

    private func finish(id: UUID, error: Error?) {
        guard operationID == id else { return }
        operation = nil; operationID = nil; snapshot.busy = false
        if disconnecting {
            clearTransient(status: "Disconnected. Recheck Glass before restoring.")
        } else if let error {
            snapshot.error = bounded(error.localizedDescription)
            snapshot.status = "Step failed. Recheck Glass before restoring."
        } else if snapshot.status.hasPrefix("Cancellation requested") {
            snapshot.status = "Cancellation requested. Recheck Glass before restoring."
        }
        publish()
    }

    private func clearTransient(status: String) {
        android = nil; recovery = nil; backupCopy = nil; disconnecting = false
        snapshot.step = .check; snapshot.battery = nil; snapshot.busy = false; snapshot.backupNames = []
        snapshot.backupSaved = false; snapshot.preparedFolder = nil; snapshot.status = status; snapshot.error = nil
    }

    private func newBackupDestination() throws -> URL {
        let root = backupRoot.standardizedFileURL
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ExplorerFlashError.invalidDevice("Mac backup destination is unavailable.") }
        let destination = root.appendingPathComponent("Glass-Backup-" + UUID().uuidString.lowercased(), isDirectory: true).standardizedFileURL
        guard destination.deletingLastPathComponent() == root, !FileManager.default.fileExists(atPath: destination.path) else {
            throw ExplorerFlashError.invalidDevice("Mac backup destination is unavailable.")
        }
        return destination
    }

    private func publish() {
        snapshot.revision += 1
        snapshot.status = bounded(snapshot.status)
        if let error = snapshot.error { snapshot.error = bounded(error) }
        onChange?(snapshot)
    }

    private func bounded(_ value: String) -> String {
        guard value.utf8.count > 512 else { return value }
        var result = ""
        for scalar in value.unicodeScalars {
            guard (result + String(scalar)).utf8.count <= 509 else { break }
            result.unicodeScalars.append(scalar)
        }
        return result + "…"
    }
}
