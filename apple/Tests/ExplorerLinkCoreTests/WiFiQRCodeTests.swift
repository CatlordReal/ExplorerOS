import Foundation
import XCTest
@testable import ExplorerLinkCore

final class WiFiQRCodeTests: XCTestCase {
    func testBasicPayloadAndOpenIgnoresStalePassword() throws {
        XCTAssertEqual(try WiFiQRCode.payload(ssid: "Glass", password: "password", security: .wpaPersonal),
                       "WIFI:T:WPA;S:Glass;P:password;;")
        XCTAssertEqual(try WiFiQRCode.payload(ssid: "Guest", password: "stale;P:secret\n🔑", security: .open),
                       "WIFI:T:nopass;S:Guest;;")
    }

    func testEscapesEveryDelimiterAndBackslashWithoutFieldInjection() throws {
        XCTAssertEqual(try WiFiQRCode.payload(ssid: #"a\;,:"b"#, password: #"p\;,:"word"#, security: .wpaPersonal),
                       #"WIFI:T:WPA;S:a\\\;\,\:\"b;P:p\\\;\,\:\"word;;"#)
        XCTAssertEqual(try WiFiQRCode.payload(ssid: "Guest;P:injected", password: "", security: .open),
                       #"WIFI:T:nopass;S:Guest\;P\:injected;;"#)
    }

    func testLeadingAndTrailingSpacesArePreserved() throws {
        XCTAssertEqual(try WiFiQRCode.payload(ssid: " Network ", password: " secret ", security: .wpaPersonal),
                       "WIFI:T:WPA;S: Network ;P: secret ;;")
        XCTAssertEqual(try WiFiQRCode.payload(ssid: " ", password: "", security: .open), "WIFI:T:nopass;S: ;;")
    }

    func testSSIDUsesUTF8BytesAndPreservesUnicodeWithoutNormalization() throws {
        let maximum = String(repeating: "🛜", count: 8)
        XCTAssertEqual(try WiFiQRCode.payload(ssid: maximum, password: "", security: .open), "WIFI:T:nopass;S:\(maximum);;")
        XCTAssertThrowsError(try WiFiQRCode.payload(ssid: maximum + "a", password: "", security: .open))
        let decomposed = "Cafe\u{301}"
        XCTAssertEqual(Array(try WiFiQRCode.payload(ssid: decomposed, password: "", security: .open).utf8),
                       Array("WIFI:T:nopass;S:\(decomposed);;".utf8))
        XCTAssertNoThrow(try WiFiQRCode.payload(ssid: String(repeating: "a", count: 32), password: "", security: .open))
        for ssid in ["", String(repeating: "a", count: 33), "bad\nname", "bad\0name", "bad\u{7f}name"] {
            XCTAssertThrowsError(try WiFiQRCode.payload(ssid: ssid, password: "", security: .open)) {
                XCTAssertEqual($0 as? WiFiQRCode.ValidationError, .invalidSSID)
            }
        }
    }

    func testWPAPasswordBoundariesAndCharacterRestrictions() throws {
        for count in [8, 63] {
            XCTAssertNoThrow(try WiFiQRCode.payload(ssid: "Glass", password: String(repeating: "a", count: count), security: .wpaPersonal))
        }
        for password in ["", "1234567", String(repeating: "a", count: 64), "password\n", "password\t", "password\0", "password\u{7f}", "passwörd", "password🔑"] {
            XCTAssertThrowsError(try WiFiQRCode.payload(ssid: "Glass", password: password, security: .wpaPersonal)) {
                XCTAssertEqual($0 as? WiFiQRCode.ValidationError, .invalidPassword)
            }
        }
    }

    func testErrorsNeverContainSubmittedCredentials() {
        let secretSSID = "private-network\n", secretPassword = "private-password🔑"
        for (ssid, password) in [(secretSSID, secretPassword), ("Valid private network", secretPassword)] {
            do {
                _ = try WiFiQRCode.payload(ssid: ssid, password: password, security: .wpaPersonal)
                XCTFail("Invalid credentials accepted")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains(ssid))
                XCTAssertFalse(error.localizedDescription.contains(password))
                XCTAssertFalse(String(describing: error).contains("private"))
            }
        }
    }
}
