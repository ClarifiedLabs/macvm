import Darwin

/// Best-effort trigger for macOS's Local Network privacy alert.
///
/// Connecting a UDP socket to a local address causes the system to evaluate
/// Local Network access without transmitting any packets. This follows the
/// approach recommended in Apple Technical Note TN3179.
enum LocalNetworkPrivacy {
    struct InterfaceAddress {
        let flags: UInt32
        let address: sockaddr_in6
    }

    static func triggerAlert() {
        let hostParts = (0..<2).map { _ in
            (0..<8).map { _ in UInt8.random(in: 0...255) }
        }
        let addresses = selectedLinkLocalIPv6Addresses(
            from: ipv6InterfaceAddresses(),
            hostParts: hostParts
        )
        for address in addresses {
            connectUDP(to: address)
        }
    }

    static func selectedLinkLocalIPv6Addresses(
        from interfaces: [InterfaceAddress],
        hostParts: [[UInt8]]
    ) -> [sockaddr_in6] {
        precondition(hostParts.allSatisfy { $0.count == 8 })

        return interfaces
            .filter { ($0.flags & UInt32(bitPattern: IFF_BROADCAST)) != 0 }
            .map(\.address)
            .filter(isIPv6AddressLinkLocal)
            .flatMap { address in
                hostParts.map { hostPart in
                    var target = setIPv6LinkLocalAddressHostPart(of: address, to: hostPart)
                    target.sin6_port = UInt16(9).bigEndian
                    return target
                }
            }
    }

    private static func connectUDP(to address: sockaddr_in6) {
        let socketDescriptor = Darwin.socket(AF_INET6, SOCK_DGRAM, 0)
        guard socketDescriptor >= 0 else { return }
        defer { Darwin.close(socketDescriptor) }

        withUnsafePointer(to: address) { addressPointer in
            addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                _ = Darwin.connect(
                    socketDescriptor,
                    socketAddress,
                    socklen_t(socketAddress.pointee.sa_len)
                )
            }
        }
    }

    private static func ipv6InterfaceAddresses() -> [InterfaceAddress] {
        var addressList: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addressList) == 0, let firstAddress = addressList else {
            return []
        }
        defer { freeifaddrs(firstAddress) }

        var result: [InterfaceAddress] = []
        var currentAddress: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = currentAddress {
            defer { currentAddress = interface.pointee.ifa_next }
            guard let socketAddress = interface.pointee.ifa_addr,
                  socketAddress.pointee.sa_family == AF_INET6,
                  socketAddress.pointee.sa_len >= MemoryLayout<sockaddr_in6>.size else {
                continue
            }
            result.append(InterfaceAddress(
                flags: interface.pointee.ifa_flags,
                address: UnsafeRawPointer(socketAddress).load(as: sockaddr_in6.self)
            ))
        }
        return result
    }

    private static func setIPv6LinkLocalAddressHostPart(
        of address: sockaddr_in6,
        to hostPart: [UInt8]
    ) -> sockaddr_in6 {
        var result = address
        withUnsafeMutableBytes(of: &result.sin6_addr) { buffer in
            buffer[8...].copyBytes(from: hostPart)
        }
        return result
    }

    private static func isIPv6AddressLinkLocal(_ address: sockaddr_in6) -> Bool {
        withUnsafeBytes(of: address.sin6_addr) { buffer in
            buffer[0] == 0xfe && (buffer[1] & 0xc0) == 0x80
        }
    }
}
