import AppIntents
import ExplorerLinkCore

struct SendToGlassIntent: AppIntent {
    static let title: LocalizedStringResource = "Send text to Glass"
    static let description = IntentDescription("Show text you supply on paired Glass. This does not access Siri's transcript.")
    static let openAppWhenRun = true
    @Parameter(title: "Text") var text: String
    static var parameterSummary: some ParameterSummary { Summary("Send \(\.$text) to Glass") }
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let companion = CompanionModel.shared
        try await companion.requireConnection()
        try companion.sendCard(title: "From Shortcuts", body: text, source: "appIntent")
        return .result(dialog: "Sent your text to the Glass connection.")
    }
}
struct ConnectGlassIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect Glass"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await CompanionModel.shared.requireConnection()
        return .result(dialog: "Glass connected.")
    }
}
struct NextGlassDirectionIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Glass direction"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let companion = CompanionModel.shared
        try await companion.requireConnection()
        guard let route = companion.route, route.current != nil else { throw NSError(domain: "ExplorerLink", code: 2, userInfo: [NSLocalizedDescriptionKey: "Calculate a route in Explorer Link first."]) }
        guard route.index < route.steps.count - 1 else { return .result(dialog: "You are already on the final route step.") }
        companion.route?.move(1); try companion.sendRoute()
        return .result(dialog: "Sent the next route step.")
    }
}
struct GlassShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SendToGlassIntent(), phrases: ["Send text with \(.applicationName)"], shortTitle: "Send to Glass", systemImageName: "eyeglasses")
        AppShortcut(intent: ConnectGlassIntent(), phrases: ["Connect my Glass with \(.applicationName)"], shortTitle: "Connect Glass", systemImageName: "antenna.radiowaves.left.and.right")
        AppShortcut(intent: NextGlassDirectionIntent(), phrases: ["Next direction with \(.applicationName)"], shortTitle: "Next direction", systemImageName: "arrow.turn.up.right")
        AppShortcut(intent: CreateQuickNoteIntent(), phrases: ["Save a note with \(.applicationName)"], shortTitle: "Save note", systemImageName: "note.text")
        AppShortcut(intent: BrowseQuickNotesIntent(), phrases: ["Show notes with \(.applicationName)"], shortTitle: "Show notes", systemImageName: "list.bullet")
    }
}

struct CreateQuickNoteIntent: AppIntent {
    static let title: LocalizedStringResource = "Create quick note"
    static let openAppWhenRun = true
    @Parameter(title: "Text") var text: String
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let companion = CompanionModel.shared
        companion.quickNotes.create(title: "Quick Note", body: text)
        guard companion.quickNotes.error.isEmpty else { throw NSError(domain: "ExplorerLink", code: 3, userInfo: [NSLocalizedDescriptionKey: companion.quickNotes.error]) }
        return .result(dialog: "Saved on this iPhone.")
    }
}

struct BrowseQuickNotesIntent: AppIntent {
    static let title: LocalizedStringResource = "Show quick notes on Glass"
    static let openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let companion = CompanionModel.shared
        try await companion.requireConnection()
        try companion.browseQuickNotes()
        return .result(dialog: "Sent the note list to Glass. Swipe to browse.")
    }
}
