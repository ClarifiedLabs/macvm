#!/bin/bash

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
macvm="${MACVM_E2E_BINARY:-$repo_root/.build/xcode-derived/Build/Products/Debug/macvm}"
app_path="${MACVM_E2E_APP_PATH:-$repo_root/.build/xcode-derived/Build/Products/Debug/MacVM.app}"
vm_root="${MACVM_E2E_ROOT:-$HOME/VirtualMachines/MacVMHost}"
seed="${MACVM_DOCKER_E2E_SEED:-}"
suite="${MACVM_DOCKER_E2E_SUITE:-full}"
skip_baseline="${MACVM_DOCKER_E2E_SKIP_BASELINE:-0}"
baseline_context="${MACVM_DOCKER_E2E_BASELINE_CONTEXT:-}"
keep_vm="${MACVM_DOCKER_E2E_KEEP_VM:-0}"
require_amd64="${MACVM_DOCKER_E2E_REQUIRE_AMD64:-0}"
timeout_seconds="${MACVM_DOCKER_E2E_TIMEOUT_SECONDS:-900}"
run_id="$(date +%Y%m%d-%H%M%S)-$$"
artifact_root="${MACVM_DOCKER_E2E_ARTIFACTS:-$repo_root/.build/docker-compat/$run_id}"
prefix="macvm-compat-$run_id"
primary="$prefix-primary"
secondary="$prefix-secondary"
seed_bundle=
primary_bundle="$vm_root/$primary.macvm"
secondary_bundle="$vm_root/$secondary.macvm"
contract_dir="$repo_root/Tests/DockerCompatibility"
xfails="$contract_dir/xfail.tsv"
current_ignition_version=$(sed -n 's/.*currentIgnitionVersion = \([0-9][0-9]*\).*/\1/p' "$repo_root/Sources/MacVMHostKit/Docker/DockerSidecarMetadata.swift")
baseline_results="$artifact_root/baseline/results.tsv"
macvm_results="$artifact_root/macvm/results.tsv"
lifecycle_results="$artifact_root/macvm/lifecycle.tsv"
active_pid=
created_primary=0
created_secondary=0
completed=0
overall_status=0

fail() {
    echo "Docker compatibility E2E failed: $*" >&2
    exit 1
}

json_value() {
    key=$1
    python3 -c 'import json,sys; value=json.load(sys.stdin); print(value.get(sys.argv[1], ""))' "$key"
}

validate_toggle() {
    name=$1
    value=$2
    case "$value" in 0|1) ;; *) fail "$name must be 0 or 1" ;; esac
}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    if [ -n "$active_pid" ] && kill -0 "$active_pid" >/dev/null 2>&1; then
        kill "$active_pid" >/dev/null 2>&1 || true
        wait "$active_pid" >/dev/null 2>&1 || true
    fi
    if [ "$status" -eq 0 ] && [ "$completed" = 1 ] && [ "$keep_vm" = 0 ]; then
        if [ "$created_secondary" = 1 ]; then
            "$macvm" stop --root "$vm_root" "$secondary" >/dev/null 2>&1 || true
            "$macvm" rm --root "$vm_root" --force "$secondary" >/dev/null 2>&1 || true
        fi
        if [ "$created_primary" = 1 ]; then
            "$macvm" stop --root "$vm_root" "$primary" >/dev/null 2>&1 || true
            "$macvm" rm --root "$vm_root" --force "$primary" >/dev/null 2>&1 || true
        fi
    else
        if [ "$created_primary" = 1 ]; then
            echo "Primary disposable VM retained at $primary_bundle" >&2
        fi
        if [ "$created_secondary" = 1 ]; then
            echo "Secondary disposable VM retained at $secondary_bundle" >&2
        fi
    fi
    echo "Docker compatibility artifacts: $artifact_root"
    exit "$status"
}
trap cleanup EXIT INT TERM

