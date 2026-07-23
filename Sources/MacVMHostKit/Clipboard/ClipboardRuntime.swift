import AppKit
import Foundation
import MacVMClipboardProtocol
import Virtualization

public struct ClipboardRuntimeStatus: Equatable, Sendable {
    public var enabled: Bool
    public var viewerActive: Bool
    public var helper: ClipboardHelperConnectionState

    public init(enabled: Bool, viewerActive: Bool, helper: ClipboardHelperConnectionState) {
        self.enabled = enabled
        self.viewerActive = viewerActive
        self.helper = helper
    }

    public var displayName: String {
        guard enabled else { return "Disabled" }
        guard viewerActive else { return "Inactive window"
        }
        return helper.displayName
    }
}

enum ClipboardHelperUnavailableError: Error, LocalizedError {
    case unavailable(ClipboardHelperConnectionState)

    var errorDescription: String? {
        switch self {
        case .unavailable(let state):
            return "The authenticated clipboard helper is \(state.displayName.lowercased())."
        }
    }
}

private enum ClipboardRuntimeEvent: Sendable {
    case state(ClipboardHelperConnectionState)
    case guestChanged(Int, String)
    case peerChanged
    case guestOverflow
}

private final class ClipboardRuntimeEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ClipboardRuntimeEvent] = []
    private var drainScheduled = false
    private var guestOverflowPending = false
    private let handler: @MainActor @Sendable (ClipboardRuntimeEvent) -> Void

    init(handler: @escaping @MainActor @Sendable (ClipboardRuntimeEvent) -> Void) {
        self.handler = handler
    }

    func enqueue(_ event: ClipboardRuntimeEvent) {
        let shouldSchedule = lock.withLock { () -> Bool in
            switch event {
            case .guestChanged:
                guard !guestOverflowPending else { return false }
                let pendingGuestEvents = events.reduce(into: 0) { count, item in
                    if case .guestChanged = item { count += 1 }
                }
                if pendingGuestEvents >= 4 {
                    events.removeAll { item in
                        if case .guestChanged = item { return true }
                        return false
                    }
                    guestOverflowPending = true
                    events.append(.guestOverflow)
                } else {
                    events.append(event)
                }
            case .state:
                events.removeAll { item in
                    if case .state = item { return true }
                    return false
                }
                events.append(event)
            case .peerChanged:
                events.removeAll { item in
                    if case .peerChanged = item { return true }
                    return false
                }
                events.append(event)
            case .guestOverflow:
                break
            }
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
        guard shouldSchedule else { return }
        Task { @MainActor [weak self] in
            self?.drain()
        }
    }

    @MainActor
    private func drain() {
        while true {
            let next = lock.withLock { () -> ClipboardRuntimeEvent? in
                guard !events.isEmpty else {
                    drainScheduled = false
                    return nil
                }
                return events.removeFirst()
            }
            guard let next else { return }
            handler(next)
            if case .guestOverflow = next {
                lock.withLock { guestOverflowPending = false }
            }
        }
    }
}

@MainActor
public final class ClipboardRuntime {
    private let managedVM: ManagedVM
    private let bundle: VMBundle
    private var server: ClipboardSocketServer?
    private var eventBuffer: ClipboardRuntimeEventBuffer?
    private var serverEpoch: UInt64 = 0
    private var monitoringRequestTail: Task<Void, Error>?
    private(set) var enabled: Bool
    private(set) var viewerActive = false
    private(set) var helperState: ClipboardHelperConnectionState = .connecting

    var onGuestChanged: ((Int, String) -> Void)?
    var onPeerChange: (() -> Void)?
    var onSynchronizationInvalidated: (() -> Void)?
    public var onStatusChange: ((ClipboardRuntimeStatus) -> Void)?

    public init(managedVM: ManagedVM) {
        self.managedVM = managedVM
        self.bundle = VMBundle(url: managedVM.bundleURL)
        self.enabled = managedVM.metadata.isAutomaticClipboardSyncEnabled
    }

