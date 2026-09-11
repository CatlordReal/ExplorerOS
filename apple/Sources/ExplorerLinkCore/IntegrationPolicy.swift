import Foundation

/// Allowlisted actions on the authenticated `phone.action` extension.
public enum PhoneIntegrationAction: String, CaseIterable, Codable, Sendable {
    case focusOn = "focus.on"
    case focusOff = "focus.off"
    case silentOn = "silent.on"
    case silentOff = "silent.off"
    case notesCreate = "notes.create"
    case notesBrowse = "notes.browse"

    public var title: String {
        switch self {
        case .focusOn: "Focus on"
        case .focusOff: "Focus off"
        case .silentOn: "Silent on"
        case .silentOff: "Silent off"
        case .notesCreate: "Create note"
        case .notesBrowse: "Browse notes"
        }
    }

    public var shortcutName: String {
        switch self {
        case .focusOn: "Explorer Focus On"
        case .focusOff: "Explorer Focus Off"
        case .silentOn: "Explorer Silent On"
        case .silentOff: "Explorer Silent Off"
        case .notesCreate: "Explorer Create Note"
        case .notesBrowse: "Explorer Browse Notes"
        }
    }
}

public struct PendingPhoneAction: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let action: PhoneIntegrationAction
    public let createdAt: Date

    public init(id: UUID = UUID(), action: PhoneIntegrationAction, createdAt: Date = Date()) {
        self.id = id
        self.action = action
        self.createdAt = createdAt
    }
}

public struct PhoneActionQueue: Sendable {
    public private(set) var pending: [PendingPhoneAction] = []
    public init() {}
    public mutating func enqueue(_ action: PhoneIntegrationAction) {
        guard !pending.contains(where: { $0.action == action }), pending.count < 8 else { return }
        pending.append(PendingPhoneAction(action: action))
    }
    public mutating func remove(_ id: UUID) { pending.removeAll { $0.id == id } }
    public mutating func clear() { pending.removeAll() }
}

public enum IntegrationPolicy {

    /// External text is a draft for local review, never an instruction to transmit or execute.
    public static func previewText(from url: URL) throws -> String {
        guard url.absoluteString.utf8.count <= 40_000,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "explorerlink", parts.host == "preview",
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.fragment == nil,
              let items = parts.queryItems, items.count == 1,
              items[0].name == "text", let text = items[0].value,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 4096, !text.contains("\0") else {
            throw LinkFailure.invalidMessage
        }
        return text
    }

    /// Shortcut names are local user configuration, never a caller-provided URL.
    public static func validatedShortcutName(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: { (0...31).contains($0.value) || $0.value == 127 }) else {
            throw LinkFailure.invalidMessage
        }
        return name
    }

    public static func shortcutRunURL(named value: String) throws -> URL {
        let name = try validatedShortcutName(value)
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { throw LinkFailure.invalidMessage }
        return url
    }

}
