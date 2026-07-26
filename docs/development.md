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

### Docker compatibility suite

Run the real-guest contract against a stopped, SSH-ready, Docker-ready seed:

```bash
make test-docker-e2e MACVM_DOCKER_E2E_SEED=docker-seed
```

The seed is never started or modified. The harness creates disposable
copy-on-write clones, uses the Debug CLI and app built from the current
checkout, and removes the clones only after a successful run. Failed clones are
retained with their names printed at exit. Quit any installed or older
`MacVM.app` before starting; the preflight refuses to hand test VMs to an app
from a different path.

The default `full` suite runs the black-box contract, Testcontainers for Go,
kind, and destructive lifecycle checks. A quicker `smoke` run omits the
ecosystem and lifecycle portions:

```bash
MACVM_DOCKER_E2E_SUITE=smoke \
  make test-docker-e2e MACVM_DOCKER_E2E_SEED=docker-seed
```

The host needs Python and Docker for the comparison run; `full` comparisons
also need Go, kind, and kubectl. The harness installs missing Python, Go, kind,
and kubectl tools only inside its disposable macOS clone. Use the baseline skip
below when those host-side comparison tools are intentionally unavailable.

By default, the same black-box contract first runs against the active host
Docker selection. `MACVM_DOCKER_E2E_BASELINE_CONTEXT=<context>` selects an
explicit Docker context; if it is omitted, `DOCKER_HOST`, `DOCKER_CONTEXT`, and
the current Docker context retain their normal meaning. Remote contexts still
exercise portable engine operations but skip host-path and local-socket
assertions. Baseline failures are diagnostic and never waive a MacVM contract
failure.

Useful controls are:

- `MACVM_E2E_ROOT=<directory>` when the seed is outside the default
  `~/VirtualMachines/MacVMHost`
- `MACVM_DOCKER_E2E_SKIP_BASELINE=1` when no traditional host Docker endpoint
  is available
- `MACVM_DOCKER_E2E_KEEP_VM=1` to retain successful disposable clones
- `MACVM_DOCKER_E2E_REQUIRE_AMD64=1` to make unavailable Rosetta/amd64 support a
  required-test failure
- `MACVM_DOCKER_E2E_TIMEOUT_SECONDS=<seconds>` to change the 15-minute sidecar
  and SSH readiness timeout
- `MACVM_DOCKER_E2E_ARTIFACTS=<directory>` to override the default
  `.build/docker-compat/<run-id>` report location

Each run writes per-test logs, raw TSV results, host and sidecar engine
metadata, TAP, JUnit XML, a JSON summary, and a Markdown comparison. Expected
failures live in `Tests/DockerCompatibility/xfail.tsv`: every entry needs a
stable tracking reference, an expected failure is reported as `XFAIL`, and an
unexpected pass is a failing `XPASS` until the stale entry is removed. Coverage
sources and licenses are recorded in
`Tests/DockerCompatibility/UPSTREAM.md`.

## Clone Invariants

Cloning requires the source VM to remain stopped. APFS uses copy-on-write clones
for installed disks and other bundle files; filesystems without clone support
fall back to ordinary copies.

A clone inherits guest accounts and tools, hostname, machine identifier, SSH
state, setup metadata, shared files, and any CPU or memory value that was not
overridden. It receives a new MacVM UUID, creation date, and MAC address. Runtime
session files and launch-on-boot state are not copied.

For a Docker-enabled VM, cloning provisions a fresh Fedora CoreOS system disk
and EFI state from the verified cached release, copies the Docker data disk and
pairing state, and refreshes the generic machine identity, Docker engine
identity, and NAT MAC address. Source and clone can then run concurrently
without rerunning Ignition against an already provisioned root filesystem.

## Memory Pressure Invariants

Every macOS VM configuration must contain zero memory-balloon devices. Do not
register macOS guests with `MemoryPressureCoordinator`: changing a macOS
balloon target under host pressure can deadlock the guest and its
Virtualization.framework worker.

Every Docker appliance configuration contains exactly one traditional virtio
memory balloon. Register only the Docker appliance with the process-local
`MemoryPressureCoordinator`, only after it starts successfully, and unregister
it on every stop or failure path. The coordinator records requested targets
because Virtualization.framework does not report the amount of memory actually
returned by a guest.

Keep target calculation independent from monitoring and timers so its pressure
levels, Docker floor, cooldown, and round-robin recovery remain deterministic
in tests. System-pressure monitoring is activated for every running macOS VM
even when no Docker sidecar exists so incident logs retain pressure transitions.
The externally documented policy and diagnostic predicates are in
[Resource Management](resource-management.md); update that guide whenever these
values or behaviors change.

All private Virtualization.framework symbols must stay isolated in `Sources/MacVMPrivateVZ/` and be resolved at runtime.
