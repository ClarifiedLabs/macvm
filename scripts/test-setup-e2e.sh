#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
macvm="${MACVM_E2E_BINARY:-$repo_root/.build/xcode-derived/Build/Products/Debug/macvm}"
vm_root="${MACVM_E2E_ROOT:-$repo_root/.build/setup-e2e}"
iterations="${MACVM_E2E_ITERATIONS:-3}"
keep_vm="${MACVM_E2E_KEEP_VM:-0}"
timeout_seconds="${MACVM_E2E_SETUP_TIMEOUT_SECONDS:-1800}"
expected_flow="${MACVM_E2E_EXPECTED_FLOW:-}"
expected_major="${MACVM_E2E_EXPECTED_MAJOR:-}"
expected_build="${MACVM_E2E_EXPECTED_BUILD:-}"
run_id="$(date +%Y%m%d-%H%M%S)-$$"
seed="${MACVM_E2E_SEED:-macvm-setup-seed-$run_id}"
seed_bundle="$vm_root/$seed.macvm"
owns_seed=1
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
        if [ "$owns_seed" = "1" ]; then
            "$macvm" rm --root "$vm_root" --force "$seed" >/dev/null 2>&1 || true
        fi
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
    mode="$2"
    python3 - "$bundle" "$mode" "$expected_major" "$expected_build" <<'PY'
import json
import pathlib
import sys

bundle = pathlib.Path(sys.argv[1])
mode = sys.argv[2]
expected_major = sys.argv[3]
expected_build = sys.argv[4]
metadata = json.loads((bundle / "Metadata.json").read_text())
if not metadata.get("setupCompletedAt"):
    raise SystemExit("metadata has no setupCompletedAt")
if metadata.get("setupUsername") != "admin":
    raise SystemExit(f"unexpected setup username: {metadata.get('setupUsername')!r}")
release = metadata.get("installedMacOSRelease") or {}
if expected_major and release.get("majorVersion") != int(expected_major):
    raise SystemExit(f"unexpected guest major version: {release!r}")
if expected_build and release.get("buildVersion") != expected_build:
    raise SystemExit(f"unexpected guest build: {release!r}")
diagnostics = sorted((bundle / "Setup" / "diagnostics").glob("*/trace.jsonl"))
if mode == "ocr":
    if not diagnostics:
        raise SystemExit("OCR setup produced no decision trace")
    events = [json.loads(line) for line in diagnostics[-1].read_text().splitlines() if line.strip()]
    pointer_events = [
        event for event in events
        if event.get("event") == "rfb" and event.get("kind") == "pointer_click"
    ]
    if not pointer_events:
        raise SystemExit("OCR setup trace contains no RFB pointer diagnostics")
    unsafe = [
        event for event in pointer_events
        if event.get("lastCaptureHadPixels") != "true"
        or not event.get("captureWidth")
        or not event.get("captureHeight")
    ]
    if unsafe:
        raise SystemExit(f"setup sent pointer input without a captured framebuffer: {unsafe!r}")
if diagnostics:
    print(diagnostics[-1])
else:
    print("native provisioning completed without an OCR decision trace")
PY
}

[ -x "$macvm" ] || fail "macvm binary not found at $macvm; run make build-cli first"
case "$iterations" in ''|*[!0-9]*|0) fail "MACVM_E2E_ITERATIONS must be a positive integer" ;; esac
case "$timeout_seconds" in ''|*[!0-9]*|0) fail "MACVM_E2E_SETUP_TIMEOUT_SECONDS must be a positive integer" ;; esac
mkdir -p "$vm_root"
if [ -n "${MACVM_E2E_SEED:-}" ]; then
    [ -d "$seed_bundle" ] || fail "MACVM_E2E_SEED does not exist under $vm_root: $seed"
    owns_seed=0
    echo "Reusing pristine macOS seed '$seed'."
else
    [ ! -e "$seed_bundle" ] || fail "seed VM already exists: $seed_bundle"
    create_args=("$macvm" create --root "$vm_root" --name "$seed")
    if [ -n "${MACVM_E2E_IPSW:-}" ]; then
        [ -f "$MACVM_E2E_IPSW" ] || fail "MACVM_E2E_IPSW does not exist: $MACVM_E2E_IPSW"
        create_args+=(--ipsw "$MACVM_E2E_IPSW")
    else
        create_args+=(--latest)
    fi

    echo "Installing pristine macOS seed '$seed'."
    run_with_timeout 7200 "${create_args[@]}" || fail "seed installation failed"
fi

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
    mode="ocr"
    if grep -q "with native provisioning" "$log"; then
        mode="native"
    fi
    if [ -n "$expected_flow" ]; then
        grep -q "Selected setup flow $expected_flow " "$log" \
            || fail "iteration $iteration did not select setup flow $expected_flow; inspect $log"
    fi
    verify_setup "$vm_root/$name.macvm" "$mode"
    grep -q "Setup complete. $name is Ansible-ready." "$log" \
        || fail "iteration $iteration did not report SSH readiness; inspect $log"
    successful_bundles+=("$name")
    successful_logs+=("$log")
    failed_bundle=""
    echo "[$iteration/$iterations] PASS"
done

echo "PASS: $iterations fresh-clone Setup Assistant runs completed and reached SSH."
