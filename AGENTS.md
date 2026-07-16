# Repository Guidelines

## Project Shape
`macvm` is an Xcode project for macOS virtualization. Core code is in `Sources/MacVMHostKit/`, the CLI entrypoint is `Sources/MacVMCLI/main.swift`, the SwiftUI app is in `Sources/MacVM/`, tests are in `Tests/MacVMHostKitTests/` and `Tests/MacVMTests/`, bootstrap resources are in `Sources/MacVMHostKit/Resources/Bootstrap/`, and release signing uses `Support/macvm.entitlements`.

The `MacVM` app (built by Xcode through the `MacVM App` scheme via `make build-app`/`make dist-app`) is the sole owner of ordinary `run` and `run --headless` VMs. The bundled CLI sends acknowledged, full-path requests through the per-user app control queue; `attach` lazily adds a native display to the existing app-owned VM. Setup retains its dedicated `HeadlessRunner` + `MacVMService.provisionSetup` path. The app and embedded CLI are signed with the virtualization entitlement, and `/usr/local/bin/macvm` is a symlink to `MacVM.app/Contents/Helpers/macvm`.

## Automation Modules
Programmatic guest interaction is organized under `Sources/MacVMHostKit/`: `VNC/` (RFB protocol, DES auth, framebuffer, keysyms, the `RFBClient` actor, and the `VNCSession` descriptor), `OCR/` (Vision text recognition and matching), `Setup/` (the `SetupStep` flow model + runner, per-version `SetupFlows`, `GuestHardener`, `GuestProvisioningScript`, `SSHKeyManager`, drivers), and `Network/` (MAC/DHCP/ARP resolution, `GuestSSH`, Ansible inventory). All PRIVATE Virtualization.framework symbols (`_VZVNCServer`, the macOS 27 `VZMacGuestProvisioningOptions`) live only in the separate `Sources/MacVMPrivateVZ/` ObjC target, resolved at runtime via `NSClassFromString`.

Two invariants: (1) `MacVM.app` owns ordinary run lifecycles; `run`, `attach`, and `stop` are control clients, while automation commands (`screenshot`/`type`/`keys`/`vnc`/`wait-text`/`click-text`) attach to the live `Runtime/vnc-session.json` over loopback RFB and error if no session is live. Never terminate a `.manager` PID to stop one VM. (2) The Setup Assistant flow in `SetupFlows` is macOS-version-specific and empirically maintained; verify pane changes against a real guest and update the flow or a bundle `Setup/steps.json` override.

## Build And Test
Use `make` for the standard flow: it runs the Xcode tests, builds release, and stages the Xcode-signed `dist/macvm` with the Virtualization entitlement. Use `make test`, `make build`, `make build-cli`, `make build-app`, and `make release` for narrower work. This repository is not SwiftPM-driven; do not use `swift test`. Use the pinned Swift toolchain in `.swift-version`; the project targets the macOS 26 SDK.

## Coding And Tests
Match nearby Swift style: 4-space indentation, `UpperCamelCase` types, `lowerCamelCase` members, direct CLI help text, and small focused helpers. Tests use Swift Testing (`import Testing`, `@Test`). Add regression tests for bug fixes and update tests when changing CLI parsing, metadata serialization, bundle layout, bootstrap behavior, or VM sizing defaults.

## Workflow Rules
Assume no backwards compatibility or migration work is needed unless explicitly requested. Use conventional commits. Do not create Draft PRs. PRs should include a concise summary, test evidence, and any changed host requirements such as macOS/Xcode version, entitlements, signing, or restore-image behavior.

## Safety
Do not commit VM bundles, restore images, Apple ID data, or generated artifacts such as `.build/`, `.swiftpm/`, or `dist/`. If signing or entitlement behavior changes, update `Support/macvm.entitlements`, `scripts/stage-cli.sh`, and `README.md` together.
