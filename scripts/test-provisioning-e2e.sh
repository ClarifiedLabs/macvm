#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
macvm="${MACVM_E2E_BINARY:-$repo_root/.build/xcode-derived/Build/Products/Debug/macvm}"
vm_root="${MACVM_E2E_ROOT:-$repo_root/.build/provisioning-e2e}"
keep_vm="${MACVM_E2E_KEEP_VM:-0}"
create_timeout="${MACVM_E2E_CREATE_TIMEOUT_SECONDS:-7200}"
name="${MACVM_E2E_VM_NAME:-macvm-provisioning-e2e-$(date +%Y%m%d-%H%M%S)-$$}"
profile_id="e2e-smoke"
marker="macvm-e2e-$(date +%s)-$$"
fixture="$repo_root/Tests/ProvisioningProfiles/$profile_id"
profile_target="$vm_root/.profiles/$profile_id"
bundle="$vm_root/$name.macvm"
active_pid=""
installed_fixture=0

fail() {
    echo "Provisioning E2E failed: $*" >&2
    exit 1
}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ -n "$active_pid" ] && kill -0 "$active_pid" 2>/dev/null; then
        kill "$active_pid" 2>/dev/null || true
        wait "$active_pid" 2>/dev/null || true
    fi
    if [ "$keep_vm" = "1" ]; then
        echo "Keeping E2E VM '$name' at $bundle"
        echo "Keeping its local profile fixture at $profile_target"
    else
        "$macvm" stop --root "$vm_root" "$name" >/dev/null 2>&1 || true
        "$macvm" rm --root "$vm_root" --force "$name" >/dev/null 2>&1 || true
        if [ "$installed_fixture" = "1" ]; then
            rm -rf "$profile_target"
        fi
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

run_with_timeout() {
    timeout_seconds="$1"
    shift
    started="$(date +%s)"
    "$@" &
    active_pid=$!
    while kill -0 "$active_pid" 2>/dev/null; do
        now="$(date +%s)"
        if [ $((now - started)) -ge "$timeout_seconds" ]; then
            kill "$active_pid" 2>/dev/null || true
            wait "$active_pid" 2>/dev/null || true
            active_pid=""
            fail "command timed out after ${timeout_seconds}s: $*"
        fi
        sleep 5
    done
    set +e
    wait "$active_pid"
    status=$?
    set -e
    active_pid=""
    return "$status"
}

assert_successful_state() {
    python3 - "$bundle" "$profile_id" <<'PY'
import json
import pathlib
import sys

bundle = pathlib.Path(sys.argv[1])
profile_id = sys.argv[2]
state_path = bundle / "Setup" / "provisioning-state.json"
if not state_path.is_file():
    raise SystemExit(f"missing provisioning state: {state_path}")
state = json.loads(state_path.read_text())
record = state.get("profiles", {}).get(profile_id)
if record is None:
    raise SystemExit(f"state has no record for {profile_id}")
if record.get("status") != "succeeded":
    raise SystemExit(f"profile status is {record.get('status')!r}, expected 'succeeded'")
log_path = bundle / "Setup" / record["logPath"]
if not log_path.is_file():
    raise SystemExit(f"missing provisioning log: {log_path}")
print(log_path)
PY
}

wait_for_ssh() {
    deadline=$(( $(date +%s) + 600 ))
    until "$macvm" ssh --root "$vm_root" "$name" -- true >/dev/null 2>&1; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
            fail "SSH did not become ready within 600 seconds"
        fi
        sleep 5
    done
}

[ -x "$macvm" ] || fail "macvm binary not found at $macvm; run 'make build-cli' first"
command -v ansible-playbook >/dev/null 2>&1 || fail "ansible-playbook is required; run 'brew install ansible'"
case "$create_timeout" in
    ''|*[!0-9]*) fail "MACVM_E2E_CREATE_TIMEOUT_SECONDS must be a positive integer" ;;
    0) fail "MACVM_E2E_CREATE_TIMEOUT_SECONDS must be a positive integer" ;;
esac
[ -d "$fixture" ] || fail "missing E2E profile fixture: $fixture"
[ ! -e "$bundle" ] || fail "VM already exists: $bundle"
[ ! -e "$profile_target" ] || fail "profile target already exists: $profile_target"

mkdir -p "$(dirname "$profile_target")"
cp -R "$fixture" "$profile_target"
installed_fixture=1

"$macvm" profiles list --root "$vm_root" | grep -q "^${profile_id}[[:space:]]" \
    || fail "the local E2E profile was not discovered"

create_args=(
    "$macvm" create
    --root "$vm_root"
    --name "$name"
    --profile "$profile_id"
    --profile-input "$profile_id.marker=$marker"
    --shutdown-after
)
if [ -n "${MACVM_E2E_IPSW:-}" ]; then
    [ -f "$MACVM_E2E_IPSW" ] || fail "MACVM_E2E_IPSW does not exist: $MACVM_E2E_IPSW"
    create_args+=(--ipsw "$MACVM_E2E_IPSW")
else
    create_args+=(--latest)
fi

echo "Creating '$name' and applying '$profile_id' (timeout: ${create_timeout}s)."
run_with_timeout "$create_timeout" "${create_args[@]}"

first_log="$(assert_successful_state)"
echo "Initial provisioning state and log verified: $first_log"

"$macvm" run --root "$vm_root" --headless "$name"
wait_for_ssh

# This expansion is intentionally deferred to the guest's login shell.
# shellcheck disable=SC2016
printf -v verify_command 'test "$(cat "$HOME/.macvm-provisioning-smoke")" = "%s"' "$marker"
"$macvm" ssh --root "$vm_root" "$name" -- "$verify_command"
echo "Guest marker verified over SSH."

"$macvm" provision --root "$vm_root" "$name" \
    --profile "$profile_id" \
    --profile-input "$profile_id.marker=$marker"
second_log="$(assert_successful_state)"
grep -Eq 'changed=0([[:space:]]|$)' "$second_log" \
    || fail "the second provisioning run was not idempotent; inspect $second_log"

"$macvm" ssh --root "$vm_root" "$name" -- "$verify_command"
echo "PASS: fresh-VM provisioning, persisted state/logs, guest effects, and idempotent reprovisioning all succeeded."
