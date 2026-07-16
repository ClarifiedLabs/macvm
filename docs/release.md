# Release Process

MacVM releases contain a signed, notarized `.dmg` app image for Homebrew and a signed, notarized `.pkg` installer for manual installation. Each release also updates the `macvm` cask in `ClarifiedLabs/homebrew-tap`. There is no App Store or TestFlight publishing path.

## Workflows

`test.yml` runs on:

- pushes to `main`
- pushes to `release-ci`
- pull requests
- manual dispatch

`release.yml` runs on:

- pushes to `release-ci`
- `v*.*.*` tags
- manual dispatch

The release workflow has three jobs:

1. `require-tests` waits for a successful `test.yml` run for the same commit, or dispatches one and waits.
2. `build` signs, notarizes, staples, and uploads `MacVM-<version>.dmg` and `MacVM-<version>.pkg`.
3. `homebrew-publish` calculates the disk image SHA-256 and updates `Casks/macvm.rb` in `ClarifiedLabs/homebrew-tap` using a GitHub App installation token. The cask moves `MacVM.app` into Homebrew's configured app directory and links its embedded CLI into `$(brew --prefix)/bin`.

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

That branch should run tests, then build signed and notarized disk-image and package artifacts. It does not create a GitHub Release.

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
make package
hdiutil imageinfo dist/MacVM-1.0.0.dmg
pkgutil --payload-files dist/MacVM-1.0.0.pkg
```

The disk image contains `MacVM.app` for the Homebrew `app` artifact. The package additionally installs the `/usr/local/bin/macvm` link for manual users. Unsigned local artifacts are for payload inspection only; public artifacts must come from the GitHub release workflow.