run_with_timeout() {
    limit=$1
    shift
    started=$(date +%s)
    "$@" &
    active_pid=$!
    while kill -0 "$active_pid" >/dev/null 2>&1; do
        if [ $(( $(date +%s) - started )) -ge "$limit" ]; then
            kill "$active_pid" >/dev/null 2>&1 || true
            wait "$active_pid" >/dev/null 2>&1 || true
            active_pid=
            return 124
        fi
        sleep 2
    done
    set +e
    wait "$active_pid"
    status=$?
    set -e
    active_pid=
    return "$status"
}

verify_current_app() {
    expected="$app_path/Contents/MacOS/MacVM"
    expected=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$expected")
    pids=$(pgrep -x MacVM 2>/dev/null || true)
    for pid in $pids; do
        actual=$(python3 - "$pid" <<'PY'
import ctypes
import os
import sys

libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
buffer = ctypes.create_string_buffer(4096)
length = libproc.proc_pidpath(int(sys.argv[1]), buffer, len(buffer))
if length > 0:
    print(os.path.realpath(buffer.value.decode()))
PY
)
        if [ -n "$actual" ] && [ "$actual" != "$expected" ]; then
            fail "MacVM is already running from $actual; quit it so the suite can use $expected"
        fi
    done
}

docker_status_json() {
    "$macvm" docker status --root "$vm_root" --json "$1"
}

