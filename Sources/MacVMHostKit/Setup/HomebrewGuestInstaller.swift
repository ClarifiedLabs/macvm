import Foundation

enum HomebrewGuestInstaller {
    static let executablePath = "/opt/homebrew/bin/brew"

    static let installScript = #"""
    set -euo pipefail
    brew_path=/opt/homebrew/bin/brew
    xcode_dir_before="$(xcode-select -p 2>/dev/null || true)"

    if [[ ! -x "$brew_path" ]]; then
      NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    xcode_dir_after="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "$xcode_dir_before" && "$xcode_dir_before" != "$xcode_dir_after" && -d "$xcode_dir_before" ]]; then
      sudo -n /usr/bin/xcode-select --switch "$xcode_dir_before"
    fi

    [[ -x "$brew_path" ]]
    profile_line='eval "$(/opt/homebrew/bin/brew shellenv)"'
    touch "$HOME/.zprofile"
    grep -Fqx "$profile_line" "$HOME/.zprofile" || printf '\n%s\n' "$profile_line" >> "$HOME/.zprofile"
    "$brew_path" --version
    """#

    static func install(
        over ssh: GuestSSH,
        bundle: VMBundle,
        progress: VMOperationHandler?
    ) async throws {
        let logURL = bundle.setupDirectoryURL.appendingPathComponent("homebrew-install.log")
        progress?(.status("Homebrew: installing in the macOS guest"))
        progress?(.setupLog(SetupLogArtifact(
            label: "Homebrew installation",
            bundleRelativePath: "Setup/homebrew-install.log"
        )))
        let status = try await ssh.runLoggedAsync(
            remoteCommand: [
                "/bin/bash", "-c", GuestProvisioningScript.shellQuote(installScript),
            ],
            logFile: logURL,
            timeout: 30 * 60
        )
        guard status == 0 else {
            throw MacVMError.message(
                "Homebrew installation failed inside macOS (status \(status)). See \(logURL.path)."
            )
        }
        progress?(.status("Homebrew installation complete."))
    }
}
