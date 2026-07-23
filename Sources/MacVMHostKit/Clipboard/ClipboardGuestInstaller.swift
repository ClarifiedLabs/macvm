import Foundation
import MacVMClipboardProtocol

public enum ClipboardGuestInstallDisposition: String, Equatable, Sendable {
    case started
    case deferredUntilLogin
    /// A detached guest transaction is already running; no files were modified.
    case inProgress

    public var message: String {
        switch self {
        case .started:
            return "Installed and started the clipboard helper."
        case .deferredUntilLogin:
            return "Installed the clipboard helper; it will start at the next GUI login."
        case .inProgress:
            return "Clipboard helper installation is already in progress in the guest; its result will be reported when it finishes."
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

    /// A restartable, journaled guest transaction guarded by a live-owner lock.
    /// The caller launches this script detached from SSH, so host cancellation or
    /// process death cannot interrupt a partially published helper — but the host
    /// also loses visibility into the detached run, so a live-owner lock directory
    /// (atomic `mkdir`) serializes guest transactions: a lock whose recorded owner
    /// PID is still alive rejects concurrent installs, while a lock left behind by
    /// a crashed or `kill -9`'d transaction is reclaimed before rollback replay.
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
        let lockDirectory = "\(supportDirectory)/install.lock"
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
        lock=\(quote(lockDirectory))
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

        # Record "in progress" for every outcome, including failure paths taken
        # before the lock is acquired.
        /usr/bin/true > "$result"

        # Acquire the live-owner lock before touching the journal or any file. A
        # lock whose owner PID is still running a guest transaction rejects the
        # concurrent attempt; a stale lock left by a crashed transaction is
        # reclaimed so its journal can be rolled back below.
        install -d -m 0700 \(quote(supportDirectory))
        if ! /bin/mkdir "$lock" 2>/dev/null; then
          owner_pid=""
          if [[ -f "$lock/owner" ]]; then
            owner_pid=$(/bin/cat "$lock/owner" 2>/dev/null | /usr/bin/tr -dc '0-9' || /usr/bin/true)
          fi
          if [[ -n "$owner_pid" ]] && /bin/kill -0 "$owner_pid" 2>/dev/null; then
            if [[ -f "$lock/stage" ]]; then
              live_stage=$(/bin/cat "$lock/stage" 2>/dev/null || /usr/bin/true)
              if [[ -n "$live_stage" && -f "$live_stage.result" ]]; then
                /bin/rm -f "$live_stage.result"
                /bin/ln "$result" "$live_stage.result" 2>/dev/null || /usr/bin/true
              fi
            fi
            /bin/echo "in-progress" > "$result.new"
            /bin/mv -f "$result.new" "$result"
            /bin/sync
            exit 0
          fi
          # Stale lock: the recorded owner is gone, so reclaim the transaction.
          # Releasing a lock and reclaiming one are distinct paths; keep this
          # removal next to the re-acquisition so a lost race still reports
          # in-progress instead of running two transactions.
          /bin/rm -rf "$lock"
          if ! /bin/mkdir "$lock" 2>/dev/null; then
            /bin/echo "in-progress" > "$result.new"
            /bin/mv -f "$result.new" "$result"
            /bin/sync
            exit 0
          fi
        fi
        /bin/echo "$$" > "$lock/owner"
        /bin/echo "$stage" > "$lock/stage"
        /bin/sync

        # Recover a transaction interrupted by a guest crash before using its stage.
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
          # Release the live-owner lock so that retry can reclaim the transaction.
          /bin/rm -rf "$lock"
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
          # Bounded post-bootstrap health check: bootstrap proves registration,
          # not that the agent stays alive (an immediately crashing helper
          # unregisters despite KeepAlive). Never wait indefinitely — the helper
          # may take a moment to pair with the host, so launchd registration is
          # the bounded success criterion and runtime status reports pairing.
          healthy=""
          for _ in 1 2 3 4 5 6 7 8 9 10; do
            if launchctl print "gui/$uid/\(label)" >/dev/null 2>&1; then
              healthy=1
              break
            fi
            sleep 1
          done
          if [[ -z "$healthy" ]]; then
            rollback 70
          fi
          disposition=started
        else
          disposition=deferred
        fi

        # Make the installed generation durable before retiring its rollback data.
        /bin/sync
        rm -f "$journal"
        /bin/sync
        trap - ERR INT TERM
        /bin/rm -rf "$lock"
        printf '%s\n' "$disposition" > "$result.new"
        mv -f "$result.new" "$result"
        rm -rf "$stage"
        """
    }
}
