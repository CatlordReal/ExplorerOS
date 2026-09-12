import Foundation
import CryptoKit

public enum LinkFailure: Error, LocalizedError, Equatable {
    case invalidKey, malformedFrame, oversizedFrame, unexpectedHello, authentication, replay, unsupportedVersion, invalidMessage, notReady
    public var errorDescription: String? {
        switch self {
        case .invalidKey: return "Pairing requires exactly 64 hexadecimal characters."
        case .malformedFrame: return "The peer sent an invalid protocol frame."
        case .oversizedFrame: return "The peer exceeded the message size limit."
        case .unexpectedHello: return "Unexpected session handshake. Reconnect to start a new session."
        case .authentication: return "Authentication failed. Check the pairing key on both devices."
        case .replay: return "A stale or repeated message was rejected."
        case .unsupportedVersion: return "This peer uses an unsupported protocol version."
        case .invalidMessage: return "The peer sent an invalid application message."
        case .notReady: return "The peer has not completed the connection handshake."
        }
    }
}

public struct LinkMessage: Codable, Equatable, Sendable {
    public let type: String
    public let payload: [String: String]
    public init(type: String, payload: [String: String] = [:]) { self.type = type; self.payload = payload }
    public func validate() throws {
        guard !type.isEmpty, type.utf8.count <= 64, payload.count <= 32,
              payload.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 64 && $0.value.utf8.count <= 4096 }) else {
            throw LinkFailure.invalidMessage
        }
        let keys = Set(payload.keys)
        func require(_ expected: Set<String>) throws { guard keys == expected else { throw LinkFailure.invalidMessage } }
        switch type {
        case "capabilities":
            try require(["endpoint", "features"])
            guard ["glass", "ios", "simulator", "qt"].contains(payload["endpoint"] ?? "") else { throw LinkFailure.invalidMessage }
        case "card":
            try require(["title", "body", "source"])
            guard ["companion", "appIntent", "speech"].contains(payload["source"] ?? "") else { throw LinkFailure.invalidMessage }
        case "navigation":
            try require(["instruction", "distance", "destination", "step", "total", "source"])
            guard ["mapkit", "demo"].contains(payload["source"] ?? "") else { throw LinkFailure.invalidMessage }
        case "navigation.stop": try require([])
        case "input":
            try require(["gesture"])
            guard GlassGesture(rawValue: payload["gesture"] ?? "") != nil else { throw LinkFailure.invalidMessage }
        case "phone.action":
            try require(["action"])
            guard PhoneIntegrationAction(rawValue: payload["action"] ?? "") != nil else { throw LinkFailure.invalidMessage }
        case "media.begin": try MediaTransfer.validateBegin(payload)
        case "media.accept": try MediaTransfer.validateAccept(payload)
        case "media.chunk": try MediaTransfer.validateChunk(payload)
        case "media.ack": try MediaTransfer.validateAck(payload)
        case "media.finish": try MediaTransfer.validateFinish(payload)
        case "media.complete": try MediaTransfer.validateComplete(payload)
        case "media.cancel": try MediaTransfer.validateCancel(payload)
        case "ping", "pong": guard keys.isSubset(of: ["id"]) else { throw LinkFailure.invalidMessage }
        case "error": try require(["code", "message"])
        default: break // Unknown extensions receive an authenticated error from the endpoint.
        }
    }
    public static func capabilities(endpoint: String, features: [String]) -> Self {
        .init(type: "capabilities", payload: ["endpoint": endpoint, "features": features.joined(separator: ",")])
    }
}

/// A connection owns one decoder. Clear it, its crypto session and queued data together.
public struct LineDecoder {
    public static let maximumBytes = 32768
    private var buffer = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in bytes {
            if byte == 10 {
                guard !buffer.isEmpty, buffer.last != 13, String(data: buffer, encoding: .utf8) != nil else { throw LinkFailure.malformedFrame }
                lines.append(buffer)
                buffer.removeAll(keepingCapacity: true)
            } else {
                guard buffer.count < Self.maximumBytes else { throw LinkFailure.oversizedFrame }
                buffer.append(byte)
            }
        }
        return lines
    }
}

