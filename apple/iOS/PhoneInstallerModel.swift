import Foundation
import SwiftUI
import ExplorerLinkCore

@MainActor final class PhoneInstallerModel: ObservableObject {
    @Published var pairingCode = ""
    @Published private(set) var connected = false
    @Published private(set) var connecting = false
    @Published private(set) var snapshot: InstallerSnapshot?
    @Published private(set) var status = "Connect to Explorer Tools on your Mac."
    @Published private(set) var error: String?
    @Published private(set) var awaitingReply = false
    private var link: WiFiTransport?
    private var session: SecureSession?
    private var decoder = LineDecoder()
    private var generation = UUID()
    private var deadline: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var outstandingSince: Date?
    private var lastResponse: Date?
    #if DEBUG
    private var simulatedActions = Set<InstallerAction>()
    #endif

    func connect() {
        disconnect()
        do {
            let code = try InstallerPairingCode.parse(pairingCode)
            let secure = try SecureSession(keyHex: code.key)
            session = secure; error = nil; connecting = true; status = "Connecting to Mac…"
            let token = generation
            let transport = WiFiTransport(); link = transport
            transport.onOpen = { [weak self] in
                guard let self, self.generation == token else { return }
                do { try self.link?.send(secure.hello()) } catch { self.fail("Connection handshake failed.") }
            }
            transport.onBytes = { [weak self] data in
                guard let self, self.generation == token else { return }
                self.receive(data)
            }
            transport.onClose = { [weak self] _ in
                guard let self, self.generation == token else { return }
                self.fail("Mac disconnected. Reconnect and recheck Glass before restoring.")
            }
            transport.start(host: code.host, port: code.port)
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(12)) } catch { return }
                guard let self, self.generation == token, !self.connected else { return }
                self.fail("Mac did not authenticate. Check the connection code and Wi-Fi.")
            }
        } catch { fail("Paste the private connection code from Explorer Tools on your Mac.") }
    }

    func disconnect() {
        generation = UUID(); deadline?.cancel(); deadline = nil; heartbeat?.cancel(); heartbeat = nil
        link?.stop(); link = nil; session = nil; decoder = LineDecoder()
        connected = false; connecting = false; awaitingReply = false; outstandingSince = nil; lastResponse = nil
        snapshot = nil; status = "Disconnected. Reconnect to check the current step."
    }

    func send(_ action: InstallerAction, value: String = "", reviewed: InstallerSnapshot? = nil) {
        guard connected, let snapshot, action == .status || action == .cancel || !awaitingReply else { return }
        guard !snapshot.busy || action == .status || action == .cancel else { return }
        if let reviewed, !snapshot.matchesReview(reviewed) {
            error = "Glass or the current step changed. Review it again."
            return
        }
        do {
            let request = InstallerRequest(hostSession: snapshot.hostSession, revision: snapshot.revision, action: action, value: value)
            try write(request)
            if action != .status { awaitingReply = true; outstandingSince = Date(); error = nil }
        } catch { fail("Could not send the request. Reconnect and check the current step.") }
    }

    func leaveForeground() {
        if connecting || connected {
            disconnect()
            status = "Connection closed. Reopen it to check Glass before continuing."
        }
    }

    private func write(_ request: InstallerRequest) throws {
        guard let session, let link else { throw LinkFailure.notReady }
        try link.send(session.seal(request.message()))
    }

    private func receive(_ data: Data) {
        do {
            guard let session else { throw LinkFailure.notReady }
            for line in try decoder.append(data) {
                guard let message = try session.receive(line) else {
                    try write(InstallerRequest(hostSession: "", revision: 0, action: .status))
                    continue
                }
                let state = try InstallerSnapshot.decode(message)
                if let previous = snapshot {
                    guard previous.hostSession == state.hostSession, state.revision >= previous.revision else { throw LinkFailure.replay }
                }
                snapshot = state; connected = true; connecting = false; lastResponse = Date()
                status = state.status; error = state.error; awaitingReply = false; outstandingSince = nil
                deadline?.cancel(); deadline = nil
                startHeartbeat()
                #if DEBUG
                advanceSimulationIfRequested(state)
                #endif
            }
        } catch { fail("The Mac sent an invalid or unauthenticated response. Nothing further was requested.") }
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let token = generation
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, token == self.generation, self.connected else { return }
                if let last = self.lastResponse, Date().timeIntervalSince(last) > 20 {
                    self.fail("Mac stopped responding. Reconnect and recheck Glass.")
                    return
                }
                if let start = self.outstandingSince, Date().timeIntervalSince(start) > 20 {
                    self.fail("Request outcome unknown. Reconnect and recheck Glass.")
                    return
                }
                self.send(.status)
            }
        }
    }

    private func fail(_ message: String) {
        disconnect(); error = message; status = "Connection unavailable."
    }

    #if DEBUG
    func configureSimulationIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("--installer-integration-test"),
              let code = ProcessInfo.processInfo.environment["EXPLORER_INSTALLER_TEST_CODE"],
              let parsed = try? InstallerPairingCode.parse(code), parsed.host == "127.0.0.1" else { return }
        simulatedActions = []; pairingCode = code; connect()
    }

    private func advanceSimulationIfRequested(_ state: InstallerSnapshot) {
        guard ProcessInfo.processInfo.arguments.contains("--installer-integration-test"), state.simulated,
              !state.busy, state.error == nil else { return }
        let action: InstallerAction?
        switch state.step {
        case .check: action = .inspectAndroid
        case .recovery: action = simulatedActions.contains(.rebootRecovery) ? .inspectRecovery : .rebootRecovery
        case .backup: action = state.backupNames.isEmpty ? .listBackups : .copyBackup
        case .prepare: action = .prepare
        case .prepared: action = nil
        }
        if let action, simulatedActions.insert(action).inserted {
            send(action, value: action == .copyBackup ? state.backupNames[0] : "")
        }
        if state.step == .prepared, let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let data = try? JSONEncoder().encode(state) {
            try? data.write(to: directory.appendingPathComponent("installer-simulation-result.json"), options: .atomic)
        }
    }
    #endif
}
