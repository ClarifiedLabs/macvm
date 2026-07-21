# MacVM

MacVM creates and runs macOS virtual machines on Apple silicon Macs.
It can also setup a sidecar docker VM for your macOS VM to enable the use of docker from within the macOS VM.

It ships as a signed and notarized Mac app with:

- `MacVM.app`, a native SwiftUI app installed in `/Applications/MacVM.app`
- `macvm`, its bundled CLI helper linked into Homebrew's bin directory or `/usr/local/bin`

MacVM uses Apple's Virtualization framework, creates each VM from a macOS restore image, and stores VMs as ordinary bundles on disk.

## Requirements

- Apple silicon Mac
- macOS 26 or newer
- Internet access during automated setup and when enabling, resetting, or updating Docker

MacVM can fetch the latest macOS restore image supported by your host. You can also pass a local `.ipsw` restore image.

## Install

Install with Homebrew:

```bash
brew install --cask clarifiedlabs/tap/macvm
```

Homebrew installs `MacVM.app` in its configured app directory (normally
`/Applications`) and links `macvm` into `$(brew --prefix)/bin`.

To use the optional provisioning profiles, install Ansible on the host:

```bash
brew install ansible
```

Alternatively, download the latest `MacVM-<version>.pkg` from GitHub Releases,
open it, and complete the installer. The package installs `MacVM.app` in
`/Applications` and links `macvm` into `/usr/local/bin`.

If `/usr/local/bin` is not on your shell `PATH`, add it before running the CLI.

## Quick Start

MacVM has a CLI tool, `macvm`, and a GUI, `MacVM.app`, with equivalent functionality.

### MacVM.app GUI

Open `MacVM.app`, click **New VM**, choose a name and VM settings, then click
**Create**. The default **Latest supported** restore image is downloaded
automatically, or you can choose a local `.ipsw`. When installation finishes,
select the VM and click **Run**.

### `macvm` CLI

```bash
macvm create --name dev-01
macvm run dev-01
```

Create a larger VM:

```bash
macvm create --name bigdev-01 --cpu 6 --memory-gi-b 12 --disk-gi-b 200
```

Configured memory is the VM's maximum. MacVM can reclaim unused guest memory
when the host is under pressure; see [Resource Management](docs/resource-management.md).

