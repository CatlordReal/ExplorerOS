import AppKit
import Darwin
import ExplorerFlashCore
import ExplorerLinkCore
import SwiftUI

@MainActor final class MacPhoneInstallerModel: ObservableObject {
    @Published private(set) var sharing = false
    @Published private(set) var stopping = false
    @Published private(set) var status = "Select Glass, then enable iPhone control."
    @Published private(set) var snapshot: InstallerSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var codeReady = false
    @Published var address = MacPhoneInstallerModel.localAddress()
    private var server: PhoneInstallerServer?
    private var host: PhoneRecoveryHost?
    private var code: String?

    func start(adb: URL, serial: String, firmware: URL, sha256: String) throws {
        guard !sharing else { return }
        let key = PairingKey.generate()
        let endpoint = try InstallerPairingCode(host: address, key: key)
        let parent = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                 appropriateFor: nil, create: true)
        let backupRoot = parent.appendingPathComponent("org.exploreros.ExplorerTools/Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        guard backupRoot.standardizedFileURL == backupRoot.resolvingSymlinksInPath().standardizedFileURL else {
            throw ExplorerFlashError.invalidDevice("Mac backup folder must not contain symbolic links.")
        }
        let installer = try RecoveryInstaller(adb: adb, serial: serial)
        let host = PhoneRecoveryHost(installer: installer, firmware: firmware, sha256: sha256,
                                     backupRoot: backupRoot, firmwareName: firmware.lastPathComponent, serial: serial)
        let server = try PhoneInstallerServer(host: host, keyHex: key)
        self.host = host; self.server = server; sharing = true; stopping = false; error = nil
        server.onSnapshot = { [weak self] in self?.snapshot = $0 }
        server.onStatus = { [weak self] in self?.status = $0 }
        server.onError = { [weak self, weak server] message in
            guard let self else { return }
            self.error = message
            if server?.listeningPort == nil { self.stop() }
        }
        server.onListening = { [weak self] port in
            guard let self else { return }
            self.code = try? InstallerPairingCode(host: endpoint.host, port: port, key: key).text
            self.codeReady = self.code != nil
        }
        do { try server.start() }
        catch { stop(); throw error }
    }

    func stop() {
        guard !stopping else { return }
        stopping = true; codeReady = false; code = nil
        server?.stop(); server = nil
        guard let host, host.snapshot.busy else { finishStopping(); return }
        status = "Stopping current operation…"
        snapshot = host.snapshot
        // Keep the device reservation until the audited installer has settled.
        host.onChange = { [weak self] state in
            guard let self else { return }
            self.snapshot = state
            if !state.busy { self.finishStopping() }
        }
    }

    private func finishStopping() {
        host?.onChange = nil; host = nil
        sharing = false; stopping = false; snapshot = nil
        status = "iPhone control stopped. Recheck Glass before restoring."
    }

    func copyCode() {
        guard sharing, let code else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    func report(_ error: Error) { self.error = error.localizedDescription }

    private static func localAddress() -> String {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return "" }
        defer { freeifaddrs(head) }
        var current = head
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            guard let raw = entry.pointee.ifa_addr, raw.pointee.sa_family == UInt8(AF_INET),
                  String(cString: entry.pointee.ifa_name).hasPrefix("en"),
                  entry.pointee.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var result = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(raw, socklen_t(raw.pointee.sa_len), &result, socklen_t(result.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let value = String(cString: result)
            if LocalEndpoint.accepts(value) { return value }
        }
        return ""
    }
}

struct PhoneInstallerView: View {
    @ObservedObject var model: MacPhoneInstallerModel
    let selectedSerial: String?
    let canStart: Bool
    let start: () -> Void
    @Environment(\.linkPalette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("iPhone installer").font(.largeTitle.bold())
            Text("Keep Glass connected to this Mac by USB. iPhone controls the checks, backup and firmware copy.")
                .foregroundStyle(palette.muted)
            GroupBox("Connection") {
                VStack(alignment: .leading, spacing: 12) {
                    LabeledContent("Glass serial", value: model.snapshot?.serial ?? selectedSerial ?? "Select Glass on the Firmware page")
                    TextField("Mac Wi-Fi address", text: $model.address).disabled(model.sharing)
                    if model.sharing {
                        HStack {
                            Button("Copy connection code") { model.copyCode() }.disabled(!model.codeReady)
                            Button(model.stopping ? "Stopping…" : "Stop iPhone control") { model.stop() }.disabled(model.stopping)
                        }
                        Text("On iPhone, open Explorer Link › Glass › Firmware. Paste the code and connect. The code is private; it expires when control stops.").font(.callout)
                    } else {
                        Button("Enable iPhone control", action: start).buttonStyle(.borderedProminent).disabled(!canStart || model.address.isEmpty)
                    }
                    Text(model.status).font(.callout)
                    if let error = model.error { Text(error).foregroundStyle(.red).font(.callout) }
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let state = model.snapshot {
                GroupBox("Current step") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(state.firmwareName).font(.headline)
                        Text(state.firmwareSHA256).font(.caption.monospaced()).textSelection(.enabled)
                        if let battery = state.battery { Text("Battery \(battery)%") }
                        Text(state.status)
                        if state.busy { ProgressView() }
                        if let error = state.error { Text(error).foregroundStyle(.red) }
                        if let folder = state.preparedFolder { Text(folder).font(.caption.monospaced()).textSelection(.enabled) }
                    }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Text("Final restoration stays in CWM on Glass and can overwrite device data. Preparation does not prove hardware compatibility. Mac-free USB flashing is not available.")
                .font(.callout).foregroundStyle(palette.muted)
        }
    }
}
