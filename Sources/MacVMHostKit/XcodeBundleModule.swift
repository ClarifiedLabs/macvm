#if !SWIFT_PACKAGE
import Foundation

extension Bundle {
    static var module: Bundle {
        let bundleName = "macvm_MacVMHostKit"
        let bundleFileName = "\(bundleName).bundle"
        let fileManager = FileManager.default
        let executableURL = CommandLine.arguments.first.map {
            URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath()
        }
        let embeddedAppResourcesURL = executableURL.map {
            $0.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
        }

        let candidates = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            Bundle(for: BundleFinder.self).resourceURL,
            Bundle(for: BundleFinder.self).bundleURL,
            Bundle(for: BundleFinder.self).bundleURL.deletingLastPathComponent(),
            executableURL?.deletingLastPathComponent(),
            embeddedAppResourcesURL,
        ].compactMap { $0 }

        for candidate in candidates {
            let bundleURL = candidate.appendingPathComponent(bundleFileName, isDirectory: true)
            if fileManager.fileExists(atPath: bundleURL.path),
               let bundle = Bundle(url: bundleURL) {
                return bundle
            }
        }

        return Bundle(for: BundleFinder.self)
    }
}

private final class BundleFinder {}
#endif
