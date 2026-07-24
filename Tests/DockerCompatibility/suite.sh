#!/bin/bash
#
# Portable Docker compatibility contract. This file intentionally stays within
# Bash 3.2 so it can run in a stock macOS guest as well as on the host.

set -u

TARGET=
MODE=full
RESULTS=
LOG_DIR=
RUN_PREFIX=
REQUIRE_AMD64=0
AMD64_STATE=unknown
LOCAL_DAEMON=1
LABEL_KEY=dev.macvm.docker-compat.run

usage() {
    cat <<'EOF'
Usage: suite.sh --target macvm|baseline --mode smoke|full --results PATH
                --logs DIR --prefix PREFIX [--require-amd64 0|1]
                [--amd64-state available|unavailable|unknown]
                [--local-daemon 0|1]
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --target) TARGET=$2; shift 2 ;;
        --mode) MODE=$2; shift 2 ;;
        --results) RESULTS=$2; shift 2 ;;
        --logs) LOG_DIR=$2; shift 2 ;;
        --prefix) RUN_PREFIX=$2; shift 2 ;;
        --require-amd64) REQUIRE_AMD64=$2; shift 2 ;;
        --amd64-state) AMD64_STATE=$2; shift 2 ;;
        --local-daemon) LOCAL_DAEMON=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

case "$TARGET:$MODE:$REQUIRE_AMD64:$LOCAL_DAEMON" in
    macvm:smoke:[01]:[01]|macvm:full:[01]:[01]|baseline:smoke:[01]:[01]|baseline:full:[01]:[01]) ;;
    *) echo "Invalid or incomplete Docker compatibility suite arguments." >&2; usage >&2; exit 2 ;;
esac

if [ -z "$RESULTS" ] || [ -z "$LOG_DIR" ] || [ -z "$RUN_PREFIX" ]; then
    echo "The results, logs, and prefix arguments are required." >&2
    exit 2
fi
case "$RUN_PREFIX" in
    *[!A-Za-z0-9_.-]*|'') echo "The prefix may contain only letters, digits, dots, underscores, and hyphens." >&2; exit 2 ;;
esac

mkdir -p "$LOG_DIR" "$(dirname "$RESULTS")"
printf 'test_id\tstatus\tduration_ms\tpolicy\tnote\n' >"$RESULTS"

RUN_ID=$RUN_PREFIX
WORK_ROOT="$PWD/.macvm-docker-compat-work-$RUN_PREFIX"
[ ! -e "$WORK_ROOT" ] || {
    echo "Docker compatibility work directory already exists: $WORK_ROOT" >&2
    exit 2
}
mkdir "$WORK_ROOT"
CASE_DIR=
CASE_LOG=
TOTAL=0
PASSED=0
FAILED=0
SKIPPED=0

sanitize_note() {
    awk 'NF { line=$0 } END { print line }' "$1" | tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//'
}

skip() {
    echo "SKIP: $*"
    return 77
}

fail() {
    echo "FAIL: $*" >&2
    return 1
}

assert_contains() {
    haystack=$1
    needle=$2
    case "$haystack" in
        *"$needle"*) return 0 ;;
        *) fail "expected output to contain '$needle'; got '$haystack'" ;;
    esac
}

assert_eq() {
    actual=$1
    expected=$2
    if [ "$actual" != "$expected" ]; then
        fail "expected '$expected'; got '$actual'"
    fi
}

container_name() {
    printf '%s-%s' "$RUN_PREFIX" "$1" | tr '.:/' '---' | cut -c 1-60
}

label_args() {
    printf '%s=%s' "$LABEL_KEY" "$RUN_ID"
}

remove_container() {
    docker rm -fv "$1" >/dev/null 2>&1 || true
}

remove_volume() {
    docker volume rm -f "$1" >/dev/null 2>&1 || true
}

remove_network() {
    docker network rm "$1" >/dev/null 2>&1 || true
}

