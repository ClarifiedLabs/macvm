import Foundation
import MacVMClipboardProtocol

public enum ClipboardGuestInstallDisposition: String, Equatable, Sendable {
    case started
    case deferredUntilLogin

    public var message: String {
        switch self {
        case .started:
            return "Installed and started the clipboard helper."
        case .deferredUntilLogin:
            return "Installed the clipboard helper; it will start at the next GUI login."
        }
    }
}

struct ClipboardGuestInstaller {
    static let label = "dev.macvm.clipboard-guest"
    static let executablePath = "/usr/local/libexec/macvm-clipboard-guest"
    static let helperVersion = 1

    struct Configuration: Codable, Equatable {
        var vmID: UUID
        var pairingKeyPath: String
    }

    struct InstallationMarker: Codable, Equatable {
        var helperVersion: Int
        var protocolVersion: UInt16
    }

    static func configurationData(vmID: UUID, homeDirectory: String) throws -> Data {
        let configuration = Configuration(
            vmID: vmID,
            pairingKeyPath: "\(homeDirectory)/Library/Application Support/MacVM/Clipboard/pairing.key"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(configuration)
    }

    static func installationMarkerData() throws -> Data {
        let marker = InstallationMarker(
            helperVersion: helperVersion,
            protocolVersion: ClipboardProtocolConstants.applicationVersion
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(marker)
    }

    static func launchAgentData(homeDirectory: String) throws -> Data {
        let logDirectory = "\(homeDirectory)/Library/Logs/MacVM"
        let propertyList: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executablePath],
            "LimitLoadToSessionType": "Aqua",
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 5,
            "StandardOutPath": "\(logDirectory)/clipboard-helper.log",
            "StandardErrorPath": "\(logDirectory)/clipboard-helper.log",
            "ProcessType": "Interactive",
        ]
        return try PropertyListSerialization.data(
            fromPropertyList: propertyList,
            format: .xml,
            options: 0
        )
    }

