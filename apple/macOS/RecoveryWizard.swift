import AppKit
import ExplorerFlashCore
import Foundation
import SwiftUI

@MainActor final class RecoveryWizardModel: ObservableObject {
    enum Step: Int { case connect = 1, recovery, backup, prepare, restore }
    @Published private(set) var step: Step = .connect
    @Published private(set) var busy = false
    @Published private(set) var status = "Check the connected Glass to begin."
    @Published private(set) var error: String?
    @Published private(set) var android: RecoveryAndroidObservation?
    @Published private(set) var recovery: RecoveryObservation?
    @Published private(set) var backups: [String] = []
    @Published var selectedBackup = ""
    @Published private(set) var backupCopy: RecoveryBackupCopy?
    @Published private(set) var preparation: RecoveryPreparation?
    private var installer: RecoveryInstaller?
    private var operation: Task<Void, Never>?

    func reset() {
        guard !busy else { return }
        installer = nil; android = nil; recovery = nil; backupCopy = nil; preparation = nil
        backups = []; selectedBackup = ""; step = .connect; error = nil
        status = "Check the connected Glass to begin."
    }
    func cancel() { operation?.cancel() }
    func report(_ error: Error) { self.error = error.localizedDescription }
    private func run(_ title: String, action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil; status = title
        operation = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.operation = nil }
            do { try await action() }
            catch is CancellationError { self.status = "Cancellation requested. Recheck Glass before restoring." }
            catch { self.error = error.localizedDescription; self.status = "Step failed. Recheck Glass before restoring." }
        }
    }
    func inspect(adb: URL, serial: String) {
        run("Checking Glass…") {
            let installer = try RecoveryInstaller(adb: adb, serial: serial)
            let observation = try await installer.inspectAndroid()
            try Task.checkCancellation()
            self.installer = installer; self.android = observation
            self.recovery = nil; self.backupCopy = nil; self.preparation = nil
            self.backups = []; self.selectedBackup = ""; self.step = .recovery
            self.status = "Glass identity and battery checked."
        }
    }
    func openRecovery() {
        guard let installer, let android else { return }
        run("Restarting into installed recovery…") {
            try await installer.rebootToRecovery(from: android)
            self.status = "Wait for recovery on Glass, then check recovery."
        }
    }
    func checkRecovery() {
        guard let installer, let android else { return }
        run("Checking recovery and storage…") {
            let observation = try await installer.inspectRecovery(after: android)
            try Task.checkCancellation()
            self.recovery = observation; self.step = .backup
            self.status = "Audited CWM files and mounted storage matched."
        }
    }
    func refreshBackups() {
        guard let installer, let recovery else { return }
        run("Finding recovery backups…") {
            let names = try await installer.listBackups(recovery: recovery)
            try Task.checkCancellation()
            self.backups = names
            if !names.contains(self.selectedBackup) { self.selectedBackup = "" }
            self.status = names.isEmpty ? "No supported backups found. Create one in CWM first." : "Select the current backup to copy to your Mac."
        }
    }
    func chooseBackupDestination() {
        guard !busy, !selectedBackup.isEmpty else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Save backup here"
        panel.message = "A new Glass backup folder will be created here."
        panel.begin { [weak self] result in
            guard result == .OK, let parent = panel.url else { return }
            Task { @MainActor in self?.copyBackup(to: parent.appendingPathComponent("Glass-Backup-" + UUID().uuidString.lowercased(), isDirectory: true)) }
        }
    }
    private func copyBackup(to destination: URL) {
        guard let installer, let recovery, backups.contains(selectedBackup), !busy else { return }
        let selected = selectedBackup
        run("Copying and verifying backup on Mac…") {
            let result = try await installer.copyBackup(named: selected, recovery: recovery, to: destination)
            try Task.checkCancellation()
            self.backupCopy = result; self.step = .prepare
            self.status = "Copied and verified \(result.verifiedFileCount) backup files."
        }
    }
    func prepare(firmware: URL, sha256: String) {
        guard let installer, let android, let recovery, let backupCopy,
              FileManager.default.fileExists(atPath: backupCopy.localDirectory.path) else {
            error = "Copy and verify a recovery backup on your Mac first."; return
        }
        run("Copying and verifying firmware on Glass…") {
            do { try await installer.revalidateBackup(backupCopy) }
            catch {
                self.backupCopy = nil; self.step = .backup
                throw error
            }
            let result = try await installer.prepare(firmwareURL: firmware, expectedSHA256: sha256,
                                                     android: android, recovery: recovery, offDeviceBackupConfirmed: true, backupCopy: backupCopy)
            try Task.checkCancellation()
            self.preparation = result; self.step = .restore
            self.status = "Prepared \(result.verifiedFileCount) verified files. Firmware has not been restored."
        }
    }
}

