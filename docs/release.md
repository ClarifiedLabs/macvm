# Release Process

MacVM releases contain a signed, notarized `.dmg` app image for Homebrew and a signed, notarized `.pkg` installer for manual installation. Each release also updates the `macvm` cask in `ClarifiedLabs/homebrew-tap`. There is no App Store or TestFlight publishing path.

## Workflows

`test.yml` runs on:

- pushes to `main`
- pushes to `release-ci`
- pull requests
- manual dispatch

`docker-e2e.yml` runs only for trusted upstream refs. Pushes to `main` and `vX.Y.Z` tags run `smoke`; nightly schedules run `full`; pushes to the prerelease `release-ci` branch run `full`; manual dispatch on an allowed ref defaults to `smoke` and may explicitly select `full`. Tags must resolve to a commit on `main`. The workflow has no pull-request trigger.

A GitHub-hosted `authorize` job validates the canonical `ClarifiedLabs/macvm` repository, remote ref, tag ancestry, suite, and exact commit before work is sent to `[self-hosted, macOS, ARM64, macvm-docker-e2e]`. The real-guest job makes a fresh detached exact-SHA checkout under `runner.temp`; no persistent runner checkout is reused. Workflow concurrency serializes all runs that use the configured seed. The suite snapshots the stopped seed's complete filesystem metadata before and after the run, executes repository code only in disposable copy-on-write VM clones, uploads runner/report/failed-clone diagnostics on every outcome, then removes the current run's clones, mounts, and checkout.

Create a GitHub Environment named **`release-ci`**, configure required reviewers with self-review disabled, and restrict deployment branches to `release-ci` before enabling the runner. Any `release-ci` push or manual run targets that Environment, so arbitrary prerelease code cannot reach the self-hosted runner until a reviewer approves it. Main, main-ancestry tags, schedules, and manual runs of those trusted refs use the unprivileged `docker-e2e` Environment. Protect `main` and limit workflow dispatch permission to trusted maintainers. Configure repository variables `MACVM_DOCKER_E2E_SEED` and, when needed, `MACVM_DOCKER_E2E_ROOT`; the seed must remain stopped, SSH-ready, Docker-ready, nonpersonal, and disposable in security terms.

`release.yml` runs on:

- pushes to `release-ci`
- `v*.*.*` tags
- manual dispatch

The release workflow has four jobs:

1. `require-tests` reuses a matching `test.yml` run for the same commit, or dispatches one only when no matching run exists, then waits. An existing failed matching run fails the release job rather than being redispatched.
2. `require-docker-e2e` waits for a successful trusted `docker-e2e.yml` run whose `head_sha` exactly equals the release SHA. It cannot dispatch a replacement run; a missing, failed, or different-SHA result blocks release packaging.
3. `build` signs, notarizes, staples, verifies, and uploads `MacVM-<version>.dmg` and `MacVM-<version>.pkg` only after both gates pass.
4. `homebrew-publish` calculates the disk image SHA-256 and updates `Casks/macvm.rb` in `ClarifiedLabs/homebrew-tap` using a GitHub App installation token. The cask moves `MacVM.app` into Homebrew's configured app directory and links its embedded CLI into `$(brew --prefix)/bin`.

Only tag runs create or update a GitHub Release. `release-ci` runs the full signing, notarization, and packaging path and uploads both files as Actions artifacts without creating a public release.

## Required Secrets

Developer ID signing:

- `DEVELOPER_ID_APPLICATION_CERTIFICATE_BASE64`
- `DEVELOPER_ID_APPLICATION_CERTIFICATE_PASSWORD`
- `DEVELOPER_ID_INSTALLER_CERTIFICATE_BASE64`
- `DEVELOPER_ID_INSTALLER_CERTIFICATE_PASSWORD`

Notarization with App Store Connect API keys:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`

Homebrew tap publishing:

- `HOMEBREW_TAP_APP_CLIENT_ID`
- `HOMEBREW_TAP_APP_PRIVATE_KEY`

The GitHub App must be installed on `ClarifiedLabs/homebrew-tap` with repository Contents read/write permission. The tap repository must already have an initialized default branch; the cask file is created automatically on the first release.

The certificates should be `.p12` exports, base64 encoded without committing them to the repository.

## Testing The Full Release Path

Push a branch named `release-ci`:

```bash
git push origin HEAD:release-ci
```

That branch runs ordinary tests and the protected-Environment `full` real-guest Docker E2E at the same commit, then builds signed and notarized disk-image and package artifacts. A required reviewer must inspect the commit and approve the `release-ci` Environment before self-hosted execution begins. It does not create a GitHub Release. If approval is withheld, the Docker runner is unavailable, or the exact-SHA run fails, the release workflow stops at the gate rather than accepting another commit's result.

## Creating A Release Tag

Use the sshapp-style release helper through Make:

```bash
make release VERSION=patch
make release VERSION=minor
make release VERSION=major
make release VERSION=1.2.3
```

Dry run without changing files, commits, tags, or remotes:

```bash
make release VERSION=patch DRY_RUN=1
```

Create the version commit and tag, then push automatically:

```bash
make release VERSION=patch AUTOPUSH=1
```

`AUTOPUSH=1` pushes the version commit if one was created, verifies the release commit is on `origin/main`, and pushes the tag.

The helper:

1. resolves the next semver from existing `v*.*.*` tags
2. updates Xcode `MARKETING_VERSION`
3. commits with `chore(release): bump version to vX.Y.Z`
4. creates an annotated `vX.Y.Z` tag

Pushing the tag triggers `release.yml`, which builds `dist/MacVM-X.Y.Z.dmg` and `dist/MacVM-X.Y.Z.pkg`, attaches both to the GitHub Release, and publishes the matching Homebrew cask from the disk image. After the workflow succeeds, install it with:

```bash
brew install --cask clarifiedlabs/tap/macvm
```

## Local Artifact Smoke Test

To test both artifact layouts without Developer ID secrets:

```bash
VERSION=$(xcodebuild -project macvm.xcodeproj -scheme "MacVM App" -showBuildSettings 2>/dev/null | awk '$1 == "MARKETING_VERSION" { print $3; exit }')
make package
make verify-package VERSION="$VERSION" VERIFY_MODE=unsigned
```

`make package` already runs the same unsigned verifier; the explicit command is useful when checking artifacts copied from another build directory (`PACKAGE_OUTPUT_DIR=<directory>`). `scripts/verify-release-artifacts.sh` first runs `hdiutil verify`, mounts read-only, tracks every device for cleanup even when attach-plist parsing fails, and expands the PKG privately. It enforces exact DMG-root, package-component, payload, and no-scripts allowlists; exact paths/resources/helpers and arm64 slices; package/app/helper identifiers; an isolated `--version` and bundled-profile CLI self-check; and a recursive type/mode/symlink/SHA-256 manifest match between the DMG and PKG app copies. `VERIFY_MODE=signed` additionally requires exact Developer ID signing identifiers, one consistent team, hardened runtime, virtualization entitlement only on the app and host CLI, no guest-helper entitlements, and successful stapler and Gatekeeper checks for both containers. Signed mode therefore requires notarized artifacts; the release workflow runs it after notarization and stapling.

The disk image contains `MacVM.app` for the Homebrew `app` artifact. The package additionally installs the `/usr/local/bin/macvm` link for manual users. Unsigned local artifacts are for payload inspection only; public artifacts must come from the GitHub release workflow.

The package marks `MacVM.app` as non-relocatable so PackageKit always installs
it at `/Applications/MacVM.app`, even when another build with the same bundle
identifier exists elsewhere on the host.
