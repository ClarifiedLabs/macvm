import CommonCrypto
import Foundation

/// VNC "VNC Authentication" (security type 2) challenge-response.
///
/// The server sends a 16-byte challenge; the client DES-ECB-encrypts it with a key
/// derived from the password. The quirk: VNC uses the password bytes (max 8, zero
/// padded) as the DES key but with each byte's bits mirrored (LSB↔MSB).
enum RFBAuth {
    /// Reverse the bit order within a byte (0b0000_0001 → 0b1000_0000).
    static func mirrorBits(_ byte: UInt8) -> UInt8 {
        var input = byte
        var output: UInt8 = 0
        for _ in 0..<8 {
            output = (output << 1) | (input & 1)
            input >>= 1
        }
        return output
    }

    /// The 8-byte DES key: password bytes (truncated/zero-padded to 8), each mirrored.
    static func desKey(from password: String) -> [UInt8] {
        var key = [UInt8](repeating: 0, count: 8)
        let passwordBytes = Array(password.utf8.prefix(8))
        for index in passwordBytes.indices {
            key[index] = mirrorBits(passwordBytes[index])
        }
        return key
    }

    /// DES-ECB encrypt `data` (a multiple of 8 bytes) with an 8-byte `key`.
    static func desEncryptECB(data: [UInt8], key: [UInt8]) -> [UInt8] {
        var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeDES)
        var movedBytes = 0

        let status = key.withUnsafeBytes { keyPointer in
            data.withUnsafeBytes { dataPointer in
                output.withUnsafeMutableBytes { outputPointer in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmDES),
                        CCOptions(kCCOptionECBMode),
                        keyPointer.baseAddress, key.count,
                        nil,
                        dataPointer.baseAddress, data.count,
                        outputPointer.baseAddress, outputPointer.count,
                        &movedBytes
                    )
                }
            }
        }

        guard status == kCCSuccess else { return [] }
        return Array(output.prefix(movedBytes))
    }

    /// Compute the 16-byte response to a 16-byte `challenge` for `password`.
    static func response(challenge: [UInt8], password: String) -> [UInt8] {
        let key = desKey(from: password)
        let encrypted = desEncryptECB(data: challenge, key: key)
        return Array(encrypted.prefix(16))
    }
}
