import EventKit
import SwiftUI
import UIKit
import ExplorerLinkCore

struct PhoneUtilitiesSection: View {
    let connected: Bool
    let sendToGlass: (_ title: String, _ body: String) throws -> Void
    @State private var status = ""
    @State private var loading = false
    @State private var utilityTask: Task<Void, Never>?

    var body: some View {
        Section("Phone") {
            Button("Send phone status", action: sendStatus).disabled(!connected)
            Button(loading ? "Reading calendar…" : "Send next events") { utilityTask = Task { @MainActor in await sendEvents() } }
                .disabled(!connected || loading)
            Button(loading ? "Reading reminders…" : "Send reminders") { utilityTask = Task { @MainActor in await sendReminders() } }
                .disabled(!connected || loading)
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            Text("Calendar and Reminder access are requested only after their button. Events include those in progress and the next 24 hours; up to three events or five reminders are sent.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onDisappear { utilityTask?.cancel() }
        .onChange(of: connected) { _, isConnected in if !isConnected { utilityTask?.cancel() } }
    }

    private func sendStatus() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let batteryState: String?
        switch UIDevice.current.batteryState {
        case .charging: batteryState = "charging"
        case .full: batteryState = "full"
        case .unplugged: batteryState = "on battery"
        default: batteryState = nil
        }
        do {
            try sendToGlass("Phone status", PhoneCards.statusBody(batteryLevel: UIDevice.current.batteryLevel, batteryState: batteryState, now: .now))
            status = "Sent phone status."
        } catch { status = "Glass connection is unavailable." }
    }

    private func sendEvents() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let store = EKEventStore()
        do {
            let granted = try await fullEventAccess(store, kind: .event)
            guard granted else { status = "Calendar access was not granted."; return }
            guard connected else { throw CancellationError() }
            try Task.checkCancellation()
            let now = Date.now
            let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-24 * 60 * 60), end: now.addingTimeInterval(24 * 60 * 60), calendars: nil))
                .map { PhoneCalendarEvent(title: $0.title ?? "Untitled event", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay) }
            guard connected else { throw CancellationError() }
            try Task.checkCancellation()
            try sendToGlass("Next events", PhoneCards.nextEventsBody(events, now: now))
            status = "Sent next calendar events."
        } catch is CancellationError { status = "Calendar request cancelled." }
        catch { status = "Calendar events are unavailable." }
    }

    private func sendReminders() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        let store = EKEventStore()
        do {
            let granted = try await fullEventAccess(store, kind: .reminder)
            guard granted else { status = "Reminder access was not granted."; return }
            guard connected else { throw CancellationError() }
            try Task.checkCancellation()
            let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
            let reminders = try await incompleteReminders(store, predicate: predicate)
                .map { reminder in
                    let due = reminder.dueDateComponents.flatMap { Calendar.current.date(from: $0) }
                    return PhoneReminder(title: reminder.title ?? "Untitled reminder", due: due)
                }
            guard connected else { throw CancellationError() }
            try Task.checkCancellation()
            try sendToGlass("Reminders", PhoneCards.remindersBody(reminders, now: .now))
            status = "Sent incomplete reminders."
        } catch is CancellationError { status = "Reminder request cancelled." }
        catch { status = "Reminders are unavailable." }
    }

    private enum Kind { case event, reminder }

    private func fullEventAccess(_ store: EKEventStore, kind: Kind) async throws -> Bool {
        switch kind {
        case .event:
            if EKEventStore.authorizationStatus(for: .event) == .fullAccess { return true }
            return try await store.requestFullAccessToEvents()
        case .reminder:
            if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { return true }
            return try await store.requestFullAccessToReminders()
        }
    }

    private func incompleteReminders(_ store: EKEventStore, predicate: NSPredicate) async throws -> [EKReminder] {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            store.fetchReminders(matching: predicate) { reminders in
                guard let reminders else {
                    continuation.resume(throwing: NSError(domain: "ExplorerLink.Reminders", code: 1))
                    return
                }
                continuation.resume(returning: reminders)
            }
        }
    }
}
