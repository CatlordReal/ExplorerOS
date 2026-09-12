import SwiftUI
import QuickLook

struct MediaLibraryView: View {
    @ObservedObject var store: MediaSyncStore
    let connected: Bool
    let wifi: Bool
    let onAvailabilityChanged: () -> Void
    @State private var preview: URL?
    var body: some View {
        List {
            Section("Automatic receive") {
                Toggle("Receive media from Glass", isOn: $store.receiveEnabled).disabled(!connected || !wifi).onChange(of: store.receiveEnabled) { _, _ in onAvailabilityChanged() }
                Text("Wi-Fi and Explorer Link open required. Files stay in a private protected vault until you choose Save to Photos.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Staged media") {
                if store.items.isEmpty { Text("No media staged.").foregroundStyle(.secondary) }
                ForEach(store.items) { item in
                    VStack(alignment: .leading) {
                        Label(item.mime.hasPrefix("image/") ? "Photo" : "Video", systemImage: item.mime.hasPrefix("image/") ? "photo" : "video").font(.headline)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Preview") { preview = store.fileURL(for: item) }
                            Spacer()
                            Button("Save to Photos") { Task { await store.saveToPhotos(item) } }
                        }.buttonStyle(.borderless)
                    }
                }
            }
            if !store.status.isEmpty { Section { Text(store.status).font(.caption).foregroundStyle(.secondary) } }
        }.navigationTitle("Glass media").quickLookPreview($preview)
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--media-open-first"), let item = store.items.first { preview = store.fileURL(for: item) }
            #endif
        }
    }
}
