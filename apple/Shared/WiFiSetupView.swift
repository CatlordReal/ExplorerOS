import SwiftUI
import CoreImage.CIFilterBuiltins
import ExplorerLinkCore
#if os(macOS)
import AppKit
#endif

struct WiFiSetupView: View {
    @State private var ssid = ""
    @State private var password = ""
    @State private var security = WiFiQRCode.Security.wpaPersonal
    @State private var code: CGImage?
    @State private var error: String?
    @FocusState private var editing: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.linkPalette) private var palette

    init() {
        #if DEBUG
        // Synthetic credentials only; this preview never connects to a network.
        if ProcessInfo.processInfo.arguments.contains("--wifi-preview") {
            _ssid = State(initialValue: "Glass Test Network")
            _password = State(initialValue: "test-network-2026")
            if let payload = try? WiFiQRCode.payload(ssid: "Glass Test Network", password: "test-network-2026", security: .wpaPersonal) {
                _code = State(initialValue: Self.image(for: payload))
            }
        }
        #endif
    }

    var body: some View {
        Group {
            #if os(iOS)
            ScrollView { content.padding(20).frame(maxWidth: 580) }
                .background(palette.bg)
                .navigationTitle("Glass Wi-Fi")
                .navigationBarTitleDisplayMode(.inline)
            #else
            content.frame(maxWidth: 640, alignment: .leading)
            #endif
        }
        .foregroundStyle(palette.fg)
        .onChange(of: ssid) { _, _ in hideCode() }
        .onChange(of: password) { _, _ in hideCode() }
        .onChange(of: security) { _, _ in hideCode() }
        .onChange(of: editing) { _, active in if active { hideCode() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { clearCredentials() } }
        .onDisappear(perform: clearCredentials)
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in clearCredentials() }
        #endif
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            #if os(macOS)
            Text("Wi-Fi setup").font(.system(.largeTitle, design: .rounded, weight: .semibold))
            #endif
            VStack(alignment: .leading, spacing: 12) {
                TextField("Network name (SSID)", text: $ssid)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled().focused($editing)
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                Picker("Security", selection: $security) {
                    Text("WPA / WPA2 Personal").tag(WiFiQRCode.Security.wpaPersonal)
                    Text("Open").tag(WiFiQRCode.Security.open)
                }.pickerStyle(.segmented)
                if security == .wpaPersonal {
                    SecureField("Wi-Fi password", text: $password)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().focused($editing)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }
                Button("Show Wi-Fi code", action: showCode)
                    #if os(macOS)
                    .buttonStyle(.bordered)
                    .tint(palette.bg)
                    .foregroundStyle(palette.fg)
                    #else
                    .buttonStyle(.borderedProminent)
                    .foregroundStyle(palette.dark ? Color.black : Color.white)
                    #endif
                    .disabled(ssid.isEmpty || (security == .wpaPersonal && password.isEmpty))
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }
            if let code {
                VStack(spacing: 12) {
                    Image(decorative: code, scale: 1)
                        .interpolation(.none).resizable().scaledToFit()
                        #if os(iOS)
                        .frame(maxWidth: 220)
                        #else
                        .frame(maxWidth: 260)
                        #endif
                        .padding(12).background(.white)
                        .accessibilityLabel("Wi-Fi QR code for Glass")
                    Text(security == .wpaPersonal ? "Code contains your Wi-Fi password." : "Code contains the network name.")
                        .font(.caption).foregroundStyle(palette.muted)
                    Button("Hide code", action: hideCode)
                }.frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("On Glass").font(.headline)
                Text("Settings › Wi-Fi › Add Wi-Fi network › Use a Wi-Fi access QR code.")
                Text("Scan this code, then check the connection on Glass.")
                Text("Works offline. No USB needed. Credentials clear when you leave this screen or app.")
                    .font(.caption).foregroundStyle(palette.muted)
            }.fixedSize(horizontal: false, vertical: true)
        }
    }

    private func showCode() {
        editing = false
        hideCode()
        do {
            let payload = try WiFiQRCode.payload(ssid: ssid, password: password, security: security)
            guard let image = Self.image(for: payload) else {
                error = "The Wi-Fi code could not be created. Try again."
                return
            }
            code = image
        } catch { self.error = error.localizedDescription }
    }

    private func hideCode() { code = nil; error = nil }

    private func clearCredentials() {
        hideCode()
        ssid = ""; password = ""; editing = false
    }

    private static func image(for payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        // Keep module edges sharp and an explicit white quiet zone in every theme.
        let bounds = output.extent.insetBy(dx: -4, dy: -4)
        let white = CIImage(color: .white).cropped(to: bounds)
        let padded = output.composited(over: white).cropped(to: bounds)
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
}
