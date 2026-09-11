import Foundation
import Darwin

public enum LocalEndpoint {
    public static func accepts(_ host: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host == "localhost" { return true }
        if host.hasSuffix(".local"), host.utf8.count <= 253, host.range(of: "^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\\.local$", options: .regularExpression) != nil, !host.contains("..") { return true }
        var ipv4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv4) { Array($0) }
            return bytes[0] == 10 || bytes[0] == 127 || (bytes[0] == 192 && bytes[1] == 168) ||
                (bytes[0] == 172 && (16...31).contains(bytes[1])) || (bytes[0] == 169 && bytes[1] == 254)
        }
        var ipv6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: &ipv6) { Array($0) }
            return (bytes[0] & 0xfe) == 0xfc || (bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80) || (bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1)
        }
        return false
    }
}
