import SwiftUI
import CoreImage.CIFilterBuiltins
import AppIntents
import ExplorerLinkCore

@main struct ExplorerLinkApp: App {
    @StateObject private var companion = CompanionModel.shared
    @StateObject private var themes = ThemeSettings()
    var body: some Scene {
        WindowGroup {
            ThemedRoot(settings: themes) {
                CompanionTabs(companion: companion, themes: themes)
            }.task {
                GlassShortcuts.updateAppShortcutParameters()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--integration-test"), let key = ProcessInfo.processInfo.environment["EXPLORERLINK_TEST_KEY"] {
                    companion.pair(key); companion.host = "127.0.0.1"; companion.mode = .wifi
                    if ProcessInfo.processInfo.arguments.contains("--media-sync") { companion.mediaSync.receiveEnabled = true }
                    if ProcessInfo.processInfo.arguments.contains("--notes-fixture"), companion.quickNotes.notes.isEmpty {
                        companion.quickNotes.create(title: "Test note", body: "Synthetic note for the Glass integration test.")
                    }
                    do {
                        try await companion.requireConnection()
                        try companion.sendCard(title: "Connection test", body: "Encrypted Wi-Fi connected. Use the simulator controls to send Glass input.")
                    } catch { companion.error = error.localizedDescription }
                    let report: [String: Any] = ["connected": companion.connected, "paired": companion.paired, "status": companion.status, "error": companion.error ?? "", "peer": companion.peer]
                    if let data = try? JSONSerialization.data(withJSONObject: report), let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        try? data.write(to: directory.appendingPathComponent("integration-result.json"), options: .atomic)
                    }
                }
                #endif
            }
        }
    }
}

struct CompanionTabs: View {
    @ObservedObject var companion: CompanionModel
    @ObservedObject var themes: ThemeSettings
    @StateObject private var directions = DirectionsModel()
    @StateObject private var dictation = DictationModel()
    @State private var selection = "glass"
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { GlassHome(companion: companion, dictation: dictation) }.tabItem { Label("Glass", systemImage: "eyeglasses") }.tag("glass")
            NavigationStack { DirectionsView(companion: companion, directions: directions) }.tabItem { Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond") }.tag("directions")
            NavigationStack { IntegrationView(companion: companion) }.tabItem { Label("Shortcuts", systemImage: "square.stack.3d.up") }.tag("shortcuts")
            NavigationStack {
                PhoneIntegrationsView(notes: companion.quickNotes, phone: companion.phoneIntegrations, connected: companion.connected) { note in
                    try companion.sendCard(title: note.title, body: note.body)
                }
            }.tabItem { Label("Phone", systemImage: "iphone") }.tag("phone")
            NavigationStack { CompanionSettings(companion: companion, themes: themes) }.tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag("settings")
        }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--phone-preview") { selection = "phone" }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { dictation.stop(); companion.mediaSync.leaveForeground() }
            companion.refreshMediaCapability()
        }
        .onOpenURL { url in
            do {
                companion.draft = try IntegrationPolicy.previewText(from: url)
                selection = "glass"
            } catch { companion.error = "This shared text could not be opened. Use 4,096 bytes or fewer." }
        }
        .onChange(of: companion.connected) { _, connected in if !connected { dictation.stop() } }
        .alert("Connection", isPresented: Binding(get: { companion.error != nil }, set: { if !$0 { companion.error = nil } })) { Button("OK") { companion.error = nil } } message: { Text(companion.error ?? "") }
    }
}

