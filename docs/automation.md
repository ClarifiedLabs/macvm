# Automation

MacVM can drive a fresh VM unattended and reach it over SSH so you can hand off to Ansible or other tooling.

## Setup Flow

`macvm run --headless` boots a VM without a window, records the owner PID under the bundle's `Runtime/`, and starts a VNC server so tools can attach. `macvm setup` uses the same headless machinery to take a fresh VM from first boot to an SSH-ready state with an Ansible inventory:

1. Boot headless and connect an in-process RFB client.
2. Drive Setup Assistant with an OCR-anchored step flow. Vision reads the screen, then the client clicks buttons and types fields.
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

Setup Assistant panes drift between macOS releases. The built-in macOS 26 flow is empirically maintained against real guests. If Apple renames buttons or reorders panes, `macvm setup` dumps screenshots to:

```text
<vm>.macvm/Setup/screenshots/
```

Override the flow without rebuilding by dropping a `Setup/steps.json` into the bundle or passing `--script`.

## macOS 27 Native Provisioning

On macOS 27+ hosts and guests, `macvm setup` uses the public `VZMacGuestProvisioningOptions` API to create the account and enable SSH natively on first boot. It falls back to the VNC/OCR flow on macOS 26.

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