struct RecoveryWizardView: View {
    @ObservedObject var wizard: RecoveryWizardModel
    let canInspect: Bool
    let inspect: () -> Void
    let prepare: () -> Void
    @State private var confirmReboot = false
    @State private var confirmPreparation = false
    @Environment(\.linkPalette) private var palette

    var body: some View {
        GroupBox("Guided firmware setup · Step \(wizard.step.rawValue) of 5") {
            VStack(alignment: .leading, spacing: 12) {
                switch wizard.step {
                case .connect:
                    Text("1 · Check Glass").font(.headline)
                    Text("Connect Explorer Edition in Android with USB debugging enabled. Select its serial above.")
                    Button("Check Glass", action: inspect).buttonStyle(.borderedProminent).disabled(!canInspect)
                case .recovery:
                    Text("2 · Open recovery").font(.headline)
                    if let glass = wizard.android { Text("\(glass.model) · \(glass.glassVersion) · Battery \(glass.batteryPercent)%").foregroundStyle(palette.muted) }
                    Text("Use the recovery already installed on Glass. A missing or different recovery stops preparation.")
                    HStack {
                        Button("Restart in recovery…") { confirmReboot = true }
                        Button("Check recovery") { wizard.checkRecovery() }.buttonStyle(.borderedProminent)
                    }
                case .backup:
                    Text("3 · Save a recovery backup").font(.headline)
                    Text("On Glass, choose backup and restore > backup. When it finishes, refresh the list and copy that backup to your Mac.")
                    HStack {
                        Picker("Backup", selection: $wizard.selectedBackup) {
                            Text("Select backup").tag("")
                            ForEach(wizard.backups, id: \.self) { Text($0).tag($0) }
                        }
                        Button("Refresh backups") { wizard.refreshBackups() }
                    }
                    Button("Copy backup to Mac…") { wizard.chooseBackupDestination() }.buttonStyle(.borderedProminent).disabled(wizard.selectedBackup.isEmpty)
                case .prepare:
                    Text("4 · Prepare firmware").font(.headline)
                    if let backup = wizard.backupCopy {
                        Text("Backup: \(backup.localDirectory.path)").font(.caption).textSelection(.enabled)
                    }
                    Text("Copies the bundled firmware to a new recovery folder and verifies each file. Existing backups stay in place.")
                    Button("Copy firmware to Glass…") { confirmPreparation = true }.buttonStyle(.borderedProminent)
                case .restore:
                    Text("5 · Restore on Glass").font(.headline)
                    if let prepared = wizard.preparation {
                        Text("Prepared folder").font(.subheadline)
                        Text(prepared.recoveryFolder).font(.caption.monospaced()).textSelection(.enabled)
                        Text("On Glass: backup and restore > restore > \(URL(fileURLWithPath: prepared.recoveryFolder).lastPathComponent).")
                    }
                    Text("Restoring can replace boot, system, data and cache. Physical compatibility and successful recovery remain unverified; do not confirm the restore until those checks are complete.")
                    Text("After a successful restore and restart, open Explorer Link setup once to pair.").foregroundStyle(palette.muted)
                }
                Divider()
                HStack { if wizard.busy { ProgressView().controlSize(.small) }; Text(wizard.status).font(.callout) }
                if let error = wizard.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if wizard.step != .connect { Button("Start over") { wizard.reset() }.disabled(wizard.busy) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
        .confirmationDialog("Restart the selected Glass in recovery?", isPresented: $confirmReboot, titleVisibility: .visible) {
            Button("Restart in recovery") { wizard.openRecovery() }
        } message: { Text("Serial: \(wizard.android?.serial ?? ""). This ends the current Glass session.") }
        .confirmationDialog("Copy firmware to the selected Glass?", isPresented: $confirmPreparation, titleVisibility: .visible) {
            Button("Copy and verify", action: prepare)
        } message: { Text("Writes only a new backup folder on device storage. This does not restore partitions or certify firmware compatibility.") }
    }
}
