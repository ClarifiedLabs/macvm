# Provisioning Profiles

MacVM provisioning profiles are ordinary Ansible playbooks with a small JSON
manifest. Ansible runs on the host and connects with the per-VM SSH key created
by `macvm setup`.

Install the optional host dependency with:

```bash
brew install ansible
```

## Catalogs

MacVM merges bundled profiles with profiles found under:

- `~/Library/Application Support/macvm/Profiles`
- `~/.config/macvm/profiles`
- `<macvm root>/.profiles`
- `<vm>.macvm/Setup/Profiles` when targeting an existing VM

Symlinked directories are resolved and loaded once. Profile IDs must be unique
across every active catalog; a collision disables all profiles with that ID.
VM-local profiles are available for later provisioning but not initial creation.

List or validate profiles with:

```bash
macvm profiles list
macvm profiles list --all
macvm profiles validate ~/.config/macvm/profiles/my-tools
```

## Profile Format

Each profile is a directory containing `profile.json`, its playbook, and any
roles, templates, or files it needs:

```text
my-tools/
  profile.json
  playbook.yml
  roles/
```

Minimal `profile.json`:

```json
{
  "schemaVersion": 1,
  "id": "my-tools",
  "name": "My Tools",
  "description": "Install my standard command-line tools.",
  "category": "Local",
  "version": "1",
  "playbook": "playbook.yml",
  "dependencies": ["homebrew"]
}
```

IDs use lowercase letters, digits, and hyphens. Dependencies may reference
bundled or local profiles. Cycles and missing dependencies are rejected.

An optional `inputs` array supports `string`, `boolean`, `choice`, and `secret`
types. Values reach the playbook in `macvm_inputs`; VM information is available
in `macvm_context`:

```yaml
---
- hosts: macvm
  gather_facts: false
  tasks:
    - ansible.builtin.raw: echo {{ macvm_inputs.message | quote }}
```

Pass non-secret inputs as `--profile-input my-tools.message=hello`. CLI secrets
must use `env:NAME` or `file:/path`; Manager accepts them through a secure field.
MacVM writes resolved variables to a mode-0600 temporary file and deletes it,
but a local playbook can still expose its inputs and must use Ansible `no_log`
for secret-bearing tasks.

Provisioning runs without an SSH pseudo-terminal and cannot answer interactive
prompts. Profiles must select noninteractive flags or environment variables for
tools that can prompt; an unexpected prompt should fail instead of blocking the
setup pipeline indefinitely.

## Security and State

Local profiles are executable code. They can use `delegate_to: localhost` and
therefore modify the host, not just the guest. Inspect profiles before selecting
them. Manager asks again when a local profile's content digest changes.

Results are recorded in `<vm>.macvm/Setup/provisioning-state.json`; timestamped
Ansible logs are stored under `<vm>.macvm/Setup/Provisioning/`. A failed profile
does not undo profiles that already completed. Rerunning a profile always invokes
its idempotent playbook.

## GitHub Runner Registration

The bundled `github-runner` profile installs but does not register the runner.
The copyable example in `docs/examples/profiles/github-runner-register` shows
registration with a GitHub App while keeping its private key on the host.

Copy the example into a local catalog, then select it in the CLI or Manager. For
repository runners the App needs repository **Administration: read and write**;
for organization runners it needs organization **Self-hosted runners: read and
write**. Avoid persistent self-hosted runners for untrusted public-repository
workflows.

## End-to-End Smoke Test

The opt-in smoke test creates and installs a real VM, discovers a local test
profile, passes a typed input to Ansible, verifies the guest over SSH, applies
the profile a second time, and checks that the second Ansible recap reports no
changes. It removes the VM when finished:

```bash
brew install ansible
make test-provisioning-e2e
```

The provisioning smoke test requires a supported macOS 15, 26, or 27 setup flow. Set
`MACVM_E2E_IPSW=/path/to/restore.ipsw` to select the guest release explicitly.
It stores the temporary VM under
`.build/provisioning-e2e`. Set `MACVM_E2E_KEEP_VM=1` to retain the
VM for inspection, or `MACVM_E2E_CREATE_TIMEOUT_SECONDS` to change the default
two-hour creation timeout. These tests are intentionally local-only and are not
part of the normal `make test` or hosted CI workflow.
