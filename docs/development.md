# Development

MacVM is an Xcode project for macOS virtualization. It is not SwiftPM-driven; do not use `swift test`.

## Project Layout

- `Sources/MacVMHostKit/`: core VM, automation, VNC, OCR, setup, networking, Docker sidecar, and shared helpers
- `Sources/MacVMDockerGuest/`: arm64 macOS guest daemon for Docker API bind mapping and published-port relays (SwiftNIO 2.86.0)
- `Sources/MacVMCLI/main.swift`: CLI entry point
- `Sources/MacVM/`: SwiftUI app
- `Sources/MacVMPrivateVZ/`: Objective-C runtime shim for private Virtualization.framework symbols
- `Tests/MacVMHostKitTests/` and `Tests/MacVMTests/`: Swift Testing tests
- `Sources/MacVMHostKit/Resources/Bootstrap/`: guest bootstrap resources
- `Support/macvm.entitlements`: virtualization entitlement used by CLI and app
- `scripts/package-release.sh`: Developer ID signing, notarization, disk-image creation, and installer packaging

## Build And Test

Use the pinned Swift toolchain from `.swift-version` and Xcode 26.

```bash
make test
make build
make build-cli
make build-app
make dist
make dist-cli
make dist-app
make package
```

`make build`, `make build-cli`, and `make build-app` produce locally signed Debug products in Xcode's derived data without running tests. `make test` runs the Xcode test suite. Bare `make` and `make dist` run tests and stage Release builds of both `dist/macvm` and `dist/MacVM.app` with the local Xcode signing configuration. Use `make dist-cli` or `make dist-app` to test and stage only one product. `make package` builds local unsigned `.dmg` and `.pkg` release artifacts for layout testing.

Public release artifacts are produced in GitHub Actions with Developer ID signing and notarization. Homebrew consumes the disk image; manual installations use the package.

## Signing

Local Debug and Release builds use ad-hoc signing with `Support/macvm.entitlements` so the CLI and app can use Virtualization.framework.

Public releases use `scripts/package-release.sh` with:

- Developer ID Application signing without virtualization entitlements for the bundled `macvm-docker-guest` payload
- Developer ID Application signing with virtualization entitlements for `/Applications/MacVM.app/Contents/Helpers/macvm`
- Developer ID Application signing for `/Applications/MacVM.app` after both nested executables
- Developer ID Application signing for `MacVM-<version>.dmg`
- Developer ID Installer signing for `MacVM-<version>.pkg`
- Apple notarization and stapling for both release artifacts

The Homebrew disk image contains `MacVM.app`. Its cask moves the app into Homebrew's configured app directory and links `MacVM.app/Contents/Helpers/macvm` into `$(brew --prefix)/bin`.

The manual package installs:

```text
/Applications/MacVM.app
/Applications/MacVM.app/Contents/Helpers/macvm
/Applications/MacVM.app/Contents/Resources/macvm_MacVMHostKit.bundle
/usr/local/bin/macvm -> ../../../Applications/MacVM.app/Contents/Helpers/macvm
```

The app target embeds the CLI with Code Sign On Copy. The HostKit resource build also embeds the separately built arm64 Docker guest helper. Release packaging signs the guest helper first (without the virtualization entitlement), the CLI second, and the outer app last. Both installation channels link the same CLI rather than copying another one, so the app and CLI cannot drift between versions.

## Versioning

The Xcode project owns the release version through `MARKETING_VERSION`.

- The CLI embeds an Info.plist section and exposes `macvm --version`.
- MacVM reads the same bundle metadata and shows the version in the sidebar footer.
- `tools/release.py` updates all three-part `MARKETING_VERSION` entries before creating a release tag.

## Runtime Ownership Invariants

`MacVM.app` owns every ordinary `run` and `run --headless` VM in-process. The CLI resolves the VM to a canonical full bundle path and uses the per-user file-backed control queue for acknowledged run, attach, and stop requests. `--headless` controls only the initial presentation: `attach` adds a `VZVirtualMachineView` to the existing VM without restarting it. Setup can still use its dedicated `HeadlessRunner` ownership path.

Because ordinary VMs share the app process, quitting or crashing MacVM affects
every VM it currently owns. Headless handoff to the app also requires a
logged-in macOS GUI session.

Every owner publishes a password-protected `Runtime/vnc-session.json`. VNC client automation commands such as `screenshot`, `type`, `keys`, `vnc`, `wait-text`, and `click-text` attach to that live session over loopback RFB and should error if no session is live; they do not instantiate a `VZVirtualMachine`, although the bundled CLI is still signed with the virtualization entitlement. The private server itself binds beyond loopback, so the password is mandatory. App runtimes use the `manager` owner role; never signal that PID to stop one VM. Route the request to the app and stop its path-keyed `VMViewerController` instead. Native display close requests always hide the window without ending the VM.