    public var status: ClipboardRuntimeStatus {
        ClipboardRuntimeStatus(enabled: enabled, viewerActive: viewerActive, helper: helperState)
    }

    /// Configure the listener before the VM starts. Clipboard failures degrade the
    /// feature to unavailable or unpaired and never prevent the VM from booting.
    public func prepare(on virtualMachine: VZVirtualMachine) {
        serverEpoch &+= 1
        let epoch = serverEpoch
        eventBuffer = nil
        server?.stop()
        server = nil
        onSynchronizationInvalidated?()

        let secret: Data
        var pairingFailure = false
        do {
            secret = try ClipboardPairingStore(bundle: bundle).ensureSecret()
        } catch {
            pairingFailure = true
            do {
                secret = try ClipboardAuthentication.randomBytes(
                    count: ClipboardProtocolConstants.pairingSecretBytes
                )
            } catch {
                helperState = .unavailable
                publishStatus()
                return
            }
        }

        let eventBuffer = ClipboardRuntimeEventBuffer { [weak self] event in
            guard let self, self.serverEpoch == epoch else { return }
            self.handleRuntimeEvent(event, pairingFailure: pairingFailure)
        }
        let server = ClipboardSocketServer(vmID: managedVM.metadata.id, secret: secret)
        server.onStateChange = { state in eventBuffer.enqueue(.state(state)) }
        server.onGuestChanged = { changeCount, text in
            eventBuffer.enqueue(.guestChanged(changeCount, text))
        }
        server.onAuthenticatedPeerChange = { eventBuffer.enqueue(.peerChanged) }
        self.eventBuffer = eventBuffer
        self.server = server

        do {
            try server.install(on: virtualMachine)
            if pairingFailure {
                helperState = .unpaired
                publishStatus()
            }
        } catch {
            server.stop()
            if serverEpoch == epoch {
                self.server = nil
                self.eventBuffer = nil
                helperState = .unavailable
                publishStatus()
            }
        }
    }

    public func setEnabled(_ enabled: Bool) throws {
        if enabled {
            _ = try bundle.updateMetadata { metadata in
                metadata.automaticClipboardSyncEnabled = true
            }
            self.enabled = true
            publishStatus()
            return
        }

        // Safety first: disabling takes effect in memory and revokes every in-flight
        // synchronization epoch before persistence. Monitor-off is attempted even if
        // the metadata write fails.
        self.enabled = false
        onSynchronizationInvalidated?()
        _ = enqueueMonitoringRequest(false)
        publishStatus()
        _ = try bundle.updateMetadata { metadata in
            metadata.automaticClipboardSyncEnabled = false
        }
    }

    func setViewerActive(_ active: Bool) {
        guard viewerActive != active else { return }
        viewerActive = active
        publishStatus()
    }

    func setMonitoring(_ active: Bool) async throws {
        try await enqueueMonitoringRequest(active).value
    }

    private func enqueueMonitoringRequest(_ active: Bool) -> Task<Void, Error> {
        let previous = monitoringRequestTail
        let server = server
        let peer = server?.peer
        let unavailableState = helperState
        let request = Task { @MainActor in
            if let previous { _ = await previous.result }
            guard let server, let peer else {
                throw ClipboardHelperUnavailableError.unavailable(unavailableState)
            }
            do {
                try await peer.setMonitoring(active)
            } catch {
                // Monitor-off is a privacy boundary. If the helper cannot acknowledge
                // it, close that exact peer so its guest poller cannot remain active.
                if !active { server.disconnect(peer) }
                throw error
            }
        }
        monitoringRequestTail = request
        return request
    }

    func readText(timeout: TimeInterval = 1) async throws -> String {
        guard let peer = server?.peer else {
            throw ClipboardHelperUnavailableError.unavailable(helperState)
        }
        return try await peer.readText(timeout: timeout)
    }