public enum PairingKey {
    public static func generate() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).hex }
    }
    public static func data(from hex: String) throws -> Data {
        guard hex.utf8.count == 64, hex.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw LinkFailure.invalidKey
        }
        return Data(stride(from: 0, to: 64, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// AES-GCM authenticates each message; the receiver's fresh challenge rejects old connections.
public final class SecureSession {
    public static let aad = Data("ExplorerLink/1".utf8)
    private let key: SymmetricKey
    public let challenge: String
    private var peerChallenge: String?
    private var outgoing: UInt64 = 0
    private var incoming: UInt64 = 0
    private var failed = false
    public private(set) var authenticated = false
    public var hasPeerHello: Bool { peerChallenge != nil }
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private struct Hello: Codable { let v: Int; let hello: String }
    private struct Box: Codable { let v: Int; let nonce: String; let box: String }
    private struct Plain: Codable { let challenge: String; let seq: UInt64; let type: String; let payload: [String: String] }

    public init(keyHex: String, challenge: String? = nil) throws {
        key = SymmetricKey(data: try PairingKey.data(from: keyHex))
        self.challenge = challenge ?? PairingKey.generate()
        _ = try PairingKey.data(from: self.challenge)
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }
    public func hello() throws -> Data { try framed(encoder.encode(Hello(v: 1, hello: challenge))) }
    public func receive(_ line: Data) throws -> LinkMessage? {
        guard !failed else { throw LinkFailure.authentication }
        do { return try receiveValidated(line) }
        catch { failed = true; authenticated = false; throw error }
    }
    private func receiveValidated(_ line: Data) throws -> LinkMessage? {
        guard line.count <= LineDecoder.maximumBytes, let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let version = object["v"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID() else { throw LinkFailure.malformedFrame }
        guard version == 1 else { throw LinkFailure.unsupportedVersion }
        if object["hello"] != nil {
            guard peerChallenge == nil, Set(object.keys) == ["v", "hello"] else { throw LinkFailure.unexpectedHello }
            let hello = try decoder.decode(Hello.self, from: line)
            _ = try PairingKey.data(from: hello.hello)
            peerChallenge = hello.hello
            return nil
        }
        guard peerChallenge != nil else { throw LinkFailure.notReady }
        guard Set(object.keys) == ["v", "nonce", "box"] else { throw LinkFailure.malformedFrame }
        let wire = try decoder.decode(Box.self, from: line)
        guard let nonce = Data(base64Encoded: wire.nonce), nonce.count == 12,
              let box = Data(base64Encoded: wire.box), box.count >= 16 else { throw LinkFailure.malformedFrame }
        let plaintext: Data
        do {
            let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: box.dropLast(16), tag: box.suffix(16))
            plaintext = try AES.GCM.open(sealed, using: key, authenticating: Self.aad)
        } catch { throw LinkFailure.authentication }
        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              Set(object.keys) == ["challenge", "seq", "type", "payload"] else { throw LinkFailure.invalidMessage }
        let packet = try decoder.decode(Plain.self, from: plaintext)
        guard packet.challenge == challenge else { throw LinkFailure.authentication }
        guard packet.seq > incoming, packet.seq <= 9_007_199_254_740_991 else { throw LinkFailure.replay }
        let message = LinkMessage(type: packet.type, payload: packet.payload)
        try message.validate()
        incoming = packet.seq
        authenticated = true
        return message
    }
    public func seal(_ message: LinkMessage) throws -> Data {
        guard !failed, let peerChallenge else { throw LinkFailure.notReady }
        try message.validate()
        guard outgoing < 9_007_199_254_740_991 else { throw LinkFailure.replay }
        let sequence = outgoing + 1
        let data = try encoder.encode(Plain(challenge: peerChallenge, seq: sequence, type: message.type, payload: message.payload))
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Self.aad)
        let wire = Box(v: 1, nonce: Data(sealed.nonce).base64EncodedString(), box: (sealed.ciphertext + sealed.tag).base64EncodedString())
        let result = try framed(encoder.encode(wire))
        outgoing = sequence
        return result
    }
    private func framed(_ data: Data) throws -> Data {
        guard data.count <= LineDecoder.maximumBytes else { throw LinkFailure.oversizedFrame }
        return data + Data([10])
    }
}
