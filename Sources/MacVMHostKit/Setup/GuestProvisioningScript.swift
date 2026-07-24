import Foundation

/// Inputs for the guest provisioning script.
struct GuestProvisioningInputs {
    var username: String
    var password: String
    /// The per-VM public key to authorize for SSH.
    var authorizedKey: String
    /// An optional additional public key (e.g. the operator's own).
    var extraAuthorizedKey: String?
    var enableAutoLogin: Bool
    /// Path, inside the guest, of the file holding the account password (so it isn't
    /// passed on the command line / visible in `ps`). The script reads and deletes it.
    var passwordFilePath: String
    /// Path in the shared folder used to report running/done/failed status to the host.
    var statusFilePath: String
    /// Path in the shared folder used to authenticate the guest's SSH host keys.
    var sshHostKeysFilePath: String
}

/// Builds the shell script that runs inside the guest to make it Ansible-ready.
///
/// Everything fragile lives here as a staged script rather than typed keystrokes.
/// SSH is enabled with `launchctl load -w …/ssh.plist`, which — unlike
/// `systemsetup -setremotelogin on` — does not require Full Disk Access.
enum GuestProvisioningScript {
    static let doneMarker = "MACVM_PROVISION_DONE"

    /// Whether a username is safe to interpolate into the script and sudoers path.
    /// macOS short names are already restricted to this set; validating here closes
    /// any shell/sudoers-injection route from the `--username` flag.
    static func isValidUsername(_ username: String) -> Bool {
        !username.isEmpty
            && username.count <= 32
            && username.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
    }

    static func build(_ inputs: GuestProvisioningInputs) -> String {
        var authorizedKeys = inputs.authorizedKey
        if let extra = inputs.extraAuthorizedKey, !extra.isEmpty {
            authorizedKeys += "\n" + extra
        }

        let autoLoginBlock: String
        if inputs.enableAutoLogin {
            autoLoginBlock = """
            echo "$PW" | sudo -S sysadminctl -autologin set -userName \(shellQuote(inputs.username)) -password "$PW" 2>/dev/null || true
            """
        } else {
            autoLoginBlock = "# auto-login disabled"
        }

        // The sudoers drop-in is validated with visudo before install so a typo can
        // never lock the account out of sudo.
        return """
        #!/bin/zsh
        set -euo pipefail
        umask 077

        PW_FILE=\(shellQuote(inputs.passwordFilePath))
        STATUS_FILE=\(shellQuote(inputs.statusFilePath))
        SSH_HOST_KEYS_FILE=\(shellQuote(inputs.sshHostKeysFilePath))
        printf 'running\\n' > "$STATUS_FILE"
        trap 'status=$?; if (( status != 0 )); then printf "failed:%s\\n" "$status" > "$STATUS_FILE"; fi' EXIT

        PW="$(cat "$PW_FILE")"
        rm -f "$PW_FILE"

        # Authorize SSH keys for this account.
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        cat >> "$HOME/.ssh/authorized_keys" <<'MACVM_KEYS'
        \(authorizedKeys)
        MACVM_KEYS
        chmod 600 "$HOME/.ssh/authorized_keys"

        # Fresh macOS installs do not create SSH host keys until sshd's launch wrapper
        # first runs. Generate them explicitly so the host can pin them before making
        # its first network connection.
        echo "$PW" | sudo -S /usr/bin/ssh-keygen -A

        # Export the SSH host public keys through the Virtualization.framework shared
        # directory before any network trust decision. The host pins these exact keys.
        echo "$PW" | sudo -S sh -c 'cat /etc/ssh/ssh_host_*_key.pub' \
          | awk 'NF >= 2 { print $1 " " $2 }' | sort -u > "$SSH_HOST_KEYS_FILE.tmp"
        [[ -s "$SSH_HOST_KEYS_FILE.tmp" ]]
        mv -f "$SSH_HOST_KEYS_FILE.tmp" "$SSH_HOST_KEYS_FILE"
        chmod 600 "$SSH_HOST_KEYS_FILE"

        # Enable Remote Login (SSH) without needing Full Disk Access.
        echo "$PW" | sudo -S launchctl load -w /System/Library/LaunchDaemons/ssh.plist 2>/dev/null || true

        # Passwordless sudo for Ansible `become`. The username is validated to a safe
        # character set by the host before this script is built, and the drop-in is
        # checked with visudo before install so a bad entry can never lock out sudo.
        SUDOERS_TMP="$(mktemp)"
        echo "\(inputs.username) ALL=(ALL) NOPASSWD: ALL" > "$SUDOERS_TMP"
        if visudo -cf "$SUDOERS_TMP" >/dev/null 2>&1; then
            echo "$PW" | sudo -S install -m 0440 "$SUDOERS_TMP" \(shellQuote("/etc/sudoers.d/macvm-\(inputs.username)"))
        fi
        rm -f "$SUDOERS_TMP"

        # Auto-login for an unattended desktop session.
        \(autoLoginBlock)

        # Do not restore the previous desktop session after a macvm shutdown.
        defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool false

        # Keep the machine awake and unlocked for CI use.
        echo "$PW" | sudo -S pmset -a sleep 0 displaysleep 0 disksleep 0 2>/dev/null || true
        defaults -currentHost write com.apple.screensaver idleTime 0 2>/dev/null || true

        printf 'done\\n' > "$STATUS_FILE"
        echo "\(doneMarker)"
        """
    }

    /// Single-quote a string for safe embedding in the shell script.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