    @discardableResult
    func writeText(_ text: String, timeout: TimeInterval = 1) async throws -> Int {
        _ = try ClipboardPayload.encodeText(text)
        guard let peer = server?.peer else {
            throw ClipboardHelperUnavailableError.unavailable(helperState)
        }
        return try await peer.writeText(text, timeout: timeout)
    }

    @discardableResult
    func commitText(_ text: String, sourceChangeCount: Int) async throws -> Int {
        _ = try ClipboardPayload.encodeText(text)
        guard let peer = server?.peer else {
            throw ClipboardHelperUnavailableError.unavailable(helperState)
        }
        return try await peer.commitText(text, sourceChangeCount: sourceChangeCount)
    }

    public func stop() {
        serverEpoch &+= 1
        eventBuffer = nil
        server?.stop()
        server = nil
        onSynchronizationInvalidated?()
        helperState = .disconnected
        viewerActive = false
        publishStatus()
    }

    private func handleRuntimeEvent(_ event: ClipboardRuntimeEvent, pairingFailure: Bool) {
        switch event {
        case .state(let state):
            guard !pairingFailure else { return }
            helperState = state
            publishStatus()
        case .guestChanged(let changeCount, let text):
            onGuestChanged?(changeCount, text)
        case .peerChanged:
            onPeerChange?()
        case .guestOverflow:
            // A paired guest cannot retain unbounded clipboard values on the host.
            // Drop the burst and force both sides to establish fresh baselines.
            onPeerChange?()
        }
    }

    private func publishStatus() {
        onStatusChange?(status)
    }
}

@MainActor
protocol ClipboardRuntimeAccess: AnyObject {
    var enabled: Bool { get }
    var onGuestChanged: ((Int, String) -> Void)? { get set }
    var onPeerChange: (() -> Void)? { get set }
    var onSynchronizationInvalidated: (() -> Void)? { get set }

    func setViewerActive(_ active: Bool)
    func setMonitoring(_ active: Bool) async throws
    func commitText(_ text: String, sourceChangeCount: Int) async throws -> Int
}

extension ClipboardRuntime: ClipboardRuntimeAccess {}

@MainActor
protocol ClipboardPasteboardAccess: AnyObject {
    var changeCount: Int { get }
    func string() -> String?
    @discardableResult func writeString(_ text: String) -> Int
}

@MainActor
final class GeneralClipboardPasteboard: ClipboardPasteboardAccess {
    static let shared = GeneralClipboardPasteboard()

    private let pasteboard = NSPasteboard.general

    var changeCount: Int { pasteboard.changeCount }

    func string() -> String? {
        pasteboard.string(forType: .string)
    }

    @discardableResult
    func writeString(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }
}

@MainActor
final class ClipboardSyncCoordinator {
    private let runtime: any ClipboardRuntimeAccess
    private let pasteboard: ClipboardPasteboardAccess
    private var activationGeneration: UInt64?
    private var lastHostChangeCount: Int?
    private var remoteWriteChangeCount: Int?
    private var synchronizationEpoch: UInt64 = 0
    private var pendingGuestEvents: [(generation: UInt64, epoch: UInt64, changeCount: Int, text: String)] = []
    private var guestDrainTask: Task<Void, Never>?
    private var guestDrainID: UUID?
    private var automaticTransferEpoch: UInt64?
    private var monitoringTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?

    init(runtime: any ClipboardRuntimeAccess, pasteboard: ClipboardPasteboardAccess = GeneralClipboardPasteboard.shared) {
        self.runtime = runtime
        self.pasteboard = pasteboard
        runtime.onGuestChanged = { [weak self] changeCount, text in
            self?.guestChanged(changeCount: changeCount, text: text)
        }
        runtime.onPeerChange = { [weak self] in
            self?.peerChanged()
        }
        runtime.onSynchronizationInvalidated = { [weak self] in
            self?.synchronizationInvalidated()
        }
    }

