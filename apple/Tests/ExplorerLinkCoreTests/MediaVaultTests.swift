import XCTest
@testable import ExplorerLinkCore

final class MediaVaultTests: XCTestCase {
    private var vault: URL!
    override func setUpWithError() throws { vault = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: false) }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: vault) }
    private func item(_ data: Data = Data("fixture".utf8)) throws -> MediaVaultItem {
        let id = UUID().uuidString.lowercased(), filename = MediaVault.filename(id: id, mime: "image/png")
        try data.write(to: vault.appendingPathComponent(filename))
        return .init(id: id, sha256: try MediaVault.hash(vault.appendingPathComponent(filename)), bytes: UInt64(data.count), mime: "image/png", capturedMS: 1, filename: filename)
    }
    func testSaveLoadChecksMetadataHashAndStableLocalIdentity() throws {
        let value = try item(); let index = vault.appendingPathComponent("index.json")
        try MediaVault.save([value], to: index)
        XCTAssertEqual(try MediaVault.load(vault: vault, index: index).items, [value])
        try Data("changed".utf8).write(to: vault.appendingPathComponent(value.filename))
        XCTAssertTrue(try MediaVault.load(vault: vault, index: index).items.isEmpty)
    }
    func testOrphanCompletedFilesCountAgainstQuotaAndBadIndexFailsClosed() throws {
        let value = try item(Data(repeating: 7, count: 123)); let index = vault.appendingPathComponent("index.json")
        XCTAssertEqual(try MediaVault.load(vault: vault, index: index).orphanBytes, 123)
        try Data(repeating: 1, count: MediaVault.maximumIndexBytes + 1).write(to: index)
        XCTAssertThrowsError(try MediaVault.load(vault: vault, index: index))
        XCTAssertFalse(value.id.isEmpty)
    }
    func testMissingIndexedFileIsSkippedButInvalidOrOversizedInventoryFailsClosed() throws {
        let value = try item(); let index = vault.appendingPathComponent("index.json")
        try MediaVault.save([value], to: index); try FileManager.default.removeItem(at: vault.appendingPathComponent(value.filename))
        XCTAssertTrue(try MediaVault.load(vault: vault, index: index).items.isEmpty)
        let bad = MediaVaultItem(id: value.id, sha256: value.sha256, bytes: MediaVault.maximumVaultBytes + 1, mime: value.mime, capturedMS: 1, filename: value.filename)
        XCTAssertThrowsError(try MediaVault.save([bad], to: index))
    }
    func testCorruptAndAggregateOversizedIndexesFailClosed() throws {
        let index = vault.appendingPathComponent("index.json")
        try Data("not json".utf8).write(to: index)
        XCTAssertThrowsError(try MediaVault.load(vault: vault, index: index))
        let hash = String(repeating: "a", count: 64)
        let items = (0..<5).map { number in
            let id = String(format: "00000000-0000-4000-8000-%012d", number)
            return MediaVaultItem(id: id, sha256: hash, bytes: MediaTransfer.maximumVideoBytes, mime: "video/mp4", capturedMS: 1, filename: MediaVault.filename(id: id, mime: "video/mp4"))
        }
        XCTAssertThrowsError(try MediaVault.save(items, to: index))
    }
}
