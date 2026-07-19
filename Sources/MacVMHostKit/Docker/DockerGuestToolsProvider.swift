import Foundation

struct DockerGuestTools: Sendable {
    var dockerCLITarball: URL
    var composePlugin: URL
}

struct DockerGuestToolsProvider: Sendable {
    static let dockerVersion = "28.3.2"
    static let dockerSHA256 = "eebb8180a9377b58d493994c69c03a21cfe8cd0c788c3d2124f2c66984cabd21"
    static let composeVersion = "2.38.2"
    static let composeSHA256 = "d3af9d008da340f355df89d16361a6c19a363c33e7b7ab145a81b76aa2ed9b86"

    let cacheDirectory: URL
    let downloader: any DockerImageDownloading

    init(
        cacheDirectory: URL,
        downloader: any DockerImageDownloading = URLSessionDockerImageDownloader()
    ) {
        self.cacheDirectory = cacheDirectory
        self.downloader = downloader
    }

    func prepare(progress: VMOperationHandler? = nil) async throws -> DockerGuestTools {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let dockerURL = cacheDirectory.appendingPathComponent("docker-\(Self.dockerVersion)-darwin-arm64.tgz")
        let composeURL = cacheDirectory.appendingPathComponent("docker-compose-v\(Self.composeVersion)-darwin-arm64")
        try await prepare(
            destination: dockerURL,
            source: URL(string: "https://download.docker.com/mac/static/stable/aarch64/docker-\(Self.dockerVersion).tgz")!,
            sha256: Self.dockerSHA256,
            label: "Docker CLI \(Self.dockerVersion)",
            progress: progress
        )
        try await prepare(
            destination: composeURL,
            source: URL(string: "https://github.com/docker/compose/releases/download/v\(Self.composeVersion)/docker-compose-darwin-aarch64")!,
            sha256: Self.composeSHA256,
            label: "Docker Compose \(Self.composeVersion)",
            progress: progress
        )
        return DockerGuestTools(dockerCLITarball: dockerURL, composePlugin: composeURL)
    }

    private func prepare(
        destination: URL,
        source: URL,
        sha256: String,
        label: String,
        progress: VMOperationHandler?
    ) async throws {
        if FileManager.default.fileExists(atPath: destination.path),
           try FedoraCoreOSImageProvider.sha256Hex(of: destination) == sha256 {
            return
        }
        try? FileManager.default.removeItem(at: destination)
        progress?(.status("Downloading verified \(label) for the macOS guest..."))
        let downloaded = try await downloader.download(from: source)
        try Task.checkCancellation()
        let actual = try FedoraCoreOSImageProvider.sha256Hex(of: downloaded)
        guard actual == sha256 else {
            throw MacVMError.message("\(label) checksum mismatch: expected \(sha256), received \(actual).")
        }
        try FileManager.default.moveItem(at: downloaded, to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
    }
}