cleanup_resources() {
    if [ -f "$WORK_ROOT/apfs-device" ]; then
        apfs_device=$(cat "$WORK_ROOT/apfs-device")
        case "$apfs_device" in /dev/disk*) hdiutil detach -quiet "$apfs_device" >/dev/null 2>&1 || true ;; esac
    fi
    if [ -f "$WORK_ROOT/swarm-created" ]; then
        docker swarm leave --force >/dev/null 2>&1 || true
    fi
    if [ -f "$WORK_ROOT/kind-cluster" ] && command -v kind >/dev/null 2>&1; then
        kind_cluster=$(cat "$WORK_ROOT/kind-cluster")
        case "$kind_cluster" in "mvm-$TARGET"-[0-9]*) kind delete cluster --name "$kind_cluster" >/dev/null 2>&1 || true ;; esac
    fi
    if [ -f "$WORK_ROOT/ssh-agent-pid" ]; then
        agent_pid=$(cat "$WORK_ROOT/ssh-agent-pid")
        case "$agent_pid" in ''|*[!0-9]*) ;; *) kill "$agent_pid" >/dev/null 2>&1 || true ;; esac
    fi
    if [ -f "$WORK_ROOT/socket-dir" ]; then
        socket_dir=$(cat "$WORK_ROOT/socket-dir")
        case "$socket_dir" in /private/tmp/mvm-dc.*) rm -rf "$socket_dir" ;; esac
    fi
    ids=$(docker ps -aq --filter "label=$LABEL_KEY=$RUN_ID" 2>/dev/null || true)
    for id in $ids; do
        docker rm -fv "$id" >/dev/null 2>&1 || true
    done
    for name in $(docker ps -a --format '{{.Names}}' 2>/dev/null || true); do
        case "$name" in "$RUN_PREFIX"-*) docker rm -fv "$name" >/dev/null 2>&1 || true ;; esac
    done
    ids=$(docker image ls -q --filter "label=$LABEL_KEY=$RUN_ID" 2>/dev/null || true)
    for id in $ids; do
        docker image rm -f "$id" >/dev/null 2>&1 || true
    done
    for reference in $(docker image ls --format '{{.Repository}}:{{.Tag}}' 2>/dev/null || true); do
        case "$reference" in "$RUN_PREFIX"-*) docker image rm -f "$reference" >/dev/null 2>&1 || true ;; esac
    done
    for name in $(docker volume ls -q 2>/dev/null || true); do
        case "$name" in "$RUN_PREFIX"-*) docker volume rm -f "$name" >/dev/null 2>&1 || true ;; esac
    done
    for name in $(docker network ls --format '{{.Name}}' 2>/dev/null || true); do
        case "$name" in "$RUN_PREFIX"-*) docker network rm "$name" >/dev/null 2>&1 || true ;; esac
    done
    rm -rf \
        "$PWD/.macvm-docker-compat-$RUN_PREFIX" \
        "/Users/Shared/.macvm-docker-compat-$RUN_PREFIX" \
        "/private/tmp/.macvm-docker-compat-$RUN_PREFIX"
    rm -rf "$WORK_ROOT"
}
trap cleanup_resources EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

run_case() {
    test_id=$1
    policy=$2
    function_name=$3
    TOTAL=$((TOTAL + 1))
    safe_id=$(printf '%s' "$test_id" | tr '.:/' '---')
    CASE_DIR="$WORK_ROOT/$safe_id"
    CASE_LOG="$LOG_DIR/$safe_id.log"
    mkdir -p "$CASE_DIR"
    started=$(date +%s)
    (
        set -e
        "$function_name"
    ) >"$CASE_LOG" 2>&1
    status=$?
    finished=$(date +%s)
    duration_ms=$(((finished - started) * 1000))
    note=
    if [ -s "$CASE_LOG" ]; then
        note=$(sanitize_note "$CASE_LOG")
    fi
    case "$status" in
        0)
            result=PASS
            PASSED=$((PASSED + 1))
            ;;
        77)
            result=SKIP
            SKIPPED=$((SKIPPED + 1))
            ;;
        *)
            result=FAIL
            FAILED=$((FAILED + 1))
            ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$test_id" "$result" "$duration_ms" "$policy" "$note" >>"$RESULTS"
    printf '%s %s - %s\n' "$result" "$test_id" "$note"
}

test_engine_cli() {
    docker version
    docker info
    docker buildx version
    docker compose version
    server_version=$(docker version --format '{{.Server.Version}}')
    [ -n "$server_version" ] || fail "Docker Server.Version was empty"
    os_type=$(docker info --format '{{.OSType}}')
    assert_eq "$os_type" linux
}

test_pull_tag_inspect() {
    source=alpine:3.23
    tagged="$RUN_PREFIX-pulled:latest"
    docker pull "$source"
    docker tag "$source" "$tagged"
    image_os=$(docker image inspect "$tagged" --format '{{.Os}}')
    image_arch=$(docker image inspect "$tagged" --format '{{.Architecture}}')
    assert_eq "$image_os" linux
    [ -n "$image_arch" ] || fail "image architecture was empty"
    docker image rm "$tagged"
}

test_image_archive() {
    name=$(container_name archive)
    image="$RUN_PREFIX-archive:latest"
    docker create --name "$name" --label "$(label_args)" alpine:3.23 sh
    docker export -o "$CASE_DIR/rootfs.tar" "$name"
    docker import --change "LABEL $LABEL_KEY=$RUN_ID" "$CASE_DIR/rootfs.tar" "$image"
    label=$(docker image inspect "$image" --format "{{index .Config.Labels \"$LABEL_KEY\"}}")
    assert_eq "$label" "$RUN_ID"
    docker save -o "$CASE_DIR/image.tar" "$image"
    docker image rm "$image"
    docker load -i "$CASE_DIR/image.tar"
    output=$(docker run --rm --label "$(label_args)" "$image" /bin/sh -c 'printf archive-marker')
    assert_eq "$output" archive-marker
}

