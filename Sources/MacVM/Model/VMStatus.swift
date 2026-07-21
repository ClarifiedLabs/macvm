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
        setupOperationActive: Bool = false,
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
        // Active setup necessarily has a live runtime and must keep the setup
        // progress view visible while it drives the guest.
        if settingUp && setupOperationActive {
            return .settingUp
        }
        // A live runtime wins over an inactive setup marker. A stale
        // setup-state.json left after setup must not demote a running VM.
        if viewerActive || liveProcess != nil || liveDisplay != nil || liveSession != nil {
            return .running
        }
        if settingUp {
            return .settingUp
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
