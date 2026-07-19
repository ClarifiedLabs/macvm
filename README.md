# MacVM

MacVM creates and runs macOS virtual machines on Apple silicon Macs.

It ships as a signed and notarized Mac app with:

- `MacVM`, a native SwiftUI app installed in `/Applications`
- `macvm`, its bundled command-line helper linked into Homebrew's bin directory or `/usr/local/bin`

MacVM uses Apple's Virtualization framework, creates each VM from a macOS restore image, and stores VMs as ordinary bundles on disk.

## Requirements

- Apple silicon Mac
- macOS 26 or newer
- Enough free disk space for the guest OS and VM disk
- Internet access while enabling Docker (Fedora CoreOS, Docker CLI, and Compose are checksum-verified before use)
- Optional: Rosetta for Linux for `linux/amd64` containers; MacVM only installs it after an explicit CLI or app action

MacVM can fetch the latest macOS restore image supported by your host. You can also pass a local `.ipsw` restore image.

## Install

Install with Homebrew:

```bash
brew install --cask clarifiedlabs/tap/macvm
```

Homebrew installs `MacVM.app` in its configured app directory (normally
`/Applications`) and manages the `macvm` link in `$(brew --prefix)/bin`.

To use the optional provisioning profiles, install Ansible on the host:

```bash
brew install ansible
```

Alternatively, download the latest `MacVM-<version>.pkg` from GitHub Releases, open it, and complete the installer. The `.dmg` release artifact is the app image consumed by the Homebrew cask.

The manual package installs:

