import SwiftUI
import ExplorerLinkCore

@MainActor final class CompanionModel: ObservableObject {
    static let shared = CompanionModel()
    enum Mode: String, CaseIterable { case wifi = "Wi-Fi", bluetooth = "Bluetooth" }
    @Published var mode: Mode = Mode(rawValue: UserDefaults.standard.string(forKey: "linkMode") ?? "") ?? .wifi { didSet { UserDefaults.standard.set(mode.rawValue, forKey: "linkMode") } }
    @Published var host = UserDefaults.standard.string(forKey: "glassHost") ?? ""
    @Published private(set) var status = "Disconnected"
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var paired = KeychainStore.read() != nil
    @Published private(set) var peer = "Glass"
    @Published private(set) var capabilities: Set<String> = []
    @Published var error: String?
    @Published var draft = ""
    @Published var cardTitle = "No card"
    @Published var cardBody = "Connect Glass to send text or directions."
    @Published var cardSource = "EXPLORER LINK"
    @Published var lastInput = "No input yet"
    @Published var route: RouteProgress?
    let quickNotes = QuickNotesStore()
    let phoneIntegrations = PhoneIntegrationsModel()
    private var browsedNoteIndex: Int?
    private var transport: LinkTransport?
    private var session: SecureSession?
    private var decoder = LineDecoder()
    private var timeout: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var pendingPing: String?
    private var capabilitiesSent = false
    var keyForQR: String? { KeychainStore.read() }