test_container_lifecycle() {
    name=$(container_name lifecycle)
    docker create --name "$name" --label "$(label_args)" alpine:3.23 sh -c 'trap "exit 0" TERM; while :; do sleep 1; done'
    docker start "$name"
    assert_eq "$(docker inspect "$name" --format '{{.State.Running}}')" true
    docker stop -t 5 "$name"
    assert_eq "$(docker inspect "$name" --format '{{.State.ExitCode}}')" 0
    docker start "$name"
    docker kill "$name"
    assert_eq "$(docker inspect "$name" --format '{{.State.Running}}')" false
    docker rm "$name"
}

test_container_operations() {
    name=$(container_name operations)
    renamed=$(container_name renamed)
    docker run -d --name "$name" --label "$(label_args)" alpine:3.23 sleep 300
    docker pause "$name"
    assert_eq "$(docker inspect "$name" --format '{{.State.Paused}}')" true
    docker unpause "$name"
    docker restart -t 5 "$name"
    assert_eq "$(docker inspect "$name" --format '{{.State.Running}}')" true
    docker rename "$name" "$renamed"
    assert_contains "$(docker top "$renamed")" sleep
    assert_eq "$(docker stats --no-stream --format '{{.Name}}' "$renamed")" "$renamed"
}

test_streams_exit() {
    name=$(container_name streams)
    set +e
    output=$(docker run --name "$name" --label "$(label_args)" alpine:3.23 sh -c 'echo stdout-marker; echo stderr-marker >&2; exit 42' 2>&1)
    code=$?
    set -e
    assert_eq "$code" 42
    assert_contains "$output" stdout-marker
    assert_contains "$output" stderr-marker
    stdin_output=$(printf 'stdin-marker\n' | docker run --rm -i --label "$(label_args)" alpine:3.23 cat)
    assert_eq "$stdin_output" stdin-marker
}

test_exec_copy() {
    name=$(container_name execcopy)
    docker run -d --name "$name" --label "$(label_args)" alpine:3.23 sleep 300
    assert_eq "$(docker exec "$name" sh -c 'printf exec-marker')" exec-marker
    printf 'copy-marker\n' >"$CASE_DIR/input.txt"
    docker cp "$CASE_DIR/input.txt" "$name:/tmp/input.txt"
    assert_eq "$(docker exec "$name" cat /tmp/input.txt)" copy-marker
    docker exec "$name" sh -c 'printf "copy-out-marker\n" >/tmp/output.txt'
    docker cp "$name:/tmp/output.txt" "$CASE_DIR/output.txt"
    assert_eq "$(cat "$CASE_DIR/output.txt")" copy-out-marker
}

test_logs_events() {
    name=$(container_name logevents)
    since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker run --name "$name" --label "$(label_args)" alpine:3.23 echo log-marker
    assert_contains "$(docker logs "$name")" log-marker
    sleep 1
    until_time=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    events=$(docker events --since "$since" --until "$until_time" --filter "container=$name" --format '{{.Action}}' || true)
    assert_contains "$events" start
    assert_contains "$events" die
}

test_volume_network() {
    volume="$RUN_PREFIX-data"
    network="$RUN_PREFIX-net"
    docker volume create --label "$(label_args)" "$volume"
    docker network create --label "$(label_args)" "$network"
    docker run --rm --label "$(label_args)" -v "$volume:/data" alpine:3.23 sh -c 'printf volume-marker >/data/value'
    assert_eq "$(docker run --rm --label "$(label_args)" -v "$volume:/data:ro" alpine:3.23 cat /data/value)" volume-marker
    server=$(container_name netserver)
    docker run -d --name "$server" --label "$(label_args)" --network "$network" --network-alias web nginx:1.29-alpine
    docker run --rm --label "$(label_args)" --network "$network" alpine:3.23 sh -c 'until wget -qO- http://web | grep -q "Welcome to nginx"; do sleep 1; done'
}

test_buildx() {
    image="$RUN_PREFIX-build:latest"
    cat >"$CASE_DIR/Dockerfile" <<EOF
FROM alpine:3.23
LABEL $LABEL_KEY=$RUN_ID
ARG VALUE=build-marker
RUN printf '%s' "\$VALUE" >/value
CMD ["cat", "/value"]
EOF
    docker buildx build --load --progress=plain -t "$image" --build-arg VALUE=build-marker "$CASE_DIR"
    assert_eq "$(docker run --rm --label "$(label_args)" "$image")" build-marker
}

