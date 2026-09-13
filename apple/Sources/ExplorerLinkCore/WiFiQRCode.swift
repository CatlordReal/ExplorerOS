import Foundation

/// Encodes the Wi-Fi payload understood by the pinned XE24 scanner.
/// Credentials are preserved exactly and never stored or included in errors.
public struct WiFiQRCode {
    public enum Security: Sendable { case wpaPersonal, open }

    public enum ValidationError: Error, Equatable, LocalizedError, Sendable {
        case invalidSSID, invalidPassword

        public var errorDescription: String? {
            switch self {
            case .invalidSSID: return "Network name must contain 1–32 UTF-8 bytes and no control characters."
            case .invalidPassword: return "WPA password must contain 8–63 printable ASCII characters."
            }
        }
    }

    public static func payload(ssid: String, password: String, security: Security) throws -> String {
        guard (1...32).contains(ssid.utf8.count),
              !ssid.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ValidationError.invalidSSID
        }
        switch security {
        case .open:
            return "WIFI:T:nopass;S:\(escape(ssid));;"
        case .wpaPersonal:
            // XE24 quotes all WPA keys, so a raw 64-digit hexadecimal PSK is unsupported.
            guard (8...63).contains(password.utf8.count),
                  password.utf8.allSatisfy({ (0x20...0x7e).contains($0) }) else {
                throw ValidationError.invalidPassword
            }
            return "WIFI:T:WPA;S:\(escape(ssid));P:\(escape(password));;"
        }
    }

    private static func escape(_ value: String) -> String {
        var output = ""
        for scalar in value.unicodeScalars {
            if scalar == "\\" || scalar == ";" || scalar == "," || scalar == "\"" || scalar == ":" {
                output.append("\\")
            }
            output.unicodeScalars.append(scalar)
        }
        return output
    }
}
