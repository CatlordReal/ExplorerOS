import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ExplorerFlashCore

@MainActor final class FlashAppDelegate: NSObject, NSApplicationDelegate {
    static var flashing = false
    let model = ToolsModel()
    let themes = ThemeSettings()
    private var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let content = ThemedRoot(settings: themes) { ToolsView(model: self.model, themes: self.themes) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Explorer Tools"
        window.minSize = NSSize(width: 780, height: 620)
        window.contentView = NSHostingView(rootView: content)
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window?.makeKeyAndOrderFront(nil); return true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { Self.flashing ? .terminateCancel : .terminateNow }
}

@main struct ExplorerToolsApp: App {
    @NSApplicationDelegateAdaptor(FlashAppDelegate.self) private var delegate
    var body: some Scene {
        Settings { Form { ThemeSettingsView(settings: delegate.themes) }.formStyle(.grouped).padding().frame(width: 500, height: 600) }
    }
}

@MainActor final class ToolsModel: ObservableObject {
    @Published var adbPath = ""
    @Published var fastbootPath = ""
    @Published private(set) var devices: [Device] = []
    @Published var selected = ""
    @Published private(set) var busy = false
    @Published private(set) var log = "Choose tools, then refresh devices."
    @Published private(set) var portable: PortableResources?
    @Published private(set) var bundleStatus = "No portable bundle. Choose your own files."
    @Published var showAdvancedFirmware = false
    private let portableRoot = Bundle.main.resourceURL?.appendingPathComponent("Portable", isDirectory: true)
    @Published private(set) var manifest: FlashManifest?
    @Published private(set) var manifestURL: URL?
    @Published private(set) var apk: URL?
    @Published private(set) var plan: FlashPlan?
    @Published private(set) var installPlan: ProcessCommand?
    @Published var acknowledgement = ""
    @Published var recoveryVerified = false
    @Published var batteryVerified = false
    @Published var firmwareEnabled = false
    @Published var page = "apps"
    private let runner = ProcessRunner()
    var selectedDevice: Device? { devices.first { "\($0.mode.rawValue):\($0.serial)" == selected } }
    var canFlash: Bool { !busy && firmwareEnabled && recoveryVerified && batteryVerified && plan != nil && acknowledgement == plan?.device.serial }