## Common CLI Usage

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
macvm shutdown dev-01 --wait
macvm stop dev-01
macvm rm dev-01
```

VMs are stored under `~/VirtualMachines/MacVMHost` by default. Change the shared
app/CLI default in **MacVM > Settings** or from the CLI:

```bash
macvm config
macvm config set-root ~/VirtualMachines/MyMacVMs
macvm config reset-root
```

A command-specific `--root` overrides the shared setting. Bare `shutdown`
returns after the guest accepts the request; add `--wait` (and optionally
`--timeout`) when the next operation requires a fully stopped VM. `stop` is a
force-stop operation and is not a substitute for a clean guest shutdown.

## Clone a VM

After configuring a VM with the accounts and tools you want, stop it and clone
it instead of installing macOS again:

```bash
macvm shutdown dev-01 --wait
macvm clone dev-01 --name dev-02 --cpu 4 --memory-gi-b 8
macvm run dev-02
```

The CPU and memory options are independent; omitted values are inherited from
the source VM. The source must remain stopped while cloning. APFS provides fast
copy-on-write clones, while other filesystems use ordinary copies. Leave enough
free space for the VMs to diverge, and expect Apple Account services to require
reauthentication in a clone.

## Docker Inside the macOS Guest

Add Docker support while creating a VM:

```bash
macvm create --name docker-dev --docker
macvm run docker-dev
```

`--docker` implies automated setup. For an existing SSH-ready VM, shut it down
before enabling or changing Docker:

```bash
macvm docker enable docker-dev
macvm docker status docker-dev
macvm docker configure docker-dev --cpu 4 --memory-gi-b 8 --disk-gi-b 128
macvm docker update docker-dev
macvm docker disable docker-dev
macvm docker reset docker-dev
```

Automated setup installs the required Homebrew dependency. For another
SSH-ready VM, run `macvm provision docker-dev --profile homebrew` while it is
running before enabling Docker. Docker defaults to 2 vCPUs, 4 GiB RAM, and a
sparse 64 GiB data disk. Disk capacity can grow but cannot shrink; `reset`
destroys Docker images, containers, and volumes.

Install Rosetta for Linux explicitly when `linux/amd64` containers need it:

```bash
macvm docker configure docker-dev --amd64 --install-rosetta
```

Inside the guest, use ordinary Docker commands and macOS guest paths for bind
mount sources:

```bash
macvm ssh docker-dev
docker run --rm -v "$PWD:/work" -w /work alpine ls
```

See [Docker](docs/docker.md) for image caching, offline use, bind mounts,
published-port support, data lifecycle, troubleshooting, and architecture.

## Automated Setup

MacVM can drive a fresh macOS install to an SSH-ready state. Automated setup is
tested and supported for macOS 15, 26, and 27 guests. Other compatible releases
can be installed and completed manually.

```bash
macvm create --name dev-02 --ipsw ~/Downloads/UniversalMac_27.x_Restore.ipsw --setup
macvm ssh dev-02
macvm inventory dev-02 > dev-02.inventory
ansible -i dev-02.inventory all -m raw -a true
```

Setup starts the completed VM through `MacVM.app` by default. Pass
`--shutdown-after` to leave it stopped instead. The default account is
`admin` / `admin`; override it when creating or setting up a VM:

```bash
macvm setup dev-02 --username developer --password 'secret' --shutdown-after
```

Setup installs Homebrew by default. Use `--no-homebrew` for an offline or
minimal guest. Docker setup requires Homebrew.

Install Xcode during setup by passing a local `.xip` archive:

```bash
macvm create --name xcode-02 --setup --xcode ~/Downloads/Xcode_26.3.xip
```

Apply bundled provisioning profiles during creation:

```bash
macvm profiles list
macvm create --name dev-03 --profile go --profile python --profile codex
```

Profiles imply `--setup`. To provision an existing SSH-ready VM, start it and run:

```bash
macvm provision dev-03 --profile typescript --profile claude-code
```

See [Automation](docs/automation.md) for setup support and troubleshooting, and
[Provisioning Profiles](docs/provisioning.md) for profile discovery, formats,
inputs, and security.

## Display and VNC Access

Closing a native display window leaves its VM running. Use **Attach** in MacVM
or `macvm attach` to show it again. A headless VM can gain its first native
display without restarting:

```bash
macvm run dev-02
macvm attach dev-02

macvm run dev-02 --headless
macvm attach dev-02
macvm vnc --open dev-02
macvm screenshot dev-02 -o shot.png
macvm wait-text dev-02 "Continue"
macvm click-text dev-02 "Continue"
macvm type dev-02 "hello"
macvm keys dev-02 return tab
```

Bare `macvm vnc <vm>` prints the live `vnc://` URL; `macvm vnc --open <vm>`
opens it in macOS Screen Sharing. VNC sessions use temporary credentials and
may be reachable from the local network, so treat the URL as a secret.

Native attached display windows include two pasteboard buttons in the right
side of the title bar. **Paste to VM** sends the current plain-text host
pasteboard to the guest. **Copy from VM** waits for the next plain-text copy in
the guest and writes it to the host pasteboard.

## Launch on Boot

Launch a VM headless when your macOS user logs in:

```bash
macvm create --name dev-03 --launch-on-boot
macvm autostart enable dev-02
```

Launch-on-boot is per user and starts at login, not before login. The first
login after enabling it may ask for Local Network access; allow MacVM so the
guest can use its virtual network. You can change this later in **System
Settings > Privacy & Security > Local Network**.

## Shared Files

Each VM's host-side `Shared` directory is mounted in the guest at:

```text
/Volumes/My Shared Files
```

For a VM named `dev-01`, the host and guest transfer paths are:

```text
~/VirtualMachines/MacVMHost/dev-01.macvm/Shared/Transfers
/Volumes/My Shared Files/Transfers
```

VMs created with `--no-bootstrap` do not attach this share automatically.

## Notes

- iCloud sign-in must be completed interactively in the guest.
- Moving or cloning a VM can require iCloud reauthentication.

## More Documentation

- [Docker](docs/docker.md)
- [Resource management](docs/resource-management.md)
- [Automation](docs/automation.md)
- [Provisioning profiles](docs/provisioning.md)
- [Development guide](docs/development.md)
- [Release process](docs/release.md)