When `VMMetadata.dockerSidecar` is enabled, `VMViewerController` also owns a
`DockerSidecarRuntime` and one retained `DockerPairNetwork`. The sidecar starts
before the ordinary macOS start request and stops after macOS. Recovery never
starts it. Synchronous configuration, integrity, transaction-recovery, and lock
failures prevent the macOS start request; failures that occur later during
sidecar readiness or guest-helper integration can leave macOS running and publish
`Runtime/docker-sidecar.json` as degraded. Do not move this ownership into `HeadlessRunner` or
create a top-level managed VM for `DockerSidecar/`.

The nested bundle contains FCOS system/data disks, EFI and generic identities,
Ignition, and reset-stable pairing public material. FCOS stream metadata must
select `architectures.aarch64.artifacts.applehv.formats.raw.gz.disk` and verify
both compressed and uncompressed SHA-256 values. The guest helper is built as a
separate executable target, copied into the HostKit resource bundle, and
installed only after setup has produced an SSH-ready account.

The bind mapper is a Docker API and mount-namespace boundary: add endpoint-specific
JSON transforms for Docker API schema changes; never perform arbitrary textual
path replacement. Unknown endpoints and upgrade/hijack streams remain raw byte
relays. SSHFS mounts must remain constrained to `/run/macvm-macos/<filesystem-id>`,
the resolved requested source subtree, and the isolated `192.168.127.0/30`
sidecar link. Exact-file binds must use the isolated one-entry export and must
never widen to the source's parent directory. This namespace restriction is not
containment against compromised sidecar root, which owns the restricted SSHFS key.

Existing appliance replacement uses `renameatx_np(RENAME_SWAP)` and an external
journal. A committed replacement's journal must remain until parent metadata and
old-stage cleanup are complete; a completed rollback removes its journal before
best-effort candidate cleanup so interruption cannot manufacture ambiguity.
Startup, status, clone, and Docker mutation paths must recover a journal while
holding the stable sibling `.<bundle>.docker-sidecar.lock` inode, derived after
resolving bundle symlinks so aliases cannot bypass serialization. The lock remains
outside the removable bundle so a concurrent late operation cannot recreate
`Runtime/` around a different inode. Unsupported atomic exchange must fail closed
with the old appliance still canonical.

The helper must invalidate and restore persisted mounts and broker-owned port
rules after an SSH reconnect. Keep Zincati masked unless Docker startup is first
gated on successful host-side mount reconciliation; an autonomous FCOS reboot
must never let restart-policy containers write into empty `/run` mountpoints.

Real-guest release checks are required for:

- `$PWD`, `/Users/Shared`, `/private/tmp`, and a mounted path under `/Volumes`
  through both `-v` and `--mount`, including inspect reverse mapping
- reverse-tunneled SSHFS transport, symlinks, spaces, Unicode,
  read-only mounts, inotify/watch behavior, and large trees
- fixed/random IPv4 TCP and UDP publishing with loopback/all-interface semantics,
  multiple independent UDP clients, cleanup after container removal, and explicit
  rejection of unsupported IPv6-only or same-port/multi-address bindings
- native arm64 and `linux/amd64` images with Rosetta, including clear behavior
  when Rosetta is unavailable or not installed
- clone source/destination concurrent use, Docker engine ID refresh, recovery
  bypass, degraded startup, disable preservation, and destructive reset

## Clone Invariants

Cloning requires the source VM to remain stopped. APFS uses copy-on-write clones
for installed disks and other bundle files; filesystems without clone support
fall back to ordinary copies.

A clone inherits guest accounts and tools, hostname, machine identifier, SSH
state, setup metadata, shared files, and any CPU or memory value that was not
overridden. It receives a new MacVM UUID, creation date, and MAC address. Runtime
session files and launch-on-boot state are not copied.

For a Docker-enabled VM, cloning copies the complete nested appliance and then
refreshes its generic machine identity, Docker engine identity, and NAT MAC
address. Pairing state and Docker data remain usable while the new identities
allow source and clone to run concurrently.

## Memory Pressure Invariants

Every macOS and Docker VM configuration includes one traditional virtio memory
balloon. Register a VM with the process-local `MemoryPressureCoordinator` only
after it starts successfully, and unregister it on every stop or failure path.
The coordinator records requested targets because Virtualization.framework does
not report the amount of memory actually returned by a guest.

Keep target calculation independent from monitoring and timers so its pressure
levels, guest floors, cooldown, and round-robin recovery remain deterministic in
tests. The externally documented policy is in
[Resource Management](resource-management.md); update that guide whenever these
values or behaviors change.

All private Virtualization.framework symbols must stay isolated in `Sources/MacVMPrivateVZ/` and be resolved at runtime.
