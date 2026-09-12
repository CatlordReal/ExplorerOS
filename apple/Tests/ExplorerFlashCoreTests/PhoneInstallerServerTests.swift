import Darwin
import ExplorerLinkCore
import Foundation
import XCTest
@testable import ExplorerFlashCore

@MainActor final class PhoneInstallerServerTests: XCTestCase {
    private let key = String(repeating: "12", count: 32)

    private func start(_ host: SyntheticInstaller) async throws -> PhoneInstallerServer {
        let server = try PhoneInstallerServer(host: host, keyHex: key, port: 0, loopbackOnly: true)
        XCTAssertNil(server.listeningPort)
        let ready = expectation(description: "listening")
        server.onListening = { _ in ready.fulfill() }
        try server.start()
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertNotNil(server.listeningPort)
        return server
    }
    private func connect(_ server: PhoneInstallerServer, key: String? = nil, fragmented: Bool = false) async throws -> (SocketPeer, SecureSession) {
        let client = try SocketPeer(port: XCTUnwrap(server.listeningPort))
        let session = try SecureSession(keyHex: key ?? self.key)
        let hello = try await client.line()
        XCTAssertNotNil(hello)
        _ = try session.receive(XCTUnwrap(hello))
        try await client.write(session.hello(), fragmentBytes: fragmented ? 3 : nil)
        return (client, session)
    }
    private func status(_ client: SocketPeer, session: SecureSession) async throws -> InstallerSnapshot {
        let request = InstallerRequest(hostSession: "", revision: 0, action: .status)
        try await client.write(session.seal(request.message()), fragmentBytes: 7)
        return try await snapshot(client, session: session)
    }
    private func snapshot(_ client: SocketPeer, session: SecureSession) async throws -> InstallerSnapshot {
        let line = try await client.line()
        return try InstallerSnapshot.decode(XCTUnwrap(session.receive(XCTUnwrap(line))))
    }
    private func closed(_ peer: SocketPeer, file: StaticString = #filePath, line: UInt = #line) async {
        do { let data = try await peer.line(); XCTAssertNil(data, "Unexpected data after rejection", file: file, line: line) }
        catch let error as NSError { XCTAssertEqual(error.domain, NSPOSIXErrorDomain, file: file, line: line); XCTAssertTrue([ECONNRESET, ENOTCONN].contains(Int32(error.code)), "Expected close, got \(error)", file: file, line: line) }
    }

