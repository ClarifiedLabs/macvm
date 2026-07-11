#!/usr/bin/env bash
set -euo pipefail

: "${TAG:?TAG is required}"
: "${PKG_SHA256:?PKG_SHA256 is required}"

tap_dir="${TAP_DIR:?TAP_DIR is required}"
cask_dir="${tap_dir}/Casks"
version="${TAG#v}"

if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Invalid release tag: $TAG" >&2
  exit 2
fi

if [[ ! "$PKG_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
  echo "Invalid package SHA-256: $PKG_SHA256" >&2
  exit 2
fi

mkdir -p "$cask_dir"
cat >"${cask_dir}/macvm.rb" <<CASK
cask "macvm" do
  version "${version}"
  sha256 "${PKG_SHA256}"

  url "https://github.com/ClarifiedLabs/macvm/releases/download/v#{version}/MacVM-#{version}.pkg"
  name "MacVM"
  desc "Create and run macOS virtual machines on Apple silicon"
  homepage "https://github.com/ClarifiedLabs/macvm"

  depends_on arch: :arm64
  depends_on macos: :tahoe

  pkg "MacVM-#{version}.pkg"

  caveats <<~EOS
    Ansible is optional and is required only when using provisioning profiles:
      brew install ansible
  EOS

  uninstall pkgutil: "dev.macvm.macvm.pkg"
end
CASK