```text
/Applications/MacVM.app
/Applications/MacVM.app/Contents/Helpers/macvm
/usr/local/bin/macvm -> ../../../Applications/MacVM.app/Contents/Helpers/macvm
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

VMs are stored under `~/VirtualMachines/MacVMHost` by default. Change the shared app/CLI default in **MacVM > Settings** or from the CLI:

```bash
macvm config
macvm config set-root ~/VirtualMachines/MyMacVMs
macvm config reset-root
```

A command-specific `--root` still overrides the shared setting.

## Clone a VM

After configuring a VM with the accounts and tools you want, stop it and clone
it instead of installing macOS again:

```bash
macvm shutdown dev-01
macvm clone dev-01 --name dev-02 --cpu 4 --memory-gi-b 8
macvm run dev-02
```

The `--cpu` and `--memory-gi-b` options can be used independently. Omit either
option to inherit that value from the source VM. The MacVM app exposes the same
controls in its clone sheet.

On APFS, macvm uses copy-on-write clones for the installed disk and other
files, so the initial clone is fast and shares unchanged storage blocks. Other
filesystems fall back to ordinary copies. Leave enough free space for both VMs
to diverge over time.

The clone inherits the guest accounts, tools, hostname, machine identifier,
SSH state, any VM sizing that was not overridden, setup metadata, and shared
files. It receives a new macvm UUID, creation date, and MAC address. Runtime
session files and launch on boot are not copied. The source must remain stopped
for the duration of the clone, and Apple Account services may require
reauthentication.

If Docker is enabled, the clone also copies the complete sidecar appliance — its
Fedora CoreOS state, Docker images/layers, containers, volumes, data disk, EFI
state, and pairing configuration. MacVM refreshes the sidecar's generic machine
identity and NAT MAC address so source and clone can run concurrently. APFS
copy-on-write behavior applies to these disks too.

## Docker inside the macOS guest

Apple-silicon macOS guests cannot run Docker's Linux VM nested inside MacVM.
MacVM can instead create one hidden Fedora CoreOS **aarch64 AppleHV** sidecar
for each macOS VM. The app owns both VMs as one lifecycle; the
Linux sidecar is never listed, attached, run, stopped, or removed independently.

Creation-time setup is the simplest path:

```bash
macvm create --name docker-dev --docker
# --docker implies --setup and performs a clean shutdown before appliance creation
macvm run docker-dev
```

Existing SSH-ready VMs can enable it while stopped:

```bash
macvm docker enable docker-dev
macvm docker status docker-dev
macvm docker configure docker-dev --cpu 4 --memory-gi-b 8 --disk-gi-b 128
macvm docker update docker-dev             # updates FCOS, preserves Docker state
macvm docker disable docker-dev            # preserves all sidecar data
macvm docker reset docker-dev              # destructive; asks for confirmation
```

Defaults are 2 vCPUs, 4 GiB RAM, a sparse 64 GiB Docker data disk, and
`linux/amd64` support requested. Disk configuration can grow but not shrink;
use the destructive reset operation for a smaller fresh disk. Settings can only
change while the macOS VM is stopped. Install Rosetta for Linux explicitly when
needed:

```bash
macvm docker configure docker-dev --amd64 --install-rosetta
# or: macvm docker enable docker-dev --install-rosetta
```

On first normal start, MacVM installs checksum-pinned arm64 Docker CLI and
Compose binaries plus its separately signed guest helper, which has no
Virtualization.framework entitlement.
`/var/run/docker.sock` belongs to a
dedicated `docker` group containing the setup account. The helper reaches Moby
through a per-VM SSH local forward; Docker TCP is never exposed on either VM
NIC. The VMs share a retained datagram socketpair as a private Ethernet segment,
while the Linux appliance has its own NAT NIC for image pulls. Automatic Fedora
CoreOS reboots are disabled so mounts cannot disappear beneath restart-policy
containers. Use `macvm docker update` while the macOS VM is stopped to replace
the Fedora CoreOS system appliance while preserving its machine identity and
the separate `/var/lib/docker` data disk. The update is staged with APFS
copy-on-write clones when available and atomically replaces the old appliance;
`macvm docker reset` remains the destructive way to create a completely fresh
Docker data disk.

MacVM automatically checks Fedora's stable stream before creating, resetting,
or updating an appliance. A successfully refreshed image is recorded as the
verified current cache entry. If the host is offline, MacVM verifies and uses
that cached image instead. Cache management is available independently of any
VM:

```bash
macvm docker image status
macvm docker image refresh                 # requires network access
macvm docker image auto-refresh off        # use only the verified cache
macvm docker image auto-refresh on         # default; offline fallback remains enabled
```

With automatic refresh disabled, creation, reset, and update require an
existing verified cache entry. Run the explicit refresh once while connected
before taking the host offline.

Bind sources are paths in the **macOS guest**, exactly as written in ordinary
Docker syntax:

```bash
macvm ssh docker-dev
docker run --rm -v "$PWD:/work" -w /work alpine ls
docker run --rm --mount type=bind,src=/private/tmp,dst=/tmp alpine ls /tmp
```

A schema-aware Docker API proxy rewrites supported bind fields to narrowly scoped
mounts under `/run/macvm-macos`. It exposes only each requested source subtree
over an SSHFS connection carried by the isolated reverse SSH tunnel, including
mounted paths under `/Volumes`. Persisted
mappings are remounted after helper or sidecar reconnects. It does not blindly
replace strings in arbitrary JSON. Container-published IPv4 TCP and UDP ports
are relayed inside the macOS guest and follow running container lifecycle;
IPv6-only and ambiguous same-port/multi-address publications are reported as
unsupported rather than exposed incorrectly.

Recovery boots skip the sidecar. A synchronous sidecar configuration or lock
failure aborts sidecar startup; a later readiness or guest-helper failure leaves
macOS running and is reported as a degraded Docker status. `disable` preserves data;
`reset` destroys Docker images, containers, and volumes. Removing the owner
bundle removes the nested sidecar automatically.

## MacVM App

Open `MacVM` from `/Applications` for a graphical VM manager. It can create and clone VMs, list existing VMs, own multiple running VMs, run setup, manage restore images, and track Xcode `.xip` archives used for guest provisioning. `macvm run`, `macvm run --headless`, `macvm attach`, and `macvm stop` are control commands for this same app process. Closing a VM display hides it without stopping the VM; use **Attach** to restore it. Use the Clone button or a stopped VM's sidebar context menu to create a copy.

Because MacVM owns ordinary running VMs in-process, quitting or crashing the app affects every VM it currently owns. Headless handoff also requires a logged-in macOS GUI session.

## Automated Setup

MacVM can drive a fresh macOS install to an SSH-ready state:

Automated setup is tested and supported for macOS 15, 26, and 27 guests. macOS 27 hosts prefer Virtualization.framework's native first-boot guest provisioning; macOS 15 and 26 guests use versioned OCR flows. Other Virtualization.framework-compatible releases can still be installed and run with Setup Assistant completed manually. An explicit `--script` or per-VM `Setup/steps.json` opts into custom VNC automation for an otherwise unsupported release.

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

Every running VM owner publishes a temporary password-protected VNC session. Closing a native display window leaves its VM running. Use **Attach** in MacVM or `macvm attach` to show a native window; a VM started with `--headless` gets its first native display lazily without restarting:

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

`macvm attach` asks MacVM to show its native display. Use `macvm vnc` when you want the live `vnc://` URL or macOS Screen Sharing instead. The private VNC server binds beyond loopback and uses a random password embedded in that URL. Treat the session as reachable from your local network while the VM is running.

## Launch On Boot

Launch a VM headless when your macOS user logs in:

```bash
macvm create --name dev-03 --launch-on-boot
macvm autostart enable dev-02
```

Launch-on-boot is per user and starts at login, not before login. It uses the same MacVM-owned headless/VNC path as `macvm run --headless`. The first login after enabling it may ask for Local Network access; allow MacVM so the guest can use its virtual network. You can change this later in **System Settings > Privacy & Security > Local Network**.

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