    func testFragmentedAuthenticatedRequestAndHostUpdatesUseEncryptedSnapshots() async throws {
        let host = SyntheticInstaller(); let server = try await start(host); defer { server.stop() }
        let (client, session) = try await connect(server, fragmented: true)
        let initial = try await status(client, session: session)
        XCTAssertEqual(initial, host.snapshot); XCTAssertEqual(host.actions, [])
        let request = InstallerRequest(hostSession: initial.hostSession, revision: initial.revision, action: .inspectAndroid)
        try await client.write(session.seal(request.message()), fragmentBytes: 1)
        let updated = try await snapshot(client, session: session)
        XCTAssertEqual(updated.revision, 1); XCTAssertEqual(host.actions, [.inspectAndroid])
        host.publish("Synthetic update")
        let changed = try await snapshot(client, session: session)
        XCTAssertEqual(changed.status, "Synthetic update")
        await client.close()
    }
    func testInvalidKeyRejectedAtInitializationWithoutHostEffects() throws {
        let host = SyntheticInstaller()
        XCTAssertThrowsError(try PhoneInstallerServer(host: host, keyHex: "bad", port: 0, loopbackOnly: true))
        XCTAssertEqual(host.actions, []); XCTAssertEqual(host.disconnects, 0); XCTAssertNil(host.onChange)
        host.onChange = { _ in }
        let unused = try PhoneInstallerServer(host: host, keyHex: key, port: 0, loopbackOnly: true)
        unused.stop()
        XCTAssertNotNil(host.onChange, "An unstarted server must not clear another callback owner")
    }
    func testWrongKeyPlaintextAndOversizedFramesHaveZeroHostOperations() async throws {
        for fault in ["wrong-key", "plaintext", "oversize", "unsupported"] {
            let host = SyntheticInstaller(); let server = try await start(host)
            let (client, session) = try await connect(server, key: fault == "wrong-key" ? String(repeating: "34", count: 32) : key)
            if fault == "oversize" { try await client.write(Data(repeating: 65, count: LineDecoder.maximumBytes + 1) + Data([10])) }
            else if fault == "plaintext" { try await client.write(Data("{\"type\":\"installer.request\",\"payload\":{}}\n".utf8)) }
            else if fault == "unsupported" { try await client.write(session.seal(LinkMessage(type: "phone.action", payload: ["action": "notes.create"]))) }
            else { try await client.write(session.seal(InstallerRequest(hostSession: "", revision: 0, action: .status).message())) }
            await closed(client)
            XCTAssertEqual(host.actions, []); XCTAssertEqual(host.statusRequests, 0); XCTAssertEqual(host.disconnects, 0)
            await client.close(); server.stop()
        }
    }
    func testHelloAloneReceivesNoSnapshotAndDeadlineDoesNotCancelHost() async throws {
        let host = SyntheticInstaller(); let server = try await start(host); defer { server.stop() }
        let expired = expectation(description: "authentication deadline")
        server.onError = { if $0 == "Authentication timed out." { expired.fulfill() } }
        let (client, _) = try await connect(server)
        host.publish("Private host status")
        // The only plaintext transmission was the fresh challenge, consumed by connect().
        do { _ = try await client.line(); XCTFail("Sent snapshot before authentication") }
        catch let error as NSError { XCTAssertEqual(error.code, Int(EAGAIN)) }
        await fulfillment(of: [expired], timeout: 9)
        await closed(client)
        XCTAssertEqual(host.actions, []); XCTAssertEqual(host.disconnects, 0)
        await client.close()
    }
    func testReplayClosesAuthenticatedPeerWithoutRepeatingAction() async throws {
        let host = SyntheticInstaller(); let server = try await start(host); defer { server.stop() }
        let disconnected = expectation(description: "authenticated disconnect")
        host.onDisconnect = { disconnected.fulfill() }
        let (client, session) = try await connect(server)
        let initial = try await status(client, session: session)
        let request = InstallerRequest(hostSession: initial.hostSession, revision: initial.revision, action: .inspectAndroid)
        let frame = try session.seal(request.message())
        try await client.write(frame); _ = try await client.line()
        try await client.write(frame); await closed(client)
        await fulfillment(of: [disconnected], timeout: 2)
        XCTAssertEqual(host.actions, [.inspectAndroid]); XCTAssertEqual(host.disconnects, 1)
        await client.close()
    }
    func testSecondPeerCannotReplaceOrCancelAuthenticatedPeer() async throws {
        let host = SyntheticInstaller(); let server = try await start(host); defer { server.stop() }
        let (first, session) = try await connect(server); _ = try await status(first, session: session)
        let second = try SocketPeer(port: XCTUnwrap(server.listeningPort)); await closed(second)
        XCTAssertEqual(host.disconnects, 0)
        _ = try await status(first, session: session)
        XCTAssertEqual(host.statusRequests, 2); XCTAssertEqual(host.actions, [])
        await second.close(); await first.close()
    }
    func testStopCancelsOnlyAuthenticatedOwnedHostAndAllowsFreshRestart() async throws {
        let host = SyntheticInstaller(), otherHost = SyntheticInstaller()
        let server = try await start(host), otherServer = try await start(otherHost)
        defer { server.stop(); otherServer.stop() }
        let (client, session) = try await connect(server); _ = try await status(client, session: session)
        let (other, otherSession) = try await connect(otherServer); _ = try await status(other, session: otherSession)
        server.stop(); await closed(client)
        XCTAssertEqual(host.disconnects, 1); XCTAssertEqual(otherHost.disconnects, 0); XCTAssertNil(server.listeningPort)
        _ = try await status(other, session: otherSession)
        let restarted = expectation(description: "restarted")
        server.onListening = { _ in restarted.fulfill() }; try server.start()
        await fulfillment(of: [restarted], timeout: 3)
        let (newClient, newSession) = try await connect(server)
        XCTAssertNotEqual(session.challenge, newSession.challenge)
        _ = try await status(newClient, session: newSession)
        await client.close(); await other.close(); await newClient.close()
    }
    func testSnapshotFloodClosesPeerAtBoundedOutgoingQueue() async throws {
        let host = SyntheticInstaller(); let server = try await start(host); defer { server.stop() }
        let (client, session) = try await connect(server); _ = try await status(client, session: session)
        var overflow = false
        server.onError = { overflow = $0 == LinkFailure.oversizedFrame.localizedDescription }
        // No await here: completion callbacks cannot drain accounting during this burst.
        for _ in 0..<500 { host.publish(String(repeating: "x", count: 512)) }
        XCTAssertTrue(overflow); XCTAssertEqual(host.disconnects, 1)
        XCTAssertNotNil(server.listeningPort)
        await client.close()
    }
    func testFrameFromPreviousSessionCannotAuthenticateNewConnection() async throws {
        let host = SyntheticInstaller(); let server = try await start(host); defer { server.stop() }
        let (first, firstSession) = try await connect(server)
        let oldFrame = try firstSession.seal(InstallerRequest(hostSession: "", revision: 0, action: .status).message())
        try await first.write(oldFrame); _ = try await first.line()
        let disconnected = expectation(description: "old peer closed")
        host.onDisconnect = { disconnected.fulfill() }; await first.close()
        await fulfillment(of: [disconnected], timeout: 2)
        host.onDisconnect = nil
        let (second, _) = try await connect(server)
        try await second.write(oldFrame); await closed(second)
        XCTAssertEqual(host.statusRequests, 1); XCTAssertEqual(host.disconnects, 1)
        await second.close()
    }
    func testAuthenticatedIdleDeadlineRefreshesThenCancelsOnlyOwnedHost() async throws {
        let host = SyntheticInstaller(); let server = try await start(host); defer { server.stop() }
        let expired = expectation(description: "authenticated idle timeout")
        server.onError = { if $0 == "iPhone connection timed out." { expired.fulfill() } }
        let (client, session) = try await connect(server); _ = try await status(client, session: session)
        try await Task.sleep(for: .seconds(1))
        _ = try await status(client, session: session)
        let refreshed = ContinuousClock.now
        await fulfillment(of: [expired], timeout: 22)
        XCTAssertGreaterThanOrEqual(refreshed.duration(to: .now), .milliseconds(19_500))
        XCTAssertEqual(host.disconnects, 1); XCTAssertEqual(host.statusRequests, 2)
        XCTAssertNotNil(server.listeningPort)
        await closed(client); await client.close()
    }
    func testMultibyteHostErrorIsByteBoundedAndConnectionRemainsUsable() async throws {
        let host = SyntheticInstaller(); let server = try await start(host); defer { server.stop() }
        let (client, session) = try await connect(server); let initial = try await status(client, session: session)
        // One grapheme with many combining scalars defeats Character-count truncation.
        host.rejection = NSError(domain: "synthetic", code: 1, userInfo: [NSLocalizedDescriptionKey: "e" + String(repeating: "\u{301}", count: 1000)])
        let request = InstallerRequest(hostSession: initial.hostSession, revision: initial.revision, action: .inspectAndroid)
        try await client.write(session.seal(request.message()))
        let rejection = try await snapshot(client, session: session)
        XCTAssertLessThanOrEqual(try XCTUnwrap(rejection.error).utf8.count, 128)
        XCTAssertEqual(host.disconnects, 0); XCTAssertEqual(host.actions, [])
        host.rejection = nil; _ = try await status(client, session: session)
        await client.close()
    }
    func testHostRejectionReturnsEncryptedBoundedErrorWithoutExecutingAction() async throws {
        let host = SyntheticInstaller(); let server = try await start(host); defer { server.stop() }
        let (client, session) = try await connect(server); let initial = try await status(client, session: session)
        let stale = InstallerRequest(hostSession: initial.hostSession, revision: 99, action: .prepare)
        try await client.write(session.seal(stale.message()))
        let rejection = try await snapshot(client, session: session)
        XCTAssertNotNil(rejection.error); XCTAssertEqual(host.actions, []); XCTAssertEqual(host.disconnects, 0)
        await client.close()
    }
}

