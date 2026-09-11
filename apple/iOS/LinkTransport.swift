import Foundation
import Network
import CoreBluetooth
import ExplorerLinkCore

@MainActor protocol LinkTransport: AnyObject {
    var onBytes: ((Data) -> Void)? { get set }
    var onOpen: (() -> Void)? { get set }
    var onClose: ((String) -> Void)? { get set }
    func send(_ data: Data) throws
    func stop()
}

@MainActor final class WiFiTransport: LinkTransport {
    var onBytes: ((Data) -> Void)?
    var onOpen: (() -> Void)?
    var onClose: ((String) -> Void)?
    private var connection: NWConnection?
    private var pendingBytes = 0
    private var generation = UUID()
    func start(host: String, port: UInt16 = 8765) {
        stop()
        let token = generation
        let connection = NWConnection(host: .init(host), port: .init(rawValue: port)!, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, token == self.generation else { return }
                switch state {
                case .ready: self.onOpen?(); self.receive(token: token)
                case .failed(let error): self.close(error.localizedDescription)
                case .waiting(let error): self.close(error.localizedDescription)
                default: break
                }
            }
        }
        connection.start(queue: .main)
    }
    func send(_ data: Data) throws {
        guard let connection, pendingBytes + data.count <= 262144 else { throw LinkFailure.notReady }
        pendingBytes += data.count
        let token = generation
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self, token == self.generation else { return }
                self.pendingBytes -= data.count
                if let error { self.close(error.localizedDescription) }
            }
        })
    }
    private func receive(token: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            Task { @MainActor in
                guard let self, token == self.generation else { return }
                if let data, !data.isEmpty { self.onBytes?(data) }
                guard token == self.generation else { return }
                if let error { self.close(error.localizedDescription) }
                else if done { self.close("Glass disconnected.") }
                else { self.receive(token: token) }
            }
        }
    }
    private func close(_ reason: String) { stop(); onClose?(reason) }
    func stop() { generation = UUID(); connection?.cancel(); connection = nil; pendingBytes = 0 }
}

/// iPhone peripheral role is deliberate: XE24's public APIs only expose the central role.
@MainActor final class BLETransport: NSObject, LinkTransport, @preconcurrency CBPeripheralManagerDelegate {
    static let service = CBUUID(string: "D973F2E0-B19E-11EE-A506-0242AC120002")
    private let rxID = CBUUID(string: "D973F2E1-B19E-11EE-A506-0242AC120002")
    private let txID = CBUUID(string: "D973F2E2-B19E-11EE-A506-0242AC120002")
    var onBytes: ((Data) -> Void)?
    var onOpen: (() -> Void)?
    var onClose: ((String) -> Void)?
    private var manager: CBPeripheralManager?
    private var tx: CBMutableCharacteristic?
    private var central: CBCentral?
    private var queued: [Data] = []
    private var wanted = false
    func start() {
        wanted = true
        manager = CBPeripheralManager(delegate: self, queue: .main)
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard wanted else { return }
        guard peripheral.state == .poweredOn else {
            if peripheral.state == .poweredOff || peripheral.state == .unauthorized || peripheral.state == .unsupported {
                close("Bluetooth is \(peripheral.state == .unauthorized ? "not authorized" : "unavailable"). Check Settings and retry.")
            }
            return
        }
        peripheral.removeAllServices()
        configure(peripheral)
    }
    private func configure(_ peripheral: CBPeripheralManager) {
        let rx = CBMutableCharacteristic(type: rxID, properties: [.write], value: nil, permissions: [.writeable])
        let tx = CBMutableCharacteristic(type: txID, properties: [.notify], value: nil, permissions: [])
        self.tx = tx
        let service = CBMutableService(type: Self.service, primary: true)
        service.characteristics = [rx, tx]
        peripheral.add(service)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard wanted else { return }
        if let error { close(error.localizedDescription); return }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.service], CBAdvertisementDataLocalNameKey: "Explorer Link"])
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { close(error.localizedDescription) }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard wanted, characteristic.uuid == txID else { return }
        guard self.central == nil else { return }
        self.central = central
        queued.removeAll()
        onOpen?()
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        if self.central?.identifier == central.identifier { close("Glass unsubscribed. Start Bluetooth again to reconnect.") }
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard wanted, request.central.identifier == central?.identifier, request.characteristic.uuid == rxID,
                  request.offset == 0, let bytes = request.value else {
                peripheral.respond(to: request, withResult: .writeNotPermitted); continue
            }
            peripheral.respond(to: request, withResult: .success)
            onBytes?(bytes)
        }
    }
    func send(_ data: Data) throws {
        guard let central, tx != nil, queued.reduce(0, { $0 + $1.count }) + data.count <= 131072 else { throw LinkFailure.notReady }
        let size = max(1, min(central.maximumUpdateValueLength, 512))
        for start in stride(from: 0, to: data.count, by: size) { queued.append(data.subdata(in: start..<min(start + size, data.count))) }
        flush()
    }
    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { flush() }
    private func flush() {
        guard let manager, let tx, let central else { return }
        while let first = queued.first {
            guard manager.updateValue(first, for: tx, onSubscribedCentrals: [central]) else { return }
            queued.removeFirst()
        }
    }
    private func close(_ reason: String) { stop(); onClose?(reason) }
    func stop() { wanted = false; manager?.stopAdvertising(); manager?.removeAllServices(); manager?.delegate = nil; manager = nil; central = nil; tx = nil; queued.removeAll() }
}
