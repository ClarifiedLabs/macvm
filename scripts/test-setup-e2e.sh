#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
macvm="${MACVM_E2E_BINARY:-$repo_root/.build/xcode-derived/Build/Products/Debug/macvm}"
vm_root="${MACVM_E2E_ROOT:-$repo_root/.build/setup-e2e}"
iterations="${MACVM_E2E_ITERATIONS:-3}"
keep_vm="${MACVM_E2E_KEEP_VM:-0}"
timeout_seconds="${MACVM_E2E_SETUP_TIMEOUT_SECONDS:-1800}"
run_id="$(date +%Y%m%d-%H%M%S)-$$"
seed="macvm-setup-seed-$run_id"
seed_bundle="$vm_root/$seed.macvm"
successful_bundles=()
successful_logs=()
failed_bundle=""
active_pid=""

fail() {
    echo "Setup E2E failed: $*" >&2
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
        echo "Keeping setup soak bundles under $vm_root"
    else
        for bundle in "${successful_bundles[@]}"; do
            "$macvm" rm --root "$vm_root" --force "$bundle" >/dev/null 2>&1 || true
        done
        for log in "${successful_logs[@]}"; do
            rm -f "$log"
        done
        "$macvm" rm --root "$vm_root" --force "$seed" >/dev/null 2>&1 || true
    fi
    if [ -n "$failed_bundle" ]; then
        echo "Failed VM retained at $vm_root/$failed_bundle.macvm" >&2
        echo "Diagnostics are under $vm_root/$failed_bundle.macvm/Setup/diagnostics" >&2
    fi
    exit "$status"
}
trap cleanup EXIT INT TERM

run_with_timeout() {
    limit="$1"
    shift
    started="$(date +%s)"
    "$@" &
    active_pid=$!
    while kill -0 "$active_pid" 2>/dev/null; do
        if [ $(( $(date +%s) - started )) -ge "$limit" ]; then
            kill "$active_pid" 2>/dev/null || true
            wait "$active_pid" 2>/dev/null || true
            active_pid=""
            return 124
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

verify_setup() {
    bundle="$1"
    python3 - "$bundle" <<'PY'
import json
import pathlib
import sys

bundle = pathlib.Path(sys.argv[1])
metadata = json.loads((bundle / "Metadata.json").read_text())
if not metadata.get("setupCompletedAt"):
    raise SystemExit("metadata has no setupCompletedAt")
if metadata.get("setupUsername") != "admin":
    raise SystemExit(f"unexpected setup username: {metadata.get('setupUsername')!r}")
diagnostics = sorted((bundle / "Setup" / "diagnostics").glob("*/trace.jsonl"))
if not diagnostics:
    raise SystemExit("setup produced no decision trace")
print(diagnostics[-1])
PY
}

[ -x "$macvm" ] || fail "macvm binary not found at $macvm; run make build-cli first"
case "$iterations" in ''|*[!0-9]*|0) fail "MACVM_E2E_ITERATIONS must be a positive integer" ;; esac
case "$timeout_seconds" in ''|*[!0-9]*|0) fail "MACVM_E2E_SETUP_TIMEOUT_SECONDS must be a positive integer" ;; esac
[ ! -e "$seed_bundle" ] || fail "seed VM already exists: $seed_bundle"

mkdir -p "$vm_root"
create_args=("$macvm" create --root "$vm_root" --name "$seed")
if [ -n "${MACVM_E2E_IPSW:-}" ]; then
    [ -f "$MACVM_E2E_IPSW" ] || fail "MACVM_E2E_IPSW does not exist: $MACVM_E2E_IPSW"
    create_args+=(--ipsw "$MACVM_E2E_IPSW")
else
    create_args+=(--latest)
fi

echo "Installing pristine macOS seed '$seed'."
run_with_timeout 7200 "${create_args[@]}" || fail "seed installation failed"

for iteration in $(seq 1 "$iterations"); do
    name="macvm-setup-soak-$run_id-$iteration"
    log="$vm_root/$name.setup.log"
    echo "[$iteration/$iterations] Cloning seed to '$name'."
    "$macvm" clone --root "$vm_root" "$seed" --name "$name"
    failed_bundle="$name"
    echo "[$iteration/$iterations] Running Setup Assistant (timeout: ${timeout_seconds}s)."
    if ! run_with_timeout "$timeout_seconds" "$macvm" setup --root "$vm_root" --shutdown-after "$name" >"$log" 2>&1; then
        tail -100 "$log" >&2 || true
        fail "setup iteration $iteration failed; inspect $log"
    fi
    verify_setup "$vm_root/$name.macvm"
    grep -q "Setup complete. $name is Ansible-ready." "$log" \
        || fail "iteration $iteration did not report SSH readiness; inspect $log"
    successful_bundles+=("$name")
    successful_logs+=("$log")
    failed_bundle=""
    echo "[$iteration/$iterations] PASS"
done

echo "PASS: $iterations fresh-clone Setup Assistant runs completed and reached SSH."
