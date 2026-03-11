import Foundation

public enum MacVMVersion {
    public static func shortVersion(bundle: Bundle = .main) -> String {
        nonEmptyString(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")) ?? "1.0.0"
    }

    public static func displayVersion(bundle: Bundle = .main) -> String {
        let version = shortVersion(bundle: bundle)
        guard let build = nonEmptyString(bundle.object(forInfoDictionaryKey: "CFBundleVersion")),
              build != "1" else {
            return "Version \(version)"
        }

        return "Version \(version) (\(build))"
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