@MainActor private final class SyntheticInstaller: InstallerServing {
    var snapshot = InstallerSnapshot(serial: "SYNTHETIC", firmwareName: "fixture.zip", firmwareSHA256: String(repeating: "a", count: 64))
    var onChange: ((InstallerSnapshot) -> Void)?
    var onDisconnect: (() -> Void)?
    var rejection: Error?
    var actions: [InstallerAction] = []
    var statusRequests = 0, disconnects = 0
    func submit(_ request: InstallerRequest) throws {
        try request.validate()
        if request.action == .status { statusRequests += 1; return }
        if let rejection { throw rejection }
        guard request.hostSession == snapshot.hostSession, request.revision == snapshot.revision else { throw LinkFailure.replay }
        actions.append(request.action); snapshot.revision += 1; snapshot.status = "Synthetic action"
        onChange?(snapshot)
    }
    func publish(_ text: String) { snapshot.status = text; onChange?(snapshot) }
    func disconnect() { disconnects += 1; onDisconnect?() }
}

/// Blocking socket calls run on this actor's executor, never the main actor/NWListener queue.
private actor SocketPeer {
    private var descriptor: Int32
    private var buffered = Data()
    init(port: UInt16) throws {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw Self.error() }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        _ = setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(socket, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard result == 0 else { let error = Self.error(); Darwin.close(socket); throw error }
        descriptor = socket
    }
    func write(_ data: Data, fragmentBytes: Int? = nil) throws {
        var offset = 0
        while offset < data.count {
            let count = min(fragmentBytes ?? data.count, data.count - offset)
            let sent = data.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress!.advanced(by: offset), count, 0) }
            guard sent > 0 else { throw Self.error() }; offset += sent
        }
    }
    func line() throws -> Data? {
        while true {
            if let end = buffered.firstIndex(of: 10) {
                let line = Data(buffered[..<end]); buffered.removeSubrange(...end); return line
            }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.recv(descriptor, &bytes, bytes.count, 0)
            if count == 0 { return nil }
            guard count > 0 else { throw Self.error() }
            buffered.append(contentsOf: bytes.prefix(count))
            guard buffered.count <= 65536 else { throw LinkFailure.oversizedFrame }
        }
    }
    deinit { if descriptor >= 0 { Darwin.close(descriptor) } }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
    private static func error() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
