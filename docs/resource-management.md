# Resource Management

The memory configured for a VM is its maximum, not a reservation that MacVM
always keeps assigned. MacVM adds a virtio memory-balloon device to macOS guests
and Docker appliances so it can ask them to return unused memory when the host
reports memory pressure.

## Pressure Targets

MacVM monitors the host's normal, warning, and critical memory-pressure events.
It requests the following target from every VM owned by the current process:

| Host pressure | Requested guest memory |
| --- | --- |
| Normal | Configured maximum |
| Warning | 75% of the configured maximum |
| Critical | 50% of the configured maximum |

Targets do not fall below 4 GiB for a macOS guest or 2 GiB for a Docker
appliance. If a VM's configured maximum is below its guest-type floor, MacVM
does not request a target below that configured maximum. Targets are aligned
down to whole MiB values.

Virtualization.framework exposes the requested balloon target but does not
report how many pages the guest actually releases. MacVM therefore tracks the
requested target, and the guest may return less memory than requested.

A VM that starts while the host is already under warning or critical pressure
immediately receives the current reduced target.

## Recovery

When host pressure returns to normal, MacVM waits 30 seconds before beginning
recovery. It then restores at most 1 GiB to one reduced VM every 10 seconds,
rotating round-robin across all reduced macOS guests and Docker appliances owned
by the process. Recovery stops when every VM reaches its configured maximum.

New warning or critical pressure cancels the cooldown or recovery timer and
immediately applies any further reduction. MacVM does not begin restoring memory
while pressure remains elevated. Stopping a VM removes it from the recovery
rotation.

## Operational Guidance

- Size a VM for its expected peak workload; the configured value remains its
  upper limit after pressure clears.
- Treat reclamation as best-effort because the guest controls how many pages it
  returns.
- Docker appliance memory is managed independently from its owning macOS VM and
  uses the lower 2 GiB floor.
- Sustained host pressure can keep guests at their reduced target until macOS
  reports normal pressure again.

The implementation is centralized in a process-local
`MemoryPressureCoordinator`. App-owned guests share the app's coordinator, and
the dedicated setup runner registers its VM with the coordinator in the CLI
process. Contributor invariants are documented in the
[Development Guide](development.md#memory-pressure-invariants).
