# Clipboard

MacVM supports one-shot plain-text transfers and opt-in **Automatic Clipboard
Sync** between the host and a macOS guest. The guest helper adds this capability
but never enables automatic synchronization on its own.

## Install or upgrade the helper

Automated setup installs the helper by default after the guest becomes reachable
over SSH. Pass `--no-clipboard-helper` to `macvm create --setup` or `macvm setup`
to omit it. The helper is optional: if its installation fails, setup still
completes and the VM remains usable. The failure is recorded on the VM and shown
in its detail view; repair it later with `macvm clipboard install <name>` while
the VM is running.

For an existing VM, start it through `MacVM.app` and run:

```bash
macvm run dev-01
macvm clipboard install dev-01
```

The CLI sends the full VM bundle path to the owning app. Installation requires
an SSH-ready guest, the setup username stored in VM metadata, and that VM's SSH
key. It installs:

- `/usr/local/libexec/macvm-clipboard-guest`
- `~/Library/LaunchAgents/dev.macvm.clipboard-guest.plist`
- `~/Library/Application Support/MacVM/Clipboard/configuration.json`
- `~/Library/Application Support/MacVM/Clipboard/pairing.key`

The per-user LaunchAgent runs only in an Aqua login session. If no GUI session
exists, installation succeeds in a deferred state and the helper starts at the
next login. Re-running `macvm clipboard install` upgrades the helper and refreshes
its configuration. Replaced files are backed up during installation and restored
if deployment fails.

The guest transaction runs detached from SSH under a live-owner lock
(`~/Library/Application Support/MacVM/Clipboard/install.lock`, an atomic
directory whose `owner` file records the transaction PID). A concurrent or
retried install sees the live owner and reports `in-progress` without modifying
files; a lock left behind by a crashed transaction is stale — its dead owner PID
lets the next install reclaim the lock and roll back the interrupted journal
before upgrading. When the helper is started, the install also runs a bounded
post-bootstrap health check of the LaunchAgent (`launchctl print`), reporting a
distinct failure if the agent does not stay registered rather than waiting
indefinitely for a guest connection.

## One-shot transfers

A native VM viewer exposes the exact actions:

- **Paste to VM →** writes current plain text from the host pasteboard to the
  guest.
- **← Copy from VM** reads current plain text from the guest pasteboard and
  writes it to the host.

The actions try the authenticated helper for one second. They fall back to the
live VNC session only when the helper is unavailable. Authentication, malformed
text, oversized data, or other validation failures are reported and do not fall
back to a less trusted path.

The VNC fallback is best-effort. RFB clipboard bridging is not functional on
every macOS guest/Virtualization.framework combination and may time out or fail
without changing the destination pasteboard. Install the authenticated helper
for reliable one-shot transfers; automatic synchronization never uses VNC.

## Automatic synchronization

**Automatic Clipboard Sync** is disabled by default for new, existing, and
cloned VMs. Enable it from the native viewer toolbar or the VM's detail view.
The preference persists per VM.

Synchronization is active only when all of these conditions hold:

1. The preference is enabled.
2. The helper is authenticated and compatible.
3. The VM has a visible native viewer and that viewer is the genuinely key
   window.
4. The host is awake and the VM is running rather than paused.

Manager, hidden, closed, miniaturized, and headless windows are excluded. When
focus changes between viewers, MacVM revokes the old viewer before activating
the new one, and only one VM can be active. Focus changes, wake, resume, and
helper reconnects establish fresh host and guest baselines before monitoring;
they do not blindly copy stale text.

Disabling synchronization takes effect in memory before its metadata update, so
a disk-write failure cannot leave synchronization active. Explicit one-shot
actions remain available while automatic synchronization is off.

## Security and privacy

The helper connects to the host on fixed virtio-socket port `42042`; it does not
open a guest TCP listener. Each VM has an independent random 32-byte pairing key:

- Host: `<bundle>/Secrets/clipboard-pairing.key`
- Guest: `~/Library/Application Support/MacVM/Clipboard/pairing.key`

Directories and files are restricted to owner-only mode (`0700` and `0600`). A
mutually authenticated HMAC-SHA256 handshake binds the VM UUID, negotiated
protocol version, helper/host builds, and fresh host and guest nonces. Session frame authentication binds the
transfer direction and a strictly increasing sequence, preventing cross-VM use,
replay, and reordering. Frames are bounded before allocation and
only strict UTF-8 plain text up to exactly 1 MiB is accepted.

Normal VM startup never silently replaces a missing or corrupt persistent key.
Run the explicit install command to repair pairing. Cloning excludes `Secrets`,
disables automatic synchronization, and generates a fresh host pairing key, so
a clone cannot authenticate with the source VM's guest key.

Clipboard contents are sensitive. Enabling automatic synchronization allows the
active key viewer to read changing plain text from both host and guest
pasteboards. Keep the preference disabled when that behavior is not wanted.

## Troubleshooting

### Helper unavailable or disconnected

Confirm the VM is running in `MacVM.app`, a user is logged into the guest, and
the helper is installed:

```bash
macvm clipboard install dev-01
```

Inside the guest, inspect:

```bash
launchctl print gui/$(id -u)/dev.macvm.clipboard-guest
log show --last 10m --predicate 'process == "macvm-clipboard-guest"'
tail -100 ~/Library/Logs/MacVM/clipboard-helper.log
```

A helper installed while no Aqua session was present starts at the next GUI
login. If a helper-unavailable one-shot transfer also fails, the guest's RFB
clipboard bridge is likely unsupported or inactive; reinstall/start the helper
rather than relying on VNC fallback.

### Unpaired or authentication failed

The host or guest pairing key is missing, malformed, or does not match. Re-run
`macvm clipboard install <vm>` while the VM is running. Runtime startup will not
rotate the key automatically because doing so could silently invalidate an
otherwise recoverable guest installation.

### Incompatible helper

Upgrade both the MacVM app/CLI and the guest helper, then reinstall:

```bash
macvm clipboard install dev-01
```

### Automatic sync is inactive

Bring the native viewer to the front and make sure it is not hidden or
miniaturized. The manager window and `run --headless` intentionally cannot
activate synchronization. Attaching a native viewer to a headless VM enables it
only after that viewer actually becomes key.

### Text is rejected

Only strict UTF-8 plain text up to 1 MiB is supported. Files, images, rich text,
and oversized text are not synchronized. Validation errors intentionally do not
trigger VNC fallback.