wait_for_docker() {
    name=$1
    deadline=$(( $(date +%s) + timeout_seconds ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        status=$(docker_status_json "$name" 2>/dev/null || true)
        state=$(printf '%s' "$status" | json_value state 2>/dev/null || true)
        if [ "$state" = ready ] && guest "$name" \
            'docker version >/dev/null && docker buildx version >/dev/null && docker compose version >/dev/null' \
            >/dev/null 2>&1; then
            return 0
        fi
        if [ "$state" = degraded ] || [ "$state" = corrupt ]; then
            printf '%s\n' "$status" >&2
            return 1
        fi
        sleep 5
    done
    return 1
}

wait_for_state() {
    name=$1
    expected=$2
    limit=${3:-120}
    deadline=$(( $(date +%s) + limit ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        status=$(docker_status_json "$name" 2>/dev/null || true)
        state=$(printf '%s' "$status" | json_value state 2>/dev/null || true)
        if [ "$state" = "$expected" ]; then
            return 0
        fi
        sleep 2
    done
    printf '%s\n' "$status" >&2
    return 1
}

guest() {
    name=$1
    shift
    "$macvm" ssh --root "$vm_root" "$name" -- \
        "export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH; $*"
}

record_host_engine() {
    destination=$1
    mkdir -p "$destination"
    docker version >"$destination/version.txt" 2>&1 || true
    docker version --format '{{json .}}' >"$destination/version.json" 2>"$destination/version-json.stderr" || true
    docker info >"$destination/info.txt" 2>&1 || true
    docker info --format '{{json .}}' >"$destination/info.json" 2>"$destination/info-json.stderr" || true
    docker context show >"$destination/context.txt" 2>&1 || true
    docker context inspect >"$destination/context.json" 2>"$destination/context-json.stderr" || true
    docker buildx version >"$destination/buildx-version.txt" 2>&1 || true
    docker compose version >"$destination/compose-version.txt" 2>&1 || true
}

record_guest_engine() {
    name=$1
    destination=$2
    mkdir -p "$destination"
    guest "$name" "docker version" >"$destination/version.txt" 2>&1 || true
    guest "$name" "docker version --format '{{json .}}'" >"$destination/version.json" 2>"$destination/version-json.stderr" || true
    guest "$name" "docker info" >"$destination/info.txt" 2>&1 || true
    guest "$name" "docker info --format '{{json .}}'" >"$destination/info.json" 2>"$destination/info-json.stderr" || true
    guest "$name" "docker context inspect" >"$destination/context.json" 2>"$destination/context-json.stderr" || true
    guest "$name" "docker buildx version" >"$destination/buildx-version.txt" 2>&1 || true
    guest "$name" "docker compose version" >"$destination/compose-version.txt" 2>&1 || true
    docker_status_json "$name" >"$destination/macvm-status.json"
}

active_endpoint_is_local() {
    if [ -n "${DOCKER_HOST:-}" ]; then
        endpoint=$DOCKER_HOST
    else
        endpoint=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
    fi
    case "$endpoint" in unix://*) return 0 ;; *) return 1 ;; esac
}

run_baseline_suite() {
    mkdir -p "$artifact_root/baseline/logs"
    (
        if [ -n "$baseline_context" ]; then
            export DOCKER_CONTEXT="$baseline_context"
            unset DOCKER_HOST
        fi
        docker version >/dev/null
        record_host_engine "$artifact_root/baseline/engine"
        if active_endpoint_is_local; then local_daemon=1; else local_daemon=0; fi
        amd64_state=unknown
        if docker run --rm --platform linux/amd64 alpine:3.23 true >/dev/null 2>&1; then
            amd64_state=available
        else
            amd64_state=unavailable
        fi
        /bin/bash "$contract_dir/suite.sh" \
            --target baseline \
            --mode "$suite" \
            --results "$baseline_results" \
            --logs "$artifact_root/baseline/logs" \
            --prefix "$prefix-baseline" \
            --require-amd64 "$require_amd64" \
            --amd64-state "$amd64_state" \
            --local-daemon "$local_daemon"
    )
}

prepare_guest_dependencies() {
    name=$1
    # Expansion is intentionally deferred to the guest login shell.
    # shellcheck disable=SC2016
    if ! guest "$name" 'export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH; command -v python3 >/dev/null'; then
        echo "Installing Python in the disposable guest for host-network and socket fixtures."
        # shellcheck disable=SC2016
        guest "$name" 'export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH; brew install python'
    fi
    if [ "$suite" != full ]; then
        return
    fi
    echo "Ensuring Go, kind, and kubectl are available in the disposable guest."
    # shellcheck disable=SC2016
    guest "$name" \
        'export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:$PATH; command -v go >/dev/null && command -v kind >/dev/null && command -v kubectl >/dev/null || brew install go kind kubernetes-cli'
}

run_guest_contract() {
    name=$1
    guest_root="/private/tmp/$prefix"
    source_archive="$artifact_root/contract.tar"
    result_archive="$artifact_root/macvm-results.tar"
    tar -C "$contract_dir" -cf "$source_archive" . \
        || fail "could not archive the Docker compatibility contract"
    guest "$name" "rm -rf '$guest_root' && mkdir -p '$guest_root' && tar -xf - -C '$guest_root'" <"$source_archive" \
        || fail "could not transfer the Docker compatibility contract to '$name'"
    status=$(docker_status_json "$name") \
        || fail "could not read Docker status for '$name'"
    if [ "$(printf '%s' "$status" | json_value amd64Available)" = True ]; then
        amd64_state=available
    else
        amd64_state=unavailable
    fi
    mkdir -p "$artifact_root/macvm/logs"
    guest "$name" \
        "cd '$guest_root' && export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:\$PATH && /bin/bash ./suite.sh --target macvm --mode '$suite' --results '$guest_root/results.tsv' --logs '$guest_root/logs' --prefix '$prefix-macvm' --require-amd64 '$require_amd64' --amd64-state '$amd64_state' --local-daemon 1" \
        2>&1 | tee "$artifact_root/macvm/suite.log"
    suite_status=${PIPESTATUS[0]}
    guest "$name" "tar -C '$guest_root' -cf - results.tsv results.tsv.complete logs" >"$result_archive" \
        || fail "could not fetch Docker compatibility results from '$name'"
    tar -C "$artifact_root/macvm" -xf "$result_archive" \
        || fail "could not extract Docker compatibility results"
    [ -f "$macvm_results.complete" ] || fail "the guest contract did not reach its completion marker"
    return "$suite_status"
}

append_lifecycle_result() {
    test_id=$1
    status=$2
    duration=$3
    note_file=$4
    note=$(awk 'NF { line=$0 } END { print line }' "$note_file" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//')
    printf '%s\t%s\t%s\trequired\t%s\n' "$test_id" "$status" "$duration" "$note" >>"$lifecycle_results"
}

run_lifecycle_case() {
    test_id=$1
    function_name=$2
    safe_id=$(printf '%s' "$test_id" | tr '.:/' '---')
    log="$artifact_root/macvm/logs/$safe_id.log"
    started=$(date +%s)
    set +e
    (
        set -e
        "$function_name"
    ) >"$log" 2>&1
    code=$?
    set -e
    duration=$((($(date +%s) - started) * 1000))
    if [ -d "$secondary_bundle" ]; then
        created_secondary=1
    fi
    if [ "$code" -eq 0 ]; then
        result=PASS
    else
        result=FAIL
    fi
    append_lifecycle_result "$test_id" "$result" "$duration" "$log"
    echo "$result $test_id - $(tr '\t\r\n' '   ' <"$log" | sed 's/  */ /g; s/^ //; s/ $//')"
}

lifecycle_helper_reconnect() {
    bind_path="/private/tmp/$prefix-reconnect"
    container="$prefix-reconnect"
    guest "$primary" "mkdir -p '$bind_path' && printf reconnect-marker >'$bind_path/index.html' && docker rm -f '$container' >/dev/null 2>&1 || true; docker run -d --name '$container' --label dev.macvm.docker-compat.run='$prefix' --restart unless-stopped -p 127.0.0.1::80 -v '$bind_path:/usr/share/nginx/html:ro' nginx:1.29-alpine"
    port=$(guest "$primary" "docker port '$container' 80/tcp | sed 's/.*://'")
    guest "$primary" "curl -fsS http://127.0.0.1:$port | grep -q reconnect-marker"
    guest "$primary" "sudo -n launchctl kickstart -k system/dev.macvm.docker-guest"
    deadline=$(( $(date +%s) + 120 ))
    until guest "$primary" "docker inspect '$container' --format '{{.State.Running}}' | grep -q true && curl -fsS http://127.0.0.1:$port | grep -q reconnect-marker" >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] || return 1
        sleep 3
    done
    echo "restart-policy container, bind mount, and published port survived helper restart"
}

lifecycle_stop_start() {
    volume="$prefix-persist"
    guest "$primary" "docker volume create '$volume' >/dev/null && docker run --rm -v '$volume:/data' alpine:3.23 sh -c 'printf persisted >/data/value' && docker tag alpine:3.23 '$prefix-persist:latest'"
    "$macvm" shutdown --root "$vm_root" --wait --timeout 180 "$primary"
    "$macvm" run --root "$vm_root" --headless "$primary"
    wait_for_docker "$primary"
    value=$(guest "$primary" "docker run --rm -v '$volume:/data:ro' alpine:3.23 cat /data/value")
    [ "$value" = persisted ]
    guest "$primary" "docker image inspect '$prefix-persist:latest' >/dev/null"
    echo "volume and image persisted across a macOS VM stop/start"
}

lifecycle_clone_isolation() {
    "$macvm" shutdown --root "$vm_root" --wait --timeout 180 "$primary"
    "$macvm" clone --root "$vm_root" "$primary" --name "$secondary"
    created_secondary=1
    "$macvm" run --root "$vm_root" --headless "$primary"
    "$macvm" run --root "$vm_root" --headless "$secondary"
    wait_for_docker "$primary"
    wait_for_docker "$secondary"
    primary_id=$(guest "$primary" "docker info --format '{{.ID}}'")
    secondary_id=$(guest "$secondary" "docker info --format '{{.ID}}'")
    [ -n "$primary_id" ] && [ -n "$secondary_id" ] && [ "$primary_id" != "$secondary_id" ]
    for name in "$primary" "$secondary"; do
        value=$(guest "$name" "docker run --rm -v '$prefix-persist:/data:ro' alpine:3.23 cat /data/value")
        [ "$value" = persisted ]
    done
    echo "concurrent clone has a distinct engine ID and inherited Docker data"
}

lifecycle_recovery_bypass() {
    "$macvm" shutdown --root "$vm_root" --wait --timeout 180 "$secondary"
    "$macvm" run --root "$vm_root" --headless --recovery "$secondary"
    sleep 15
    wait_for_state "$secondary" stopped 30
    "$macvm" stop --root "$vm_root" "$secondary"
    echo "recovery boot left the Docker sidecar stopped"
}

lifecycle_disable_enable_grow_update() {
    status=$(docker_status_json "$secondary")
    cpu=$(printf '%s' "$status" | json_value cpuCount)
    memory_bytes=$(printf '%s' "$status" | json_value memorySizeBytes)
    disk_bytes=$(printf '%s' "$status" | json_value dataDiskSizeBytes)
    amd64_requested=$(printf '%s' "$status" | json_value amd64Requested)
    memory_gib=$((memory_bytes / 1073741824))
    disk_gib=$((disk_bytes / 1073741824))
    grown_gib=$((disk_gib + 1))
    "$macvm" docker disable --root "$vm_root" "$secondary"
    wait_for_state "$secondary" disabled 30
    enable_args=("$macvm" docker enable --root "$vm_root" --cpu "$cpu" --memory-gi-b "$memory_gib" --disk-gi-b "$disk_gib")
    if [ "$amd64_requested" != True ]; then enable_args+=(--no-amd64); fi
    enable_args+=("$secondary")
    "${enable_args[@]}"
    wait_for_state "$secondary" stopped 30
    "$macvm" docker configure --root "$vm_root" --disk-gi-b "$grown_gib" "$secondary"
    status=$(docker_status_json "$secondary")
    [ "$(printf '%s' "$status" | json_value dataDiskSizeBytes)" -eq $((grown_gib * 1073741824)) ]
    python3 - "$secondary_bundle/DockerSidecar/Metadata.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["ignitionVersion"] = max(0, int(value["ignitionVersion"]) - 1)
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
PY
    "$macvm" docker update --root "$vm_root" "$secondary"
    ignition=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ignitionVersion"])' "$secondary_bundle/DockerSidecar/Metadata.json")
    [ "$ignition" -eq "$current_ignition_version" ]
    "$macvm" run --root "$vm_root" --headless "$secondary"
    wait_for_docker "$secondary"
    value=$(guest "$secondary" "docker run --rm -v '$prefix-persist:/data:ro' alpine:3.23 cat /data/value")
    [ "$value" = persisted ]
    echo "disable/enable preserved data, disk grew, and forced update preserved data"
}

restore_secondary_homebrew() {
    deadline=$(( $(date +%s) + 120 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if guest "$secondary" \
            "if [ -e /opt/homebrew/bin/brew.macvm-compat ]; then sudo -n mv -f /opt/homebrew/bin/brew.macvm-compat /opt/homebrew/bin/brew; fi; test -x /opt/homebrew/bin/brew && /bin/sync" \
            >/dev/null 2>&1; then
            return 0
        fi
        "$macvm" run --root "$vm_root" --headless "$secondary" >/dev/null 2>&1 || true
        sleep 2
    done
    echo "could not restore Homebrew after degraded-recovery sabotage" >&2
    return 1
}

finish_degraded_recovery() {
    degraded_status=$?
    trap - EXIT INT TERM
    if ! restore_secondary_homebrew; then
        [ "$degraded_status" -ne 0 ] || degraded_status=1
    fi
    exit "$degraded_status"
}

lifecycle_degraded_recovery() {
    trap finish_degraded_recovery EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    guest "$secondary" \
        "test -x /opt/homebrew/bin/brew && test ! -e /opt/homebrew/bin/brew.macvm-compat && sudo -n mv /opt/homebrew/bin/brew /opt/homebrew/bin/brew.macvm-compat"
    "$macvm" shutdown --root "$vm_root" --wait --timeout 180 "$secondary"
    python3 - "$secondary_bundle/Metadata.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["dockerSidecar"]["guestProvisioningVersion"] = max(
    0, int(value["dockerSidecar"]["guestProvisioningVersion"]) - 1
)
path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
PY
    set +e
    "$macvm" run --root "$vm_root" --headless "$secondary"
    set -e
    wait_for_state "$secondary" degraded 300
    restore_secondary_homebrew
    "$macvm" stop --root "$vm_root" "$secondary"
    "$macvm" run --root "$vm_root" --headless "$secondary"
    wait_for_docker "$secondary"
    echo "controlled guest-provisioning failure reported degraded and recovered on retry"
}

lifecycle_reset_last() {
    "$macvm" shutdown --root "$vm_root" --wait --timeout 180 "$secondary"
    "$macvm" docker reset --root "$vm_root" --force "$secondary"
    "$macvm" run --root "$vm_root" --headless "$secondary"
    wait_for_docker "$secondary"
    set +e
    guest "$secondary" "docker volume inspect '$prefix-persist'" >/dev/null 2>&1
    code=$?
    set -e
    [ "$code" -ne 0 ]
    echo "reset removed the inherited sentinel volume"
}

run_lifecycle_suite() {
    printf 'test_id\tstatus\tduration_ms\tpolicy\tnote\n' >"$lifecycle_results"
    run_lifecycle_case lifecycle.helper-reconnect lifecycle_helper_reconnect
    run_lifecycle_case lifecycle.stop-start-persistence lifecycle_stop_start
    run_lifecycle_case lifecycle.clone-identity lifecycle_clone_isolation
    run_lifecycle_case lifecycle.recovery-bypass lifecycle_recovery_bypass
    run_lifecycle_case lifecycle.maintenance lifecycle_disable_enable_grow_update
    run_lifecycle_case lifecycle.degraded-recovery lifecycle_degraded_recovery
    run_lifecycle_case lifecycle.reset lifecycle_reset_last
}

validate_toggle MACVM_DOCKER_E2E_SKIP_BASELINE "$skip_baseline"
validate_toggle MACVM_DOCKER_E2E_KEEP_VM "$keep_vm"
validate_toggle MACVM_DOCKER_E2E_REQUIRE_AMD64 "$require_amd64"
case "$suite" in smoke|full) ;; *) fail "MACVM_DOCKER_E2E_SUITE must be smoke or full" ;; esac
case "$timeout_seconds" in ''|*[!0-9]*|0) fail "MACVM_DOCKER_E2E_TIMEOUT_SECONDS must be a positive integer" ;; esac
[ -n "$seed" ] || fail "MACVM_DOCKER_E2E_SEED is required and must name a stopped, Docker-ready seed"
[ -x "$macvm" ] || fail "macvm binary not found at $macvm; run make build-cli first"
[ -d "$app_path" ] || fail "MacVM.app not found at $app_path; run make build-app first"
[ -f "$contract_dir/suite.sh" ] || fail "Docker compatibility contract is missing"
command -v python3 >/dev/null 2>&1 || fail "python3 is required"
[ -n "$current_ignition_version" ] || fail "could not resolve DockerSidecarMetadata.currentIgnitionVersion"
command -v docker >/dev/null 2>&1 || [ "$skip_baseline" = 1 ] || fail "docker is required for the baseline; set MACVM_DOCKER_E2E_SKIP_BASELINE=1 to omit it"
if [ "$suite" = full ] && [ "$skip_baseline" = 0 ]; then
    command -v go >/dev/null 2>&1 || fail "Go is required by the full baseline suite"
    command -v kind >/dev/null 2>&1 || fail "kind is required by the full baseline suite"
    command -v kubectl >/dev/null 2>&1 || fail "kubectl is required by the full baseline suite"
fi

mkdir -p "$artifact_root/macvm/logs"
git_commit=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)
python3 - "$artifact_root/run.json" "$run_id" "$suite" "$seed" "$vm_root" "$baseline_context" "$skip_baseline" "$require_amd64" "$macvm" "$app_path" "$git_commit" <<'PY'
import json
import pathlib
import sys

keys = [
    "run_id",
    "suite",
    "seed",
    "vm_root",
    "baseline_context",
    "skip_baseline",
    "require_amd64",
    "macvm_binary",
    "macvm_app",
    "git_commit",
]
path = pathlib.Path(sys.argv[1])
path.write_text(
    json.dumps(dict(zip(keys, sys.argv[2:])), indent=2, sort_keys=True) + "\n"
)
PY
verify_current_app
export MACVM_APP_PATH="$app_path"

if [[ "$seed" == */* ]] || [[ "$seed" == *.macvm ]]; then
    seed_bundle="$seed"
else
    seed_bundle="$vm_root/$seed.macvm"
fi
[ -d "$seed_bundle" ] || fail "seed bundle does not exist: $seed_bundle"
seed_status=$("$macvm" docker status --root "$vm_root" --json "$seed")
printf '%s\n' "$seed_status" >"$artifact_root/seed-status.json"
[ "$(printf '%s' "$seed_status" | json_value state)" = stopped ] \
    || fail "seed must be stopped and Docker-ready; inspect $artifact_root/seed-status.json"

if [ "$skip_baseline" = 0 ]; then
    echo "Running the comparison endpoint contract before starting disposable VMs."
    set +e
    run_baseline_suite 2>&1 | tee "$artifact_root/baseline-suite.log"
    baseline_status=${PIPESTATUS[0]}
    set -e
    if [ "$baseline_status" -ne 0 ]; then
        echo "Baseline reported failures; they are diagnostic and will appear in the comparison." >&2
    fi
fi

echo "Cloning immutable seed '$seed' to disposable VM '$primary'."
"$macvm" clone --root "$vm_root" "$seed" --name "$primary"
created_primary=1
"$macvm" run --root "$vm_root" --headless "$primary"
wait_for_docker "$primary" || fail "Docker did not become ready in '$primary'"
prepare_guest_dependencies "$primary"
record_guest_engine "$primary" "$artifact_root/macvm/engine"

echo "Running the Docker compatibility contract inside '$primary'."
set +e
run_guest_contract "$primary"
contract_status=$?
set -e
if [ "$contract_status" -ne 0 ]; then
    echo "The raw MacVM contract contains failures; applying the XFAIL policy in the report step." >&2
fi

if [ "$suite" = full ]; then
    echo "Running destructive lifecycle checks on disposable clones."
    run_lifecycle_suite
else
    printf 'test_id\tstatus\tduration_ms\tpolicy\tnote\n' >"$lifecycle_results"
fi

report_args=(
    python3 "$repo_root/tools/compare-docker-compat.py"
    --macvm-results "$macvm_results"
    --macvm-results "$lifecycle_results"
    --xfails "$xfails"
    --output-dir "$artifact_root/report"
    --run-id "$run_id"
    --suite "$suite"
)
if [ "$skip_baseline" = 0 ]; then
    report_args+=(--baseline-results "$baseline_results")
fi
set +e
"${report_args[@]}"
report_status=$?
set -e
if [ "$report_status" -ne 0 ]; then overall_status=1; fi

completed=1
if [ "$overall_status" -ne 0 ]; then
    fail "one or more contract or lifecycle checks failed; see $artifact_root/report/summary.json"
fi
echo "PASS: Docker compatibility contract and lifecycle checks succeeded."
