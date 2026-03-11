import Foundation
import Virtualization

enum VirtualizationAsync {
    static func fetchLatestSupportedRestoreImage() async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.fetchLatestSupported { result in
                continuation.resume(with: result)
            }
        }
    }

    static func loadRestoreImage(from fileURL: URL) async throws -> VZMacOSRestoreImage {
        try await withCheckedThrowingContinuation { continuation in
            VZMacOSRestoreImage.load(from: fileURL) { result in
                continuation.resume(with: result)
            }
        }
    }

    @MainActor
    static func install(_ installer: VZMacOSInstaller) async throws {
        try await withCheckedThrowingContinuation { continuation in
            installer.install { result in
                continuation.resume(with: result)
            }
        }
    }

    @MainActor
    static func start(_ virtualMachine: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { continuation in
            virtualMachine.start { result in
                continuation.resume(with: result)
            }
        }
    }

    @MainActor
    static func start(_ virtualMachine: VZVirtualMachine, options: VZVirtualMachineStartOptions) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            virtualMachine.start(options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    static func stop(_ virtualMachine: VZVirtualMachine) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            virtualMachine.stop { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
