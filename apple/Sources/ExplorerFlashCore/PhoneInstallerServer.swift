import ExplorerLinkCore
import Foundation
import Network

/// Explicitly started LAN transport. Device operations remain in InstallerServing.
@MainActor public final class PhoneInstallerServer {
    public var onListening: ((UInt16) -> Void)?
    public var onStatus: ((String) -> Void)?
    public var onError: ((String) -> Void)?
    public var onSnapshot: ((InstallerSnapshot) -> Void)?
    public private(set) var listeningPort: UInt16?
    private let host: any InstallerServing
    private let keyHex: String
    private let port: UInt16
    private let loopbackOnly: Bool
    private var listener: NWListener?
    private var peer: Peer?
    private static let maximumQueuedBytes = 262_144

    @MainActor private final class Peer {
        let connection: NWConnection
        let session: SecureSession
        var decoder = LineDecoder()
        var authenticated = false
        var queuedBytes = 0
        var deadline: Task<Void, Never>?
        init(connection: NWConnection, key: String) throws {
            self.connection = connection; session = try SecureSession(keyHex: key)
        }
    }

    public init(host: any InstallerServing, keyHex: String, port: UInt16 = 8766, loopbackOnly: Bool = false) throws {
        _ = try PairingKey.data(from: keyHex)
        self.host = host; self.keyHex = keyHex; self.port = port; self.loopbackOnly = loopbackOnly
    }

    public func start() throws {
        guard listener == nil else { throw LinkFailure.notReady }
        let parameters = NWParameters.tcp
        if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
        self.listener = listener
        host.onChange = { [weak self] snapshot in self?.onSnapshot?(snapshot); self?.send(snapshot) }
        onSnapshot?(host.snapshot)
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { self.failListener("Listener has no port."); return }
                    self.listeningPort = port; self.onStatus?("Waiting for iPhone."); self.onListening?(port)
                case .failed(let error): self.failListener(error.localizedDescription)
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self, weak listener] connection in
            Task { @MainActor in
                guard let self, let listener, self.listener === listener else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.start(queue: .main)
    }

    public func stop() {
        guard let listener = self.listener else { return }
        self.listener = nil; listeningPort = nil
        closePeer()
        host.onChange = nil
        listener.newConnectionHandler = nil; listener.stateUpdateHandler = nil; listener.cancel()
        onStatus?("Stopped.")
    }

    private func accept(_ connection: NWConnection) {
        // Never replace an authenticated or handshaking connection with an incoming one.
        guard peer == nil else { connection.cancel(); return }
        do {
            let accepted = try Peer(connection: connection, key: keyHex)
            peer = accepted
            armDeadline(accepted, timeout: .seconds(8), message: "Authentication timed out.")
            connection.stateUpdateHandler = { [weak self, weak accepted] state in
                Task { @MainActor in
                    guard let self, let accepted, self.peer === accepted else { return }
                    switch state {
                    case .ready:
                        do { try self.sendFrame(accepted.session.hello(), to: accepted); self.receive(accepted) }
                        catch { self.closePeer(error: error.localizedDescription) }
                    case .failed(let error): self.closePeer(error: error.localizedDescription)
                    case .cancelled: self.closePeer()
                    default: break
                    }
                }
            }
            connection.start(queue: .main)
        } catch { connection.cancel(); onError?(error.localizedDescription) }
    }

    private func receive(_ accepted: Peer) {
        guard peer === accepted else { return }
        accepted.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self, weak accepted] data, _, complete, error in
            Task { @MainActor in
                guard let self, let accepted, self.peer === accepted else { return }
                do {
                    if let data, !data.isEmpty {
                        for line in try accepted.decoder.append(data) {
                            guard self.peer === accepted else { return }
                            guard let message = try accepted.session.receive(line) else { continue }
                            let request = try InstallerRequest.decode(message)
                            if !accepted.authenticated {
                                accepted.authenticated = true
                                self.onStatus?("iPhone connected.")
                            }
                            guard self.peer === accepted else { return }
                            self.armDeadline(accepted, timeout: .seconds(20), message: "iPhone connection timed out.")
                            do {
                                try self.host.submit(request)
                                if request.action == .status { self.send(self.host.snapshot) }
                            } catch {
                                var snapshot = self.host.snapshot
                                snapshot.error = Self.boundedError(error.localizedDescription)
                                snapshot.status = "Request rejected."
                                self.send(snapshot)
                            }
                        }
                    }
                    if let error { self.closePeer(error: error.localizedDescription) }
                    else if complete { self.closePeer() }
                    else { self.receive(accepted) }
                } catch { self.closePeer(error: error.localizedDescription) }
            }
        }
    }

    private func armDeadline(_ accepted: Peer, timeout: Duration, message: String) {
        accepted.deadline?.cancel()
        accepted.deadline = Task { [weak self, weak accepted] in
            do { try await Task.sleep(for: timeout) } catch { return }
            guard !Task.isCancelled, let self, let accepted, self.peer === accepted else { return }
            self.closePeer(error: message)
        }
    }

    private static func boundedError(_ message: String) -> String {
        var text = "", bytes = 0
        for scalar in message.unicodeScalars {
            let value = String(scalar)
            guard bytes + value.utf8.count <= 128 else { break }
            text += value; bytes += value.utf8.count
        }
        return text
    }

    private func send(_ snapshot: InstallerSnapshot) {
        guard let accepted = peer, accepted.authenticated else { return }
        do { try sendFrame(accepted.session.seal(snapshot.message()), to: accepted) }
        catch { closePeer(error: error.localizedDescription) }
    }

    private func sendFrame(_ data: Data, to accepted: Peer) throws {
        guard peer === accepted, data.count <= LineDecoder.maximumBytes + 1,
              data.count <= Self.maximumQueuedBytes - accepted.queuedBytes else { throw LinkFailure.oversizedFrame }
        accepted.queuedBytes += data.count
        accepted.connection.send(content: data, completion: .contentProcessed { [weak self, weak accepted] error in
            Task { @MainActor in
                guard let self, let accepted, self.peer === accepted else { return }
                accepted.queuedBytes -= data.count
                if let error { self.closePeer(error: error.localizedDescription) }
            }
        })
    }

    private func closePeer(error: String? = nil) {
        guard let accepted = peer else { return }
        peer = nil
        accepted.deadline?.cancel(); accepted.deadline = nil
        accepted.connection.stateUpdateHandler = nil; accepted.connection.cancel()
        if accepted.authenticated { host.disconnect() }
        if let error { onError?(error) }
        onStatus?(listener == nil ? "Stopped." : "Waiting for iPhone.")
    }

    private func failListener(_ message: String) { stop(); onError?(message) }
}
