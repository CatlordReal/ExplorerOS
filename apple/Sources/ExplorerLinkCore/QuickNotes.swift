import Foundation

public struct QuickNote: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let body: String
    public let createdAt: Date
    public init(id: UUID = UUID(), title: String, body: String, createdAt: Date = .now) {
        self.id = id; self.title = title; self.body = body; self.createdAt = createdAt
    }
}

public enum QuickNotesData {
    public static let maximumBytes = 16 * 1024 * 1024
    public static func decode(_ data: Data) throws -> [QuickNote] {
        guard data.count <= maximumBytes else { throw LinkFailure.oversizedFrame }
        let notes = try JSONDecoder().decode([QuickNote].self, from: data)
        guard notes.count <= 500, Set(notes.map(\.id)).count == notes.count,
              notes.allSatisfy({ !$0.title.isEmpty && $0.title.utf8.count <= 512 && $0.body.utf8.count <= 4096 }) else {
            throw LinkFailure.invalidMessage
        }
        return notes
    }
}
