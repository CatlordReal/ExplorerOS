import XCTest
@testable import ExplorerLinkCore

final class MediaTransferTests: XCTestCase {
    private let id = String(repeating: "a", count: 32)
    private let sha = String(repeating: "b", count: 64)
    private func begin(bytes: UInt64 = 3_073, chunks: UInt64 = 2, mime: String = "image/jpeg") -> LinkMessage {
        .init(type: "media.begin", payload: ["id": id, "sha256": sha, "bytes": "\(bytes)", "chunks": "\(chunks)", "chunk_bytes": "3072", "mime": mime, "captured_ms": "1"])
    }
    func testValidWireMessagesValidate() throws {
        try begin().validate()
        try LinkMessage(type: "media.accept", payload: ["id": id]).validate()
        try LinkMessage(type: "media.chunk", payload: ["id": id, "index": "0", "data": Data(repeating: 1, count: 3_072).base64EncodedString()]).validate()
        try LinkMessage(type: "media.ack", payload: ["id": id, "next": "1"]).validate()
        try LinkMessage(type: "media.finish", payload: ["id": id]).validate()
        try LinkMessage(type: "media.complete", payload: ["id": id, "sha256": sha, "bytes": "3073", "state": "staged"]).validate()
        try MediaTransfer.cancel(id: id, code: "integrity").validate()
    }
    func testMalformedAndOutOfOrderWireRejected() {
        XCTAssertThrowsError(try begin(bytes: 3_073, chunks: 1).validate())
        XCTAssertThrowsError(try begin(mime: "image/heic").validate())
        XCTAssertThrowsError(try LinkMessage(type: "media.chunk", payload: ["id": id.uppercased(), "index": "-1", "data": "AA=="]).validate())
        XCTAssertThrowsError(try LinkMessage(type: "media.chunk", payload: ["id": id, "index": "0", "data": Data(repeating: 0, count: 3_073).base64EncodedString()]).validate())
        XCTAssertThrowsError(try LinkMessage(type: "media.cancel", payload: ["id": id, "code": "peer_error"]).validate())
        XCTAssertThrowsError(try LinkMessage(type: "media.complete", payload: ["id": id, "sha256": sha, "bytes": "1", "state": "sent"]).validate())
        var nonCanonical = begin().payload; nonCanonical["bytes"] = "03073"
        XCTAssertThrowsError(try LinkMessage(type: "media.begin", payload: nonCanonical).validate())
        XCTAssertThrowsError(try LinkMessage(type: "media.chunk", payload: ["id": id, "index": "00", "data": "AA=="]).validate())
    }
    func testLimitsAndFixedChunkSize() {
        XCTAssertThrowsError(try begin(bytes: MediaTransfer.maximumImageBytes + 1, chunks: 17_067).validate())
        var payload = begin().payload; payload["chunk_bytes"] = "1024"
        XCTAssertThrowsError(try LinkMessage(type: "media.begin", payload: payload).validate())
        XCTAssertEqual(MediaTransfer.chunkBytes, 3_072)
        var huge = begin().payload; huge["bytes"] = "18446744073709551615"; huge["chunks"] = "1"
        XCTAssertThrowsError(try LinkMessage(type: "media.begin", payload: huge).validate())
    }
    func testReceiverStateRejectsOutOfOrderAndRequiresExactLastChunk() throws {
        var state = try MediaReceiveState(begin: begin(bytes: 3_073, chunks: 2).payload)
        XCTAssertThrowsError(try state.append(id: id, index: 1, count: 1))
        XCTAssertThrowsError(try state.append(id: id, index: 0, count: 3_071))
        try state.append(id: id, index: 0, count: 3_072)
        XCTAssertFalse(state.readyToFinish)
        XCTAssertThrowsError(try state.append(id: id, index: 1, count: 2))
        try state.append(id: id, index: 1, count: 1)
        XCTAssertTrue(state.readyToFinish)
        XCTAssertThrowsError(try state.append(id: id, index: 2, count: 1))
    }
}