    /// A restartable, journaled guest transaction. The caller launches this script
    /// detached from SSH, so host cancellation or process death cannot interrupt a
    /// partially published helper. A later install rolls back any journal left by a
    /// guest crash before beginning a fresh idempotent upgrade.
    static func installScript(
        user _: String,
        homeDirectory: String,
        remoteStage: String,
        remoteResult: String? = nil
    ) -> String {
        let quote = GuestProvisioningScript.shellQuote
        let supportDirectory = "\(homeDirectory)/Library/Application Support/MacVM/Clipboard"
        let launchAgentsDirectory = "\(homeDirectory)/Library/LaunchAgents"
        let launchAgentPath = "\(launchAgentsDirectory)/\(label).plist"
        let logDirectory = "\(homeDirectory)/Library/Logs/MacVM"
        let backup = "\(remoteStage)/backup"
        let journal = "\(supportDirectory)/install-journal"
        let result = remoteResult ?? "\(remoteStage).result"
        let token = URL(fileURLWithPath: remoteStage).lastPathComponent
        let paths = ["configuration.json", "pairing.key", "installation.json"]
        let backupUserFiles = paths.map { name in
            "if [[ -e \(quote("\(supportDirectory)/\(name)")) ]]; then cp -p \(quote("\(supportDirectory)/\(name)")) \"$backup/\(name)\"; else : > \"$backup/.\(name).absent\"; fi"
        }.joined(separator: "\n")
        let restoreUserFiles = paths.map { name in
            "if [[ -e \"$old/\(name)\" ]]; then install -m 0600 \"$old/\(name)\" \(quote("\(supportDirectory)/\(name)")); elif [[ -e \"$old/.\(name).absent\" ]]; then rm -f \(quote("\(supportDirectory)/\(name)")); fi"
        }.joined(separator: "\n")
        let publishUserFiles = paths.map { name in
            let temporary = "\(supportDirectory)/.\(name).\(token).new"
            return "install -m 0600 \"$stage/\(name)\" \(quote(temporary))\nmv -f \(quote(temporary)) \(quote("\(supportDirectory)/\(name)"))"
        }.joined(separator: "\n")

        return """
        set -euo pipefail
        umask 077
        stage=\(quote(remoteStage))
        backup=\(quote(backup))
        journal=\(quote(journal))
        result=\(quote(result))
        uid=$(id -u)

        restore_stage() {
          old="$1/backup"
          [[ -d "$old" ]] || return 0
          launchctl bootout "gui/$uid/\(label)" >/dev/null 2>&1 || true
          \(restoreUserFiles)
          if [[ -e "$old/launch-agent.plist" ]]; then install -m 0644 "$old/launch-agent.plist" \(quote(launchAgentPath)); elif [[ -e "$old/.launch-agent.absent" ]]; then rm -f \(quote(launchAgentPath)); fi
          if [[ -e "$old/macvm-clipboard-guest" ]]; then sudo install -o root -g wheel -m 0755 "$old/macvm-clipboard-guest" \(quote(executablePath)); elif [[ -e "$old/.helper.absent" ]]; then sudo rm -f \(quote(executablePath)); fi
          if launchctl print "gui/$uid" >/dev/null 2>&1 && [[ -e \(quote(launchAgentPath)) ]]; then
            launchctl bootstrap "gui/$uid" \(quote(launchAgentPath)) >/dev/null 2>&1 || true
          fi
        }

        # Recover a transaction interrupted by a guest crash before using its stage.
        install -d -m 0700 \(quote(supportDirectory))
        if [[ -f "$journal" ]]; then
          previous=$(cat "$journal" 2>/dev/null || true)
          if [[ "$previous" == \(quote(supportDirectory))/.install-stage-* && -d "$previous" ]]; then
            restore_stage "$previous"
            /bin/sync
            rm -rf "$previous"
            rm -f "$previous.result"
          fi
          rm -f "$journal"
        fi

        mkdir -p "$backup"
        chmod 0700 "$stage" "$backup"
        \(backupUserFiles)
        if [[ -e \(quote(launchAgentPath)) ]]; then cp -p \(quote(launchAgentPath)) "$backup/launch-agent.plist"; else : > "$backup/.launch-agent.absent"; fi
        if [[ -e \(quote(executablePath)) ]]; then sudo cp -p \(quote(executablePath)) "$backup/macvm-clipboard-guest"; else : > "$backup/.helper.absent"; fi
        printf '%s\n' "$stage" > "$journal.new"
        mv -f "$journal.new" "$journal"
        # Persist the complete backup and write-ahead journal before replacing any
        # destination. Recovery never depends on a post-mutation journal append.
        /bin/sync

        rollback() {
          status="$1"
          set +e
          restore_stage "$stage"
          /bin/sync
          # Keep the journal and backup stage after a failed install. A later
          # retry replays the restore before removing these durable backups.
          printf 'failed:%s\n' "$status" > "$result.new"
          mv -f "$result.new" "$result"
          exit "$status"
        }
        trap 'rollback $?' ERR
        trap 'rollback 130' INT
        trap 'rollback 143' TERM

        sudo install -d -o root -g wheel -m 0755 /usr/local/libexec
        install -d -m 0755 \(quote(launchAgentsDirectory))
        install -d -m 0700 \(quote(logDirectory))
        \(publishUserFiles)
        install -m 0644 "$stage/\(label).plist" \(quote("\(launchAgentPath).\(token).new"))
        mv -f \(quote("\(launchAgentPath).\(token).new")) \(quote(launchAgentPath))
        sudo install -o root -g wheel -m 0755 "$stage/macvm-clipboard-guest" \(quote("/usr/local/libexec/.macvm-clipboard-guest.\(token).new"))
        sudo mv -f \(quote("/usr/local/libexec/.macvm-clipboard-guest.\(token).new")) \(quote(executablePath))

        if launchctl print "gui/$uid" >/dev/null 2>&1; then
          launchctl bootout "gui/$uid/\(label)" >/dev/null 2>&1 || true
          launchctl bootstrap "gui/$uid" \(quote(launchAgentPath))
          launchctl kickstart -k "gui/$uid/\(label)"
          launchctl print "gui/$uid/\(label)" >/dev/null
          disposition=started
        else
          disposition=deferred
        fi

        # Make the installed generation durable before retiring its rollback data.
        /bin/sync
        rm -f "$journal"
        /bin/sync
        trap - ERR INT TERM
        printf '%s\n' "$disposition" > "$result.new"
        mv -f "$result.new" "$result"
        rm -rf "$stage"
        """
    }
}
