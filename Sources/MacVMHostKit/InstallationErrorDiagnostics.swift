import Foundation

enum InstallationErrorDiagnostics {
    private static let maximumDepth = 8

    static func message(
        for error: Error,
        hostVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) -> String {
        var sections = ["Apple's macOS installer failed."]

        if isMobileRestoreError11(error),
           hostVersion.majorVersion == 26,
           hostVersion.minorVersion <= 5
        {
            sections.append(
                "This matches a known incompatibility between macOS 26.5 and Device Support for macOS 27. "
                    + "Update the host to macOS 26.6 beta 3 (build 25G5052e) or later, restart the Mac, "
                    + "remove the incomplete VM, and try again."
            )
        }

        sections.append("Technical details:\n\(technicalDetails(for: error))")
        return sections.joined(separator: "\n\n")
    }

    static func technicalDetails(for error: Error) -> String {
        var lines: [String] = []
        var visited: Set<ObjectIdentifier> = []
        append(error as NSError, depth: 0, lines: &lines, visited: &visited)
        return lines.joined(separator: "\n")
    }

    static func isMobileRestoreError11(_ error: Error) -> Bool {
        var pending = [error as NSError]
        var visited: Set<ObjectIdentifier> = []

        while let current = pending.popLast() {
            let identifier = ObjectIdentifier(current)
            guard visited.insert(identifier).inserted else { continue }

            if current.domain == "com.apple.MobileDevice.MobileRestore",
               current.localizedDescription.contains("error: 11")
            {
                return true
            }

            pending.append(contentsOf: underlyingErrors(of: current))
        }

        return false
    }

    private static func append(
        _ error: NSError,
        depth: Int,
        lines: inout [String],
        visited: inout Set<ObjectIdentifier>
    ) {
        let indentation = String(repeating: "  ", count: depth)
        guard depth <= maximumDepth else {
            lines.append("\(indentation)↳ Additional underlying errors omitted.")
            return
        }

        let identifier = ObjectIdentifier(error)
        guard visited.insert(identifier).inserted else {
            lines.append("\(indentation)↳ Repeated underlying error omitted.")
            return
        }

        let marker = depth == 0 ? "" : "↳ "
        var description = "\(indentation)\(marker)\(error.domain) (\(error.code)): \(error.localizedDescription)"
        if let reason = error.localizedFailureReason,
           !reason.isEmpty,
           reason != error.localizedDescription
        {
            description += " Reason: \(reason)"
        }
        if let suggestion = error.localizedRecoverySuggestion,
           !suggestion.isEmpty,
           suggestion != error.localizedDescription,
           suggestion != error.localizedFailureReason
        {
            description += " Recovery: \(suggestion)"
        }
        lines.append(description)

        for underlyingError in underlyingErrors(of: error) {
            append(underlyingError, depth: depth + 1, lines: &lines, visited: &visited)
        }
    }

    private static func underlyingErrors(of error: NSError) -> [NSError] {
        var errors: [NSError] = []
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            errors.append(underlying)
        }
        if let multiple = error.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
            errors.append(contentsOf: multiple)
        }
        return errors
    }
}