struct GlassHome: View {
    @ObservedObject var companion: CompanionModel
    @ObservedObject var dictation: DictationModel
    @State private var noteSaved = false
    @State private var showMedia = false
    @State private var showFirmware = false
    @State private var showWiFi = false
    @Environment(\.linkPalette) private var palette
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("EXPLORER EDITION").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(palette.muted)
                        Text("Glass companion").font(.system(.title, design: .rounded, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "eyeglasses").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(palette.tint).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) { Circle().fill(companion.connected ? .green : palette.muted).frame(width: 7, height: 7); Text(companion.status).font(.subheadline.weight(.medium)); Spacer(); if companion.connecting { ProgressView() } }
                    if companion.connected { Text("\(companion.peer.capitalized) · \(companion.mode.rawValue) · Last input: \(companion.lastInput)").font(.caption).foregroundStyle(palette.muted) }
                }
                GlassCard(title: companion.cardTitle, bodyText: companion.cardBody, source: companion.cardSource)
                Button { showMedia = true } label: { Label("Glass media", systemImage: "photo.on.rectangle") }
                Button { showFirmware = true } label: { Label("Firmware", systemImage: "externaldrive") }
                Button { showWiFi = true } label: { Label("Set up Glass Wi-Fi", systemImage: "wifi") }
                VStack(alignment: .leading, spacing: 12) {
                    Text("SEND TEXT").font(.caption2.weight(.semibold)).tracking(1.7).foregroundStyle(palette.muted)
                    TextField("A note for your Glass…", text: $companion.draft, axis: .vertical).lineLimit(2...5).padding(14).background(palette.panel, in: RoundedRectangle(cornerRadius: 16))
                    HStack {
                        Button(action: companion.submitDraft) { Label("Send to Glass", systemImage: "paperplane.fill").frame(maxWidth: .infinity) }.buttonStyle(.borderedProminent).disabled(!companion.connected || companion.draft.isEmpty)
                        Button { if dictation.active { dictation.stop() } else { Task { await dictation.start(companion: companion) } } } label: { Image(systemName: dictation.active ? "stop.fill" : "mic.fill").frame(minWidth: 24) }.buttonStyle(.bordered).disabled(!companion.connected).accessibilityLabel(dictation.active ? "Stop app dictation" : "Start app dictation")
                    }.controlSize(.large)
                    Button(noteSaved ? "Saved to Quick Notes" : "Save note") {
                        companion.quickNotes.create(title: "Quick Note", body: companion.draft)
                        noteSaved = companion.quickNotes.error.isEmpty
                        if !noteSaved { companion.error = companion.quickNotes.error }
                    }.disabled(noteSaved || companion.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .onChange(of: companion.draft) { _, _ in noteSaved = false }
                    if dictation.active { Label("App dictation · on-device", systemImage: "waveform").foregroundStyle(palette.tint); Text(dictation.transcript).font(.caption) }
                    if let error = dictation.error { Text(error).font(.caption).foregroundStyle(.red) }
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Label("Connection", systemImage: "antenna.radiowaves.left.and.right").font(.headline); Spacer() }
                    Picker("Transport", selection: $companion.mode) { ForEach(CompanionModel.Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).disabled(companion.connected || companion.connecting)
                    if companion.mode == .wifi { TextField("Glass IP address", text: $companion.host).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).textFieldStyle(.roundedBorder).disabled(companion.connected || companion.connecting) }
                    Button(companion.connected || companion.connecting ? "Disconnect" : "Connect Glass") {
                        if companion.connected || companion.connecting { companion.disconnect() } else { companion.connect() }
                    }.buttonStyle(.bordered).frame(maxWidth: .infinity)
                    Text(companion.paired ? "Keep both apps open for initial pairing. Bluetooth and Wi-Fi availability depend on Glass firmware." : "Start in Settings to create a pairing key, then scan the QR code on Glass.").font(.caption).foregroundStyle(palette.muted)
                }.padding(18).background(palette.panel, in: RoundedRectangle(cornerRadius: 20))
            }.padding(22).frame(maxWidth: 640)
        }.background(palette.bg).foregroundStyle(palette.fg).navigationTitle("Explorer Link").navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showMedia) {
            MediaLibraryView(store: companion.mediaSync, connected: companion.connected, wifi: companion.mode == .wifi) { companion.refreshMediaCapability() }
        }
        .navigationDestination(isPresented: $showFirmware) { PhoneFirmwareView() }
        .navigationDestination(isPresented: $showWiFi) { WiFiSetupView() }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--media-preview") { showMedia = true }
            if ProcessInfo.processInfo.arguments.contains("--firmware-preview") { showFirmware = true }
            if ProcessInfo.processInfo.arguments.contains("--wifi-preview") { showWiFi = true }
            #endif
        }
    }
}

