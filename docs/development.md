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
make dist
make dist-cli
make dist-app
make package
```

`make build`, `make build-cli`, and `make build-app` produce locally signed Debug products in Xcode's derived data without running tests. `make test` runs the Xcode test suite. Bare `make` and `make dist` run tests and stage Release builds of both `dist/macvm` and `dist/MacVM Manager.app` with the local Xcode signing configuration. Use `make dist-cli` or `make dist-app` to test and stage only one product. `make package` builds a local unsigned installer package for payload testing.

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

`run`, `run --headless`, and `setup` own a `VZVirtualMachine`. Every owner publishes a password-protected `Runtime/vnc-session.json`. Entitlement-free client commands such as `attach`, `screenshot`, `type`, `keys`, `vnc`, `wait-text`, and `click-text` attach to that live session over loopback RFB and should error if no session is live. The private server itself binds beyond loopback, so the password is mandatory.

`MacVM Manager` hosts VMs in-process through `VMViewerController`, `HeadlessRunner`, and `MacVMService.provisionSetup`. These runtimes use the `manager` owner role so an external `macvm stop` never terminates the multi-VM app. Manager power actions call the specific in-process owner. `VMViewer` remains the CLI child-process wrapper around `VMViewerController`; keep `macvm run` behavior identical when touching either. Native display close requests always hide the window without ending the VM.

All private Virtualization.framework symbols must stay isolated in `Sources/MacVMPrivateVZ/` and be resolved at runtime.
