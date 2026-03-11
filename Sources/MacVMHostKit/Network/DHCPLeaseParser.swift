import Foundation

/// A single parsed entry from `/var/db/dhcpd_leases`.
struct DHCPLease: Equatable {
    var ipAddress: String
    var hardwareAddress: String
    var expiresAt: Date?
}

/// Parser for macOS's `/var/db/dhcpd_leases` file.
///
/// The file is a sequence of brace-delimited blocks, e.g.:
/// ```
/// {
/// 	name=guest
/// 	ip_address=192.168.64.5
/// 	hw_address=1,52:55:55:14:2:36
/// 	identifier=1,52:55:55:14:2:36
/// 	lease=0x689abc12
/// }
/// ```
/// `hw_address` carries a leading hardware-type prefix (`1,`) and non-zero-padded
/// octets; `lease` is a hex Unix expiry timestamp.
enum DHCPLeaseParser {
    static func parse(_ contents: String) -> [DHCPLease] {
        var leases: [DHCPLease] = []
        var ip: String?
        var mac: String?
        var expiry: Date?
        var inBlock = false

        func flush() {
            if let ip, let mac {
                leases.append(DHCPLease(ipAddress: ip, hardwareAddress: mac, expiresAt: expiry))
            }
            ip = nil
            mac = nil
            expiry = nil
        }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line == "{" {
                inBlock = true
                ip = nil
                mac = nil
                expiry = nil
                continue
            }

            if line == "}" {
                flush()
                inBlock = false
                continue
            }

            guard inBlock, let equalsIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<equalsIndex])
            let value = String(line[line.index(after: equalsIndex)...])

            switch key {
            case "ip_address":
                ip = value
            case "hw_address":
                // "1,52:55:55:14:2:36" — drop the hardware-type prefix before the comma.
                mac = value.split(separator: ",", maxSplits: 1).last.map(String.init)
            case "lease":
                expiry = parseHexTimestamp(value)
            default:
                break
            }
        }

        // Tolerate a final block that lacks a closing brace.
        if inBlock {
            flush()
        }

        return leases
    }

    /// Choose the freshest lease matching `macAddress`. Prefers non-expired
    /// entries; if every match is expired it still returns the most recent one
    /// (a just-expired lease usually still reflects the guest's current IP).
    static func bestLease(in leases: [DHCPLease], macAddress: String, now: Date) -> DHCPLease? {
        let matching = leases.filter { MACAddress.equal($0.hardwareAddress, macAddress) }
        let live = matching.filter { lease in
            guard let expiry = lease.expiresAt else { return true }
            return expiry >= now
        }

        let pool = live.isEmpty ? matching : live
        return pool.max { lhs, rhs in
            (lhs.expiresAt ?? .distantPast) < (rhs.expiresAt ?? .distantPast)
        }
    }

    static func parseHexTimestamp(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("0x") {
            text.removeFirst(2)
        }
        guard let seconds = UInt64(text, radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }
}
