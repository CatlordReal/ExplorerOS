import SwiftUI
import ExplorerLinkCore

struct PhoneFirmwareView: View {
    @StateObject private var installer = PhoneInstallerModel()
    @StateObject private var usb = USBGlassProbe()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.linkPalette) private var palette
    @State private var backupName = ""
    @State private var review: InstallReview?

    private struct InstallReview: Identifiable {
        let id = UUID()
        let action: InstallerAction
        let snapshot: InstallerSnapshot
    }

    var body: some View {
        Form {
            Section("Mac USB bridge") {
                Text("Connect Glass to your Mac by USB. Keep Explorer Tools open and both devices on the same Wi-Fi.")
                    .font(.callout)
                if !installer.connected {
                    SecureField("Connection code from Mac", text: $installer.pairingCode)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(installer.connecting)
                }
                Button(installer.connected || installer.connecting ? "Disconnect" : "Connect to Mac") {
                    if installer.connected || installer.connecting { installer.disconnect() }
                    else { installer.connect() }
                }.disabled(!installer.connected && !installer.connecting && installer.pairingCode.isEmpty)
                if installer.connecting { ProgressView("Connecting…") }
                if !installer.connected { Text(installer.status).font(.caption).foregroundStyle(palette.muted) }
            }
            if let state = installer.snapshot {
                Section("Glass") {
                    if state.simulated { Label("Simulation · no Glass attached", systemImage: "testtube.2").foregroundStyle(palette.tint) }
                    LabeledContent("Serial", value: state.serial)
                    if let battery = state.battery { LabeledContent("Battery", value: "\(battery)%") }
                    Text(state.firmwareName).font(.subheadline)
                    Text("SHA-256 \(state.firmwareSHA256)").font(.caption2.monospaced()).textSelection(.enabled)
                }
                Section(stepTitle(state.step)) {
                    Text(state.status).font(.callout)
                    if state.busy || installer.awaitingReply { ProgressView("Working…") }
                    else { stepControls(state) }
                    if state.busy { Button("Cancel current step", role: .destructive) { installer.send(.cancel) } }
                }
                if !state.busy && state.step != .check {
                    Section { Button("Start checks again") { installer.send(.reset) } }
                }
            }
            if let error = installer.error {
                Section { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--usb-probe-debug") {
            Section("USB research check") {
                Text("Tests whether iOS exposes Glass as a USB camera. This check cannot install firmware.").font(.callout)
                Button(usb.busy ? "Stop USB check" : "Check attached USB camera") {
                    if usb.busy { usb.stop() } else { usb.start() }
                }
                if usb.busy { ProgressView() }
                Text(usb.status).font(.caption).foregroundStyle(palette.muted)
                ForEach(usb.devices) { device in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name).font(.headline)
                        Text(device.summary).font(.caption).textSelection(.enabled)
                    }
                }
                if let error = usb.error { Text(error).font(.caption).foregroundStyle(.red) }
            }
            }
            #endif
        }
        .scrollContentBackground(.hidden).background(palette.bg).foregroundStyle(palette.fg)
        .navigationTitle("Firmware").navigationBarTitleDisplayMode(.inline)
        .onChange(of: installer.snapshot?.backupNames) { _, names in
            if !(names ?? []).contains(backupName) { backupName = names?.first ?? "" }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { installer.leaveForeground(); usb.stop(); review = nil }
        }
        .onDisappear { installer.leaveForeground(); usb.stop() }
        .onAppear {
            #if DEBUG
            installer.configureSimulationIfRequested()
            #endif
        }
        .alert(item: $review) { value in
            let restart = value.action == .rebootRecovery
            return Alert(title: Text(restart ? "Restart Glass in recovery?" : "Copy verified firmware to Glass?"),
                message: Text("Glass \(value.snapshot.serial)\n\(value.snapshot.firmwareName)\n" +
                    (restart ? "This restarts Glass. It does not install firmware." : "The Mac backup must remain available. This copies a recovery folder; restoration is a separate manual step on Glass.")),
                primaryButton: .default(Text(restart ? "Restart in recovery" : "Copy firmware")) {
                    installer.send(value.action, reviewed: value.snapshot)
                }, secondaryButton: .cancel())
        }
    }

    @ViewBuilder private func stepControls(_ state: InstallerSnapshot) -> some View {
        switch state.step {
        case .check:
            Button("Check Glass") { installer.send(.inspectAndroid) }
        case .recovery:
            Button("Restart in recovery…") { review = .init(action: .rebootRecovery, snapshot: state) }
            Button("Check recovery") { installer.send(.inspectRecovery) }
        case .backup:
            Text("On Glass, use CWM Backup and Restore to make a fresh backup first.").font(.caption)
            Button("Find backups") { installer.send(.listBackups) }
            if !state.backupNames.isEmpty {
                Picker("Backup", selection: $backupName) {
                    ForEach(state.backupNames, id: \.self) { Text($0).tag($0) }
                }
                Button("Copy backup to Mac") { installer.send(.copyBackup, value: backupName) }
                    .disabled(!state.backupNames.contains(backupName))
            }
        case .prepare:
            Label("Mac backup verified", systemImage: "checkmark.shield")
            Button("Copy firmware to Glass…") { review = .init(action: .prepare, snapshot: state) }
        case .prepared:
            Label("Prepared · not installed", systemImage: "checkmark.circle")
            if let folder = state.preparedFolder {
                Text(folder).font(.caption.monospaced()).textSelection(.enabled)
            }
            Text("On Glass, open CWM Backup and Restore, then Restore. Select the explorerlink folder shown above. Review the restore confirmation on Glass.")
            Text("Restoration can overwrite boot, system, data and cache. Keep your Mac backup. Hardware compatibility is still unverified.")
                .font(.caption).foregroundStyle(palette.muted)
        }
    }

    private func stepTitle(_ step: InstallerStep) -> String {
        switch step {
        case .check: return "1 · Check Glass"
        case .recovery: return "2 · Recovery"
        case .backup: return "3 · Save backup"
        case .prepare: return "4 · Prepare firmware"
        case .prepared: return "5 · Restore on Glass"
        }
    }
}
