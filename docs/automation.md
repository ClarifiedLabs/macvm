# Automation

MacVM can drive a fresh VM unattended and reach it over SSH so you can hand off to Ansible or other tooling.

## Setup Flow

`macvm run --headless` boots a VM without a window, records the owner PID under the bundle's `Runtime/`, and starts a VNC server so tools can attach. `macvm setup` uses the same headless machinery to take a fresh VM from first boot to an SSH-ready state with an Ansible inventory:

1. Boot headless and connect an in-process RFB client.
2. Drive Setup Assistant with OCR in a perceive → decide → act → verify loop: Vision reads the screen, a pure policy (`SetupPolicy`) picks the tactic for the modal or pane that is actually visible, the runner performs it, then re-reads the screen to check it actually changed. A tactic that did nothing escalates to the next rung of that pane's ladder instead of repeating.
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

These commands attach to a live `--headless` or `setup` session:

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

`_VZVNCServer` binds all interfaces, so each session uses a random password printed in the `vnc://` URL. Treat a headless VM as reachable from the LAN by anyone with that password.

## Setup Assistant Drift

Setup Assistant panes drift between macOS releases. The built-in flow keeps the first boot/language/region screens ordered, then uses the screenshot-driven policy through the rest of Setup Assistant. The policy covers the pane families used by macOS 12 Monterey, 13 Ventura, 14 Sonoma, 15 Sequoia, and 26 Tahoe, including both the older Migration Assistant-before-account path and the newer Transfer-before-Written-and-Spoken-Languages path.

How the policy stays safe and debuggable:

- **Modals win over panes.** Known confirmation sheets and error alerts (including a generic centered-"OK" detector) are dismissed before the pane behind them is driven — background buttons stay OCR-visible under a sheet, and clicking them is how runs used to wedge.
- **Every action is verified.** After a click or keystroke the runner re-OCRs and compares the screen; no visible change escalates to the pane's next tactic (alternate button, then keyboard chord where safe).
- **Panes with selectable rows are click-only.** On the Transfer pane a stray `space` selects a migration source and "Continue" then starts a migration, so those panes never receive blind keys and never fall back to generic "Continue"; an unrecognized layout fails loudly instead.
- **Stuck runs fail with a reason** — ladder exhausted, oscillating between panes, too many actions — plus a `stuck-<pane>.png`/`.txt` pair under `<vm>.macvm/Setup/screenshots/`. The `.txt` is the exact Vision dump, and it is also the test fixture format: copy it into `Tests/MacVMHostKitTests/Fixtures/` and assert the expected decision to turn a field failure into a regression test.
- **Display sleep is handled, not trusted.** An asleep guest serves a blank point-sized framebuffer, and input sent to it is consumed as a wake event. Captures retry until a non-blank frame arrives, a blank frame is never judged as "the screen changed", and every tactic wakes the display immediately before acting.
- **Slow transitions are waited out, not escalated into failures.** Setup Assistant's last pane hands off to a multi-second OS transition. When a pane has nothing left to try, the policy waits and re-perceives rather than re-clicking (a second click could skip the next pane); it declares the run stuck only after the screen stays byte-identical for several waits. A screen that is still changing resets that counter.

Maintainer trap: a query's `|` alternatives are **not** a preference order. `OCRService.find` picks the topmost/leftmost match across the whole alternation. Express preference as successive tactics in a pane's ladder, one query per rung.

Override the flow without rebuilding by dropping a `Setup/steps.json` into the bundle or passing `--script`.

## macOS 27 Native Provisioning

On macOS 27+ hosts and guests, `macvm setup` uses the public `VZMacGuestProvisioningOptions` API to create the account and enable SSH natively on first boot. It falls back to the VNC/OCR flow when native provisioning is unavailable.

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
