# Resource Management

The memory configured for a macOS VM is the maximum exposed to that guest for
the full run. MacVM does not dynamically change a macOS guest's memory target.
In particular, macOS VM configurations do not include a virtio memory-balloon
device.

This is intentional. A pressure-triggered balloon request can leave both the
macOS guest and its Virtualization.framework worker unresponsive. Host pressure
is still monitored and logged, but the safe response is to size or stop VMs
rather than trying to reclaim their memory while they are running.

Docker appliances are Fedora CoreOS guests and retain dynamic ballooning. Their
memory is managed independently from the owning macOS VM.

## Docker Appliance Pressure Targets

MacVM monitors the host's normal, warning, and critical memory-pressure events.
It requests the following target from every running Docker appliance owned by
the current process:

| Host pressure | Requested Docker appliance memory |
| --- | --- |
| Normal | Configured maximum |
| Warning | 75% of the configured maximum |
| Critical | 50% of the configured maximum |

Targets do not fall below 2 GiB. If an appliance's configured maximum is below
that floor, MacVM does not request a target below its configured maximum.
Targets are aligned down to whole MiB values.

Virtualization.framework exposes the requested balloon target but does not
report how many pages the guest actually releases. MacVM therefore tracks the
requested target, and the guest may return less memory than requested.

An appliance that starts while the host is already under warning or critical
pressure immediately receives the current reduced target.

## Recovery

When host pressure returns to normal, MacVM waits 30 seconds before beginning
recovery. It then restores at most 1 GiB to one reduced Docker appliance every
10 seconds, rotating round-robin across all reduced appliances owned by the
process. Recovery stops when every appliance reaches its configured maximum.

New warning or critical pressure cancels the cooldown or recovery timer and
immediately applies any further reduction. MacVM does not begin restoring memory
while pressure remains elevated. Stopping an appliance removes it from the
recovery rotation.

## Diagnostics

MacVM writes low-volume, always-on unified logs for VM lifecycle transitions,
host pressure transitions, exact Docker balloon targets, and Docker sidecar
state. These do not require `--debug`.

```bash
log show --last 2h --style compact \
  --predicate 'subsystem == "dev.macvm.macvm"'
```

The categories are `vm-lifecycle`, `memory-pressure`, and `docker-sidecar`.
Configuration events include the bundle path, CPU count, configured memory
bytes, and balloon-device count. A macOS configuration must report
`balloonDeviceCount=0`.

The macOS guest helper for Docker also writes structured events to unified
logging and `/var/log/macvm-docker-guest.log`. From an SSH session in the guest:

```bash
sudo log show --last 2h --style compact \
  --predicate 'subsystem == "dev.macvm.macvm.docker-guest"'
sudo tail -200 /var/log/macvm-docker-guest.log
```

Published-port reconciliation records binding changes, first and periodic
failures, and a five-minute health summary. Expected OpenSSH
`setsockopt TCP_NODELAY` warnings from Unix-socket forwarding are collapsed into
periodic `ssh-stderr-filter` counters; other SSH stderr remains visible.

## Operational Guidance

- Leave enough physical memory for macOS and other host applications when
  sizing a macOS VM. MacVM will not shrink that VM after it starts.
- Reduce the configured VM memory or stop another VM if the host remains under
  pressure.
- Treat Docker appliance reclamation as best-effort because the guest controls
  how many pages it returns.
- Sustained host pressure can keep Docker appliances at their reduced target
  until macOS reports normal pressure again.

The Docker policy and monitoring are centralized in the process-local
`MemoryPressureCoordinator`. Contributor invariants are documented in the
[Development Guide](development.md#memory-pressure-invariants).
