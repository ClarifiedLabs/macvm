import AppKit
import ArgumentParser
import Foundation
import MacVMHostKit

struct AppControlClient {
    private static let appBundleIdentifier = MacVMSettings.domain
    private static let appName = "MacVM.app"

    let queue: MacVMAppControlQueue
    let pickupTimeout: TimeInterval
    let completionTimeout: TimeInterval

    init(
        queue: MacVMAppControlQueue = MacVMAppControlQueue(),
        pickupTimeout: TimeInterval = MacVMAppControlRequest.validityInterval + 45,
        completionTimeout: TimeInterval = MacVMAppControlRequest.operationCompletionTimeout + 30
    ) {
        self.queue = queue
        self.pickupTimeout = pickupTimeout
        self.completionTimeout = completionTimeout
    }

    func send(operation: MacVMAppControlOperation, for vm: ManagedVM) async throws -> MacVMAppControlResponse {
        let request = MacVMAppControlRequest(operation: operation, bundleURL: vm.bundleURL)
        try queue.submit(request)

        do {
            try await launchAppIfNeeded()
            let response = try await waitForResponse(to: request)
            try? queue.removeResponse(for: request.id)
            guard response.protocolVersion == MacVMAppControlRequest.currentProtocolVersion else {
                throw ValidationError("MacVM.app uses an incompatible control protocol. Update the app and CLI together.")
            }
            guard response.succeeded else {
                throw ValidationError(response.message)
            }
            return response
        } catch {
            // A request may be removed only before the app claims it. Once claimed,
            // MacVM owns completion/cancellation and will always publish a response.
            if !queue.isClaimed(request.id) {
                try? queue.removeRequest(request.id)
            }
            throw error
        }
    }

    private func waitForResponse(to request: MacVMAppControlRequest) async throws -> MacVMAppControlResponse {
        let pickupDeadline = Date().addingTimeInterval(pickupTimeout)
        while Date() < pickupDeadline {
            if let response = try queue.response(for: request.id) { return response }
            if queue.isClaimed(request.id) { return try await waitForClaimedResponse(to: request) }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError(
            "Timed out waiting for MacVM.app to pick up the request. Open MacVM and try again."
        )
    }

    private func waitForClaimedResponse(to request: MacVMAppControlRequest) async throws -> MacVMAppControlResponse {
        let completionDeadline = Date().addingTimeInterval(completionTimeout)
        while Date() < completionDeadline {
            if let response = try queue.response(for: request.id) { return response }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ValidationError(
            "MacVM.app acknowledged the request but did not complete it within the operation deadline."
        )
    }

    private func launchAppIfNeeded() async throws {
        let appURL = try await MainActor.run { () -> URL? in
            if !NSRunningApplication.runningApplications(
                withBundleIdentifier: Self.appBundleIdentifier
            ).isEmpty {
                return nil
            }
            return try locateApp()
        }
        guard let appURL else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = [MacVMAppControlQueue.controlOnlyArgument]

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    @MainActor
    private func locateApp() throws -> URL {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["MACVM_APP_PATH"], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true))
        }

        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let executableDirectory = executableURL.deletingLastPathComponent()
        candidates.append(executableDirectory.appendingPathComponent(Self.appName, isDirectory: true))

        if executableDirectory.lastPathComponent == "Helpers",
           executableDirectory.deletingLastPathComponent().lastPathComponent == "Contents" {
            candidates.append(executableDirectory.deletingLastPathComponent().deletingLastPathComponent())
        }

        candidates.append(URL(fileURLWithPath: "/Applications", isDirectory: true).appendingPathComponent(Self.appName, isDirectory: true))
        if let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.appBundleIdentifier) {
            candidates.append(registered)
        }

        var seen = Set<String>()
        for candidate in candidates {
            let normalized = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard seen.insert(normalized.path).inserted,
                  FileManager.default.fileExists(atPath: normalized.path),
                  Bundle(url: normalized)?.bundleIdentifier == Self.appBundleIdentifier else {
                continue
            }
            return normalized
        }

        throw ValidationError(
            "MacVM.app was not found. Install it in /Applications or set MACVM_APP_PATH to a development build."
        )
    }
}
