# Docker

MacVM can provide Docker inside an Apple-silicon macOS guest even though the
guest cannot run Docker's Linux VM through nested virtualization. It does this
with one hidden Fedora CoreOS **aarch64 AppleHV** appliance per macOS VM. The
MacVM app owns the macOS VM and its Docker appliance as one lifecycle; the
appliance is not listed, attached, started, stopped, or removed independently.

## Enable Docker

The simplest path is to enable Docker when creating the VM:

```bash
macvm create --name docker-dev --docker
macvm run docker-dev
```

`--docker` implies `--setup` and performs a clean shutdown before creating the
Docker appliance.

An existing VM must be SSH-ready and stopped before Docker can be enabled:

```bash
macvm docker enable docker-dev
macvm docker status docker-dev
```

Docker guest tooling requires Homebrew inside macOS. Automated setup installs
it by default. For another SSH-ready VM, install it while the VM is running,
then shut the VM down before enabling Docker:

```bash
macvm provision docker-dev --profile homebrew
macvm shutdown docker-dev --wait
macvm docker enable docker-dev
```

Enabling, resetting, and updating Docker may require network access to refresh
the Fedora CoreOS image cache. Docker CLI tools are installed on the next normal
VM start, which also requires network access unless Homebrew already has them
installed or cached.

## Configure and Maintain Docker

Docker defaults to 2 vCPUs, 4 GiB RAM, a sparse 64 GiB data disk, and
`linux/amd64` support requested. Settings can change only while the macOS VM is
stopped:

```bash
macvm docker configure docker-dev --cpu 4 --memory-gi-b 8 --disk-gi-b 128
macvm docker update docker-dev
macvm docker disable docker-dev
macvm docker reset docker-dev
```

Disk capacity can grow but cannot shrink. `reset` creates a fresh appliance at
the **currently recorded** resource settings; it accepts no CPU, memory, disk,
or amd64 overrides and therefore cannot be used to shrink the data disk. It
destroys all Docker images, containers, and volumes. To change supported
settings, use `configure` before reset; a smaller disk is not currently a
supported configuration change.

`disable` preserves the appliance, data, identities, and recorded settings. A
later re-enable uses the same appliance and data. However, the CLI `enable`
command applies the CPU, memory, disk, and amd64 values from that invocation,
including command defaults for omitted options. Repeat nondefault values when
re-enabling from the CLI; `configure`, by contrast, changes only the options you
supply.

Rosetta for Linux is never installed implicitly. The two controls are separate:
`--amd64` persists the request in this sidecar's settings, while
`--install-rosetta` only invokes Apple's host-wide Rosetta installation and may
show its consent dialog. It does not itself enable amd64 for a sidecar. Use it
with an amd64 request:

```bash
macvm docker configure docker-dev --amd64 --install-rosetta
# or: macvm docker enable docker-dev --install-rosetta
```

Once Rosetta is installed, amd64-requesting sidecars attach its host directory
share on future starts; disabling amd64 does not uninstall Rosetta. The CLI does
not expose `--install-rosetta` as a standalone setting-free configure action.

`macvm docker update` replaces the Fedora CoreOS system appliance while
preserving its machine identity and separate `/var/lib/docker` data disk.

## Image Cache and Offline Use

MacVM checks Fedora's stable stream before creating, resetting, or updating an
appliance. A successfully refreshed image becomes the verified current cache
entry. When the host is offline, MacVM verifies and uses that cached image.

Manage the cache independently of a VM:

```bash
macvm docker image status
macvm docker image refresh                 # requires network access
macvm docker image auto-refresh off        # use only the verified cache
macvm docker image auto-refresh on         # default; offline fallback remains enabled
```

With automatic refresh disabled, create, reset, and update operations require
an existing verified cache entry. Run an explicit refresh while connected
before taking the host offline.

## Bind Mounts and Published Ports

Bind sources are paths in the **macOS guest**, exactly as written in ordinary
Docker syntax:

```bash
macvm ssh docker-dev
docker run --rm -v "$PWD:/work" -w /work alpine ls
docker run --rm --mount type=bind,src=/private/tmp,dst=/tmp alpine ls /tmp
```

