import Foundation

public struct DockerPublishedPortBinding: Hashable, Sendable {
    public enum ProtocolKind: String, Hashable, Sendable {
        case tcp
        case udp
    }

    public var hostIP: String
    public var hostPort: Int
    public var guestPort: Int
    public var kind: ProtocolKind

    public init(hostIP: String, hostPort: Int, guestPort: Int, kind: ProtocolKind) {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.guestPort = guestPort
        self.kind = kind
    }

    public var normalizedHostIP: String {
        switch hostIP {
        case "", "0.0.0.0": return "0.0.0.0"
        case "::": return "::"
        default: return hostIP
        }
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.normalizedHostIP == rhs.normalizedHostIP
            && lhs.hostPort == rhs.hostPort
            && lhs.guestPort == rhs.guestPort
            && lhs.kind == rhs.kind
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(normalizedHostIP)
        hasher.combine(hostPort)
        hasher.combine(guestPort)
        hasher.combine(kind)
    }
}

/// Foundation-only decoding and validation for publications exposed by the
/// container and Swarm service Docker API schemas.
public struct DockerPublishedPortPolicy {
    /// Published-port reconciliation is ancillary to the Docker API operation.
    /// Once Docker has accepted a request, reconciliation failure must not hide
    /// that response from the client; the periodic reconciler can retry later.
    public static func forwardResponseAfterReconciliation<Failure: Error>(
        _ result: Result<Void, Failure>,
        onFailure: (Failure) -> Void,
        forwardResponse: () -> Void
    ) {
        if case .failure(let error) = result {
            onFailure(error)
        }
        forwardResponse()
    }

    public static func validateContainerConfiguration(_ root: Any) throws {
        guard let dictionary = root as? [String: Any],
              let hostConfig = dictionary["HostConfig"] as? [String: Any],
              let portBindings = hostConfig["PortBindings"] as? [String: Any] else {
            return
        }
        var hostAddressesByPublishedPort: [String: Set<String>] = [:]
        for (containerPort, rawBindings) in portBindings {
            guard let protocolName = containerPort.split(separator: "/").last,
                  let kind = DockerPublishedPortBinding.ProtocolKind(rawValue: String(protocolName).lowercased()) else {
                continue
            }
            guard let bindings = rawBindings as? [[String: Any]] else { continue }
            for binding in bindings {
                let hostIP = (binding["HostIp"] as? String) ?? ""
                let hostPort = (binding["HostPort"] as? String) ?? ""
                try validateHostAddress(hostIP, hostPort: hostPort, kind: kind)
                guard !hostPort.isEmpty else { continue }
                let key = "\(hostPort)/\(kind.rawValue)"
                hostAddressesByPublishedPort[key, default: []].insert(
                    hostIP.isEmpty ? "0.0.0.0" : hostIP
                )
            }
        }
        try rejectAmbiguousHostAddresses(hostAddressesByPublishedPort)
    }

    public static func validateServiceConfiguration(_ root: Any) throws {
        guard let dictionary = root as? [String: Any],
              let endpointSpec = dictionary["EndpointSpec"] as? [String: Any],
              let ports = endpointSpec["Ports"] as? [[String: Any]] else {
            return
        }
        var publications: Set<String> = []
        for port in ports {
            let rawProtocol = (port["Protocol"] as? String)?.lowercased() ?? "tcp"
            guard let kind = DockerPublishedPortBinding.ProtocolKind(rawValue: rawProtocol) else {
                throw DockerPublishedPortPolicyError(
                    "Swarm service publication protocol \(rawProtocol) is not supported by the macOS port relay."
                )
            }
            let publishMode = (port["PublishMode"] as? String)?.lowercased() ?? "ingress"
            guard ["ingress", "host"].contains(publishMode) else {
                throw DockerPublishedPortPolicyError(
                    "Swarm service publication mode \(publishMode) is not supported by the macOS port relay."
                )
            }
            if let targetPort = port["TargetPort"] as? Int,
               !(1...65535).contains(targetPort) {
                throw DockerPublishedPortPolicyError(
                    "Swarm service target port \(targetPort)/\(kind.rawValue) is outside the supported range."
                )
            }
            guard let publishedPort = port["PublishedPort"] as? Int else { continue }
            guard publishedPort == 0 || (1...65535).contains(publishedPort) else {
                throw DockerPublishedPortPolicyError(
                    "Swarm service published port \(publishedPort)/\(kind.rawValue) is outside the supported range."
                )
            }
            guard publishedPort != 0 else { continue }
            let publication = "\(publishedPort)/\(kind.rawValue)"
            guard publications.insert(publication).inserted else {
                throw DockerPublishedPortPolicyError(
                    "Swarm service published port \(publication) is specified more than once."
                )
            }
        }
    }

