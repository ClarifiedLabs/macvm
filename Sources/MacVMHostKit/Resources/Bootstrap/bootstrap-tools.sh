#!/bin/zsh
set -euo pipefail

SHARED_DIR="${MACVM_SHARED_DIR:-/Volumes/My Shared Files}"
TRANSFERS_DIR="$SHARED_DIR/Transfers"
INSTALL_XCODE="${MACVM_INSTALL_XCODE:-0}"
INSTALL_IOS_SIMULATOR="${MACVM_INSTALL_IOS_SIMULATOR:-0}"
INSTALL_PACKAGES="${MACVM_INSTALL_PACKAGES:-1}"
XCODE_SOURCE="${MACVM_XCODE_SOURCE:-}"
IOS_RUNTIME_BUILD="${MACVM_IOS_RUNTIME_BUILD:-}"
SIMULATOR_ARCH="${MACVM_SIMULATOR_ARCH:-arm64}"

log() {
  printf '[bootstrap] %s\n' "$*"
}

fail() {
  printf '[bootstrap] %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage: bootstrap-tools.sh [options]

Options:
  --install-xcode              Install Xcode from --xcode-source or Transfers/
  --xcode-source PATH          Path to Xcode*.xip
  --install-ios-simulator      Download and install the iOS simulator runtime
  --ios-runtime-build VERSION  Pass a specific build version to xcodebuild -downloadPlatform iOS
  --simulator-arch VALUE       arm64 or universal (default: arm64)
  --skip-packages              Skip Homebrew and basic package installation
  --help                       Show this help

Environment overrides:
  MACVM_INSTALL_XCODE=1
  MACVM_XCODE_SOURCE=/path/to/Xcode_26.3.xip
  MACVM_INSTALL_IOS_SIMULATOR=1
  MACVM_INSTALL_PACKAGES=0
  MACVM_IOS_RUNTIME_BUILD=23E522
  MACVM_SIMULATOR_ARCH=arm64

Examples:
  ./bootstrap-tools.sh --install-xcode --install-ios-simulator
  ./bootstrap-tools.sh --install-xcode --xcode-source "/Volumes/My Shared Files/Transfers/Xcode_26.3.xip"
EOF
}

