import CryptoKit
import Foundation
import Security

public enum ClipboardDirection: UInt8, Sendable {
    case guestToHost = 1
    case hostToGuest = 2
}

public struct ClipboardHandshakeTranscript: Equatable, Sendable {
    public var vmID: UUID
    public var guestVersions: ClipboardVersionRange
    public var hostVersions: ClipboardVersionRange
    public var helperBuildVersion: UInt32
    public var hostBuildVersion: UInt32
    public var selectedVersion: UInt16
    public var guestNonce: Data
    public var hostNonce: Data

    public init(
        vmID: UUID,
        guestVersions: ClipboardVersionRange,
        hostVersions: ClipboardVersionRange,
        helperBuildVersion: UInt32,
        hostBuildVersion: UInt32,
        selectedVersion: UInt16,
        guestNonce: Data,
        hostNonce: Data
    ) throws {
        guard guestNonce.count == ClipboardProtocolConstants.nonceBytes,
              hostNonce.count == ClipboardProtocolConstants.nonceBytes else {
            throw ClipboardProtocolError.invalidPayload("handshake nonces must be 32 bytes")
        }
        self.vmID = vmID
        self.guestVersions = guestVersions
        self.hostVersions = hostVersions
        self.helperBuildVersion = helperBuildVersion
        self.hostBuildVersion = hostBuildVersion
        self.selectedVersion = selectedVersion
        self.guestNonce = guestNonce
        self.hostNonce = hostNonce
    }

    public func encoded(role: String) -> Data {
        var data = Data("MacVM Clipboard Protocol v1\0".utf8)
        data.appendUUID(vmID)
        data.appendInteger(guestVersions.minimum)
        data.appendInteger(guestVersions.maximum)
        data.appendInteger(hostVersions.minimum)
        data.appendInteger(hostVersions.maximum)
        data.appendInteger(helperBuildVersion)
        data.appendInteger(hostBuildVersion)
        data.appendInteger(selectedVersion)
        data.append(guestNonce)
        data.append(hostNonce)
        data.append(0)
        data.append(contentsOf: role.utf8)
        return data
    }
}

public enum ClipboardAuthentication {
    public static func randomBytes(count: Int) throws -> Data {
        guard count >= 0 else {
            throw ClipboardProtocolError.invalidPayload("random byte count must not be negative")
        }
        guard count > 0 else { return Data() }
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw ClipboardProtocolError.invalidPayload("secure random generation failed")
        }
        return data
    }

    public static func hostProof(secret: Data, transcript: ClipboardHandshakeTranscript) throws -> Data {
        try validateSecret(secret)
        return authenticationCode(secret: secret, data: transcript.encoded(role: "host"))
    }

    public static func guestProof(secret: Data, transcript: ClipboardHandshakeTranscript) throws -> Data {
        try validateSecret(secret)
        return authenticationCode(secret: secret, data: transcript.encoded(role: "guest"))
    }

    public static func sessionKey(secret: Data, transcript: ClipboardHandshakeTranscript) throws -> Data {
        try validateSecret(secret)
        return authenticationCode(secret: secret, data: transcript.encoded(role: "session"))
    }

    public static func verifyHostProof(_ proof: Data, secret: Data, transcript: ClipboardHandshakeTranscript) throws -> Bool {
        try validateSecret(secret)
        return verify(proof, secret: secret, data: transcript.encoded(role: "host"))
    }

    public static func verifyGuestProof(_ proof: Data, secret: Data, transcript: ClipboardHandshakeTranscript) throws -> Bool {
        try validateSecret(secret)
        return verify(proof, secret: secret, data: transcript.encoded(role: "guest"))
    }

    public static func frameTag(key: Data, direction: ClipboardDirection, authenticatedBytes: Data) -> Data {
        var tagged = Data([direction.rawValue])
        tagged.append(authenticatedBytes)
        return authenticationCode(secret: key, data: tagged)
    }

    public static func verifyFrameTag(
        _ tag: Data,
        key: Data,
        direction: ClipboardDirection,
        authenticatedBytes: Data
    ) -> Bool {
        var tagged = Data([direction.rawValue])
        tagged.append(authenticatedBytes)
        return verify(tag, secret: key, data: tagged)
    }

    private static func validateSecret(_ secret: Data) throws {
        guard secret.count == ClipboardProtocolConstants.pairingSecretBytes else {
            throw ClipboardProtocolError.invalidPayload("the pairing secret must be 32 bytes")
        }
    }

    private static func authenticationCode(secret: Data, data: Data) -> Data {
        let code = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: secret))
        return Data(code)
    }

    private static func verify(_ code: Data, secret: Data, data: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(
            code,
            authenticating: data,
            using: SymmetricKey(data: secret)
        )
    }
}
