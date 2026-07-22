import Foundation

public struct DockerAPIPathRewriter {
    public typealias PathTransform = (String) throws -> String

    /// kind needs the Docker host's kernel modules while bootstrapping its
    /// privileged node container. This source belongs to the Linux sidecar,
    /// not to the macOS guest that supplies ordinary bind mounts.
    private static let sidecarNativeBindSources: Set<String> = ["/lib/modules"]

    public static func rewritesRequest(method: String, uri: String) -> Bool {
        let path = normalizedAPIPath(uri)
        if method == "POST", path == "/containers/create" { return true }
        if method == "POST", path == "/services/create" { return true }
        if method == "POST", path.hasPrefix("/services/"), path.hasSuffix("/update") { return true }
        if method == "POST", path == "/volumes/create" { return true }
        return false
    }

    public static func rewritesResponse(method: String, uri: String, status: Int) -> Bool {
        guard method == "GET", (200...299).contains(status) else { return false }
        let path = normalizedAPIPath(uri)
        if path.hasPrefix("/containers/"), path.hasSuffix("/json") { return true }
        if path.hasPrefix("/services/") { return true }
        if path.hasPrefix("/volumes/") { return true }
        return false
    }

    public static func rewriteRequestBody(
        _ data: Data,
        method: String,
        uri: String,
        transform: PathTransform
    ) throws -> Data {
        guard rewritesRequest(method: method, uri: uri) else { return data }
        var root = try jsonObject(data)
        let path = normalizedAPIPath(uri)
        if path == "/containers/create" {
            try rewriteContainerConfiguration(&root, transform: transform)
        } else if path == "/services/create" || (path.hasPrefix("/services/") && path.hasSuffix("/update")) {
            try rewriteServiceConfiguration(&root, transform: transform)
        } else if path == "/volumes/create" {
            try rewriteVolumeConfiguration(&root, transform: transform)
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    public static func rewriteResponseBody(
        _ data: Data,
        method: String,
        uri: String,
        status: Int,
        transform: PathTransform
    ) throws -> Data {
        guard rewritesResponse(method: method, uri: uri, status: status) else { return data }
        var root = try jsonObject(data)
        let path = normalizedAPIPath(uri)
        if path.hasPrefix("/containers/") {
            try rewriteMountArray(in: &root, keyPath: ["Mounts"], transform: transform)
        } else if path.hasPrefix("/services/") {
            try rewriteMountArray(
                in: &root,
                keyPath: ["Spec", "TaskTemplate", "ContainerSpec", "Mounts"],
                transform: transform
            )
        } else if path.hasPrefix("/volumes/") {
            try rewriteVolumeResponse(&root, transform: transform)
        }
        return try JSONSerialization.data(withJSONObject: root)
    }

    public static func normalizedAPIPath(_ uri: String) -> String {
        let path = uri.split(separator: "?", maxSplits: 1).first.map(String.init) ?? uri
        guard path.hasPrefix("/v") else { return path }
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count > 2,
              pieces[1].first == "v",
              pieces[1].dropFirst().split(separator: ".").allSatisfy({ Int($0) != nil }) else {
            return path
        }
        return "/" + pieces.dropFirst(2).joined(separator: "/")
    }

    private static func rewriteContainerConfiguration(
        _ root: inout Any,
        transform: PathTransform
    ) throws {
        try validatePublishedPorts(in: root)
        try rewriteBindStrings(in: &root, keyPath: ["HostConfig", "Binds"], transform: transform)
        try rewriteMountArray(in: &root, keyPath: ["HostConfig", "Mounts"], transform: transform)
    }

    private static func validatePublishedPorts(in root: Any) throws {
        guard let dictionary = root as? [String: Any],
              let hostConfig = dictionary["HostConfig"] as? [String: Any],
              let portBindings = hostConfig["PortBindings"] as? [String: Any] else {
            return
        }
        var hostAddressesByPublishedPort: [String: Set<String>] = [:]
        for (containerPort, rawBindings) in portBindings {
            guard let protocolKind = containerPort.split(separator: "/").last,
                  let bindings = rawBindings as? [[String: Any]] else { continue }
            for binding in bindings {
                let hostIP = (binding["HostIp"] as? String) ?? ""
                let hostPort = (binding["HostPort"] as? String) ?? ""
                guard !hostIP.contains(":") else {
                    throw DockerAPIPathRewriterError(
                        "IPv6 Docker publication \(hostIP):\(hostPort)/\(protocolKind) is not supported by the macOS port relay."
                    )
                }
                guard ["", "0.0.0.0", "127.0.0.1"].contains(hostIP) else {
                    throw DockerAPIPathRewriterError(
                        "Docker publication on host address \(hostIP) is not supported; use 127.0.0.1 or 0.0.0.0."
                    )
                }
                guard !hostPort.isEmpty else { continue }
                let key = "\(hostPort)/\(protocolKind)"
                let normalizedHostIP = hostIP.isEmpty ? "0.0.0.0" : hostIP
                hostAddressesByPublishedPort[key, default: []].insert(normalizedHostIP)
            }
        }
        if let ambiguous = hostAddressesByPublishedPort
            .filter({ $0.value.count > 1 })
            .keys
            .sorted()
            .first {
            throw DockerAPIPathRewriterError(
                "Docker published port \(ambiguous) cannot use multiple host addresses."
            )
        }
    }

    private static func rewriteServiceConfiguration(
        _ root: inout Any,
        transform: PathTransform
    ) throws {
        try rewriteMountArray(
            in: &root,
            keyPath: ["TaskTemplate", "ContainerSpec", "Mounts"],
            transform: transform
        )
    }

    private static func rewriteVolumeConfiguration(
        _ root: inout Any,
        transform: PathTransform
    ) throws {
        guard var dictionary = root as? [String: Any],
              var options = dictionary["DriverOpts"] as? [String: Any],
              (options["type"] as? String) == "none",
              let mountOptions = options["o"] as? String,
              mountOptions.split(separator: ",").contains(where: { $0 == "bind" || $0 == "rbind" }),
              let source = options["device"] as? String,
              shouldTransformBindSource(source) else { return }
        options["device"] = try transform(source)
        dictionary["DriverOpts"] = options
        root = dictionary
    }

    private static func rewriteVolumeResponse(
        _ root: inout Any,
        transform: PathTransform
    ) throws {
        guard var dictionary = root as? [String: Any],
              var options = dictionary["Options"] as? [String: Any],
              let source = options["device"] as? String else { return }
        options["device"] = try transform(source)
        dictionary["Options"] = options
        root = dictionary
    }

    private static func rewriteBindStrings(
        in root: inout Any,
        keyPath: [String],
        transform: PathTransform
    ) throws {
        try mutateValue(in: &root, keyPath: keyPath) { value in
            guard let binds = value as? [String] else { return value }
            return try binds.map { bind in
                guard let delimiter = bind.range(of: ":/") else { return bind }
                let source = String(bind[..<delimiter.lowerBound])
                guard shouldTransformBindSource(source) else { return bind }
                let suffix = bind[delimiter.lowerBound...]
                return try transform(source) + suffix
            }
        }
    }

    private static func rewriteMountArray(
        in root: inout Any,
        keyPath: [String],
        transform: PathTransform
    ) throws {
        try mutateValue(in: &root, keyPath: keyPath) { value in
            guard let mounts = value as? [[String: Any]] else { return value }
            return try mounts.map { mount in
                var mount = mount
                let type = (mount["Type"] as? String)?.lowercased() ?? "bind"
                if type == "bind",
                   let source = mount["Source"] as? String,
                   shouldTransformBindSource(source) {
                    mount["Source"] = try transform(source)
                }
                if type == "volume",
                   var volumeOptions = mount["VolumeOptions"] as? [String: Any],
                   var driverConfig = volumeOptions["DriverConfig"] as? [String: Any],
                   var options = driverConfig["Options"] as? [String: Any],
                   Self.isLocalBindOptions(options),
                   let source = options["device"] as? String,
                   shouldTransformBindSource(source) {
                    options["device"] = try transform(source)
                    driverConfig["Options"] = options
                    volumeOptions["DriverConfig"] = driverConfig
                    mount["VolumeOptions"] = volumeOptions
                }
                return mount
            }
        }
    }

    private static func isLocalBindOptions(_ options: [String: Any]) -> Bool {
        guard (options["type"] as? String) == "none",
              let mountOptions = options["o"] as? String else { return false }
        return mountOptions.split(separator: ",").contains { $0 == "bind" || $0 == "rbind" }
    }

    private static func shouldTransformBindSource(_ source: String) -> Bool {
        source.hasPrefix("/") && !sidecarNativeBindSources.contains(source)
    }

    private static func mutateValue(
        in root: inout Any,
        keyPath: [String],
        body: (Any) throws -> Any
    ) throws {
        guard let key = keyPath.first, var dictionary = root as? [String: Any] else { return }
        if keyPath.count == 1 {
            guard let value = dictionary[key] else { return }
            dictionary[key] = try body(value)
        } else if var child = dictionary[key] {
            try mutateValue(in: &child, keyPath: Array(keyPath.dropFirst()), body: body)
            dictionary[key] = child
        }
        root = dictionary
    }

    private static func jsonObject(_ data: Data) throws -> Any {
        guard !data.isEmpty else { return [String: Any]() }
        return try JSONSerialization.jsonObject(with: data)
    }
}

private struct DockerAPIPathRewriterError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