sudo_cmd() {
  if [[ $EUID -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

ensure_sudo_session() {
  if [[ $EUID -eq 0 ]]; then
    return
  fi

  log "Requesting sudo access for Xcode installation tasks..."
  sudo -v
}

find_default_xcode_source() {
  local candidate

  for candidate in "$TRANSFERS_DIR"/Xcode*.xip(N); do
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

find_installed_xcode_app() {
  local candidate

  if [[ -d /Applications/Xcode.app ]]; then
    printf '%s\n' /Applications/Xcode.app
    return 0
  fi

  for candidate in /Applications/Xcode*.app(N); do
    printf '%s\n' "$candidate"
    return 0
  done

  return 1
}

install_xcode_from_source() {
  local source_path="$1"
  local expanded_root=""
  local app_source_path=""
  local target_path=""

  [[ -e "$source_path" ]] || fail "Xcode source not found: $source_path"

  case "$source_path" in
    *.xip)
      expanded_root="$(mktemp -d "${TMPDIR:-/tmp}/macvm-xcode.XXXXXX")"
      log "Expanding $(basename "$source_path")..."
      (
        cd "$expanded_root"
        xip --expand "$source_path"
      )
      app_source_path="$(printf '%s\n' "$expanded_root"/Xcode*.app(N[1]))"
      [[ -n "$app_source_path" ]] || fail "Expanded archive did not contain Xcode.app"
      ;;
    *)
      fail "Unsupported Xcode source: $source_path. Provide Xcode*.xip."
      ;;
  esac

  target_path="/Applications/$(basename "$app_source_path")"

  if [[ "$app_source_path" != "$target_path" ]]; then
    log "Installing $(basename "$app_source_path") into $target_path..."
    sudo_cmd rm -rf "$target_path"
    sudo_cmd ditto "$app_source_path" "$target_path"
  else
    log "Using Xcode already installed at $target_path"
  fi

  if [[ -n "$expanded_root" ]]; then
    rm -rf "$expanded_root"
  fi

  printf '%s\n' "$target_path"
}

select_xcode() {
  local app_path="$1"
  local developer_dir="$app_path/Contents/Developer"

  [[ -d "$developer_dir" ]] || fail "Missing Developer directory in $app_path"

  log "Selecting Xcode developer directory: $developer_dir"
  sudo_cmd xcode-select --switch "$developer_dir"
}

ensure_xcode_ready() {
  if xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    log "Xcode first-launch tasks are already complete."
    return
  fi

  log "Running xcodebuild -runFirstLaunch..."
  sudo_cmd xcodebuild -runFirstLaunch
}

install_ios_simulator_runtime() {
  local cmd=(xcodebuild -downloadPlatform iOS -architectureVariant "$SIMULATOR_ARCH")

  if [[ -n "$IOS_RUNTIME_BUILD" ]]; then
    cmd+=(-buildVersion "$IOS_RUNTIME_BUILD")
  fi

  log "Downloading and installing the iOS simulator runtime..."
  sudo_cmd "${cmd[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install-xcode)
      INSTALL_XCODE=1
      ;;
    --xcode-source)
      shift
      [[ $# -gt 0 ]] || fail "--xcode-source requires a value"
      XCODE_SOURCE="$1"
      ;;
    --install-ios-simulator)
      INSTALL_IOS_SIMULATOR=1
      ;;
    --ios-runtime-build)
      shift
      [[ $# -gt 0 ]] || fail "--ios-runtime-build requires a value"
      IOS_RUNTIME_BUILD="$1"
      ;;
    --simulator-arch)
      shift
      [[ $# -gt 0 ]] || fail "--simulator-arch requires a value"
      SIMULATOR_ARCH="$1"
      ;;
    --skip-packages)
      INSTALL_PACKAGES=0
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option: $1"
      ;;
  esac
  shift
done

case "$SIMULATOR_ARCH" in
  arm64|universal)
    ;;
  *)
    fail "--simulator-arch must be arm64 or universal"
    ;;
esac

log "Preparing macOS guest for common setup tasks..."

if [[ "$INSTALL_XCODE" == "1" || "$INSTALL_IOS_SIMULATOR" == "1" ]]; then
  ensure_sudo_session
fi

if [[ "$INSTALL_XCODE" == "1" ]]; then
  if [[ -z "$XCODE_SOURCE" ]]; then
    XCODE_SOURCE="$(find_default_xcode_source || true)"
  fi

  [[ -n "$XCODE_SOURCE" ]] || fail "No Xcode source found. Put Xcode*.xip in $TRANSFERS_DIR or pass --xcode-source."

  INSTALLED_XCODE_APP="$(install_xcode_from_source "$XCODE_SOURCE")"
  select_xcode "$INSTALLED_XCODE_APP"
  ensure_xcode_ready
fi

if [[ "$INSTALL_IOS_SIMULATOR" == "1" ]]; then
  if ! xcode-select -p >/dev/null 2>&1; then
    INSTALLED_XCODE_APP="$(find_installed_xcode_app || true)"
    [[ -n "$INSTALLED_XCODE_APP" ]] || fail "Cannot install the iOS simulator runtime because no Xcode installation was found."
    select_xcode "$INSTALLED_XCODE_APP"
  fi

  ensure_xcode_ready
  install_ios_simulator_runtime
fi

if [[ "$INSTALL_PACKAGES" != "1" ]]; then
  log "Skipping Homebrew and package installation."
elif ! xcode-select -p >/dev/null 2>&1; then
  log "Developer tools are not configured. Skipping Homebrew and package installation."
else
  if ! command -v brew >/dev/null 2>&1; then
    log "Installing Homebrew..."
    NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  fi

  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  if command -v brew >/dev/null 2>&1; then
    log "Installing basic packages..."
    brew update
    brew install git gh jq gnu-tar
  fi
fi

cat <<'EOF'

Bootstrap complete.

Suggested next steps:
- Use the shared Transfers directory for large archives, installers, and handoff files.
- If you installed Xcode, verify it with: xcodebuild -version
- If you installed the iOS simulator runtime, verify it with: xcrun simctl list runtimes
- To use this VM as a GitHub Actions runner, register the runner with your repository or organization token.

EOF