    init() {
        guard let root = portableRoot, FileManager.default.fileExists(atPath: root.appendingPathComponent("bundle.json").path) else { return }
        do {
            let resources = try PortableResources(root: root)
            portable = resources
            adbPath = resources.candidate(role: "adb")?.path ?? ""
            fastbootPath = resources.candidate(role: "fastboot")?.path ?? ""
            apk = resources.candidate(role: "bridge")
            bundleStatus = "Bundled files selected · not yet verified"
        } catch { bundleStatus = error.localizedDescription }
    }
    func useBundledBridge() {
        guard let candidate = portable?.candidate(role: "bridge") else { log = "Bundled bridge unavailable."; return }
        invalidate(); apk = candidate; log = "Bundled bridge selected. Validate before installing."
    }
    func useBundledTools() {
        guard let portable else { log = "Bundled tools unavailable."; return }
        invalidate(); adbPath = portable.candidate(role: "adb")?.path ?? ""; fastbootPath = portable.candidate(role: "fastboot")?.path ?? ""
    }
    func verifyBundle() async {
        guard !busy, let portable else { return }
        busy = true; bundleStatus = "Verifying bundle…"; defer { busy = false }
        do {
            try await Task.detached { for file in portable.bundle.files { _ = try portable.validated(role: file.role) } }.value
            bundleStatus = "Bundle hashes verified"
            log = portable.bundle.isCWMBackup ? "CWM backup verified. Restore manually in recovery; raw-image flashing is not supported for this ZIP." : "Bundle verified. Use only the workflow documented in the install guide."
        } catch { bundleStatus = "Bundle verification failed"; log = error.localizedDescription }
    }
    func openFirmwareFolder() {
        guard let url = portable?.candidate(role: "firmware") else { log = "Bundled firmware unavailable."; return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    func openInstallGuide() {
        guard let root = portableRoot else { return }
        let guide = root.appendingPathComponent("INSTALL.md")
        guard FileManager.default.fileExists(atPath: guide.path), PortableResources.contains(guide, root: root), guide.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { log = "Install guide unavailable."; return }
        NSWorkspace.shared.open(guide)
    }
    private func checkedBundleFile(_ url: URL, role: String) async throws -> URL {
        guard let root = portableRoot, PortableResources.contains(url, root: root) else { return url }
        guard let portable else { throw ExplorerFlashError.invalidManifest("Bundle unavailable. Choose your own files outside the app bundle.") }
        return try await Task.detached { try portable.checkedSelection(url, role: role) }.value
    }
    func invalidate() { plan = nil; installPlan = nil; acknowledgement = ""; recoveryVerified = false; batteryVerified = false }
    private func binary(_ path: String, role: String) async throws -> URL {
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { throw ExplorerFlashError.invalidDevice("Choose an existing absolute executable path for adb/fastboot.") }
        return try await checkedBundleFile(URL(fileURLWithPath: path), role: role)
    }
    func choose(kind: String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if kind == "manifest" { panel.allowedContentTypes = [.json] }
        else if kind == "apk" { panel.allowedContentTypes = [UTType(filenameExtension: "apk") ?? .data] }
        panel.begin { [weak self] result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                self.invalidate()
                do {
                    switch kind {
                    case "manifest":
                        let manifest = try FlashManifest.load(from: url)
                        self.manifest = manifest; self.manifestURL = url; self.log = "Manifest loaded. Select a fastboot device, then validate a preview."
                    case "apk": self.apk = url; self.log = "APK selected. Review the exact device and command before installing."
                    case "adb": self.adbPath = url.path
                    case "fastboot": self.fastbootPath = url.path
                    default: break
                    }
                } catch { self.log = error.localizedDescription }
            }
        }
    }
    func refresh() async {
        guard !busy else { return }; busy = true; invalidate(); defer { busy = false }
        do {
            let adb = try await binary(adbPath, role: "adb"); let fastboot = try await binary(fastbootPath, role: "fastboot")
            let a = try await runner.run(.init(executable: adb, arguments: ["devices", "-l"], timeout: 15))
            let f = try await runner.run(.init(executable: fastboot, arguments: ["devices"], timeout: 15))
            guard a.exitCode == 0 else { throw ExplorerFlashError.processFailed(a) }
            guard f.exitCode == 0 else { throw ExplorerFlashError.processFailed(f) }
            devices = DeviceParser.adbDevices(a.stdout) + DeviceParser.fastbootDevices(f.stdout)
            if !devices.contains(where: { "\($0.mode.rawValue):\($0.serial)" == selected }) { selected = "" }
            log = devices.isEmpty ? "No ADB or fastboot devices found. Connect Glass with USB debugging enabled. Nothing was changed." : "Found \(devices.count) device(s). Choose the exact Glass serial; no device is automatically selected."
        } catch { devices = []; selected = ""; log = error.localizedDescription }
    }
    func preview() async {
        guard !busy else { return }; busy = true; invalidate(); defer { busy = false }
        do {
            guard let device = selectedDevice else { throw ExplorerFlashError.invalidDevice("Select a device first.") }
            if page == "apps" {
                guard let apk else { throw ExplorerFlashError.invalidDevice("Choose an APK first.") }
                let adb = try await binary(adbPath, role: "adb")
                let checkedAPK = try await checkedBundleFile(apk, role: "bridge")
                installPlan = try APKInstaller.plan(adb: adb, device: device, apk: checkedAPK)
                log = "APK preview ready. Installing replaces an existing app with the same package ID."
            } else {
                guard let manifest, let manifestURL else { throw ExplorerFlashError.invalidManifest("Choose a verified release manifest first.") }
                let fastboot = try await binary(fastbootPath, role: "fastboot")
                let prepared = try await Task.detached { try FlashPlanner.review(manifest: manifest, manifestURL: manifestURL, fastboot: fastboot, device: device) }.value
                plan = prepared
                log = "Hashes and sizes verified. This proves file integrity, not firmware compatibility or recovery. No hardware command was sent."
            }
        } catch { log = error.localizedDescription }
    }
    func install() async {
        guard !busy, let approved = installPlan, let device = selectedDevice, let apk else { return }
        busy = true; defer { busy = false; installPlan = nil }
        do {
            let adb = try await binary(adbPath, role: "adb")
            let fresh = try await runner.run(.init(executable: adb, arguments: ["devices", "-l"], timeout: 15))
            guard fresh.exitCode == 0 else { throw ExplorerFlashError.processFailed(fresh) }
            let selected = try DeviceParser.select(serial: device.serial, mode: .adb, from: DeviceParser.adbDevices(fresh.stdout))
            let checkedAPK = try await checkedBundleFile(apk, role: "bridge")
            let command = try APKInstaller.plan(adb: adb, device: selected, apk: checkedAPK)
            guard command == approved else { throw ExplorerFlashError.invalidDevice("Selection changed. Review again.") }
            let result = try await runner.run(command)
            log = result.stdout + "\n" + result.stderr
            guard result.exitCode == 0 else { throw ExplorerFlashError.processFailed(result) }
            log += "\nAPK installation completed for \(selected.serial)."
        } catch { log += "\n" + error.localizedDescription }
    }
    func flash() async {
        guard canFlash, let plan, let manifest, let manifestURL else { return }
        busy = true; FlashAppDelegate.flashing = true
        defer { busy = false; FlashAppDelegate.flashing = false; invalidate(); firmwareEnabled = false }
        do {
            let fastboot = try await binary(fastbootPath, role: "fastboot")
            let fresh = try await runner.run(.init(executable: fastboot, arguments: ["devices"], timeout: 15))
            guard fresh.exitCode == 0 else { throw ExplorerFlashError.processFailed(fresh) }
            log = "Flashing verified plan. Keep USB connected. Closing the app is disabled until this finishes."
            let results = try await FlashExecutor().execute(plan: plan, manifest: manifest, manifestURL: manifestURL, fastboot: fastboot, runner: runner, acknowledgement: acknowledgement, currentDevices: DeviceParser.fastbootDevices(fresh.stdout))
            log = results.map { $0.stdout + "\n" + $0.stderr }.joined(separator: "\n") + "\nPlan completed. No reboot was issued. Verify boot and recovery on the device."
        } catch { log += "\nStopped: " + error.localizedDescription }
    }
}

struct ToolsView: View {
    @ObservedObject var model: ToolsModel
    @ObservedObject var themes: ThemeSettings
    @Environment(\.linkPalette) private var palette
    @State private var confirmInstall = false
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "eyeglasses").font(.system(size: 34, weight: .light)).foregroundStyle(palette.tint)
                Text("Explorer\nTools").font(.system(.title, design: .rounded, weight: .semibold))
                Text("Apps and firmware").foregroundStyle(palette.muted)
                Divider()
                sidebarButton("Install apps", icon: "square.and.arrow.down", page: "apps")
                sidebarButton("Firmware", icon: "externaldrive", page: "firmware")
                sidebarButton("Appearance", icon: "paintpalette", page: "appearance")
                Spacer()
                Label("Preview first", systemImage: "checkmark.shield").font(.caption).foregroundStyle(palette.muted)
                Text("Explorer Edition · USB").font(.caption2).foregroundStyle(palette.muted)
            }.padding(26).frame(width: 220, alignment: .leading).background(palette.panel)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if model.page == "appearance" {
                        Text("Appearance").font(.largeTitle.bold())
                        Form { ThemeSettingsView(settings: themes) }.formStyle(.grouped).frame(minHeight: 520)
                    } else {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(model.page == "apps" ? "Install APK" : "Firmware").font(.system(.largeTitle, design: .rounded, weight: .semibold))
                                Text(model.page == "apps" ? "Select an APK and device." : "Manual recovery or advanced raw images").foregroundStyle(palette.muted)
                            }; Spacer(); if model.busy { ProgressView() }
                        }
                        portablePanel
                        if model.page == "firmware" { Toggle("Advanced raw-image workflow", isOn: $model.showAdvancedFirmware) }
                        if model.page == "apps" || model.showAdvancedFirmware {
                        GroupBox("1 · Select tools and device") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack { Text("ADB").frame(width: 70, alignment: .leading); TextField("Absolute path", text: $model.adbPath); Button("Choose…") { model.choose(kind: "adb") } }
                                HStack { Text("Fastboot").frame(width: 70, alignment: .leading); TextField("Absolute path", text: $model.fastbootPath); Button("Choose…") { model.choose(kind: "fastboot") } }
                                HStack {
                                    Picker("Device", selection: $model.selected) {
                                        Text("Select a device").tag("")
                                        ForEach(Array(model.devices.enumerated()), id: \.offset) { _, device in Text("\(device.serial) · \(device.mode.rawValue) · \(device.state)").tag("\(device.mode.rawValue):\(device.serial)") }
                                    }
                                    Button("Refresh devices") { Task { await model.refresh() } }
                                }
                            }.padding(8)
                        }
                        GroupBox(model.page == "apps" ? "2 · Choose an app" : "2 · Choose verified firmware") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text((model.page == "apps" ? model.apk?.lastPathComponent : model.manifestURL?.lastPathComponent) ?? "No file selected").foregroundStyle(palette.muted)
                                    Spacer()
                                    Button(model.page == "apps" ? "Choose APK…" : "Choose manifest…") { model.choose(kind: model.page == "apps" ? "apk" : "manifest") }
                                }
                                if model.page == "firmware" {
                                    Text("Raw partition images only. Supply a verified product-specific manifest and recovery procedure. CWM backup ZIPs are not accepted.").font(.callout)
                                    if let manifest = model.manifest {
                                        Text("Expected product: \(manifest.product)").font(.headline)
                                        ForEach(manifest.images, id: \.partition) { image in
                                            VStack(alignment: .leading) { Text("\(image.partition) · \(image.file) · \(image.size) bytes"); Text(image.sha256).font(.caption.monospaced()).textSelection(.enabled) }
                                        }
                                    }
                                }
                                Button("Validate and preview") { Task { await model.preview() } }.buttonStyle(.borderedProminent).disabled(model.selected.isEmpty)
                            }.padding(8)
                        }
                        if let command = model.installPlan {
                            GroupBox("3 · Install reviewed app") {
                                VStack(alignment: .leading, spacing: 12) { commandView(command); Button("Install APK…") { confirmInstall = true }.buttonStyle(.borderedProminent) }.padding(8)
                            }
                        }
                        if let plan = model.plan {
                            GroupBox("3 · Review firmware write") {
                                VStack(alignment: .leading, spacing: 12) {
                                    ForEach(Array(plan.commands.enumerated()), id: \.offset) { commandView($0.element) }
                                    Toggle("Enable firmware writing for this reviewed plan", isOn: $model.firmwareEnabled)
                                    Toggle("I verified the image source, correct Glass model, and working recovery procedure", isOn: $model.recoveryVerified)
                                    Toggle("Battery is charged and USB connection is stable", isOn: $model.batteryVerified)
                                    TextField("Type device serial: \(plan.device.serial)", text: $model.acknowledgement)
                                    Button("Flash reviewed images", role: .destructive) { Task { await model.flash() } }.disabled(!model.canFlash)
                                    Text("Flashing can brick Glass if the images or hardware assumptions are wrong. These checks cannot certify compatibility.").font(.caption).foregroundStyle(palette.muted)
                                }.padding(8)
                            }
                        }
                        }
                        GroupBox("Activity") { Text(model.log).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading).padding(8) }
                    }
                }.padding(28).frame(maxWidth: 1050)
            }.background(palette.bg).disabled(model.busy)
        }.foregroundStyle(palette.fg)
            .onChange(of: model.selected) { _, _ in model.invalidate() }
            .onChange(of: model.adbPath) { _, _ in model.invalidate() }
            .onChange(of: model.fastbootPath) { _, _ in model.invalidate() }
            .onChange(of: model.page) { _, _ in model.invalidate() }
            .onChange(of: model.showAdvancedFirmware) { _, _ in model.invalidate() }
            .confirmationDialog("Install this APK on the selected Glass?", isPresented: $confirmInstall, titleVisibility: .visible) { Button("Install APK") { Task { await model.install() } } } message: { Text("Existing app data follows Android’s package upgrade rules. Review the serial and APK path above.") }
    }
    private var portablePanel: some View {
                        GroupBox("Portable bundle") {
                            VStack(alignment: .leading, spacing: 10) {
                                if let resources = model.portable {
                                    Text(resources.bundle.title).font(.headline)
                                    Text(model.bundleStatus).foregroundStyle(palette.muted)
                                    if model.page == "firmware" {
                                        if let firmware = resources.bundle.files.first(where: { $0.role == "firmware" }) {
                                            Text("\(URL(fileURLWithPath: firmware.path).lastPathComponent) · \(ByteCountFormatter.string(fromByteCount: Int64(clamping: firmware.size), countStyle: .file))")
                                            Text(resources.bundle.isCWMBackup ? "CWM backup ZIP. Restore manually in recovery. Not accepted by the raw-image flasher." : "Use the install guide for this firmware format.")
                                        }
                                        HStack { Button("Verify bundle") { Task { await model.verifyBundle() } }; Button("Open firmware folder") { model.openFirmwareFolder() }; Button("Open install guide") { model.openInstallGuide() } }
                                    } else {
                                        HStack { Button("Use bundled bridge") { model.useBundledBridge() }.disabled(resources.candidate(role: "bridge") == nil); Button("Use bundled tools") { model.useBundledTools() }; Button("Verify bundle") { Task { await model.verifyBundle() } } }
                                    }
                                } else { Text(model.bundleStatus).foregroundStyle(palette.muted) }
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        }
    }
    private func sidebarButton(_ text: String, icon: String, page: String) -> some View {
        Button { model.page = page } label: { Label(text, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(model.page == page ? palette.tint.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 10)) }.buttonStyle(.plain).disabled(model.busy)
    }
    private func commandView(_ command: ProcessCommand) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(command.executable.path).font(.caption.monospaced())
            Text(command.arguments.map { "[\($0)]" }.joined(separator: " ")).font(.caption.monospaced()).textSelection(.enabled)
        }
    }
}