test_compose() {
    project=$(container_name compose)
    cat >"$CASE_DIR/compose.yaml" <<EOF
services:
  writer:
    image: alpine:3.23
    command: ["sh", "-c", "printf compose-marker >/data/value"]
    labels:
      $LABEL_KEY: "$RUN_ID"
    volumes:
      - data:/data
  reader:
    image: alpine:3.23
    command: ["cat", "/data/value"]
    labels:
      $LABEL_KEY: "$RUN_ID"
    depends_on:
      writer:
        condition: service_completed_successfully
    volumes:
      - data:/data
volumes:
  data:
    name: "$RUN_PREFIX-compose-data"
EOF
    (
        cd "$CASE_DIR"
        set +e
        output=$(docker compose -p "$project" up --abort-on-container-exit --exit-code-from reader 2>&1)
        code=$?
        set -e
        printf '%s\n' "$output"
        [ "$code" -eq 0 ] || fail "docker compose up failed"
        assert_contains "$output" compose-marker
        docker compose -p "$project" down --volumes
    )
}

test_bind_basic() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote, so host path semantics are not comparable"
    root="$CASE_DIR/bind path ünicode"
    mkdir -p "$root/directory"
    printf 'host-marker\n' >"$root/file.txt"
    output=$(docker run --rm --label "$(label_args)" -v "$root:/host" alpine:3.23 cat /host/file.txt)
    assert_eq "$output" host-marker
    docker run --rm --label "$(label_args)" -v "$root:/host" alpine:3.23 sh -c 'printf container-marker >/host/directory/from-container'
    assert_eq "$(cat "$root/directory/from-container")" container-marker
    set +e
    docker run --rm --label "$(label_args)" -v "$root:/host:ro" alpine:3.23 sh -c 'printf forbidden >/host/nope' >/dev/null 2>&1
    code=$?
    set -e
    [ "$code" -ne 0 ] || fail "read-only bind mount accepted a write"
}

test_bind_inspect_file_deletion() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    root="$CASE_DIR/exact file"
    mkdir -p "$root"
    exact_file="$root/source.txt"
    printf 'exact-marker\n' >"$exact_file"
    name=$(container_name exactfile)
    docker create --name "$name" --label "$(label_args)" \
        --mount "type=bind,source=$exact_file,target=/single.txt" \
        alpine:3.23 sh -c 'cat /single.txt; sleep 300'
    reported_source=$(docker inspect "$name" --format '{{(index .Mounts 0).Source}}')
    assert_eq "$reported_source" "$exact_file"
    assert_eq "$(docker inspect "$name" --format '{{(index .Mounts 0).Type}}')" bind
    docker start "$name"
    assert_eq "$(docker exec "$name" cat /single.txt)" exact-marker
    docker rm -f "$name"

    directory="$root/directory"
    mkdir -p "$directory"
    printf 'delete-from-container\n' >"$directory/container-delete"
    printf 'delete-from-host\n' >"$directory/host-delete"
    name=$(container_name deletion)
    docker run -d --name "$name" --label "$(label_args)" \
        --mount "type=bind,source=$directory,target=/data" alpine:3.23 sleep 300
    reported_source=$(docker inspect "$name" --format '{{(index .Mounts 0).Source}}')
    assert_eq "$reported_source" "$directory"
    docker exec "$name" rm /data/container-delete
    [ ! -e "$directory/container-delete" ] || fail "container-side deletion was not reflected on the host"
    rm "$directory/host-delete"
    set +e
    docker exec "$name" test -e /data/host-delete
    code=$?
    set -e
    [ "$code" -ne 0 ] || fail "host-side deletion was not reflected in the container"
}

exercise_bind_location() {
    host_path=$1
    marker=$2
    mkdir -p "$host_path"
    printf '%s\n' "$marker" >"$host_path/value"
    assert_eq "$(docker run --rm --label "$(label_args)" -v "$host_path:/location" alpine:3.23 cat /location/value)" "$marker"
    docker run --rm --label "$(label_args)" -v "$host_path:/location" alpine:3.23 sh -c 'printf changed >/location/value'
    assert_eq "$(cat "$host_path/value")" changed
    rm -rf "$host_path"
}

test_bind_locations() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    exercise_bind_location "$PWD/.macvm-docker-compat-$RUN_PREFIX" pwd-marker
    exercise_bind_location "/Users/Shared/.macvm-docker-compat-$RUN_PREFIX" users-shared-marker
    exercise_bind_location "/private/tmp/.macvm-docker-compat-$RUN_PREFIX" private-tmp-marker
}

test_bind_symlink() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    mkdir -p "$CASE_DIR/real"
    printf 'symlink-marker\n' >"$CASE_DIR/real/value"
    ln -s "$CASE_DIR/real" "$CASE_DIR/link"
    output=$(docker run --rm --label "$(label_args)" -v "$CASE_DIR/link:/linked" alpine:3.23 cat /linked/value)
    assert_eq "$output" symlink-marker
}

