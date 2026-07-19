import CryptoKit
import Darwin
import Foundation

protocol DockerImageDownloading: Sendable {
    func data(from url: URL) async throws -> Data
    func download(from url: URL) async throws -> URL
}

struct URLSessionDockerImageDownloader: DockerImageDownloading {
    func data(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.validate(response: response, for: url)
        return data
    }

    func download(from url: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: url)
        try Self.validate(response: response, for: url)
        return temporaryURL
    }

    private static func validate(response: URLResponse, for url: URL) throws {
        if let response = response as? HTTPURLResponse, !(200...299).contains(response.statusCode) {
            throw MacVMError.message("Download from \(url.absoluteString) failed with HTTP \(response.statusCode).")
        }
    }
}

struct FedoraCoreOSImageProvider: Sendable {
    static let stableStreamURL = URL(string: "https://builds.coreos.fedoraproject.org/streams/stable.json")!
    private static let cacheMetadataSchemaVersion = 1

    private let cacheDirectory: URL
    private let streamURL: URL
    private let downloader: any DockerImageDownloading

    init(
        cacheDirectory: URL,
        streamURL: URL = stableStreamURL,
        downloader: any DockerImageDownloading = URLSessionDockerImageDownloader()
    ) {
        self.cacheDirectory = cacheDirectory
        self.streamURL = streamURL
        self.downloader = downloader
    }

    func resolveCurrentImage() async throws -> FedoraCoreOSImage {
        try Self.parseStableAppleHVImage(from: await downloader.data(from: streamURL))
    }

    func refresh(
        progress: VMOperationHandler? = nil
    ) async throws -> FedoraCoreOSCachedImage {
        let image = try await resolveCurrentImage()
        let rawImageURL = try await prepareBaseImage(image: image, progress: progress)
        let cached = FedoraCoreOSCachedImage(
            image: image,
            rawImageURL: rawImageURL,
            refreshedAt: Date()
        )
        try writeCacheMetadata(for: cached)
        return cached
    }

    func preferredImage(
        automaticRefresh: Bool,
        progress: VMOperationHandler? = nil
    ) async throws -> FedoraCoreOSCachedImage {
        if automaticRefresh {
            do {
                return try await refresh(progress: progress)
            } catch {
                if error is CancellationError {
                    throw error
                }
                do {
                    if let cached = try cachedImage() {
                        progress?(.status(
                            "Fedora CoreOS refresh unavailable; using verified cached release \(cached.image.release)."
                        ))
                        return cached
                    }
                } catch let cacheError {
                    throw MacVMError.message(
                        "Fedora CoreOS refresh failed (\(error.localizedDescription)), and the cached image is unusable: \(cacheError.localizedDescription)"
                    )
                }
                throw error
            }
        }

        guard let cached = try cachedImage() else {
            throw MacVMError.message(
                "Automatic Fedora CoreOS image refresh is disabled and no verified image is cached. Connect this host and run `macvm docker image refresh`."
            )
        }
        progress?(.status("Using verified cached Fedora CoreOS \(cached.image.release) image; automatic refresh is disabled."))
        return cached
    }

    func cachedImage() throws -> FedoraCoreOSCachedImage? {
        let metadataURL = cacheDirectory.appendingPathComponent("current.json")
        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(
            CacheMetadata.self,
            from: Data(contentsOf: metadataURL)
        )
        guard metadata.schemaVersion == Self.cacheMetadataSchemaVersion else {
            throw MacVMError.message(
                "Fedora CoreOS cache metadata version \(metadata.schemaVersion) is unsupported. Run `macvm docker image refresh`."
            )
        }
        let rawImageURL = imageURLs(for: metadata.image).raw
        guard FileManager.default.fileExists(atPath: rawImageURL.path) else {
            throw MacVMError.message(
                "The cached Fedora CoreOS \(metadata.image.release) image is missing. Run `macvm docker image refresh`."
            )
        }
        let actualChecksum = try Self.sha256Hex(of: rawImageURL)
        guard actualChecksum == metadata.image.uncompressedSHA256 else {
            throw MacVMError.message(
                "The cached Fedora CoreOS \(metadata.image.release) image failed checksum verification. Run `macvm docker image refresh`."
            )
        }
        return FedoraCoreOSCachedImage(
            image: metadata.image,
            rawImageURL: rawImageURL,
            refreshedAt: metadata.refreshedAt
        )
    }

    static func parseStableAppleHVImage(from data: Data) throws -> FedoraCoreOSImage {
        let stream = try JSONDecoder().decode(Stream.self, from: data)
        guard let architecture = stream.architectures["aarch64"],
              let artifact = architecture.artifacts["applehv"],
              let disk = artifact.formats["raw.gz"]?.disk,
              let location = URL(string: disk.location),
              !disk.sha256.isEmpty,
              let uncompressedSHA256 = disk.uncompressedSHA256,
              !uncompressedSHA256.isEmpty else {
            throw MacVMError.message(
                "Fedora CoreOS stream metadata does not contain architectures.aarch64.artifacts.applehv.formats.raw.gz.disk with both checksums."
            )
        }
        return FedoraCoreOSImage(
            stream: stream.stream,
            architecture: "aarch64",
            platform: "applehv",
            format: "raw.gz",
            release: artifact.release,
            downloadURL: location,
            compressedSHA256: disk.sha256,
            uncompressedSHA256: uncompressedSHA256
        )
    }

