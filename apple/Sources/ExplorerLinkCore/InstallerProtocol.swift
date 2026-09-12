import Foundation

/// Authenticated iPhone control of a USB host. There is deliberately no shell,
/// partition-write, unlock, erase, or automatic CWM restore request.
public enum InstallerAction: String, Codable, CaseIterable, Sendable {
    case status, inspectAndroid, rebootRecovery, inspectRecovery, listBackups
    case copyBackup, prepare, cancel, reset
}

public enum InstallerStep: String, Codable, Sendable {
    case check, recovery, backup, prepare, prepared
}

public struct InstallerRequest: Codable, Equatable, Sendable {
    public let id: String
    public let hostSession: String
    public let revision: Int
    public let action: InstallerAction
    public let value: String

    public init(id: String = UUID().uuidString, hostSession: String, revision: Int,
                action: InstallerAction, value: String = "") {
        self.id = id; self.hostSession = hostSession; self.revision = revision
        self.action = action; self.value = value
    }

    public func validate() throws {
        guard UUID(uuidString: id) != nil, (0...9_007_199_254_740_991).contains(revision),
              action == .status ? hostSession.isEmpty || UUID(uuidString: hostSession) != nil : UUID(uuidString: hostSession) != nil,
              value.utf8.count <= 96 else { throw LinkFailure.invalidMessage }
        if action == .copyBackup {
            guard Self.safeBackupName(value) else { throw LinkFailure.invalidMessage }
        } else if !value.isEmpty { throw LinkFailure.invalidMessage }
    }

    public static func safeBackupName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,95}\\z", options: .regularExpression) != nil
    }

    public func message() throws -> LinkMessage {
        try validate()
        return try InstallerWire.encode(self, type: "installer.request")
    }

    public static func decode(_ message: LinkMessage) throws -> Self {
        let request: Self = try InstallerWire.decode(message, type: "installer.request",
            keys: ["id", "hostSession", "revision", "action", "value"])
        try request.validate()
        return request
    }
}

public struct InstallerSnapshot: Codable, Equatable, Sendable {
    public var hostSession: String
    public var revision: Int
    public var step: InstallerStep
    public var serial: String
    public var battery: Int?
    public var busy: Bool
    public var simulated: Bool
    public var backupNames: [String]
    public var backupSaved: Bool
    public var preparedFolder: String?
    public var firmwareName: String
    public var firmwareSHA256: String
    public var status: String
    public var error: String?

    public init(hostSession: String = UUID().uuidString, revision: Int = 0, step: InstallerStep = .check,
                serial: String, battery: Int? = nil, busy: Bool = false, simulated: Bool = false, backupNames: [String] = [],
                backupSaved: Bool = false, preparedFolder: String? = nil, firmwareName: String,
                firmwareSHA256: String, status: String = "Check Glass to begin.", error: String? = nil) {
        self.hostSession = hostSession; self.revision = revision; self.step = step; self.serial = serial
        self.battery = battery; self.busy = busy; self.simulated = simulated; self.backupNames = backupNames; self.backupSaved = backupSaved
        self.preparedFolder = preparedFolder; self.firmwareName = firmwareName; self.firmwareSHA256 = firmwareSHA256
        self.status = status; self.error = error
    }

