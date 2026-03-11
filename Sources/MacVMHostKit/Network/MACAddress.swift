import Foundation

/// Utilities for normalizing and comparing MAC addresses.
///
/// `/var/db/dhcpd_leases` stores octets without zero padding (`52:55:55:14:2:36`)
/// while `VZMACAddress.string` zero-pads (`52:55:55:14:02:36`). A naive string
/// compare between the two silently fails, so always compare the parsed octets.
enum MACAddress {
    /// Parse a colon-separated MAC into its six octets, tolerating missing zero
    /// padding. Returns nil for anything that isn't six hex octets.
    static func octets(_ raw: String) -> [UInt8]? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 6 else { return nil }

        var result: [UInt8] = []
        result.reserveCapacity(6)
        for part in parts {
            guard !part.isEmpty, part.count <= 2, let value = UInt8(part, radix: 16) else {
                return nil
            }
            result.append(value)
        }
        return result
    }

    /// Canonical lowercase zero-padded form (`52:55:55:14:02:36`), or nil.
    static func canonical(_ raw: String) -> String? {
        guard let octets = octets(raw) else { return nil }
        return octets.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// Compare two MAC strings by value, ignoring case and zero padding.
    static func equal(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = octets(lhs), let right = octets(rhs) else { return false }
        return left == right
    }
}
