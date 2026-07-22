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

Disk capacity can grow but cannot shrink. Use `reset` to create a smaller fresh
disk; this destroys all Docker images, containers, and volumes. `disable`
preserves the appliance and its data.

Rosetta for Linux is never installed implicitly. Request it when
`linux/amd64` containers need it:

```bash
macvm docker configure docker-dev --amd64 --install-rosetta
# or: macvm docker enable docker-dev --install-rosetta
```

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

Supported bind fields are mapped to narrowly scoped mounts under
`/run/macvm-macos`. A directory bind exposes the requested subtree. An exact
file bind uses an isolated one-entry export rather than exposing the file's
parent directory. Mounted paths under `/Volumes` are supported, and persisted
mappings are restored after the guest helper or appliance reconnects.

Unix stream socket bind sources use an SSH stream-local relay instead of
SSHFS. The container receives a sidecar-local socket whose connections are
forwarded to the original socket in the macOS guest. This supports common
Docker, BuildKit, SSH-agent, database, and service sockets, including nested
Docker clients that bind `/var/run/docker.sock`. Datagram and sequenced-packet
sockets, file-descriptor passing, and peer-credential propagation are not
supported across the VM boundary.

This Docker-visible scoping is not containment against a compromised appliance
root, which owns the restricted SSHFS credential.

Published IPv4 TCP and UDP ports are relayed inside the macOS guest and follow
the running container lifecycle. IPv6-only publications and ambiguous
same-port/multiple-address publications are rejected instead of being exposed
incorrectly.

## Data Lifecycle and Cloning

Cloning a Docker-enabled VM copies its complete appliance, including Fedora
CoreOS state, Docker images and layers, containers, volumes, data disk, EFI
state, and pairing configuration. MacVM refreshes the appliance's generic
machine identity and NAT MAC address so the source and clone can run
concurrently. APFS copy-on-write behavior applies to the Docker disks.

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
separate NAT interface for image pulls. Bind mounts use SSHFS over an isolated
reverse SSH tunnel. A schema-aware Docker API proxy transforms supported bind
fields rather than replacing arbitrary strings in JSON.

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

Contributor-facing ownership, locking, recovery, security-boundary, and
real-guest test invariants are documented in the
[Development Guide](development.md#runtime-ownership-invariants).