    func prepareBaseImage(
        image: FedoraCoreOSImage,
        progress: VMOperationHandler? = nil
    ) async throws -> URL {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let urls = imageURLs(for: image)
        let compressedURL = urls.compressed
        let rawURL = urls.raw

        if FileManager.default.fileExists(atPath: rawURL.path),
           try Self.sha256Hex(of: rawURL) == image.uncompressedSHA256 {
            progress?(.status("Using verified cached Fedora CoreOS \(image.release) image."))
            return rawURL
        }
        try? FileManager.default.removeItem(at: rawURL)

        if FileManager.default.fileExists(atPath: compressedURL.path) {
            guard try Self.sha256Hex(of: compressedURL) == image.compressedSHA256 else {
                try FileManager.default.removeItem(at: compressedURL)
                return try await downloadAndMaterialize(
                    image: image,
                    compressedURL: compressedURL,
                    rawURL: rawURL,
                    progress: progress
                )
            }
        } else {
            return try await downloadAndMaterialize(
                image: image,
                compressedURL: compressedURL,
                rawURL: rawURL,
                progress: progress
            )
        }

        return try await decompressAndVerify(
            image: image,
            compressedURL: compressedURL,
            rawURL: rawURL,
            progress: progress
        )
    }

    private func downloadAndMaterialize(
        image: FedoraCoreOSImage,
        compressedURL: URL,
        rawURL: URL,
        progress: VMOperationHandler?
    ) async throws -> URL {
        progress?(.status("Downloading Fedora CoreOS \(image.release) for AppleHV (aarch64)..."))
        let downloadedURL = try await downloader.download(from: image.downloadURL)
        try Task.checkCancellation()
        let temporaryCompressedURL = cacheDirectory.appendingPathComponent(
            ".\(compressedURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporaryCompressedURL) }
        try FileManager.default.moveItem(at: downloadedURL, to: temporaryCompressedURL)
        try Self.synchronizeFile(at: temporaryCompressedURL)

        let actualChecksum = try Self.sha256Hex(of: temporaryCompressedURL)
        guard actualChecksum == image.compressedSHA256 else {
            throw MacVMError.message(
                "Fedora CoreOS compressed image checksum mismatch: expected \(image.compressedSHA256), received \(actualChecksum)."
            )
        }
        try? FileManager.default.removeItem(at: compressedURL)
        try FileManager.default.moveItem(at: temporaryCompressedURL, to: compressedURL)
        return try await decompressAndVerify(
            image: image,
            compressedURL: compressedURL,
            rawURL: rawURL,
            progress: progress
        )
    }

    private func decompressAndVerify(
        image: FedoraCoreOSImage,
        compressedURL: URL,
        rawURL: URL,
        progress: VMOperationHandler?
    ) async throws -> URL {
        progress?(.status("Decompressing and verifying Fedora CoreOS \(image.release)..."))
        let temporaryRawURL = cacheDirectory.appendingPathComponent(
            ".\(rawURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporaryRawURL) }
        FileManager.default.createFile(atPath: temporaryRawURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: temporaryRawURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-dc", compressedURL.path]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        while process.isRunning {
            if Task.isCancelled {
                process.terminate()
                process.waitUntilExit()
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard process.terminationStatus == 0 else {
            let errorData = (process.standardError as? Pipe)?.fileHandleForReading.readDataToEndOfFile() ?? Data()
            let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MacVMError.message("Couldn't decompress Fedora CoreOS: \(message?.isEmpty == false ? message! : "gzip exited with status \(process.terminationStatus)").")
        }
        try output.synchronize()
        let actualChecksum = try Self.sha256Hex(of: temporaryRawURL)
        guard actualChecksum == image.uncompressedSHA256 else {
            throw MacVMError.message(
                "Fedora CoreOS uncompressed image checksum mismatch: expected \(image.uncompressedSHA256), received \(actualChecksum)."
            )
        }
        try? FileManager.default.removeItem(at: rawURL)
        try FileManager.default.moveItem(at: temporaryRawURL, to: rawURL)
        return rawURL
    }

    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            guard !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func synchronizeFile(at url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw MacVMError.message("Couldn't open \(url.path) for synchronization: \(String(cString: strerror(errno)))")
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw MacVMError.message("Couldn't synchronize \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    private func imageURLs(for image: FedoraCoreOSImage) -> (compressed: URL, raw: URL) {
        let safeRelease = image.release.replacingOccurrences(of: "/", with: "-")
        return (
            cacheDirectory.appendingPathComponent("fedora-coreos-\(safeRelease)-applehv.aarch64.raw.gz"),
            cacheDirectory.appendingPathComponent("fedora-coreos-\(safeRelease)-applehv.aarch64.raw")
        )
    }

    private func writeCacheMetadata(for cached: FedoraCoreOSCachedImage) throws {
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let metadata = CacheMetadata(
            schemaVersion: Self.cacheMetadataSchemaVersion,
            refreshedAt: cached.refreshedAt,
            image: cached.image
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(metadata).write(
            to: cacheDirectory.appendingPathComponent("current.json"),
            options: .atomic
        )
    }

    private struct CacheMetadata: Codable {
        let schemaVersion: Int
        let refreshedAt: Date
        let image: FedoraCoreOSImage
    }

    private struct Stream: Decodable {
        let stream: String
        let architectures: [String: Architecture]
    }

    private struct Architecture: Decodable {
        let artifacts: [String: Artifact]
    }

    private struct Artifact: Decodable {
        let release: String
        let formats: [String: Format]
    }

    private struct Format: Decodable {
        let disk: Disk?
    }

    private struct Disk: Decodable {
        let location: String
        let sha256: String
        let uncompressedSHA256: String?

        enum CodingKeys: String, CodingKey {
            case location
            case sha256
            case uncompressedSHA256 = "uncompressed-sha256"
        }
    }
}