    func activate(generation: UInt64) {
        deactivate()
        activationGeneration = generation
        advanceSynchronizationEpoch()
        runtime.setViewerActive(true)
        baseline(generation: generation, epoch: synchronizationEpoch)
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                await self.poll(generation: generation)
            }
        }
    }

    func deactivate(generation: UInt64? = nil) {
        if let generation, activationGeneration != generation { return }
        pollTask?.cancel()
        pollTask = nil
        let priorGeneration = activationGeneration
        activationGeneration = nil
        invalidateSynchronization()
        lastHostChangeCount = nil
        remoteWriteChangeCount = nil
        runtime.setViewerActive(false)
        if priorGeneration != nil {
            enqueueMonitoring(false)
        }
    }

    private func baseline(generation: UInt64, epoch: UInt64) {
        guard isCurrent(generation, epoch: epoch) else { return }
        lastHostChangeCount = pasteboard.changeCount
        remoteWriteChangeCount = nil
        guard runtime.enabled else { return }
        enqueueMonitoring(true, generation: generation, epoch: epoch)
    }

    private func enqueueMonitoring(_ active: Bool, generation: UInt64? = nil, epoch: UInt64? = nil) {
        let previous = monitoringTask
        monitoringTask = Task { @MainActor [weak self] in
            if let previous { await previous.value }
            guard let self else { return }
            if active {
                guard let generation,
                      let epoch,
                      self.isCurrent(generation, epoch: epoch),
                      self.runtime.enabled else { return }
            }
            do {
                try await self.runtime.setMonitoring(active)
            } catch {
                return
            }
            guard active,
                  let generation,
                  let epoch,
                  self.isCurrent(generation, epoch: epoch),
                  self.runtime.enabled else { return }
            // Both sides establish a new no-transfer baseline on every activation.
            self.lastHostChangeCount = self.pasteboard.changeCount
            self.remoteWriteChangeCount = nil
        }
    }

    private func synchronizationInvalidated() {
        let wasActive = activationGeneration != nil
        invalidateSynchronization()
        if wasActive { enqueueMonitoring(false) }
    }

    private func peerChanged() {
        guard let generation = activationGeneration else { return }
        // Reconnect/helper restart and queue overflow establish baselines instead of
        // replaying stale text from a prior transport epoch.
        invalidateSynchronization()
        advanceSynchronizationEpoch()
        baseline(generation: generation, epoch: synchronizationEpoch)
    }

    private func poll(generation: UInt64) async {
        let epoch = synchronizationEpoch
        guard isCurrent(generation, epoch: epoch),
              runtime.enabled,
              automaticTransferEpoch == nil else { return }
        automaticTransferEpoch = epoch
        defer {
            if automaticTransferEpoch == epoch { automaticTransferEpoch = nil }
        }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastHostChangeCount else { return }
        if changeCount == remoteWriteChangeCount {
            lastHostChangeCount = changeCount
            remoteWriteChangeCount = nil
            return
        }

        guard isCurrent(generation, epoch: epoch), runtime.enabled else { return }
        guard let text = pasteboard.string() else {
            lastHostChangeCount = changeCount
            return
        }
        guard isCurrent(generation, epoch: epoch), runtime.enabled else { return }
        do {
            _ = try ClipboardPayload.encodeText(text)
            guard isCurrent(generation, epoch: epoch), runtime.enabled else { return }
            lastHostChangeCount = changeCount
            _ = try await runtime.commitText(text, sourceChangeCount: changeCount)
            guard isCurrent(generation, epoch: epoch), runtime.enabled else { return }
        } catch {
            // Validation and transport errors are terminal for this change. Reconnect
            // takes a fresh baseline, so automatic sync never falls back to VNC.
            lastHostChangeCount = changeCount
        }
    }

    /// Serialize currently visible host and guest changes. The regular viewer path
    /// invokes the same work from its timer and event-drain tasks; keeping this hook
    /// deterministic also makes the conflict policy directly verifiable.
    func synchronizeNow() async {
        if let generation = activationGeneration {
            await poll(generation: generation)
        }
        if let guestDrainTask {
            await guestDrainTask.value
        }
    }

    private func guestChanged(changeCount: Int, text: String) {
        guard let generation = activationGeneration,
              runtime.enabled,
              isCurrent(generation, epoch: synchronizationEpoch) else { return }
        guard pendingGuestEvents.count < 4 else {
            invalidateSynchronization()
            advanceSynchronizationEpoch()
            baseline(generation: generation, epoch: synchronizationEpoch)
            return
        }
        pendingGuestEvents.append((generation, synchronizationEpoch, changeCount, text))
        startGuestDrainIfNeeded()
    }

    private func startGuestDrainIfNeeded() {
        guard guestDrainTask == nil else { return }
        let drainID = UUID()
        guestDrainID = drainID
        guestDrainTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, !self.pendingGuestEvents.isEmpty {
                let event = self.pendingGuestEvents.removeFirst()
                while self.automaticTransferEpoch != nil, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                guard !Task.isCancelled else { break }
                await self.applyGuestEvent(event)
            }
            if self.guestDrainID == drainID {
                self.guestDrainTask = nil
                self.guestDrainID = nil
            }
        }
    }

    private func applyGuestEvent(
        _ event: (generation: UInt64, epoch: UInt64, changeCount: Int, text: String)
    ) async {
        guard isCurrent(event.generation, epoch: event.epoch), runtime.enabled else { return }
        automaticTransferEpoch = event.epoch
        defer {
            if automaticTransferEpoch == event.epoch { automaticTransferEpoch = nil }
        }
        do {
            _ = try ClipboardPayload.encodeText(event.text)
            guard isCurrent(event.generation, epoch: event.epoch), runtime.enabled else { return }
            let producedChangeCount = pasteboard.writeString(event.text)
            guard isCurrent(event.generation, epoch: event.epoch), runtime.enabled else { return }
            remoteWriteChangeCount = producedChangeCount
            lastHostChangeCount = producedChangeCount
            // Confirm the serialized winner back to the guest. This also makes
            // simultaneous host/guest changes converge on one authoritative text.
            _ = try await runtime.commitText(event.text, sourceChangeCount: event.changeCount)
            guard isCurrent(event.generation, epoch: event.epoch), runtime.enabled else { return }
        } catch {
            // Never route automatic synchronization through VNC.
        }
    }

    private func invalidateSynchronization() {
        advanceSynchronizationEpoch()
        pendingGuestEvents.removeAll()
        guestDrainTask?.cancel()
        guestDrainTask = nil
        guestDrainID = nil
        lastHostChangeCount = nil
        remoteWriteChangeCount = nil
    }

    @discardableResult
    private func advanceSynchronizationEpoch() -> UInt64 {
        let (next, overflow) = synchronizationEpoch.addingReportingOverflow(1)
        synchronizationEpoch = overflow ? 1 : next
        return synchronizationEpoch
    }

    private func isCurrent(_ generation: UInt64, epoch: UInt64) -> Bool {
        activationGeneration == generation && synchronizationEpoch == epoch
    }
}

@MainActor
public final class ClipboardActivationCoordinator {
    public static let shared = ClipboardActivationCoordinator()

    private struct Grant {
        var ownerID: UUID
        var generation: UInt64
        var revoke: () -> Void
    }

    private var nextGeneration: UInt64 = 1
    private var current: Grant?

    private init() {}

    func activate(ownerID: UUID, revoke: @escaping () -> Void) -> UInt64 {
        current?.revoke()
        let generation = nextGeneration
        let (next, overflow) = nextGeneration.addingReportingOverflow(1)
        nextGeneration = overflow ? 1 : next
        current = Grant(ownerID: ownerID, generation: generation, revoke: revoke)
        return generation
    }

    func deactivate(ownerID: UUID, generation: UInt64? = nil) {
        guard let current,
              current.ownerID == ownerID,
              generation == nil || generation == current.generation else { return }
        self.current = nil
        current.revoke()
    }

    public func deactivateAll() {
        let prior = current
        current = nil
        prior?.revoke()
    }
}
