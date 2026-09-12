import CryptoKit
import Foundation
import Photos
import SwiftUI
import UIKit
import ExplorerLinkCore

typealias StagedMedia = MediaVaultItem

@MainActor final class MediaSyncStore: ObservableObject {
    static let vaultQuota: UInt64 = 1 * 1024 * 1024 * 1024
    static let maximumItems = 1_000
    static let defaultVaultURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ExplorerLink/Media", isDirectory: true)
    @Published private(set) var items: [StagedMedia] = []
    @Published var receiveEnabled = UserDefaults.standard.bool(forKey: "media.receive.enabled") { didSet { UserDefaults.standard.set(receiveEnabled, forKey: "media.receive.enabled"); if !receiveEnabled { stopReceiving(code: "disabled") } } }
    @Published private(set) var status = "Media receive is off."
    private var vaultHealthy = true
    private let indexURL: URL
    private let vaultURL: URL
    private var active: Active?
    private var idle: Task<Void, Never>?
    private var sessionBytes: UInt64 = 0
    private var orphanBytes: UInt64 = 0
    private var response: ((LinkMessage) throws -> Void)?
    private enum StorageFailure: Error { case afterMove }

    private struct Active {
        let id: String; let sha256: String; let bytes: UInt64; let chunks: UInt64; let mime: String; let capturedMS: UInt64; let partial: URL
        var ordering: MediaReceiveState; var hasher: SHA256; let handle: FileHandle
    }

