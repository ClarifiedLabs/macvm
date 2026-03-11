# MacVM

MacVM creates and runs macOS virtual machines on Apple silicon Macs.

It ships as a signed and notarized installer package with:

- `macvm`, a command-line tool installed at `/usr/local/bin/macvm`
- `MacVM Manager`, a native SwiftUI app installed in `/Applications`

MacVM uses Apple's Virtualization framework, creates each VM from a macOS restore image, and stores VMs as ordinary bundles on disk.

## Requirements

- Apple silicon Mac
- macOS 26 or newer
- Enough free disk space for the guest OS and VM disk

MacVM can fetch the latest macOS restore image supported by your host. You can also pass a local `.ipsw` restore image.

## Install

Download the latest `MacVM-<version>.pkg` from GitHub Releases, open it, and complete the installer.

The package installs:

```text
/usr/local/bin/macvm
/usr/local/bin/macvm_MacVMHostKit.bundle
/Applications/MacVM Manager.app
```

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
macvm shutdown dev-01
macvm stop dev-01
macvm rm dev-01
```

VMs are stored under `~/VirtualMachines/MacVMHost` by default.

## MacVM Manager

Open `MacVM Manager` from `/Applications` for a graphical VM manager. It can create VMs, list existing VMs, start viewer windows, run setup, manage restore images, and track Xcode `.xip` archives used for guest provisioning.

## Automated Setup

MacVM can drive a fresh macOS install to an SSH-ready state:

```bash
macvm create --name dev-02 --setup
macvm ssh dev-02
macvm inventory dev-02 > dev-02.inventory
ansible -i dev-02.inventory all -m raw -a true
```

By default setup creates an `admin` account with password `admin`. Override it when creating or setting up a VM:

```bash
macvm setup dev-02 --username developer --password 'secret' --shutdown-after
```

To install Xcode during setup, pass a local `.xip` archive:

```bash
macvm create --name xcode-02 --setup --xcode ~/Downloads/Xcode_26.3.xip
```

## Headless Access

Headless runs publish a temporary VNC session so automation commands can attach:

```bash
macvm run dev-02 --headless
macvm vnc dev-02
macvm screenshot dev-02 -o shot.png
macvm wait-text dev-02 "Continue"
macvm click-text dev-02 "Continue"
macvm type dev-02 "hello"
macvm keys dev-02 return tab
```

Headless VNC uses a random password printed in the `vnc://` URL. Treat it as reachable from your local network while the VM is running.

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
