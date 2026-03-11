# Repository Guidelines

## Project Shape
`macvm` is an Xcode project for macOS virtualization. Core code is in `Sources/MacVMHostKit/`, the CLI entrypoint is `Sources/macvm/main.swift`, the SwiftUI manager app is `Sources/MacVMManager/`, tests are in `Tests/MacVMHostKitTests/` and `Tests/MacVMManagerTests/`, bootstrap resources are in `Sources/MacVMHostKit/Resources/Bootstrap/`, and release signing uses `Support/macvm.entitlements`.

`MacVM Manager` (built by Xcode via `make app`/`make dev-app`) hosts VMs in-process: viewer windows through `VMViewerController`, setup through `HeadlessRunner` + `MacVMService.provisionSetup`. Like `run --headless`/`setup` it owns `VZVirtualMachine`, so the assembled `.app` is ad-hoc signed with the same virtualization entitlement. `VMViewer` remains the CLI child-process wrapper around `VMViewerController` — keep `macvm run` behavior identical when touching either.

## Automation Modules
Programmatic guest interaction is organized under `Sources/MacVMHostKit/`: `VNC/` (RFB protocol, DES auth, framebuffer, keysyms, the `RFBClient` actor, and the `VNCSession` descriptor), `OCR/` (Vision text recognition and matching), `Setup/` (the `SetupStep` flow model + runner, per-version `SetupFlows`, `GuestHardener`, `GuestProvisioningScript`, `SSHKeyManager`, drivers), and `Network/` (MAC/DHCP/ARP resolution, `GuestSSH`, Ansible inventory). All PRIVATE Virtualization.framework symbols (`_VZVNCServer`, the macOS 27 `VZMacGuestProvisioningOptions`) live only in the separate `Sources/MacVMPrivateVZ/` ObjC target, resolved at runtime via `NSClassFromString`.

Two invariants: (1) only `run --headless` and `setup` own a `VZVirtualMachine`; every other command (`screenshot`/`type`/`keys`/`vnc`/`wait-text`/`click-text`) is an entitlement-free client that attaches to the live `Runtime/vnc-session.json` over loopback RFB, so those commands error if no session is live. (2) The Setup Assistant flow in `SetupFlows` is macOS-version-specific and empirically maintained; verify pane changes against a real guest and update the flow or a bundle `Setup/steps.json` override.

## Build And Test
Use `make` for the standard flow: it runs the Xcode tests, builds release, and stages the Xcode-signed `dist/macvm` with the Virtualization entitlement. Use `make test`, `make build`, `make build-cli`, `make build-app`, and `make release` for narrower work. This repository is not SwiftPM-driven; do not use `swift test`. Use the pinned Swift toolchain in `.swift-version`; the project targets the macOS 26 SDK.

## Coding And Tests
Match nearby Swift style: 4-space indentation, `UpperCamelCase` types, `lowerCamelCase` members, direct CLI help text, and small focused helpers. Tests use Swift Testing (`import Testing`, `@Test`). Add regression tests for bug fixes and update tests when changing CLI parsing, metadata serialization, bundle layout, bootstrap behavior, or VM sizing defaults.

## Workflow Rules
Assume no backwards compatibility or migration work is needed unless explicitly requested. Use conventional commits. Do not create Draft PRs. PRs should include a concise summary, test evidence, and any changed host requirements such as macOS/Xcode version, entitlements, signing, or restore-image behavior.

## Safety
Do not commit VM bundles, restore images, Apple ID data, or generated artifacts such as `.build/`, `.swiftpm/`, or `dist/`. If signing or entitlement behavior changes, update `Support/macvm.entitlements`, `scripts/build-release.sh`, and `README.md` together.
