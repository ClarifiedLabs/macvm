# Development

MacVM is an Xcode project for macOS virtualization. It is not SwiftPM-driven; do not use `swift test`.

## Project Layout

- `Sources/MacVMHostKit/`: core VM, automation, VNC, OCR, setup, networking, and shared helpers
- `Sources/MacVMCLI/main.swift`: CLI entry point
- `Sources/MacVM/`: SwiftUI app
- `Sources/MacVMPrivateVZ/`: Objective-C runtime shim for private Virtualization.framework symbols
- `Tests/MacVMHostKitTests/` and `Tests/MacVMTests/`: Swift Testing tests
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

`make build`, `make build-cli`, and `make build-app` produce locally signed Debug products in Xcode's derived data without running tests. `make test` runs the Xcode test suite. Bare `make` and `make dist` run tests and stage Release builds of both `dist/macvm` and `dist/MacVM.app` with the local Xcode signing configuration. Use `make dist-cli` or `make dist-app` to test and stage only one product. `make package` builds a local unsigned installer package for payload testing.

The public release package is produced in GitHub Actions with Developer ID signing and notarization.

## Signing

Local Debug and Release builds use ad-hoc signing with `Support/macvm.entitlements` so the CLI and app can use Virtualization.framework.

Public releases use `scripts/package-release.sh` with:

- Developer ID Application signing for `/Applications/MacVM.app/Contents/Helpers/macvm`
- Developer ID Application signing for `/Applications/MacVM.app` after its nested helper
- Developer ID Installer signing for `MacVM-<version>.pkg`
- Apple notarization and stapling for the final package

The package installs:

```text
/Applications/MacVM.app
/Applications/MacVM.app/Contents/Helpers/macvm
/Applications/MacVM.app/Contents/Resources/macvm_MacVMHostKit.bundle
/usr/local/bin/macvm -> ../../../Applications/MacVM.app/Contents/Helpers/macvm
```

The app target embeds the CLI with Code Sign On Copy. Release packaging signs the helper first and the outer app last; `/usr/local/bin/macvm` is only a symlink, so the app and CLI cannot drift between versions.

## Versioning

The Xcode project owns the release version through `MARKETING_VERSION`.

- The CLI embeds an Info.plist section and exposes `macvm --version`.
- MacVM reads the same bundle metadata and shows the version in the sidebar footer.
- `tools/release.py` updates all three-part `MARKETING_VERSION` entries before creating a release tag.

## Runtime Ownership Invariants

`MacVM.app` owns every ordinary `run` and `run --headless` VM in-process. The CLI resolves the VM to a canonical full bundle path and uses the per-user file-backed control queue for acknowledged run, attach, and stop requests. `--headless` controls only the initial presentation: `attach` adds a `VZVirtualMachineView` to the existing VM without restarting it. Setup can still use its dedicated `HeadlessRunner` ownership path.

Every owner publishes a password-protected `Runtime/vnc-session.json`. Entitlement-free automation commands such as `screenshot`, `type`, `keys`, `vnc`, `wait-text`, and `click-text` attach to that live session over loopback RFB and should error if no session is live. The private server itself binds beyond loopback, so the password is mandatory. App runtimes use the `manager` owner role; never signal that PID to stop one VM. Route the request to the app and stop its path-keyed `VMViewerController` instead. Native display close requests always hide the window without ending the VM.

All private Virtualization.framework symbols must stay isolated in `Sources/MacVMPrivateVZ/` and be resolved at runtime.