    public func validate() throws {
        guard UUID(uuidString: hostSession) != nil, (0...9_007_199_254_740_991).contains(revision),
              serial.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\\z", options: .regularExpression) != nil,
              battery == nil || (0...100).contains(battery!),
              backupNames.count <= 16, Set(backupNames).count == backupNames.count,
              backupNames.allSatisfy(InstallerRequest.safeBackupName),
              !firmwareName.isEmpty, firmwareName.utf8.count <= 128,
              !firmwareName.contains("/"), !firmwareName.contains("\\"),
              firmwareName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              firmwareSHA256.range(of: "^[a-fA-F0-9]{64}\\z", options: .regularExpression) != nil,
              status.utf8.count <= 512, error == nil || error!.utf8.count <= 512 else { throw LinkFailure.invalidMessage }
        if let preparedFolder {
            guard step == .prepared, backupSaved,
                  preparedFolder.range(of: "^/data/media(/0)?/clockworkmod/backup/explorerlink-[a-f0-9-]{36}\\z", options: .regularExpression) != nil else { throw LinkFailure.invalidMessage }
        } else if step == .prepared { throw LinkFailure.invalidMessage }
        switch step {
        case .check, .recovery:
            guard !backupSaved, backupNames.isEmpty else { throw LinkFailure.invalidMessage }
        case .backup:
            guard !backupSaved else { throw LinkFailure.invalidMessage }
        case .prepare:
            guard backupSaved else { throw LinkFailure.invalidMessage }
        case .prepared:
            guard backupSaved, !busy else { throw LinkFailure.invalidMessage }
        }
    }

    public func message() throws -> LinkMessage {
        try validate()
        return try InstallerWire.encode(self, type: "installer.status")
    }

    /// Bind a confirmation to the exact target and step that was shown to the user.
    public func matchesReview(_ reviewed: Self) -> Bool {
        hostSession == reviewed.hostSession && revision == reviewed.revision && step == reviewed.step &&
        serial == reviewed.serial && firmwareSHA256 == reviewed.firmwareSHA256 && !busy && !reviewed.busy
    }

    public static func decode(_ message: LinkMessage) throws -> Self {
        let snapshot: Self = try InstallerWire.decode(message, type: "installer.status",
            keys: ["hostSession", "revision", "step", "serial", "busy", "simulated", "backupNames", "backupSaved", "firmwareName", "firmwareSHA256", "status"],
            optional: ["battery", "preparedFolder", "error"])
        try snapshot.validate()
        return snapshot
    }
}

/// This code is a private credential. Parse pasted text inside the app; never
/// register it as an OS URL handler or put it into analytics or activity logs.
public struct InstallerPairingCode: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let key: String

    public init(host: String, port: UInt16 = 8766, key: String) throws {
        guard LocalEndpoint.accepts(host), port > 0, host == host.trimmingCharacters(in: .whitespacesAndNewlines) else { throw LinkFailure.invalidMessage }
        _ = try PairingKey.data(from: key)
        self.host = host; self.port = port; self.key = key
    }

    public var text: String {
        var value = URLComponents()
        value.scheme = "explorer-install"; value.host = "pair"
        value.queryItems = [URLQueryItem(name: "host", value: host), URLQueryItem(name: "port", value: String(port)), URLQueryItem(name: "key", value: key)]
        return value.string!
    }

    public static func parse(_ text: String) throws -> Self {
        guard text.utf8.count <= 1024, let value = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              value.scheme == "explorer-install", value.host == "pair", value.path.isEmpty,
              value.user == nil, value.password == nil, value.port == nil, value.fragment == nil,
              let items = value.queryItems, items.count == 3, Set(items.map(\.name)) == ["host", "port", "key"],
              items.allSatisfy({ $0.value != nil }) else { throw LinkFailure.invalidMessage }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
        guard let port = UInt16(fields["port"]!), String(port) == fields["port"] else { throw LinkFailure.invalidMessage }
        return try Self(host: fields["host"]!, port: port, key: fields["key"]!)
    }
}

private enum InstallerWire {
    static func encode<T: Encodable>(_ value: T, type: String) throws -> LinkMessage {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else { throw LinkFailure.oversizedFrame }
        return LinkMessage(type: type, payload: ["json": text])
    }

    static func decode<T: Decodable>(_ message: LinkMessage, type: String, keys: Set<String>, optional: Set<String> = []) throws -> T {
        try message.validate()
        guard message.type == type, Set(message.payload.keys) == ["json"],
              let text = message.payload["json"], let data = text.data(using: .utf8), data.count <= 4096,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              keys.isSubset(of: Set(object.keys)), Set(object.keys).isSubset(of: keys.union(optional)) else { throw LinkFailure.invalidMessage }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