test_bind_apfs_volume() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    command -v hdiutil >/dev/null 2>&1 || skip "hdiutil is unavailable"
    image="$CASE_DIR/compat.dmg"
    volume_name="macvm-compat-$RUN_PREFIX"
    hdiutil create -quiet -size 64m -fs APFS -volname "$volume_name" "$image"
    attach_output=$(hdiutil attach -nobrowse -noverify "$image")
    device=$(printf '%s\n' "$attach_output" | awk '/^\/dev\/disk/ { print $1; exit }')
    mount_point="/Volumes/$volume_name"
    if [ -z "$device" ] || [ ! -d "$mount_point" ]; then
        [ -n "$device" ] && hdiutil detach -quiet "$device" >/dev/null 2>&1 || true
        fail "could not determine the APFS image mount point"
    fi
    printf '%s\n' "$device" >"$WORK_ROOT/apfs-device"
    printf 'volume-marker\n' >"$mount_point/value"
    set +e
    output=$(docker run --rm --label "$(label_args)" -v "$mount_point:/volume" alpine:3.23 cat /volume/value)
    code=$?
    hdiutil detach -quiet "$device"
    detach_code=$?
    rm -f "$WORK_ROOT/apfs-device"
    set -e
    [ "$detach_code" -eq 0 ] || fail "could not detach the compatibility APFS image"
    [ "$code" -eq 0 ] || fail "container could not read the mounted APFS volume"
    assert_eq "$output" volume-marker
}

test_bind_large_tree() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    mkdir -p "$CASE_DIR/tree"
    index=1
    while [ "$index" -le 1000 ]; do
        shard=$((index % 20))
        mkdir -p "$CASE_DIR/tree/$shard"
        printf '%s\n' "$index" >"$CASE_DIR/tree/$shard/file-$index"
        index=$((index + 1))
    done
    count=$(docker run --rm --label "$(label_args)" -v "$CASE_DIR/tree:/tree" alpine:3.23 sh -c 'find /tree -type f | wc -l' | tr -d ' ')
    assert_eq "$count" 1000
}

test_bind_inotify() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    mkdir -p "$CASE_DIR/watch"
    name=$(container_name inotify)
    docker run -d --name "$name" --label "$(label_args)" -v "$CASE_DIR/watch:/watch" alpine:3.23 sh -c \
        'apk add --no-cache inotify-tools >/dev/null && inotifywait -q -e create -t 30 /watch >/result'
    sleep 2
    printf 'event\n' >"$CASE_DIR/watch/from-host"
    deadline=$(( $(date +%s) + 35 ))
    while [ "$(docker inspect "$name" --format '{{.State.Running}}')" = true ] && [ "$(date +%s)" -lt "$deadline" ]; do
        sleep 1
    done
    docker cp "$name:/result" "$CASE_DIR/result"
    assert_contains "$(cat "$CASE_DIR/result")" CREATE
}

test_local_volume_bind() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    source_dir="$CASE_DIR/local-volume"
    volume="$RUN_PREFIX-local"
    mkdir -p "$source_dir"
    printf 'local-volume-marker\n' >"$source_dir/value"
    docker volume create --label "$(label_args)" \
        --driver local --opt type=none --opt o=bind --opt "device=$source_dir" "$volume"
    assert_eq "$(docker run --rm --label "$(label_args)" -v "$volume:/data" alpine:3.23 cat /data/value)" local-volume-marker
}

test_nested_docker_socket() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    if [ -n "${DOCKER_HOST:-}" ]; then
        socket_path=$DOCKER_HOST
    else
        socket_path=$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)
    fi
    case "$socket_path" in
        unix://*) socket_path=${socket_path#unix://} ;;
        *) skip "the active context does not expose a local Unix socket" ;;
    esac
    output=$(docker run --rm --label "$(label_args)" -v "$socket_path:/var/run/docker.sock" docker:28-cli version --format '{{.Server.Os}}')
    assert_eq "$output" linux
}

test_ssh_agent_socket() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    command -v ssh-agent >/dev/null 2>&1 || skip "ssh-agent is unavailable"
    eval "$(ssh-agent -s)" >/dev/null
    agent_pid=$SSH_AGENT_PID
    agent_socket=$SSH_AUTH_SOCK
    printf '%s\n' "$agent_pid" >"$WORK_ROOT/ssh-agent-pid"
    key_path="$CASE_DIR/agent-key"
    ssh-keygen -q -t ed25519 -N '' -f "$key_path"
    ssh-add "$key_path" >/dev/null
    set +e
    output=$(docker run --rm --label "$(label_args)" -e SSH_AUTH_SOCK=/agent.sock -v "$agent_socket:/agent.sock" alpine:3.23 sh -c \
        'apk add --no-cache openssh-client >/dev/null && ssh-add -L')
    code=$?
    kill "$agent_pid" >/dev/null 2>&1 || true
    rm -f "$WORK_ROOT/ssh-agent-pid"
    set -e
    [ "$code" -eq 0 ] || fail "container could not use the relayed SSH agent"
    assert_contains "$output" ssh-ed25519
}

