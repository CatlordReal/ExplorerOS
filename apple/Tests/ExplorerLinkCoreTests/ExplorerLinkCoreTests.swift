import XCTest
import CryptoKit
@testable import ExplorerLinkCore

final class ExplorerLinkCoreTests: XCTestCase {
    private let key = String(repeating: "11", count: 32)
    private func sessions() throws -> (SecureSession, SecureSession) {
        let a = try SecureSession(keyHex: key); let b = try SecureSession(keyHex: key)
        XCTAssertNil(try a.receive(b.hello().dropLast())); XCTAssertNil(try b.receive(a.hello().dropLast()))
        return (a, b)
    }
    func testFragmentedAndCoalescedLines() throws {
        var decoder = LineDecoder()
        XCTAssertTrue(try decoder.append(Data("{\"v\":1".utf8)).isEmpty)
        let result = try decoder.append(Data("}\n{\"v\":2}\n".utf8))
        XCTAssertEqual(result.map { String(decoding: $0, as: UTF8.self) }, ["{\"v\":1}", "{\"v\":2}"])
    }
    func testFramingRejectsOversizeAndInvalidUTF8() throws {
        var decoder = LineDecoder()
        XCTAssertThrowsError(try decoder.append(Data(repeating: 65, count: 32769)))
        var invalid = LineDecoder()
        XCTAssertThrowsError(try invalid.append(Data([0xff, 10])))
        var empty = LineDecoder(); XCTAssertThrowsError(try empty.append(Data([10])))
    }
    func testHandshakeIsNotAuthentication() throws {
        let (a, b) = try sessions()
        XCTAssertFalse(a.authenticated); XCTAssertFalse(b.authenticated)
        let message = LinkMessage(type: "card", payload: ["title": "Glass", "body": "A Unicode note 🥽", "source": "companion"])
        XCTAssertEqual(try b.receive(a.seal(message).dropLast()), message)
        XCTAssertTrue(b.authenticated); XCTAssertFalse(a.authenticated)
        XCTAssertEqual(try a.receive(b.seal(.init(type: "pong")).dropLast())?.type, "pong")
    }
    func testReplayFailsClosed() throws {
        let (a, b) = try sessions(); let frame = try a.seal(.init(type: "ping")).dropLast()
        _ = try b.receive(frame)
        XCTAssertThrowsError(try b.receive(frame)) { XCTAssertEqual($0 as? LinkFailure, .replay) }
        XCTAssertFalse(b.authenticated)
        XCTAssertThrowsError(try b.receive(a.seal(.init(type: "ping")).dropLast()))
    }
    func testOldConnectionAndWrongKeyRejected() throws {
        let (a, b) = try sessions(); let old = try a.seal(.init(type: "ping")).dropLast()
        let fresh = try SecureSession(keyHex: key); _ = try fresh.receive(a.hello().dropLast())
        XCTAssertThrowsError(try fresh.receive(old))
        let wrong = try SecureSession(keyHex: String(repeating: "22", count: 32)); _ = try wrong.receive(b.hello().dropLast())
        XCTAssertThrowsError(try b.receive(wrong.seal(.init(type: "ping")).dropLast()))
    }
    func testDuplicateHelloMalformedVersionAndPreHandshakeRejected() throws {
        let (a, b) = try sessions(); XCTAssertThrowsError(try a.receive(b.hello().dropLast()))
        let fresh = try SecureSession(keyHex: key)
        XCTAssertThrowsError(try fresh.receive(Data("{\"v\":true,\"hello\":\"\(key)\"}".utf8)))
        let v2 = try SecureSession(keyHex: key)
        XCTAssertThrowsError(try v2.receive(Data("{\"v\":2,\"hello\":\"\(key)\"}".utf8)))
        let initial = try SecureSession(keyHex: key)
        XCTAssertThrowsError(try initial.seal(.init(type: "card")))
    }
    func testTamperedCiphertextAndAADFailAuthentication() throws {
        let (a, b) = try sessions()
        var object = try JSONSerialization.jsonObject(with: a.seal(.init(type: "ping"))) as! [String: Any]
        var data = Data(base64Encoded: object["box"] as! String)!; data[0] ^= 1
        object["box"] = data.base64EncodedString()
        XCTAssertThrowsError(try b.receive(JSONSerialization.data(withJSONObject: object)))
    }
    func testPayloadLimitsUseUTF8BytesAndKeysAreValidated() throws {
        XCTAssertThrowsError(try LinkMessage(type: "card", payload: ["body": String(repeating: "🥽", count: 1025)]).validate())
        XCTAssertThrowsError(try LinkMessage(type: "card", payload: ["": "bad"]).validate())
        XCTAssertThrowsError(try PairingKey.data(from: String(repeating: "z", count: 64)))
        XCTAssertEqual(try PairingKey.data(from: PairingKey.generate()).count, 32)
    }
    func testPythonCryptographicFixture() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("fixtures/protocol-v1.json"))) as! [String: Any]
        let receiver = try SecureSession(keyHex: fixture["key_hex"] as! String, challenge: fixture["responder_hello"] as? String)
        _ = try receiver.receive(JSONSerialization.data(withJSONObject: ["v": 1, "hello": fixture["initiator_hello"]!]))
        let result = try receiver.receive(JSONSerialization.data(withJSONObject: fixture["encrypted_packet"]!))
        XCTAssertEqual(result?.type, "card"); XCTAssertEqual(result?.payload["body"], "Explorer Link v1 test-only vector")
    }
    func testKnownSchemasMatchOtherEndpoints() throws {
        let invalid: [LinkMessage] = [
            .init(type: "capabilities", payload: ["endpoint": "attacker", "features": "cards"]),
            .init(type: "card", payload: ["title": "Missing source", "body": "text"]),
            .init(type: "navigation.stop", payload: ["extra": "x"]),
            .init(type: "input", payload: ["gesture": "launchSiri"]),
            .init(type: "phone.action", payload: ["action": "run-arbitrary-url"]),
            .init(type: "ping", payload: ["extra": "x"])
        ]
        let (sender, receiver) = try sessions()
        for message in invalid { XCTAssertThrowsError(try sender.seal(message)) }
        XCTAssertEqual(try receiver.receive(sender.seal(.init(type: "phone.action", payload: ["action": "notes.browse"])).dropLast())?.type, "phone.action")
        var lines = LineDecoder(); XCTAssertThrowsError(try lines.append(Data("{}\r\n".utf8)))
    }
    func testRoutesNeverAdvanceOutOfBounds() {
        var route = RouteProgress(steps: [.init(instruction: " ", distance: 0), .init(instruction: "Turn left", distance: 150), .init(instruction: "Arrive", distance: 1400)], destination: "Library")
        route.move(-10); XCTAssertEqual(route.index, 0); XCTAssertEqual(route.message()?.payload["distance"], "150 m")
        route.move(10); XCTAssertEqual(route.index, 1); XCTAssertEqual(route.message()?.payload["distance"], "1.4 km")
        XCTAssertNil(RouteProgress(steps: [], destination: "").message())
    }
    func testGlassCameraDoesNotPretendToInvokeSiri() {
        XCTAssertEqual(GlassControls.action(for: .camera, routeActive: false), .showCompanion)
        XCTAssertEqual(GlassControls.action(for: .swipeRight, routeActive: true), .nextStep)
        XCTAssertEqual(GlassControls.action(for: .swipeLeft, routeActive: false), .none)
    }
    func testOnlyLocalEndpointsAccepted() {
        for host in ["127.0.0.1", "localhost", "10.1.2.3", "192.168.4.1", "172.16.0.1", "glass.local", "::1", "fd12::1"] { XCTAssertTrue(LocalEndpoint.accepts(host), host) }
        for host in ["8.8.8.8", "172.15.0.1", "example.com", "https://glass.local", "192.168.1.1:8765", "0.0.0.0", "::", "2001:4860:4860::8888", "glass..local"] { XCTAssertFalse(LocalEndpoint.accepts(host), host) }
    }
    func testSolarBoundariesAndPolarFallback() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 21, hour: 12))!
        let actual = SolarCalculator.times(date: date, latitude: 51.5, longitude: 0, calendar: calendar)
        XCTAssertFalse(actual.estimated); XCTAssertLessThan(calendar.component(.hour, from: actual.sunrise), 6)
        XCTAssertEqual(actual.phase(at: actual.sunset), .sunset)
        XCTAssertEqual(actual.phase(at: actual.sunset.addingTimeInterval(1800)), .dusk)
        XCTAssertEqual(actual.phase(at: actual.sunrise), .dawn)
        XCTAssertTrue(SolarCalculator.times(date: date, latitude: 90, longitude: 0, calendar: calendar).estimated)
    }
}