Supported bind fields are mapped to per-export paths under
`/run/macvm-macos`. The sidecar-native `/lib/modules` bind used by kind is
passed through to Fedora CoreOS instead. Each export has different capabilities:

| macOS guest source | Transport and scope | Capabilities and residual risk |
| --- | --- | --- |
| Directory | SSHFS rooted at the resolved requested directory | Containers receive the requested subtree with the Docker mount's read/write mode. Access is still limited by the setup user's macOS permissions. Symlinks and content inside that subtree remain guest-controlled. |
| Exact regular file | SSHFS over an isolated one-entry export | The parent directory is not exported. The setup user must be able to traverse to and access the file; the one entry follows its host-side symlink, so replacing the file or link changes what future access reaches. |
| Unix stream socket | One SSH stream-local relay and one sidecar-local socket | Connections forward byte streams to the exact canonical socket path. The socket must be connectable by the recorded setup user. The sidecar endpoint can reconnect while the mapping exists, but receives neither file descriptors nor peer credentials. |

Mounted paths under `/Volumes` are supported, and persisted mappings are
restored after the guest helper or appliance reconnects. FIFOs, devices,
datagram sockets, and sequenced-packet sockets are rejected. Socket relays also
do not carry file-descriptor passing or peer-credential propagation across the
VM boundary. Common Docker, BuildKit, SSH-agent, database, and service stream
sockets work when the setup user has access, including nested Docker clients
that bind `/var/run/docker.sock`.

The appliance root owns the restricted SSHFS and relay credentials. Per-export
scoping limits accidental exposure through the Docker-visible mount namespace;
it is **not containment** against a compromised appliance root, which may use
those credentials directly for the lifetime of the integration.

### Bind-mount file events

Host-created and host-modified files become visible through the bind mount, but
SSHFS does not carry macOS filesystem notifications into Linux. A process that
depends only on `inotify` may therefore miss changes made from the macOS side;
configure that process to poll the mounted tree. Container-originated changes
still generate Linux filesystem events normally. This known compatibility gap
is tracked by the `bind.inotify` entry in
`Tests/DockerCompatibility/xfail.tsv`.

Published IPv4 TCP and UDP ports are relayed inside the macOS guest and follow
the running container lifecycle. A successful container start is not returned
to the Docker client until its macOS relay is installed. IPv6-only publications
and ambiguous same-port/multiple-address publications are rejected instead of
being exposed incorrectly.

### Docker Swarm

MacVM rewrites bind mounts in Swarm service create and update task templates, so
both replicated and global service task modes use macOS guest paths on this
single sidecar node. IPv4 TCP and UDP service publications are relayed for both
Swarm's default `ingress` and `host` publish modes; they bind all macOS guest
interfaces, unlike container publications that may request loopback only.
Service inspect paths are translated back to macOS paths, while service log
streams pass through unchanged.

This is a single-node contract. Multi-node placement, per-node `host`-mode
semantics, overlay-network reachability from other nodes, and routing-mesh
behavior beyond the owning sidecar are not supported. Use a trusted disposable
VM when validating Swarm because initializing a manager changes persistent
Docker state.

The guest helper reads `/containers/json` through an in-process Unix-domain
HTTP client. It reconciles every two seconds as a fallback and immediately
after relevant Docker lifecycle requests, without launching a `curl` process
for each poll. Structured logs record binding changes, first and periodic
failures, and five-minute health summaries in
`/var/log/macvm-docker-guest.log`. Existing Docker-enabled VMs install this
helper revision automatically on their next normal start.

## Access the macOS Guest from Containers

Containers can use `host.docker.internal` to reach the owning macOS guest over
its private connection to the Docker sidecar. The name works on Docker's default
and user-defined networks, including from kind workloads through cluster DNS.
It refers to the macOS VM that owns the sidecar, not to the physical Mac host.

The macOS service must listen on all IPv4 interfaces or on the private Docker
interface. A service bound only to `127.0.0.1` is not reachable through
`host.docker.internal`. An explicit per-container DNS override can also bypass
MacVM's resolver.

After upgrading MacVM, apply this configuration to an existing sidecar while
the VM is stopped, then start the VM normally:

```bash
macvm docker update docker-dev
macvm run docker-dev
```

The update preserves Docker images, containers, volumes, and networks. Recreate
a long-lived default-bridge container if it retains an upstream-only
`/etc/resolv.conf` from before the update.

