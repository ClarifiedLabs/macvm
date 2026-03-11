# Development

MacVM is an Xcode project for macOS virtualization. It is not SwiftPM-driven; do not use `swift test`.

## Project Layout

- `Sources/MacVMHostKit/`: core VM, automation, VNC, OCR, setup, networking, and shared helpers
- `Sources/macvm/main.swift`: CLI entry point
- `Sources/MacVMManager/`: SwiftUI manager app
- `Sources/MacVMPrivateVZ/`: Objective-C runtime shim for private Virtualization.framework symbols
- `Tests/MacVMHostKitTests/` and `Tests/MacVMManagerTests/`: Swift Testing tests
- `Sources/MacVMHostKit/Resources/Bootstrap/`: guest bootstrap resources
- `Support/macvm.entitlements`: virtualization entitlement used by CLI and app
- `scripts/package-release.sh`: Developer ID signing, notarization, and installer packaging

## Build And Test

Use the pinned Swift toolchain from `.swift-version` and Xcode 26.

```bash
make test
make build
make build-cli
make build-app
make dist-cli
make app
make dev-app
make package
```

`make test` runs the Xcode test suite. `make dist-cli` runs tests and stages `dist/macvm` with the local Xcode signing configuration. `make app` runs tests and stages `dist/MacVM Manager.app`. `make package` builds a local unsigned installer package for payload testing.

The public release package is produced in GitHub Actions with Developer ID signing and notarization.

## Signing

Local Debug and Release builds use ad-hoc signing with `Support/macvm.entitlements` so the CLI and app can use Virtualization.framework.

Public releases use `scripts/package-release.sh` with:

- Developer ID Application signing for `/usr/local/bin/macvm`
- Developer ID Application signing for `/Applications/MacVM Manager.app`
- Developer ID Installer signing for `MacVM-<version>.pkg`
- Apple notarization and stapling for the final package

The package installs:

```text
/usr/local/bin/macvm
/usr/local/bin/macvm_MacVMHostKit.bundle
/Applications/MacVM Manager.app
```

The resource bundle is installed beside the CLI because `MacVMHostKit` loads bootstrap resources relative to the executable.

## Versioning

The Xcode project owns the release version through `MARKETING_VERSION`.

- The CLI embeds an Info.plist section and exposes `macvm --version`.
- MacVM Manager reads the same bundle metadata and shows the version in the sidebar footer.
- `tools/release.py` updates all three-part `MARKETING_VERSION` entries before creating a release tag.

## Runtime Ownership Invariants

Only `run --headless` and `setup` own a `VZVirtualMachine`. Entitlement-free client commands such as `screenshot`, `type`, `keys`, `vnc`, `wait-text`, and `click-text` attach to the live `Runtime/vnc-session.json` over loopback RFB and should error if no session is live.

`MacVM Manager` hosts VMs in-process through `VMViewerController`, `HeadlessRunner`, and `MacVMService.provisionSetup`. `VMViewer` remains the CLI child-process wrapper around `VMViewerController`; keep `macvm run` behavior identical when touching either.

All private Virtualization.framework symbols must stay isolated in `Sources/MacVMPrivateVZ/` and be resolved at runtime.
