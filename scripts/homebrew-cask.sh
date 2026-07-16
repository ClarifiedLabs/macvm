#!/usr/bin/env bash
set -euo pipefail

: "${TAG:?TAG is required}"
: "${DMG_SHA256:?DMG_SHA256 is required}"

tap_dir="${TAP_DIR:?TAP_DIR is required}"
cask_dir="${tap_dir}/Casks"
version="${TAG#v}"

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid release tag: $TAG" >&2
  exit 2
fi

if [[ ! "$DMG_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid disk image SHA-256: $DMG_SHA256" >&2
  exit 2
fi

mkdir -p "$cask_dir"
cat >"${cask_dir}/macvm.rb" <<CASK
cask "macvm" do
  version "${version}"
  sha256 "${DMG_SHA256}"

  url "https://github.com/ClarifiedLabs/macvm/releases/download/v#{version}/MacVM-#{version}.dmg"
  name "MacVM"
  desc "Create and run macOS virtual machines on Apple silicon"
  homepage "https://github.com/ClarifiedLabs/macvm"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "MacVM.app"
  binary "#{appdir}/MacVM.app/Contents/Helpers/macvm"

  uninstall quit: "dev.macvm.macvm"

  caveats <<~EOS
    Ansible is optional and is required only when using provisioning profiles:
      brew install ansible
  EOS
end
CASK
