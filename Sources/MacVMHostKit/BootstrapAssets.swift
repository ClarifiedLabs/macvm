import Foundation

enum BootstrapAssets {
    static let bootstrapDirectoryName = "Bootstrap"
    static let transfersDirectoryName = "Transfers"
    static let readmeFileName = "README.txt"
    static let scriptFileName = "bootstrap-tools.sh"
    private static let resourcesDirectoryName = "Resources"

    static let readme = """
    This directory is shared from the host and automounted in the guest at:
      /Volumes/My Shared Files

    Files included here:
    - Bootstrap/bootstrap-tools.sh
    - Transfers/

    Suggested first-boot flow:
    1. Complete macOS Setup Assistant in the guest.
    2. Sign in to iCloud if you want the VM to sync iCloud content.
    3. If you want full Xcode, copy Xcode*.xip into Transfers/.
    4. Open Terminal inside the guest.
    5. Run /Volumes/My Shared Files/Bootstrap/bootstrap-tools.sh --install-xcode --install-ios-simulator
    6. Use Transfers/ for installers, archives, and handoff files.

    Notes:
    - Moving this VM to a different host Mac can require iCloud reauthentication.
    - Running cloned copies of the same VM can also trigger iCloud reauthentication.
    - The bootstrap script uses Apple's documented xcodebuild flow for first-launch setup and simulator downloads.
    - Full Xcode download is intentionally not automated; provide a local Xcode*.xip via Transfers/ for unattended installation.
    - If you use this VM as a GitHub Actions runner, register the runner after first boot with your repository or organization token.
    """

    static func loadBootstrapScript() throws -> String {
        guard let url = Bundle.module.url(
            forResource: scriptFileName,
            withExtension: nil,
            subdirectory: "\(resourcesDirectoryName)/\(bootstrapDirectoryName)"
        ) else {
            throw MacVMError.message("Missing bundled bootstrap script resource: \(scriptFileName)")
        }

        return try String(contentsOf: url, encoding: .utf8)
    }
}
