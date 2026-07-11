import Foundation
import MacVMHostKit

/// Display status of a VM as the manager sees it. Derived, never stored: in-app
/// operations are authoritative, then liveness published by other processes
/// (process/session/display runtime files), else stopped.
enum VMStatus: Equatable {
    case cloning
    case installing
    case settingUp
    case running
    case stopped

    static func derive(
        cloning: Bool,
        installing: Bool,
        settingUp: Bool,
        viewerActive: Bool,
        liveProcess: VMProcessRuntimeState?,
        liveDisplay: VMDisplayRuntimeState?,
        liveSession: VNCSession?
    ) -> VMStatus {
        if cloning {
            return .cloning
        }
        if installing {
            return .installing
        }
        if settingUp {
            return .settingUp
        }
        if viewerActive || liveProcess != nil || liveDisplay != nil || liveSession != nil {
            return .running
        }
        return .stopped
    }

    /// Status label under the VM name in the detail header.
    var headerLabel: String {
        switch self {
        case .cloning: "Cloning VM…"
        case .installing: "Installing macOS…"
        case .settingUp: "Setting up — driving Setup Assistant"
        case .running: "Running"
        case .stopped: "Stopped"
        }
    }

    /// Short status word for the sidebar subtitle.
    var sidebarLabel: String {
        switch self {
        case .cloning: "Cloning…"
        case .installing: "Installing…"
        case .settingUp: "Setting up…"
        case .running: "Running"
        case .stopped: "Stopped"
        }
    }

    /// Whether the status dot pulses (in-flight states).
    var pulses: Bool {
        self == .cloning || self == .installing || self == .settingUp
    }
}