    func pair(_ text: String) {
        do {
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            try KeychainStore.save(key)
            disconnect(); paired = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func generatePairing() { pair(PairingKey.generate()) }
    func forget() { disconnect(); KeychainStore.delete(); paired = false; cardTitle = "Pairing removed"; cardBody = "Remove the pairing on Glass too."; capabilities = [] }
    func connect() {
        disconnect()
        guard let key = KeychainStore.read() else { error = "Create or enter a pairing key first."; return }
        if mode == .wifi && !LocalEndpoint.accepts(host) {
            error = "Enter a private Glass IP address, localhost, or a .local hostname, without a URL or port."; return
        }
        do { session = try SecureSession(keyHex: key) } catch { self.error = error.localizedDescription; return }
        error = nil; connecting = true; status = mode == .wifi ? "Connecting…" : "Open Glass and scan for iPhone"
        UserDefaults.standard.set(host, forKey: "glassHost")
        let link: LinkTransport = mode == .wifi ? WiFiTransport() : BLETransport()
        transport = link
        link.onOpen = { [weak self] in self?.opened() }
        link.onBytes = { [weak self] bytes in self?.received(bytes) }
        link.onClose = { [weak self] reason in self?.fail(reason) }
        if let wifi = link as? WiFiTransport { wifi.start(host: host.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if let ble = link as? BLETransport { ble.start() }
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.mode == .bluetooth ? 120 : 15))
            guard !Task.isCancelled, let self, !self.connected else { return }
            self.fail("Connection timed out. Keep both apps open, check the address and pairing key, then retry.")
        }
    }
    private func opened() {
        status = "Authenticating…"
        do { if let session { try transport?.send(session.hello()) } } catch { fail(error.localizedDescription) }
    }
    private func received(_ bytes: Data) {
        do {
            for line in try decoder.append(bytes) {
                guard let session else { return }
                if let message = try session.receive(line) {
                    if !connected {
                        connected = true; connecting = false; status = "Connected · encrypted"; timeout?.cancel(); startHeartbeat()
                    }
                    try handle(message)
                }
                if session.hasPeerHello && !capabilitiesSent {
                    capabilitiesSent = true
                    try transport?.send(session.seal(.capabilities(endpoint: "ios", features: ["cards", "navigation", "appIntents", "speech", "phone.actions"])))
                }
            }
        } catch { fail(error.localizedDescription) }
    }
    private func handle(_ message: LinkMessage) throws {
        switch message.type {
        case "capabilities":
            peer = message.payload["endpoint"] ?? "Glass"
            capabilities = Set((message.payload["features"] ?? "").split(separator: ",").map(String.init))
        case "ping": try send(.init(type: "pong", payload: message.payload))
        case "pong": if message.payload["id"] == pendingPing { pendingPing = nil }
        case "phone.action":
            guard Set(message.payload.keys) == ["action"], let action = PhoneIntegrationAction(rawValue: message.payload["action"] ?? "") else { throw LinkFailure.invalidMessage }
            if action == .notesBrowse, !quickNotes.notes.isEmpty, route == nil { try browseQuickNotes(); return }
            phoneIntegrations.enqueue(action)
            try sendCard(title: action.title, body: "Open Explorer Link on iPhone, then Phone, to review this request.")
        case "input":
            guard let gesture = GlassGesture(rawValue: message.payload["gesture"] ?? "") else { throw LinkFailure.invalidMessage }
            lastInput = gesture.rawValue
            if browsedNoteIndex != nil {
                if gesture == .swipeDown { browsedNoteIndex = nil; return }
                if gesture == .swipeLeft || gesture == .swipeRight {
                    browsedNoteIndex = (browsedNoteIndex ?? 0) + (gesture == .swipeRight ? 1 : -1)
                    try sendBrowsedNote(); return
                }
            }
            switch GlassControls.action(for: gesture, routeActive: route != nil) {
            case .nextStep: route?.move(1); try sendRoute()
            case .previousStep: route?.move(-1); try sendRoute()
            case .dismiss: cardTitle = "Card dismissed"; cardBody = "Glass input received."
            case .showCompanion: status = "Camera input received"
            case .none: break
            }
        case "error": error = message.payload["message"] ?? "The peer reported an error."
        default: try send(.init(type: "error", payload: ["code": "unsupported_type", "message": "Unsupported message type."]))
        }
    }
    private func startHeartbeat() {
        heartbeat?.cancel()
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(20)) } catch { return }
                guard let self, self.connected else { return }
                if self.pendingPing != nil { self.fail("The peer stopped responding. Reconnect when both apps are active."); return }
                let id = UUID().uuidString; self.pendingPing = id
                do { try self.send(.init(type: "ping", payload: ["id": id])) } catch { self.fail(error.localizedDescription); return }
            }
        }
    }
    func send(_ message: LinkMessage) throws {
        guard connected, let session, let transport else { throw LinkFailure.notReady }
        try transport.send(session.seal(message))
    }
    func sendCard(title: String = "From iPhone", body: String, source: String = "companion") throws {
        try send(.init(type: "card", payload: ["title": title, "body": body, "source": source]))
        cardTitle = title; cardBody = body; cardSource = source == "speech" ? "APP DICTATION" : source == "appIntent" ? "SHORTCUT" : "FROM IPHONE"
    }
    func submitDraft() { do { try sendCard(body: draft); draft = "" } catch { self.error = error.localizedDescription } }
    func browseQuickNotes() throws { browsedNoteIndex = 0; try sendBrowsedNote() }
    private func sendBrowsedNote() throws {
        guard !quickNotes.notes.isEmpty else { browsedNoteIndex = nil; try sendCard(title: "Quick Notes", body: "No saved notes."); return }
        let index = min(max(browsedNoteIndex ?? 0, 0), quickNotes.notes.count - 1)
        browsedNoteIndex = index
        let note = quickNotes.notes[index]
        try sendCard(title: "\(index + 1)/\(quickNotes.notes.count) · \(note.title)", body: note.body)
    }
    func sendRoute() throws {
        browsedNoteIndex = nil
        guard let message = route?.message() else { return }
        try send(message)
        cardTitle = message.payload["instruction"] ?? "Directions"
        cardBody = "\(message.payload["distance"] ?? "") · \(message.payload["destination"] ?? "")"
        cardSource = "MAPKIT · STEP \((route?.index ?? 0) + 1) OF \(route?.steps.count ?? 0)"
    }
    func stopRoute() { do { try send(.init(type: "navigation.stop")); route = nil } catch { self.error = error.localizedDescription } }
    func requireConnection() async throws {
        if connected { return }
        if !connecting { connect() }
        for _ in 0..<80 {
            if connected { return }
            if !connecting { throw NSError(domain: "ExplorerLink", code: 1, userInfo: [NSLocalizedDescriptionKey: error ?? LinkFailure.notReady.localizedDescription]) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw LinkFailure.notReady
    }
    private func fail(_ reason: String) { disconnect(); error = reason; status = "Disconnected" }
    func disconnect() {
        phoneIntegrations.clearPending(); browsedNoteIndex = nil
        timeout?.cancel(); timeout = nil; heartbeat?.cancel(); heartbeat = nil; pendingPing = nil
        transport?.onClose = nil; transport?.stop(); transport = nil; session = nil; decoder = LineDecoder(); capabilitiesSent = false
        connected = false; connecting = false; capabilities = []; status = "Disconnected"
    }
}