## Data Lifecycle and Cloning

Cloning a Docker-enabled VM creates a fresh Fedora CoreOS system disk and EFI
state from the source appliance's verified image release, while copying its
Docker images and layers, containers, volumes, data disk, and pairing
configuration. MacVM refreshes the appliance's generic machine identity,
standalone Moby engine identity, and NAT MAC address so the source and clone can
run concurrently. APFS copy-on-write behavior applies to the Docker data disk
and cached Fedora CoreOS image.

The lifecycle commands have these data effects:

- `disable` stops using Docker but preserves all appliance data.
- `update` replaces the Fedora CoreOS system while preserving Docker data.
- `reset` creates a fresh appliance and destroys Docker data after confirmation.
- `macvm rm` removes the owning VM bundle and its Docker appliance together.

Recovery boots skip the Docker appliance.

## Architecture and Failure Behavior

On the first normal start after Docker is enabled, MacVM uses Homebrew to
install `docker`, `docker-buildx`, and `docker-compose`, then installs its
separately signed guest helper. The helper has no Virtualization.framework
entitlement. MacVM adds `/opt/homebrew/lib/docker/cli-plugins` to the setup
account's `~/.docker/config.json` without replacing other Docker settings.
`/var/run/docker.sock` belongs to a dedicated `docker` group that contains the
setup account.

The helper reaches Moby through a per-VM SSH local forward; Docker TCP is not
exposed on either VM network interface. The two VMs share a retained datagram
socket pair as a private Ethernet segment, and the Linux appliance has a
separate NAT interface for image pulls. Both Moby's data root and containerd's
image and snapshot storage live on the configured Docker data disk. Bind mounts
use SSHFS over an isolated reverse SSH tunnel. A schema-aware Docker API proxy
transforms supported bind fields rather than replacing arbitrary strings in
JSON. It reconstructs only finite JSON bodies on
container create/inspect, service create/update/inspect, and local bind-volume
create/inspect endpoints. Mapped request or response bodies are limited to
16 MiB, and HTTP heads are limited to 64 KiB; oversize mapped requests fail with
an HTTP error. Mapped requests require `Content-Length` or chunked framing. Raw
chunk-size lines are limited to 8 KiB, trailer sections to 64 KiB, and data
queued before the backend connects to 256 KiB. Raw relay writes use 64 KiB and
256 KiB low/high watermarks for backpressure; these are buffering bounds, not a
256 KiB stream-size limit.

Unknown endpoints, non-mapped fields, service logs, and admitted Docker
hijack/upgrade streams are relayed without path translation. Upgrades require
matching request/response upgrade headers, and malformed or unsolicited
upgrades are rejected. A Docker API extension that puts a macOS path in another
schema field therefore remains sidecar-native until that field is explicitly
supported.

Automatic Fedora CoreOS reboots are disabled so mounts cannot disappear under
restart-policy containers. The helper restores persisted mounts and
host-managed port rules after a reconnect.

Appliance updates use APFS copy-on-write staging when available. The existing
appliance is committed with a Darwin atomic directory exchange and a recovery
journal. Startup, status, clone, and later Docker mutations complete an
interrupted commit or rollback. On a filesystem without atomic directory
exchange support, replacement fails without removing the old appliance.

A synchronous configuration, integrity, transaction-recovery, or locking
failure prevents the macOS VM start request. A later appliance-readiness or
guest-helper integration failure can leave macOS running and is reported by
`macvm docker status` as degraded.

Use `macvm docker status <vm> --json` for machine-readable state, logical and
allocated data-disk sizes, requested/available amd64 state, owner PID, and the
last runtime error. Status is observational during ordinary operation, but it
is not guaranteed to be filesystem-pure: if an interrupted replacement journal
exists, status takes the nonblocking per-VM Docker operation lock and completes
recovery before reporting. Mutations, startup, clone, and status recovery share
the stable sibling `.<bundle>.docker-sidecar.lock`; VM disk users separately
share `.<bundle>.disk.lock`, acquiring the disk lock first when both are needed.

Contributor-facing ownership, locking, recovery, security-boundary, and
real-guest test invariants are documented in the
[Development Guide](development.md#runtime-ownership-invariants).