test_stream_socket() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    command -v python3 >/dev/null 2>&1 || skip "python3 is unavailable"
    socket_dir=$(mktemp -d /private/tmp/mvm-dc.XXXXXX)
    printf '%s\n' "$socket_dir" >"$WORK_ROOT/socket-dir"
    socket_path="$socket_dir/echo.sock"
    cat >"$CASE_DIR/server.py" <<'PY'
import socket
import sys

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen(1)
server.settimeout(30)
connection, _ = server.accept()
with connection:
    request = connection.recv(1024)
    connection.sendall(b"stream-marker:" + request)
server.close()
PY
    python3 "$CASE_DIR/server.py" "$socket_path" >"$CASE_DIR/server.log" 2>&1 &
    server_pid=$!
    deadline=$(( $(date +%s) + 10 ))
    while [ ! -S "$socket_path" ] && [ "$(date +%s)" -lt "$deadline" ]; do sleep 1; done
    [ -S "$socket_path" ] || fail "host Unix stream socket was not created"
    set +e
    output=$(docker run --rm --label "$(label_args)" \
        --mount "type=bind,source=$socket_path,target=/relay.sock" \
        python:3.13-alpine python3 -c \
        'import socket; s=socket.socket(socket.AF_UNIX); s.connect("/relay.sock"); s.sendall(b"ping"); print(s.recv(1024).decode()); s.close()')
    code=$?
    if [ "$code" -ne 0 ]; then
        kill "$server_pid" >/dev/null 2>&1 || true
    fi
    wait "$server_pid"
    server_code=$?
    set -e
    [ "$code" -eq 0 ] || fail "container could not use the relayed stream socket"
    [ "$server_code" -eq 0 ] || fail "host stream socket server failed"
    assert_eq "$output" stream-marker:ping
    rm -rf "$socket_dir"
    rm -f "$WORK_ROOT/socket-dir"
}

test_tcp_port() {
    name=$(container_name tcp)
    docker run -d --name "$name" --label "$(label_args)" -p 127.0.0.1::80 nginx:1.29-alpine
    port=$(docker port "$name" 80/tcp | sed 's/.*://')
    [ -n "$port" ] || fail "Docker did not report the published TCP port"
    deadline=$(( $(date +%s) + 30 ))
    until curl -fsS "http://127.0.0.1:$port" >"$CASE_DIR/response"; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "published TCP port did not become reachable"
        sleep 1
    done
    assert_contains "$(cat "$CASE_DIR/response")" "Welcome to nginx"
    interface_ip=
    if command -v ipconfig >/dev/null 2>&1; then
        interface_ip=$(ipconfig getifaddr en0 2>/dev/null || true)
    fi
    if [ -n "$interface_ip" ]; then
        set +e
        curl -fsS --max-time 2 "http://$interface_ip:$port" >/dev/null 2>&1
        code=$?
        set -e
        [ "$code" -ne 0 ] || fail "loopback-only publication was reachable through en0"
    fi
    docker rm -f "$name"
    set +e
    curl -fsS --max-time 2 "http://127.0.0.1:$port" >/dev/null 2>&1
    code=$?
    set -e
    [ "$code" -ne 0 ] || fail "random published port remained reachable after container removal"

    command -v python3 >/dev/null 2>&1 || skip "python3 is unavailable"
    fixed_port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
    fixed_name=$(container_name tcpfixed)
    docker run -d --name "$fixed_name" --label "$(label_args)" -p "0.0.0.0:$fixed_port:80" nginx:1.29-alpine
    deadline=$(( $(date +%s) + 30 ))
    until curl -fsS "http://127.0.0.1:$fixed_port" >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "fixed published TCP port did not become reachable"
        sleep 1
    done
    if [ -n "$interface_ip" ]; then
        curl -fsS "http://$interface_ip:$fixed_port" >/dev/null \
            || fail "all-interface publication was not reachable through en0"
    fi
}

test_udp_port() {
    name=$(container_name udp)
    docker run -d --name "$name" --label "$(label_args)" -p 127.0.0.1::9000/udp \
        python:3.13-alpine python3 -u -c \
        'import socket; s=socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("0.0.0.0", 9000)); exec("while True:\n data, address = s.recvfrom(65535)\n s.sendto(b\"udp-marker:\" + data, address)")'
    port=$(docker port "$name" 9000/udp | sed 's/.*://')
    [ -n "$port" ] || fail "Docker did not report the published UDP port"
    udp_request() {
        python3 - "$port" "$1" <<'PY'
import socket
import sys

client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
client.settimeout(5)
client.sendto(sys.argv[2].encode(), ("127.0.0.1", int(sys.argv[1])))
print(client.recvfrom(65535)[0].decode())
PY
    }
    output=$(udp_request ping)
    assert_contains "$output" udp-marker
    output=$(udp_request second)
    assert_contains "$output" udp-marker
}

