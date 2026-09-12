import Foundation
import ImageCaptureCore
import Combine

struct USBGlassCandidate: Identifiable, Equatable {
    let id: String
    let name: String
    let summary: String
}

/// User-started, read-only eligibility check for a USB camera that ImageCaptureCore exposes.
/// It never opens a camera session, reads a catalog, sends PTP, or changes USB mode.
@MainActor final class USBGlassProbe: NSObject, ObservableObject, @preconcurrency ICDeviceBrowserDelegate {
    @Published private(set) var status = "Connect Glass, then start a read-only USB camera check."
    @Published private(set) var devices: [USBGlassCandidate] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?

    private var browser = ICDeviceBrowser()
    private var scanTask: Task<Void, Never>?
    private var generation = UUID()
    private var browserGeneration: UUID?

    override init() {
        super.init()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--usb-probe-preview") {
            devices = [.init(id: "synthetic-usb-camera", name: "Synthetic USB camera", summary: "Synthetic preview only. No USB discovery ran; this is not Glass evidence.")]
            status = "Synthetic USB probe preview."
        }
        #endif
    }

    deinit { browser.stop(); browser.delegate = nil }

    func start() {
        guard !busy else { return }
        let token = UUID()
        browser.stop(); browser.delegate = nil
        browser = ICDeviceBrowser()
        generation = token
        busy = true
        error = nil
        devices.removeAll()
        switch browser.contentsAuthorizationStatus {
        case .authorized:
            beginDiscovery(token: token)
        case .notDetermined:
            status = "Requesting permission to inspect an attached camera. No camera session will open."
            browser.requestContentsAuthorization { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.generation == token, self.busy else { return }
                    guard result == .authorized else {
                        self.permissionDenied(result, token: token)
                        return
                    }
                    self.beginDiscovery(token: token)
                }
            }
        default:
            permissionDenied(browser.contentsAuthorizationStatus, token: token)
        }
    }

    func stop() {
        generation = UUID()
        browserGeneration = nil
        scanTask?.cancel(); scanTask = nil
        browser.stop(); browser.delegate = nil
        busy = false
        if error == nil { status = "USB camera check stopped. No camera session was opened." }
    }

    private func beginDiscovery(token: UUID) {
        guard generation == token, busy else { return }
        let mask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.browsedDeviceTypeMask = mask
        browser.delegate = self
        browserGeneration = token
        browser.start()
        status = "Looking for locally attached USB cameras. Control access was not requested."
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self, self.generation == token, self.busy else { return }
            self.finishDiscovery(token: token)
        }
    }

    private func finishDiscovery(token: UUID) {
        guard generation == token, busy else { return }
        browser.stop(); browser.delegate = nil
        browserGeneration = nil
        busy = false; scanTask = nil
        if devices.isEmpty { status = "No USB camera was exposed to ImageCaptureCore." }
        else { status = "Read-only USB camera check complete. A candidate is not proof of Glass, PTP upload, or firmware staging." }
    }

    private func permissionDenied(_ value: ICAuthorizationStatus, token: UUID) {
        guard generation == token, busy else { return }
        browserGeneration = nil
        busy = false
        error = value == .restricted ? "External-camera inspection is restricted on this iPhone." : "Allow camera contents access in Settings before starting this read-only check."
        status = "USB camera check did not start."
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard browser === self.browser, busy, browserGeneration == generation else { return }
        guard let camera = device as? ICCameraDevice else { return }
        let candidate = makeCandidate(camera)
        devices.removeAll { $0.id == candidate.id }
        devices.append(candidate)
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard browser === self.browser, busy, browserGeneration == generation else { return }
        let id = device.uuidString ?? fallbackID(for: device)
        devices.removeAll { $0.id == id }
    }

    private func makeCandidate(_ device: ICCameraDevice) -> USBGlassCandidate {
        let id = device.uuidString ?? fallbackID(for: device)
        let name = device.name?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Unnamed USB camera"
        let product = device.productKind?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        let googleVID = device.usbVendorID == 0x18d1
        let glassName = name.localizedCaseInsensitiveContains("glass") || (product?.localizedCaseInsensitiveContains("glass") ?? false)
        let ptp = device.capabilities.contains(ICDeviceCapability.cameraDeviceCanAcceptPTPCommands.rawValue)
        let identity = googleVID && glassName ? "Google USB and a Glass name were both reported" : "Unverified camera candidate"
        let capability = ptp ? "PTP command capability reported" : "No PTP command capability reported"
        let kind = product.map { " · \($0)" } ?? ""
        return .init(id: id, name: name, summary: "\(identity) · VID 0x\(String(device.usbVendorID, radix: 16)) PID 0x\(String(device.usbProductID, radix: 16))\(kind) · \(capability). No session, catalog, PTP command, or write was used.")
    }

    private func fallbackID(for device: ICDevice) -> String {
        "usb-\(device.usbVendorID)-\(device.usbProductID)-\(device.name ?? "unnamed")"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
