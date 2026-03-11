import Foundation

/// Resolves a guest VM's IP address from host-side DHCP/ARP tables.
///
/// The default NAT attachment records addresses in `/var/db/dhcpd_leases`;
/// `arp -an` is the fallback for entries the DHCP server hasn't persisted (or
/// has already aged out).
enum GuestNetwork {
    static let leasesPath = "/var/db/dhcpd_leases"

    static func resolveIP(macAddress: String, now: Date = Date()) -> String? {
        if let ip = resolveFromLeases(macAddress: macAddress, now: now) {
            return ip
        }
        return resolveFromARP(macAddress: macAddress)
    }

    static func resolveFromLeases(macAddress: String, now: Date) -> String? {
        guard let contents = try? String(contentsOfFile: leasesPath, encoding: .utf8) else {
            return nil
        }
        let leases = DHCPLeaseParser.parse(contents)
        return DHCPLeaseParser.bestLease(in: leases, macAddress: macAddress, now: now)?.ipAddress
    }

    static func resolveFromARP(macAddress: String) -> String? {
        guard let output = runARP() else { return nil }
        return parseARP(output).first { MACAddress.equal($0.mac, macAddress) }?.ip
    }

    /// Parse `arp -an` output lines like:
    /// `? (192.168.64.5) at 52:55:55:14:2:36 on bridge100 ifscope [ethernet]`.
    static func parseARP(_ output: String) -> [(ip: String, mac: String)] {
        var entries: [(ip: String, mac: String)] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let ipStart = line.firstIndex(of: "("),
                  let ipEnd = line.firstIndex(of: ")"),
                  ipStart < ipEnd else { continue }
            let ip = String(line[line.index(after: ipStart)..<ipEnd])

            let tokens = line.split(separator: " ")
            guard let atIndex = tokens.firstIndex(of: "at"), atIndex + 1 < tokens.count else { continue }
            let mac = String(tokens[atIndex + 1])
            guard MACAddress.octets(mac) != nil else { continue }

            entries.append((ip: ip, mac: mac))
        }
        return entries
    }

    private static func runARP() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        process.arguments = ["-an"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
