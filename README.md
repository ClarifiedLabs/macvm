# MacVM

MacVM creates and runs macOS virtual machines on Apple silicon Macs.

It ships as a signed and notarized installer package with:

- `macvm`, a command-line tool installed at `/usr/local/bin/macvm`
- `MacVM`, a native SwiftUI app installed in `/Applications`

MacVM uses Apple's Virtualization framework, creates each VM from a macOS restore image, and stores VMs as ordinary bundles on disk.

## Requirements

- Apple silicon Mac
- macOS 26 or newer
- Enough free disk space for the guest OS and VM disk

MacVM can fetch the latest macOS restore image supported by your host. You can also pass a local `.ipsw` restore image.

## Install

Install with Homebrew:

```bash
brew install --cask clarifiedlabs/tap/macvm
```

To use the optional provisioning profiles, install Ansible on the host:

```bash
brew install ansible
```

Alternatively, download the latest `MacVM-<version>.pkg` from GitHub Releases, open it, and complete the installer.

The package installs:

```text
/usr/local/bin/macvm
/usr/local/bin/macvm_MacVMHostKit.bundle
/Applications/MacVM.app
```

The installer marks the app bundle as non-relocatable so PackageKit always
installs it at `/Applications/MacVM.app`, even when another build with
the same bundle identifier exists elsewhere on the host.

If `/usr/local/bin` is not on your shell `PATH`, add it before running the CLI.

## Quick Start

Create and boot a VM:

```bash
macvm create --name dev-01
macvm run dev-01
```

Create a larger VM:

```bash
macvm create --name xcode-01 --cpu 6 --memory-gi-b 12 --disk-gi-b 200
```

Use a restore image you already downloaded:

```bash
macvm create --name test-01 --ipsw ~/Downloads/UniversalMac_latest_Restore.ipsw
```

Manage VMs:

```bash
macvm --version
macvm list
macvm show dev-01
macvm attach dev-01
macvm autostart enable dev-01
macvm autostart status dev-01
macvm autostart disable dev-01
macvm shutdown dev-01
macvm stop dev-01
macvm rm dev-01
```

VMs are stored under `~/VirtualMachines/MacVMHost` by default.

## Clone a VM

After configuring a VM with the accounts and tools you want, stop it and clone
it instead of installing macOS again:

```bash
macvm shutdown dev-01
macvm clone dev-01 --name dev-02
macvm run dev-02
```

On APFS, macvm uses copy-on-write clones for the installed disk and other
files, so the initial clone is fast and shares unchanged storage blocks. Other
filesystems fall back to ordinary copies. Leave enough free space for both VMs
to diverge over time.

The clone inherits the guest accounts, tools, hostname, machine identifier,
SSH state, VM sizing, setup metadata, and shared files. It receives a new
macvm UUID, creation date, and MAC address. Runtime session files and launch on
boot are not copied. The source must remain stopped for the duration of the
clone, and Apple Account services may require reauthentication.

## MacVM App

Open `MacVM` from `/Applications` for a graphical VM manager. It can create and clone VMs, list existing VMs, start viewer windows, run setup, manage restore images, and track Xcode `.xip` archives used for guest provisioning. Closing a VM display hides it without stopping the VM; use **Attach** to restore a Manager-owned native window or open another running owner in macOS Screen Sharing. Use the Clone button or a stopped VM's sidebar context menu to create a copy.

## Automated Setup

MacVM can drive a fresh macOS install to an SSH-ready state:

Automated setup is tested and supported for macOS 26 and 27 guests. macOS 27 hosts prefer Virtualization.framework's native first-boot guest provisioning; macOS 26 hosts use the versioned OCR flow. Other Virtualization.framework-compatible releases can still be installed and run with Setup Assistant completed manually. An explicit `--script` or per-VM `Setup/steps.json` opts into custom VNC automation for an otherwise unsupported release.

Installing a macOS beta guest can require the matching Xcode beta's first-launch components on the host, even when the standalone Device Support package is already installed. If Virtualization.framework reports that a software update is required, install or launch the matching Xcode, allow its additional components to finish, and retry with a fresh VM bundle.

```bash
macvm create --name dev-02 --ipsw ~/Downloads/UniversalMac_27.x_Restore.ipsw --setup
macvm ssh dev-02
macvm inventory dev-02 > dev-02.inventory
ansible -i dev-02.inventory all -m raw -a true
```

Setup uses native guest provisioning where available and otherwise uses a verified OCR policy with redacted decision traces under each VM bundle's `Setup/diagnostics/`. Contributors can run `make test-setup-e2e` to soak three fresh clones of one installed seed; set `MACVM_E2E_IPSW` to select the guest release explicitly.

By default setup creates an `admin` account with password `admin`. Override it when creating or setting up a VM:

```bash
macvm setup dev-02 --username developer --password 'secret' --shutdown-after
```

To install Xcode during setup, pass a local `.xip` archive:

```bash
macvm create --name xcode-02 --setup --xcode ~/Downloads/Xcode_26.3.xip
```

Apply one or more bundled provisioning profiles during creation:

```bash
macvm profiles list
macvm create --name dev-03 --profile go --profile python --profile codex
```

Profiles imply `--setup`. To provision an existing SSH-ready VM, start it and run:

```bash
macvm provision dev-03 --profile typescript --profile claude-code
```

Local profiles are discovered from `~/Library/Application Support/macvm/Profiles`,
`~/.config/macvm/profiles`, the VM root's `.profiles` directory, and a VM bundle's
`Setup/Profiles` directory. See [Provisioning Profiles](docs/provisioning.md) for
the manifest format, inputs, security model, GitHub runner example, and opt-in
real-VM smoke test.

## Display and VNC Access

Every running VM owner publishes a temporary password-protected VNC session. Closing a native viewer window leaves its VM running. Reopen the viewer from its Dock icon, use **Attach** in MacVM, or attach from the CLI:

```bash
macvm run dev-02
macvm attach dev-02
macvm vnc dev-02

macvm run dev-02 --headless
macvm attach dev-02
macvm vnc dev-02
macvm screenshot dev-02 -o shot.png
macvm wait-text dev-02 "Continue"
macvm click-text dev-02 "Continue"
macvm type dev-02 "hello"
macvm keys dev-02 return tab
```

`macvm attach` prints the live `vnc://` URL and opens it with the system handler; `macvm vnc` remains useful when you only want the URL. The private VNC server binds beyond loopback and uses a random password embedded in that URL. Treat the session as reachable from your local network while the VM is running.

## Launch On Boot

Launch a VM headless when your macOS user logs in:

```bash
macvm create --name dev-03 --launch-on-boot
macvm autostart enable dev-02
```

Launch-on-boot is per user and starts at login, not before login. It uses the same headless/VNC access path as `macvm run --headless`. The first login after enabling it may ask for Local Network access; allow `macvm` so the guest can use its virtual network. You can change this later in **System Settings > Privacy & Security > Local Network**.

## Shared Files

Each VM has a host-side `Shared/Transfers` folder that appears in the guest under:

```text
/Volumes/My Shared Files
```

For a VM named `dev-01`, the host path is:

```text
~/VirtualMachines/MacVMHost/dev-01.macvm/Shared/Transfers
```

## Notes

- iCloud sign-in must be completed interactively in the guest.
- Moving a VM to another Mac, or running clones of the same VM on the same Mac, can require iCloud reauthentication.
- Python-backed Ansible modules need a real Python interpreter in the guest. Install Command Line Tools or Xcode first.

## More Documentation

- [Automation details](docs/automation.md)
- [Development guide](docs/development.md)
- [Release process](docs/release.md)