test_host_internal() {
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    command -v python3 >/dev/null 2>&1 || skip "python3 is unavailable"
    printf 'host-internal-marker\n' >"$CASE_DIR/index.html"
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("0.0.0.0", 0)); print(s.getsockname()[1]); s.close()')
    (
        cd "$CASE_DIR"
        python3 -m http.server "$port" --bind 0.0.0.0
    ) >"$CASE_DIR/http.log" 2>&1 &
    server_pid=$!
    sleep 2
    set +e
    output=$(docker run --rm --label "$(label_args)" alpine:3.23 wget -qO- "http://host.docker.internal:$port")
    code=$?
    set -e
    kill "$server_pid" >/dev/null 2>&1 || true
    wait "$server_pid" >/dev/null 2>&1 || true
    [ "$code" -eq 0 ] || fail "container could not reach host.docker.internal:$port"
    assert_contains "$output" host-internal-marker
}

test_intentional_rejections() {
    [ "$TARGET" = macvm ] || skip "MacVM-specific rejection semantics are not imposed on the baseline"
    set +e
    docker run --rm -p '[::1]::80' --label "$(label_args)" alpine:3.23 true >"$CASE_DIR/ipv6-only.log" 2>&1
    ipv6_code=$?
    docker run --rm -p 127.0.0.1:28999:80 -p 0.0.0.0:28999:80 \
        --label "$(label_args)" alpine:3.23 true >"$CASE_DIR/ambiguous-port.log" 2>&1
    ambiguous_code=$?
    set -e
    [ "$ipv6_code" -ne 0 ] || fail "IPv6-only publication unexpectedly succeeded"
    [ "$ambiguous_code" -ne 0 ] || fail "ambiguous same-port publication unexpectedly succeeded"
    grep -q 'IPv6 Docker publication' "$CASE_DIR/ipv6-only.log" \
        || fail "IPv6 publication failed without the MacVM compatibility error"
    grep -q 'cannot use multiple host addresses' "$CASE_DIR/ambiguous-port.log" \
        || fail "ambiguous publication failed without the MacVM compatibility error"
}

test_swarm_bind() {
    [ "$TARGET" = macvm ] || skip "the suite does not mutate baseline swarm state"
    [ "$LOCAL_DAEMON" = 1 ] || skip "the selected Docker endpoint is remote"
    state=$(docker info --format '{{.Swarm.LocalNodeState}}')
    [ "$state" = inactive ] || skip "the disposable engine already has swarm state"
    bind_path="$CASE_DIR/swarm"
    mkdir -p "$bind_path"
    printf 'swarm-marker\n' >"$bind_path/value"
    docker swarm init --advertise-addr 127.0.0.1
    touch "$WORK_ROOT/swarm-created"
    service=$(container_name swarm)
    set +e
    (
        set -e
        docker service create --detach=true --name "$service" \
            --mount "type=bind,source=$bind_path,target=/data,readonly" \
            alpine:3.23 sh -c 'cat /data/value; sleep 300'
        deadline=$(( $(date +%s) + 120 ))
        until docker service ps "$service" --filter desired-state=running --format '{{.CurrentState}}' | grep -q '^Running'; do
            [ "$(date +%s)" -lt "$deadline" ] || fail "swarm task did not reach Running"
            sleep 2
        done
        deadline=$(( $(date +%s) + 30 ))
        until docker service logs "$service" 2>&1 | grep -q swarm-marker; do
            [ "$(date +%s)" -lt "$deadline" ] || fail "swarm task did not read the macOS bind mount"
            sleep 2
        done
    )
    code=$?
    docker service rm "$service" >/dev/null 2>&1 || true
    docker swarm leave --force >/dev/null 2>&1 || true
    rm -f "$WORK_ROOT/swarm-created"
    set -e
    return "$code"
}

test_local_registry() {
    registry=$(container_name registry)
    source_image="$RUN_PREFIX-registry-source:latest"
    cat >"$CASE_DIR/Dockerfile" <<EOF
FROM alpine:3.23
LABEL $LABEL_KEY=$RUN_ID
RUN printf registry-marker >/registry-marker
EOF
    docker build -q -t "$source_image" "$CASE_DIR"
    docker run -d --name "$registry" --label "$(label_args)" -p 127.0.0.1::5000 registry:2
    port=$(docker port "$registry" 5000/tcp | sed 's/.*://')
    deadline=$(( $(date +%s) + 60 ))
    until curl -fsS "http://127.0.0.1:$port/v2/" >/dev/null 2>&1; do
        [ "$(date +%s)" -lt "$deadline" ] || fail "local registry did not become ready"
        sleep 1
    done
    remote_image="127.0.0.1:$port/$RUN_PREFIX:latest"
    docker tag "$source_image" "$remote_image"
    docker push "$remote_image"
    docker image rm "$remote_image"
    docker pull "$remote_image"
    label=$(docker image inspect "$remote_image" --format "{{index .Config.Labels \"$LABEL_KEY\"}}")
    assert_eq "$label" "$RUN_ID"
    output=$(docker run --rm --label "$(label_args)" "$remote_image" cat /registry-marker)
    assert_eq "$output" registry-marker
}