    init(vaultURL: URL = MediaSyncStore.defaultVaultURL) {
        self.vaultURL = vaultURL
        self.indexURL = vaultURL.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: vaultURL, withIntermediateDirectories: true)
        cleanupPartials(in: vaultURL); load()
    }

    var receiverAvailable: Bool { vaultHealthy && receiveEnabled && UIApplication.shared.applicationState == .active }

    func handle(_ message: LinkMessage, connected: Bool, wifi: Bool, peerSender: Bool, send: @escaping (LinkMessage) throws -> Void) {
        guard ["media.begin", "media.chunk", "media.finish", "media.cancel"].contains(message.type) else { return }
        do {
            switch message.type {
            case "media.begin": try begin(message.payload, connected: connected, wifi: wifi, peerSender: peerSender, send: send)
            case "media.chunk": try chunk(message.payload, send: send)
            case "media.finish": try finish(message.payload, send: send)
            case "media.cancel": cancel(message.payload["id"] ?? "", code: message.payload["code"] ?? "state")
            default: break
            }
        } catch {
            let id = message.payload["id"] ?? String(repeating: "0", count: 32)
            let storage = active?.id == id || error is StorageFailure
            if active?.id == id { cancel(id, code: "storage") }
            try? send(MediaTransfer.cancel(id: id, code: storage ? "storage" : "state"))
            status = "Media transfer was rejected."
        }
    }

    func disconnect() { cancel(active?.id ?? "", code: "timeout"); active = nil; idle?.cancel(); idle = nil; response = nil; sessionBytes = 0 }
    func leaveForeground() { stopReceiving(code: "state") }
    func connectionUnavailable() { stopReceiving(code: "state") }

    private func begin(_ p: [String: String], connected: Bool, wifi: Bool, peerSender: Bool, send: @escaping (LinkMessage) throws -> Void) throws {
        try MediaTransfer.validateBegin(p)
        let id = p["id"]!, sha = p["sha256"]!, bytes = UInt64(p["bytes"]!)!, chunks = UInt64(p["chunks"]!)!, mime = p["mime"]!, captured = UInt64(p["captured_ms"]!)!
        guard vaultHealthy else { try send(MediaTransfer.cancel(id: id, code: "storage")); return }
        guard receiveEnabled else { try send(MediaTransfer.cancel(id: id, code: "disabled")); return }
        guard peerSender else { try send(MediaTransfer.cancel(id: id, code: "unsupported")); return }
        guard connected, wifi, UIApplication.shared.applicationState == .active else { try send(MediaTransfer.cancel(id: id, code: "state")); return }
        guard active == nil else { try send(MediaTransfer.cancel(id: id, code: "state")); return }
        if items.contains(where: { $0.sha256 == sha && $0.bytes == bytes }) {
            try send(.init(type: "media.complete", payload: ["id": id, "sha256": sha, "bytes": "\(bytes)", "state": "deduplicated"])); status = "Already staged."; return
        }
        guard items.count < Self.maximumItems, usedBytes <= Self.vaultQuota - bytes, sessionBytes <= MediaTransfer.maximumSessionBytes - bytes, hasFreeSpace(bytes) else { try send(MediaTransfer.cancel(id: id, code: "quota")); return }
        let partial = indexURL.deletingLastPathComponent().appendingPathComponent("explorer-\(UUID().uuidString.lowercased()).partial")
        guard FileManager.default.createFile(atPath: partial.path, contents: nil) else { try send(MediaTransfer.cancel(id: id, code: "storage")); return }
        let handle: FileHandle
        do { try protect(partial); handle = try FileHandle(forWritingTo: partial) }
        catch { try? FileManager.default.removeItem(at: partial); try send(MediaTransfer.cancel(id: id, code: "storage")); return }
        active = Active(id: id, sha256: sha, bytes: bytes, chunks: chunks, mime: mime, capturedMS: captured, partial: partial, ordering: try MediaReceiveState(begin: p), hasher: SHA256(), handle: handle)
        response = send
        armIdle(); try send(.init(type: "media.accept", payload: ["id": id])); status = "Receiving media…"
    }

    private func chunk(_ p: [String: String], send: (LinkMessage) throws -> Void) throws {
        try MediaTransfer.validateChunk(p)
        guard var current = active, let index = UInt64(p["index"]!), let data = Data(base64Encoded: p["data"]!) else { throw LinkFailure.invalidMessage }
        try current.ordering.append(id: p["id"]!, index: index, count: data.count)
        try current.handle.write(contentsOf: data)
        current.hasher.update(data: data); active = current
        armIdle(); try send(.init(type: "media.ack", payload: ["id": current.id, "next": "\(current.ordering.next)"]))
    }

    private func finish(_ p: [String: String], send: (LinkMessage) throws -> Void) throws {
        try MediaTransfer.validateFinish(p)
        guard let current = active, p["id"] == current.id, current.ordering.readyToFinish else { throw LinkFailure.invalidMessage }
        try current.handle.synchronize(); try current.handle.close()
        let digest = current.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == current.sha256 else { cancel(current.id, code: "integrity"); try send(MediaTransfer.cancel(id: current.id, code: "integrity")); return }
        let localID = UUID().uuidString.lowercased()
        let filename = MediaVault.filename(id: localID, mime: current.mime)
        let destination = indexURL.deletingLastPathComponent().appendingPathComponent(filename)
        try FileManager.default.moveItem(at: current.partial, to: destination)
        let record = StagedMedia(id: localID, sha256: digest, bytes: current.bytes, mime: current.mime, capturedMS: current.capturedMS, filename: filename)
        active = nil; idle?.cancel(); idle = nil; response = nil
        do { try protect(destination) }
        catch {
            do { try FileManager.default.removeItem(at: destination) }
            catch { vaultHealthy = false; orphanBytes += current.bytes }
            throw StorageFailure.afterMove
        }
        do { try saveIndex([record] + items) }
        catch { orphanBytes += current.bytes; throw StorageFailure.afterMove }
        items.insert(record, at: 0); sessionBytes += current.bytes
        try send(.init(type: "media.complete", payload: ["id": current.id, "sha256": digest, "bytes": "\(current.bytes)", "state": "staged"])); status = "Media staged privately."
    }

    func saveToPhotos(_ item: StagedMedia) async {
        let url = fileURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else { status = "Staged file is unavailable."; return }
        let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard access == .authorized || access == .limited else { status = "Photos permission was not granted."; return }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                if item.mime.hasPrefix("image/") { PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: nil) }
                else { PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: url, options: nil) }
            }
            status = "Saved to Photos."
        } catch { status = "Could not save to Photos." }
    }

    private var usedBytes: UInt64 { orphanBytes + items.reduce(0) { $0 + $1.bytes } }
    func fileURL(for item: StagedMedia) -> URL { vaultURL.appendingPathComponent(item.filename) }
    private func hasFreeSpace(_ bytes: UInt64) -> Bool { (try? vaultURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage).map { $0 >= Int64(bytes) } ?? false }
    private func armIdle() { idle?.cancel(); let id = active?.id; idle = Task { [weak self] in try? await Task.sleep(for: .seconds(30)); guard !Task.isCancelled, self?.active?.id == id else { return }; self?.timeout() } }
    private func timeout() { guard let id = active?.id else { return }; if let response { try? response(MediaTransfer.cancel(id: id, code: "timeout")) }; cancel(id, code: "timeout"); status = "Media transfer timed out." }
    private func stopReceiving(code: String) { guard let id = active?.id else { return }; if let response { try? response(MediaTransfer.cancel(id: id, code: code)) }; cancel(id, code: code) }
    private func cancel(_ id: String, code: String) { guard let current = active, current.id == id else { return }; try? current.handle.close(); try? FileManager.default.removeItem(at: current.partial); active = nil; idle?.cancel(); idle = nil; response = nil; status = "Media transfer cancelled (\(code))." }
    private func protect(_ target: URL) throws { var url = target; var values = URLResourceValues(); values.isExcludedFromBackup = true; try url.setResourceValues(values); try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path) }
    private func saveIndex(_ next: [StagedMedia]) throws { try MediaVault.save(next, to: indexURL); try protect(indexURL) }
    private func load() { do { let loaded = try MediaVault.load(vault: vaultURL, index: indexURL); items = loaded.items; orphanBytes = loaded.orphanBytes } catch { vaultHealthy = false; status = "Media vault could not be read; receiving is disabled until it is repaired." } }
    private func cleanupPartials(in vault: URL) { for url in (try? FileManager.default.contentsOfDirectory(at: vault, includingPropertiesForKeys: nil)) ?? [] where url.lastPathComponent.range(of: "^explorer-[0-9a-f-]{36}\\.partial$", options: .regularExpression) != nil { try? FileManager.default.removeItem(at: url) } }
}
