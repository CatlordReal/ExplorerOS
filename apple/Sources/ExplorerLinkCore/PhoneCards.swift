import Foundation

public struct PhoneCalendarEvent: Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool

    public init(title: String, start: Date, end: Date? = nil, isAllDay: Bool) {
        self.title = title
        self.start = start
        self.end = end ?? start
        self.isAllDay = isAllDay
    }
}

public struct PhoneReminder: Equatable, Sendable {
    public let title: String
    public let due: Date?

    public init(title: String, due: Date?) {
        self.title = title
        self.due = due
    }
}

/// Formats bounded, local phone information for an explicit companion card.
public enum PhoneCards {
    public static func statusBody(batteryLevel: Float, batteryState: String?, now: Date, timeZone: TimeZone = .current) -> String {
        let battery: String
        if batteryLevel >= 0, batteryLevel <= 1 {
            let percentage = Int((batteryLevel * 100).rounded())
            battery = "Battery: \(percentage)%" + (batteryState.map { " · \($0)" } ?? "")
        } else {
            battery = "Battery: unavailable"
        }
        return "\(battery)\nLocal time: \(time(now, timeZone: timeZone))"
    }

    public static func nextEventsBody(_ events: [PhoneCalendarEvent], now: Date, timeZone: TimeZone = .current) -> String {
        let end = now.addingTimeInterval(24 * 60 * 60)
        let upcoming = events
            .filter { $0.end > now && $0.start < end }
            .sorted { $0.start == $1.start ? $0.title < $1.title : $0.start < $1.start }
            .prefix(3)
        guard !upcoming.isEmpty else { return "No calendar events in the next 24 hours." }
        return upcoming.map { event in
            "\(event.isAllDay ? "All day" : time(event.start, timeZone: timeZone)) · \(boundedTitle(event.title))"
        }.joined(separator: "\n")
    }

    public static func remindersBody(_ reminders: [PhoneReminder], now: Date, timeZone: TimeZone = .current) -> String {
        let sorted = reminders.sorted { lhs, rhs in
            switch (lhs.due, rhs.due) {
            case let (left?, right?): return left == right ? lhs.title < rhs.title : left < right
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.title < rhs.title
            }
        }.prefix(5)
        guard !sorted.isEmpty else { return "No incomplete reminders." }
        return sorted.map { reminder in
            let due = reminder.due.map { "Due \(time($0, timeZone: timeZone))" } ?? "No due date"
            return "\(due) · \(boundedTitle(reminder.title))"
        }.joined(separator: "\n")
    }

    private static func boundedTitle(_ title: String) -> String {
        let clean = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.utf8.count > 160 else { return clean.isEmpty ? "Untitled item" : clean }
        var result = ""
        for scalar in clean.unicodeScalars {
            let candidate = result + String(scalar)
            guard candidate.utf8.count <= 157 else { break }
            result = candidate
        }
        return result + "…"
    }

    private static func time(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: date)
    }
}