    public static func containerBindings(from data: Data) throws -> [DockerPublishedPortBinding] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let containers = object as? [[String: Any]] else { return [] }
        return containers.flatMap { container -> [DockerPublishedPortBinding] in
            guard let ports = container["Ports"] as? [[String: Any]] else { return [] }
            return ports.compactMap { binding(fromContainerPort: $0) }
        }
    }

    public static func serviceBindings(from data: Data) throws -> [DockerPublishedPortBinding] {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let services = object as? [[String: Any]] else { return [] }
        return services.flatMap { service -> [DockerPublishedPortBinding] in
            let endpoint = service["Endpoint"] as? [String: Any]
            let endpointSpec = endpoint?["Spec"] as? [String: Any]
            let serviceSpec = service["Spec"] as? [String: Any]
            let declaredSpec = serviceSpec?["EndpointSpec"] as? [String: Any]
            let ports = (endpoint?["Ports"] as? [[String: Any]])
                ?? (endpointSpec?["Ports"] as? [[String: Any]])
                ?? (declaredSpec?["Ports"] as? [[String: Any]])
                ?? []
            return ports.compactMap { binding(fromServicePort: $0) }
        }
    }

    public static func validateRuntimeBindings(_ bindings: [DockerPublishedPortBinding]) throws {
        var addressesByPort: [String: Set<String>] = [:]
        var guestPortsByEndpoint: [String: Set<Int>] = [:]
        for binding in bindings {
            let port = "\(binding.hostPort)/\(binding.kind.rawValue)"
            addressesByPort[port, default: []].insert(binding.normalizedHostIP)
            let endpoint = "\(binding.normalizedHostIP):\(port)"
            guestPortsByEndpoint[endpoint, default: []].insert(binding.guestPort)
        }
        try rejectAmbiguousHostAddresses(addressesByPort)
        if let conflict = guestPortsByEndpoint
            .filter({ $0.value.count > 1 })
            .keys
            .sorted()
            .first {
            throw DockerPublishedPortPolicyError(
                "Docker published endpoint \(conflict) targets multiple guest ports."
            )
        }
    }

    public static func swarmManagerIsActive(in data: Data) throws -> Bool {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let info = object as? [String: Any],
              let swarm = info["Swarm"] as? [String: Any],
              (swarm["LocalNodeState"] as? String)?.lowercased() == "active" else {
            return false
        }
        return (swarm["ControlAvailable"] as? Bool) == true
    }

    private static func binding(fromContainerPort port: [String: Any]) -> DockerPublishedPortBinding? {
        guard let privatePort = port["PrivatePort"] as? Int,
              let publicPort = port["PublicPort"] as? Int,
              (1...65535).contains(publicPort),
              let rawKind = port["Type"] as? String,
              let kind = DockerPublishedPortBinding.ProtocolKind(rawValue: rawKind.lowercased()) else {
            return nil
        }
        return DockerPublishedPortBinding(
            hostIP: (port["IP"] as? String) ?? "0.0.0.0",
            hostPort: publicPort,
            guestPort: privatePort,
            kind: kind
        )
    }

    private static func binding(fromServicePort port: [String: Any]) -> DockerPublishedPortBinding? {
        guard let publishedPort = port["PublishedPort"] as? Int,
              (1...65535).contains(publishedPort),
              let targetPort = port["TargetPort"] as? Int,
              (1...65535).contains(targetPort),
              let kind = DockerPublishedPortBinding.ProtocolKind(
                rawValue: ((port["Protocol"] as? String) ?? "tcp").lowercased()
              ) else {
            return nil
        }
        return DockerPublishedPortBinding(
            hostIP: "0.0.0.0",
            hostPort: publishedPort,
            guestPort: targetPort,
            kind: kind
        )
    }

    private static func validateHostAddress(
        _ hostIP: String,
        hostPort: String,
        kind: DockerPublishedPortBinding.ProtocolKind
    ) throws {
        guard !hostIP.contains(":") else {
            throw DockerPublishedPortPolicyError(
                "IPv6 Docker publication \(hostIP):\(hostPort)/\(kind.rawValue) is not supported by the macOS port relay."
            )
        }
        guard ["", "0.0.0.0", "127.0.0.1"].contains(hostIP) else {
            throw DockerPublishedPortPolicyError(
                "Docker publication on host address \(hostIP) is not supported; use 127.0.0.1 or 0.0.0.0."
            )
        }
    }

    private static func rejectAmbiguousHostAddresses(
        _ hostAddressesByPublishedPort: [String: Set<String>]
    ) throws {
        if let ambiguous = hostAddressesByPublishedPort
            .filter({ $0.value.count > 1 })
            .keys
            .sorted()
            .first {
            throw DockerPublishedPortPolicyError(
                "Docker published port \(ambiguous) cannot use multiple host addresses."
            )
        }
    }
}

private struct DockerPublishedPortPolicyError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
