import Foundation
import SwiftUI
import UIKit
import ExplorerLinkCore

@MainActor final class QuickNotesStore: ObservableObject {
    @Published private(set) var notes: [QuickNote] = []
    @Published var selectedID: UUID?
    @Published private(set) var error = ""
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ExplorerLink", isDirectory: true)
        self.fileURL = fileURL ?? support.appendingPathComponent("QuickNotes.json")
        load()
    }

    var selected: QuickNote? { notes.first { $0.id == selectedID } }

    func create(title: String, body: String) {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty || !cleanedBody.isEmpty else { error = "Enter a title or note."; return }
        guard cleanedTitle.utf8.count <= 512, cleanedBody.utf8.count <= 4096, notes.count < 500 else { error = "Use a shorter note or remove an existing one."; return }
        let note = QuickNote(title: cleanedTitle.isEmpty ? "Quick Note" : cleanedTitle, body: cleanedBody)
        notes.insert(note, at: 0); selectedID = note.id; save()
    }

    func remove(_ id: UUID) { notes.removeAll { $0.id == id }; if selectedID == id { selectedID = nil }; save() }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= QuickNotesData.maximumBytes else { throw LinkFailure.oversizedFrame }
            notes = try QuickNotesData.decode(Data(contentsOf: fileURL))
        }
        catch { self.error = "Local Quick Notes could not be read." }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(notes).write(to: fileURL, options: [.atomic, .completeFileProtection])
            var protectedURL = fileURL
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try protectedURL.setResourceValues(values)
            error = ""
        } catch { self.error = "Quick Note was kept in memory but could not be protected on disk." }
    }
}

@MainActor final class PhoneIntegrationsModel: ObservableObject {
    @AppStorage("shortcut.focusOn") var focusOnShortcut = ""
    @AppStorage("shortcut.focusOff") var focusOffShortcut = ""
    @AppStorage("shortcut.silentOn") var silentOnShortcut = ""
    @AppStorage("shortcut.silentOff") var silentOffShortcut = ""
    @AppStorage("shortcut.notesCreate") var notesCreateShortcut = ""
    @AppStorage("shortcut.notesBrowse") var notesBrowseShortcut = ""
    @Published private var queue = PhoneActionQueue()
    @Published private(set) var status = ""
    var pending: [PendingPhoneAction] { queue.pending }

    func enqueue(_ action: PhoneIntegrationAction) {
        queue.enqueue(action)
        status = "Glass requested \(action.title.lowercased()). Review it here."
    }
    func clearPending() { queue.clear() }
    func dismiss(_ id: UUID) { queue.remove(id) }

    func run(_ action: PhoneIntegrationAction, pendingID: UUID? = nil) {
        runShortcut(named: shortcutName(for: action), pendingID: pendingID)
    }
    func runShortcut(named name: String, pendingID: UUID? = nil) {
        guard UIApplication.shared.applicationState == .active else { status = "Open Explorer Link to run this action."; return }
        do {
            let url = try IntegrationPolicy.shortcutRunURL(named: name)
            guard UIApplication.shared.canOpenURL(url) else { status = "Shortcuts is unavailable."; return }
            UIApplication.shared.open(url, options: [:]) { [weak self] opened in
                Task { @MainActor in
                    self?.status = opened ? "Requested \(name). Completion is not reported." : "Could not open Shortcuts."
                    if opened, let pendingID { self?.dismiss(pendingID) }
                }
            }
        } catch { status = "Use a valid Shortcut name." }
    }
    func shortcutName(for action: PhoneIntegrationAction) -> String {
        let custom: String = switch action {
        case .focusOn: focusOnShortcut
        case .focusOff: focusOffShortcut
        case .silentOn: silentOnShortcut
        case .silentOff: silentOffShortcut
        case .notesCreate: notesCreateShortcut
        case .notesBrowse: notesBrowseShortcut
        }
        return custom.isEmpty ? action.shortcutName : custom
    }
    func setShortcutName(_ name: String, for action: PhoneIntegrationAction) {
        switch action {
        case .focusOn: focusOnShortcut = name
        case .focusOff: focusOffShortcut = name
        case .silentOn: silentOnShortcut = name
        case .silentOff: silentOffShortcut = name
        case .notesCreate: notesCreateShortcut = name
        case .notesBrowse: notesBrowseShortcut = name
        }
    }
}