struct GlassCard: View {
    let title: String
    let bodyText: String
    let source: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Image(systemName: source.contains("MAPKIT") ? "arrow.turn.up.right" : "eyeglasses"); Text(source).font(.system(size: 10, weight: .semibold)).tracking(1); Spacer(); Text("640 × 360").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.5)) }
                .foregroundStyle(Color(hex: 0xA6E3A1))
            Spacer(minLength: 6)
            Text(title).font(.system(.title2, design: .rounded, weight: .medium)).lineLimit(3)
            Text(bodyText).font(.callout).foregroundStyle(.white.opacity(0.8)).lineLimit(4)
            Spacer(minLength: 2)
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 215)
            .background(.black, in: RoundedRectangle(cornerRadius: 20)).foregroundStyle(.white)
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.1)))
            .accessibilityElement(children: .combine)
    }
}

struct DirectionsView: View {
    @ObservedObject var companion: CompanionModel
    @ObservedObject var directions: DirectionsModel
    @Environment(\.linkPalette) private var palette
    var body: some View {
        Form {
            Section {
                TextField("Destination or address", text: $directions.destination)
                Toggle("Walking route", isOn: $directions.walking)
                Button(action: directions.locate) { Label(directions.location == nil ? "Use current location" : "Refresh current location", systemImage: "location") }
                Button { Task { do { companion.route = try await directions.calculate(); try companion.sendRoute() } catch { directions.error = error.localizedDescription } } } label: {
                    HStack { Text("Calculate and send route"); if directions.busy { Spacer(); ProgressView() } }
                }.disabled(!companion.connected || directions.location == nil || directions.destination.isEmpty || directions.busy)
                if let error = directions.error { Text(error).foregroundStyle(.red).font(.caption) }
            } header: { Text("Apple MapKit") } footer: { Text("Route steps come from MapKit. Advance with Glass swipes or the buttons below. This companion does not track or mirror a route running in Apple Maps.") }
            if let route = companion.route, let step = route.current {
                Section("\(route.destination) · \(route.index + 1) of \(route.steps.count)") {
                    Label(step.instruction, systemImage: "arrow.turn.up.right").font(.title3)
                    HStack {
                        Button("Previous") { companion.route?.move(-1); do { try companion.sendRoute() } catch { companion.error = error.localizedDescription } }.disabled(route.index == 0)
                        Spacer()
                        Button("Next") { companion.route?.move(1); do { try companion.sendRoute() } catch { companion.error = error.localizedDescription } }.disabled(route.index >= route.steps.count - 1)
                    }
                    Button("Continue in Apple Maps", action: directions.openInMaps)
                    Button("Stop sharing route", role: .destructive, action: companion.stopRoute)
                }
            }
        }.scrollContentBackground(.hidden).background(palette.bg).navigationTitle("Directions")
    }
}

