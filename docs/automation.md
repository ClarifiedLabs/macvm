# Automation

MacVM can drive a fresh macOS 26 VM unattended and reach it over SSH so you can hand off to Ansible or other tooling. Other guest releases can be installed and completed manually, but have no registered built-in setup flow yet.

## Setup Flow

`macvm run --headless` boots a VM without a window, records the owner PID under the bundle's `Runtime/`, and starts a VNC server so tools can attach. `macvm setup` uses the same headless machinery to take a fresh VM from first boot to an SSH-ready state with an Ansible inventory:

1. Boot headless and connect an in-process RFB client.
2. Drive Setup Assistant with OCR in a perceive → decide → act → verify loop: Vision reads the screen, a pure policy (`SetupPolicy`) picks the tactic for the modal or pane that is actually visible, and one fresh RFB connection captures, acts, and verifies the result. A tactic that did nothing escalates to the next rung instead of repeating.
3. Create an admin account, defaulting to `admin` / `admin`.
4. Stage a provisioning script through the shared folder and run it in the guest.
5. Enable Remote Login, install a per-VM SSH key, grant passwordless sudo, enable auto-login, and disable sleep/screensaver.
6. Resolve the guest IP from `/var/db/dhcpd_leases` and wait for SSH.

Example:

```bash
macvm setup dev-03
macvm inventory dev-03 > dev-03.inventory
ansible -i dev-03.inventory all -m raw -a true
```

Python-based Ansible modules such as `ping` require a real Python interpreter in the guest. A bare macOS install exposes `/usr/bin/python3` as a Command Line Tools stub, so install Command Line Tools or Xcode first.

## VNC Automation Commands

These commands attach to the VNC session published by any live viewer, `--headless`, or `setup` owner:

```bash
macvm vnc dev-01
macvm screenshot dev-01 -o shot.png
macvm type dev-01 "hello"
macvm keys dev-01 return tab
macvm click dev-01 --x 960 --y 540
macvm wait-text dev-01 "Continue"
macvm click-text dev-01 "Continue"
```

Pasteboard commands move plain text:

```bash
printf 'hello' | macvm pbcopy dev-01
macvm pbpaste dev-01
macvm pbsync host dev-01
macvm pbsync dev-01 host
```

RFB has no request-current-pasteboard message. `pbpaste` and `pbsync <vm> host` wait for the next pasteboard update from the VM, so start the command first, then copy text inside the guest before the timeout.

## Private VNC API

There is no public API to inject input into a headless macOS guest. MacVM uses the private `_VZVNCServer` in Virtualization.framework through the isolated `MacVMPrivateVZ` target. The shim resolves the symbol at runtime with `NSClassFromString` and fails with a descriptive error if the private API is absent or changed.

`_VZVNCServer` binds all interfaces, so each session uses a random password printed in the `vnc://` URL. Treat every running VM as reachable from the LAN by anyone with that password.

## Setup Assistant Drift

Setup Assistant panes drift between macOS releases. MacVM records the installed guest's full macOS version and Apple build, then selects a registered setup plan from that guest identity. The only built-in flow currently tested and supported is `macos-26`. Other releases can be installed and completed manually, but automated setup fails before boot unless the user explicitly supplies `--script` or a per-VM `Setup/steps.json`.

Each plan composes reusable step fragments and a release-specific `SetupPolicy.RuleSet`. The capture, OCR, decision engine, input verification, safety caps, and diagnostics stay shared. Supporting another release requires registering its plan, composing only the fragments and pane rules verified for that release, adding recorded fixtures, and passing the real-guest setup soak.

How the policy stays safe and debuggable:

