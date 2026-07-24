# Docker compatibility test provenance

This suite is an independent compatibility contract. It borrows test *shapes*
and coverage ideas from established open-source projects, but does not copy
their harnesses or assertions wholesale. That keeps the contract runnable
against both MacVM and a normal macOS Docker endpoint.

| Project | What this suite borrows | Why it is not imported directly | License |
| --- | --- | --- | --- |
| [runfinch/common-tests](https://github.com/runfinch/common-tests) | CLI lifecycle, build, Compose, networking, volumes, and architecture coverage | Its assertions and cleanup target Finch/nerdctl behavior and are intentionally destructive to the selected engine | Apache-2.0 |
| [Rancher Desktop BATS tests](https://github.com/rancher-sandbox/rancher-desktop/tree/main/bats/tests) | macOS bind-mount locations, TCP/UDP publication, Compose, and `host.docker.internal` | The tests depend on Rancher Desktop's product controls and BATS helpers | Apache-2.0 |
| [Docker CLI end-to-end tests](https://github.com/docker/cli/tree/master/e2e) | CLI formatting, context, stream, event, and command lifecycle expectations | They are coupled to the Docker CLI source tree and daemon test environment | Apache-2.0 |
| [Docker Compose end-to-end tests](https://github.com/docker/compose/tree/main/pkg/e2e) | Project lifecycle, dependency ordering, logs, and named-volume behavior | They are a Go suite coupled to Compose internals and fixtures | Apache-2.0 |
| [Moby integration tests](https://github.com/moby/moby/tree/master/integration) | Engine API, restart, mount, network, and rejection semantics | They require a privileged daemon-under-test and Moby's internal test framework | Apache-2.0 |
| [Testcontainers for Go](https://github.com/testcontainers/testcontainers-go) | A real third-party consumer exercising create, wait, ports, exec, logs, networks, and cleanup | It is used as a pinned dependency through the small fixture in this directory | MIT |
| [kind](https://github.com/kubernetes-sigs/kind) | A Kubernetes-in-Docker consumer exercising privileged nested workloads and host resolution | The released CLI is invoked as a black-box ecosystem test | Apache-2.0 |

When adding coverage based on another project, record the source here, retain
its license notices if code is copied, and prefer a fresh black-box assertion
over importing product-specific helpers.