struct IntegrationView: View {
    @ObservedObject var companion: CompanionModel
    @Environment(\.linkPalette) private var palette
    var body: some View {
        List {
            Section("Siri & Shortcuts") {
                Label("Send text to Glass", systemImage: "text.bubble")
                Label("Connect Glass", systemImage: "antenna.radiowaves.left.and.right")
                Label("Next Glass direction", systemImage: "arrow.turn.up.right")
                Text("Add these actions in Shortcuts. Combine Dictate Text with Send text to Glass for a spoken note. Actions open the app to establish the connection.").font(.callout).foregroundStyle(.secondary)
                SiriTipView(intent: SendToGlassIntent())
            }
            Section("On Glass") {
                LabeledContent("Notifications", value: companion.capabilities.contains("ancs.available") ? "ANCS discovered on Glass" : "Not verified on this connection")
                LabeledContent("Media controls", value: companion.capabilities.contains("ams.available") ? "AMS discovered on Glass" : "Not verified on this connection")
                LabeledContent("Call actions", value: "Only when iOS offers an action")
                Text("Notification access and media control are negotiated by the Glass bridge with iOS. Allow Share System Notifications in Bluetooth settings when offered. Availability must be checked on real Glass.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Siri from the headset") {
                Label("Requires verified Glass firmware support", systemImage: "wrench.adjustable")
                Text("Compatible ExplorerOS builds can request Siri through Glass’s stock Bluetooth headset service. Pair Glass in iPhone Bluetooth settings. Microphone and speaker routing still require testing on Glass.")
                Text("The Glass indicator reports Bluetooth voice audio. Siri transcripts and exact listening state are unavailable. The microphone button here uses app dictation.").font(.caption).foregroundStyle(.secondary)
            }
            if companion.connected { Section("Authenticated peer") { Text(companion.capabilities.sorted().joined(separator: ", ")).font(.caption.monospaced()) } }
        }.scrollContentBackground(.hidden).background(palette.bg).navigationTitle("Shortcuts & controls")
    }
}

struct CompanionSettings: View {
    @ObservedObject var companion: CompanionModel
    @ObservedObject var themes: ThemeSettings
    @State private var key = ""
    @State private var showQR = false
    @State private var replace = false
    @Environment(\.linkPalette) private var palette
    var body: some View {
        Form {
            Section("Glass network") {
                NavigationLink("Set up Glass Wi-Fi") { WiFiSetupView() }
            }
            Section {
                LabeledContent("Pairing", value: companion.paired ? "Key stored in Keychain" : "Not paired")
                Button(companion.paired ? "Replace pairing key…" : "Create pairing key") { if companion.paired { replace = true } else { companion.generatePairing(); showQR = true } }
                if companion.paired { Button("Show pairing QR") { showQR = true } }
                SecureField("Or paste a 64-character key", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Use pasted key") { companion.pair(key); key = "" }.disabled(key.isEmpty)
                if companion.paired { Button("Forget pairing", role: .destructive, action: companion.forget) }
            } header: { Text("Pair one Glass") } footer: { Text("One Glass at a time. Replacing a pairing disconnects the previous device. Treat the QR code like a password. ANCS Bluetooth bonding is a separate step.") }
            ThemeSettingsView(settings: themes)
            Section("Connection limits") {
                Text("Initial BLE scanning needs both apps open. Reopen and reconnect after app termination; automatic restoration is not implemented. Wi-Fi can be suspended in the background. ANCS and AMS are system services independent of the companion.")
                    .font(.caption)
            }
        }.scrollContentBackground(.hidden).background(palette.bg).navigationTitle("Settings")
            .confirmationDialog("Replace this pairing?", isPresented: $replace, titleVisibility: .visible) { Button("Replace and disconnect", role: .destructive) { companion.generatePairing(); showQR = true } } message: { Text("The previous Glass key will stop working with this app.") }
            .sheet(isPresented: $showQR) { PairingQRView(key: companion.keyForQR ?? "") }
    }
}

struct PairingQRView: View {
    let key: String
    @Environment(\.dismiss) private var dismiss
    private var qr: UIImage? {
        guard let data = try? JSONSerialization.data(withJSONObject: ["service": "explorerlink", "v": 1, "key": key]) else { return nil }
        let filter = CIFilter.qrCodeGenerator(); filter.message = data
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)), let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    var body: some View {
        NavigationStack { VStack(spacing: 24) {
            Image(systemName: "qrcode.viewfinder").font(.largeTitle)
            Text("Pair your Glass").font(.title.bold())
            Text("Open Pair on the Glass bridge, then scan this code. Only show it to the device you trust.").multilineTextAlignment(.center)
            if let qr { Image(uiImage: qr).interpolation(.none).resizable().scaledToFit().frame(maxWidth: 280).padding(16).background(.white).accessibilityLabel("Pairing QR code") }
            Text(key).font(.caption.monospaced()).textSelection(.enabled)
            Text("Private pairing key. Never share a screenshot of this screen.").font(.caption).foregroundStyle(.secondary)
        }.padding(24).navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } } }
    }
}
