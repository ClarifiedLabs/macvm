import Foundation

/// Manages the per-VM SSH keypair stored in the bundle. Each VM gets its own
/// ed25519 key so access is isolated and reproducible, and the host's own key is
/// never exposed to the guest.
enum SSHKeyManager {
    /// Ensure the bundle has an ed25519 keypair, generating one if absent. Returns
    /// the public key text (a single `ssh-ed25519 …` line).
    static func ensureKeyPair(in bundle: VMBundle) throws -> String {
        try FileManager.default.createDirectory(at: bundle.setupDirectoryURL, withIntermediateDirectories: true)

        let privateKeyURL = bundle.setupPrivateKeyURL
        if !FileManager.default.fileExists(atPath: privateKeyURL.path) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
            process.arguments = [
                "-t", "ed25519",
                "-N", "",
                "-C", "macvm-\(bundle.url.deletingPathExtension().lastPathComponent)",
                "-f", privateKeyURL.path,
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw MacVMError.message("ssh-keygen failed to create a key for \(bundle.url.lastPathComponent).")
            }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateKeyURL.path)
        }

        return try String(contentsOf: bundle.setupPublicKeyURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