- **Modals win over panes.** Known confirmation sheets and error alerts (including a generic centered-"OK" detector) are dismissed before the pane behind them is driven — background buttons stay OCR-visible under a sheet, and clicking them is how runs used to wedge.
- **Every OCR action is one connection transaction.** The newest RFB connection wakes and captures the display, resolves text, sends pointer input, and captures verification without changing connections. A blank point-sized framebuffer can be retained for diagnostics but can never supply click coordinates. After a click or keystroke the runner re-OCRs and compares the screen; no visible change escalates to the pane's next tactic (alternate button, then keyboard chord where safe).
- **Account creation is an explicit operation.** Each field is captured, focused, cleared, and typed on one connection. Missing-information and password-mismatch alerts return to the form and refill visible empty fields with progressively slower typing, for at most three attempts. While "Creating account…" is visible, the runner only waits and reports elapsed time; account-field values such as `admin` are never treated as proof that the login window appeared. The Apple Account password-reset checkbox is left at the system default.
- **Preview rendering cannot steal setup input.** For app-owned setup, MacVM attaches a native read-only display to the in-process `VZVirtualMachine`; the optional Analyzed Frame view reads the runner's `Runtime/setup-preview.png`. Neither path opens a competing VNC client. Each action re-resolves and clicks on the same newest connection that verifies it.
- **Panes with selectable rows are click-only.** On the Transfer pane a stray `space` selects a migration source and "Continue" then starts a migration, so those panes never receive blind keys and never fall back to generic "Continue"; an unrecognized layout fails loudly instead.
- **Stuck runs fail with a reason** — ladder exhausted, oscillating between panes, too many actions — and a diagnostic path. Each `Setup/diagnostics/<run>/` contains a redacted `trace.jsonl` with per-connection `ServerInit`, `DesktopSize`, framebuffer, OCR action, and pointer geometry events. Failures also retain `summary.json`, anomalous and pinned OCR-action frames, and the rolling last 20 framebuffer PNG/OCR pairs. Successful runs discard the frames but keep the compact trace. Typing events record only field purpose, character count, and cadence; keysyms, VNC credentials, password text, and clipboard data are never emitted to the trace. The `.txt` files use the test-fixture format, so a field failure can become a regression test directly.
- **Display sleep is handled, not trusted.** An asleep guest serves a blank point-sized framebuffer, and input sent to it is consumed as a wake event. Captures retry until a non-blank frame arrives, a blank frame is never judged as "the screen changed", and every tactic wakes the display immediately before acting.
- **Slow transitions are waited out, not escalated into failures.** Setup Assistant's last pane hands off to a multi-second OS transition. When a pane has nothing left to try, the policy waits and re-perceives rather than re-clicking (a second click could skip the next pane); it declares the run stuck only after the screen stays byte-identical for several waits. A screen that is still changing resets that counter.

Maintainer trap: a query's `|` alternatives are **not** a preference order. `OCRService.find` picks the topmost/leftmost match across the whole alternation. Express preference as successive tactics in a pane's ladder, one query per rung.

Override the flow without rebuilding by dropping a `Setup/steps.json` into the bundle or passing `--script`. CLI overrides take precedence over bundle overrides, and either explicit override may opt an unsupported guest into VNC automation. Dispatcher steps in a custom flow use the current macOS 26 rule set; use explicit wait/click/type steps for behavior that differs on the target release.

## Local Setup Soak

The normal `make test` suite uses deterministic OCR and policy fixtures. Before a release or after setup-driver changes, run the macOS 26 real-guest soak on a virtualization-capable Mac:

```bash
make test-setup-e2e MACVM_E2E_IPSW=~/Downloads/UniversalMac_26.x_Restore.ipsw
```

The soak installs one pristine seed, creates three APFS clones, runs Setup Assistant sequentially on each clone, and requires SSH readiness. Successful clones are deleted; a failed clone and its diagnostics are retained. `MACVM_E2E_ITERATIONS`, `MACVM_E2E_ROOT`, `MACVM_E2E_KEEP_VM`, and `MACVM_E2E_SETUP_TIMEOUT_SECONDS` customize the run. After debugging a retained failed clone, set `MACVM_E2E_SEED` to the basename of an existing pristine seed under `MACVM_E2E_ROOT` to repeat the soak without reinstalling macOS; a reused seed is never deleted by the script.

## Future Native Provisioning

The runtime bridge for `VZMacGuestProvisioningOptions` is retained for a future versioned plan, but no currently supported setup plan selects it. In particular, macOS 27 can be installed and configured manually but is not accepted for automated setup until that path has been validated and registered.

## Bootstrap Script

The generated `bootstrap-tools.sh` script prepares a guest for common first-run setup tasks:

- install Homebrew if needed
- install `git`, `gh`, `jq`, and `gnu-tar`
- install a local `Xcode*.xip` from the shared `Transfers/` directory
- run `xcodebuild -runFirstLaunch`
- download the iOS simulator runtime with `xcodebuild -downloadPlatform iOS`

Run it inside the guest:

```bash
/Volumes/My\ Shared\ Files/Bootstrap/bootstrap-tools.sh --install-xcode --install-ios-simulator
```

For create-time provisioning, pass an Xcode `.xip` directly:

```bash
macvm create --setup --xcode ~/Downloads/Xcode_26.3.xip
```
