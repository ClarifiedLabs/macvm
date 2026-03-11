import Darwin
import Foundation

func processExists(pid: Int32) -> Bool {
    if kill(pid, 0) == 0 {
        return true
    }
    return errno == EPERM
}

public enum VMDisplayRuntimeSource: String, Codable, Sendable {
    case viewer
    case headless

    public var description: String {
        switch self {
        case .viewer:
            return "viewer"
        case .headless:
            return "headless"
        }
    }
}

public struct VMDisplayRuntimeState: Codable, Equatable, Sendable {
    /// Effective guest workspace size in points.
    public var width: Int
    public var height: Int
    /// Backing framebuffer size in pixels, when the owner can report it.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    public var source: VMDisplayRuntimeSource
    public var pid: Int32
    public var updatedAt: Date

    public init(
        width: Int,
        height: Int,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil,
        source: VMDisplayRuntimeSource,
        pid: Int32,
        updatedAt: Date
    ) {
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.source = source
        self.pid = pid
        self.updatedAt = updatedAt
    }

    public var displayDescription: String {
        "\(width)x\(height)"
    }

    public var pixelDescription: String? {
        guard let pixelWidth, let pixelHeight else {
            return nil
        }
        return "\(pixelWidth)x\(pixelHeight)"
    }

    public var isLive: Bool {
        processExists(pid: pid)
    }
}

struct VMViewerWindowState: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var updatedAt: Date
}