struct PhoneIntegrationsView: View {
    @ObservedObject var notes: QuickNotesStore
    @ObservedObject var phone: PhoneIntegrationsModel
    @State private var noteTitle = ""
    @State private var noteBody = ""
    @State private var operationError = ""
    let connected: Bool
    let sendToGlass: (QuickNote) throws -> Void

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                if !phone.pending.isEmpty {
                    Section("From Glass") {
                        ForEach(phone.pending) { request in
                            HStack {
                                Text(request.action.title)
                                Spacer()
                                Button("Run Shortcut") { phone.run(request.action, pendingID: request.id) }
                                Button("Dismiss") { phone.dismiss(request.id) }
                            }
                        }
                    }
                }
                PhoneUtilitiesSection(connected: connected) { title, body in
                    try sendToGlass(QuickNote(title: title, body: body))
                }
                Section("Quick Notes") {
                    TextField("Title", text: $noteTitle)
                    TextField("Note", text: $noteBody, axis: .vertical)
                    Button("Save note") { notes.create(title: noteTitle, body: noteBody); if notes.error.isEmpty { noteTitle = ""; noteBody = "" } }
                    ForEach(notes.notes) { note in
                        DisclosureGroup(note.title) {
                            Text(note.body).textSelection(.enabled)
                            Button("Show on Glass") {
                                do { try sendToGlass(note); operationError = "" }
                                catch { operationError = error.localizedDescription }
                            }.disabled(!connected)
                            Button("Delete note", role: .destructive) { notes.remove(note.id) }
                        }
                    }
                    if !notes.error.isEmpty { Text(notes.error).foregroundStyle(.red) }
                    if !operationError.isEmpty { Text(operationError).foregroundStyle(.red) }
                    Text("Stored on this iPhone. Glass can browse these notes when connected.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Shortcuts") {
                    ForEach(PhoneIntegrationAction.allCases, id: \.self) { action in
                        HStack {
                            Text(action.title)
                            Spacer()
                            if let file = ShortcutFiles.url(for: action) {
                                ShareLink("Add", item: file, preview: SharePreview(action.shortcutName))
                                    .accessibilityLabel("Add \(action.title) Shortcut")
                            } else {
                                Text("Preset unavailable").font(.caption).foregroundStyle(.secondary)
                            }
                            Button("Run") { phone.run(action) }
                        }
                    }
                    ForEach(ShortcutFiles.extras, id: \.name) { preset in
                        if let file = ShortcutFiles.url(named: preset.name) {
                            HStack {
                                Text(preset.title)
                                Spacer()
                                ShareLink("Add", item: file, preview: SharePreview(preset.name))
                                    .accessibilityLabel("Add \(preset.title) Shortcut")
                                Button("Run") { phone.runShortcut(named: preset.name) }
                            }
                        }
                    }
                    DisclosureGroup("Custom Shortcut names") {
                        ForEach(PhoneIntegrationAction.allCases, id: \.self) { action in
                            TextField(action.title, text: Binding(get: { phone.shortcutName(for: action) }, set: { phone.setShortcutName($0, for: action) }))
                        }
                    }
                    Text("Tap Add, open the file in Shortcuts, then confirm Add Shortcut. If needed, save to Files and open it there.").font(.caption).foregroundStyle(.secondary)
                    if !phone.status.isEmpty { Text(phone.status).font(.caption) }
                }
                .id("shortcuts")
                Section("Notification replies") {
                    Text("Reply actions open on iPhone. ANCS cannot send dictated text from Glass.").font(.caption).foregroundStyle(.secondary)
                }
            }.buttonStyle(.borderless).navigationTitle("Phone")
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--shortcuts-preview") {
                    try? await Task.sleep(for: .milliseconds(150))
                    scroll.scrollTo("shortcuts", anchor: .top)
                }
                #endif
            }
        }
    }
}

enum ShortcutFiles {
    struct Extra { let title: String; let name: String }
    static let extras = [Extra(title: "Weather", name: "Explorer Weather"), Extra(title: "Recognize music", name: "Explorer Recognize Music")]
    static func url(for action: PhoneIntegrationAction) -> URL? {
        url(named: action.shortcutName)
    }
    static func url(named name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "shortcut")
            ?? Bundle.main.url(forResource: name, withExtension: "shortcut", subdirectory: "ShortcutTemplates")
    }
}