test_arch_native() {
    architecture=$(docker run --rm --label "$(label_args)" alpine:3.23 uname -m)
    case "$architecture" in
        aarch64|arm64) ;;
        *) fail "expected native arm64 execution; got $architecture" ;;
    esac
}

test_arch_amd64() {
    if [ "$AMD64_STATE" = unavailable ]; then
        skip "amd64 execution was reported unavailable by the harness"
    fi
    set +e
    architecture=$(docker run --rm --platform linux/amd64 --label "$(label_args)" alpine:3.23 uname -m)
    code=$?
    set -e
    if [ "$code" -ne 0 ]; then
        fail "amd64 container failed: $architecture"
    fi
    case "$architecture" in
        x86_64|amd64) ;;
        *) fail "expected amd64 execution; got $architecture" ;;
    esac
}

test_testcontainers() {
    command -v go >/dev/null 2>&1 || skip "Go is unavailable"
    fixture_dir=$(cd "$(dirname "$0")/testcontainers" && pwd)
    (
        cd "$fixture_dir"
        MACVM_DOCKER_COMPAT_LABEL="$RUN_ID" go test -count=1 -timeout=10m ./...
    )
}

test_kind() {
    command -v kind >/dev/null 2>&1 || skip "kind is unavailable"
    command -v kubectl >/dev/null 2>&1 || skip "kubectl is unavailable"
    checksum=$(printf '%s' "$RUN_ID" | cksum | awk '{ print $1 }')
    cluster="mvm-$TARGET-$checksum"
    printf '%s\n' "$cluster" >"$WORK_ROOT/kind-cluster"
    set +e
    (
        set -e
        kind create cluster --name "$cluster" --wait 5m
        kubectl --context "kind-$cluster" wait --for=condition=Ready node --all --timeout=2m
        kubectl --context "kind-$cluster" create deployment compat-nginx --image=nginx:1.29-alpine
        kubectl --context "kind-$cluster" rollout status deployment/compat-nginx --timeout=3m
        kubectl --context "kind-$cluster" run host-resolver --image=alpine:3.23 --restart=Never -- \
            sh -c 'nslookup host.docker.internal'
        kubectl --context "kind-$cluster" wait --for=jsonpath='{.status.phase}'=Succeeded pod/host-resolver --timeout=2m
        assert_contains "$(kubectl --context "kind-$cluster" logs host-resolver)" host.docker.internal
    )
    code=$?
    kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
    rm -f "$WORK_ROOT/kind-cluster"
    set -e
    return "$code"
}

run_case engine.cli required test_engine_cli
run_case image.pull-tag-inspect required test_pull_tag_inspect
run_case image.archive required test_image_archive
run_case container.lifecycle required test_container_lifecycle
run_case container.operations required test_container_operations
run_case container.streams-exit required test_streams_exit
run_case container.exec-copy required test_exec_copy
run_case container.logs-events required test_logs_events
run_case storage.volume-network required test_volume_network
run_case build.buildx required test_buildx
run_case compose.project required test_compose
run_case bind.basic required test_bind_basic
run_case bind.inspect-file-deletion required test_bind_inspect_file_deletion
run_case ports.tcp required test_tcp_port
run_case network.host-internal required test_host_internal
run_case architecture.native required test_arch_native

if [ "$MODE" = full ]; then
    run_case bind.locations required test_bind_locations
    run_case bind.symlink-unicode required test_bind_symlink
    run_case bind.apfs-volume required test_bind_apfs_volume
    run_case bind.large-tree required test_bind_large_tree
    run_case bind.inotify required test_bind_inotify
    run_case storage.local-bind-volume required test_local_volume_bind
    run_case socket.nested-docker required test_nested_docker_socket
    run_case socket.ssh-agent required test_ssh_agent_socket
    run_case socket.stream required test_stream_socket
    run_case ports.udp required test_udp_port
    run_case network.intentional-rejections required test_intentional_rejections
    run_case swarm.bind required test_swarm_bind
    run_case distribution.local-registry required test_local_registry
    if [ "$REQUIRE_AMD64" = 1 ]; then
        run_case architecture.amd64 required test_arch_amd64
    else
        run_case architecture.amd64 optional test_arch_amd64
    fi
    run_case ecosystem.testcontainers required test_testcontainers
    run_case ecosystem.kind required test_kind
fi

printf '# total=%s pass=%s fail=%s skip=%s\n' "$TOTAL" "$PASSED" "$FAILED" "$SKIPPED"
printf 'total=%s pass=%s fail=%s skip=%s\n' "$TOTAL" "$PASSED" "$FAILED" "$SKIPPED" >"$RESULTS.complete"
if [ "$FAILED" -gt 0 ]; then
    exit 1
fi
