SHELL := /bin/bash

VERSION ?=
SKIP_TESTS ?=
DRY_RUN ?=
AUTOPUSH ?= 0
RELEASE ?= ./tools/release.py
XCODEBUILD ?= xcodebuild
XCODE_PROJECT ?= macvm.xcodeproj
XCODE_DERIVED_DATA ?= .build/xcode-derived
XCODE_SOURCE_PACKAGES ?= .build/xcode-source-packages
XCODE_DESTINATION ?= platform=macOS,arch=arm64
XCODE_RESULT_BUNDLE ?=
MACVM_TEST_APP_BUNDLE_IDENTIFIER ?= dev.macvm.macvm.test-host
VERIFY_MODE ?= unsigned
PACKAGE_OUTPUT_DIR ?= dist
XCODE_COMMON_FLAGS = -clonedSourcePackagesDirPath "$(XCODE_SOURCE_PACKAGES)" -skipPackagePluginValidation -skipMacroValidation
XCODE_RESULT_BUNDLE_FLAGS = $(if $(XCODE_RESULT_BUNDLE),-resultBundlePath "$(XCODE_RESULT_BUNDLE)",)

.PHONY: all build build-cli build-app test test-provisioning test-provisioning-e2e test-setup-e2e test-docker-compat-tools test-docker-e2e dist dist-cli dist-app package verify-package release release-list test-release clean help

all: dist

help:
	@printf '%s\n' \
		'make               Run tests and build the signed CLI and app in dist/' \
		'make build         Build the CLI and app in debug mode with xcodebuild' \
		'make build-cli     Build the macvm CLI in debug mode with xcodebuild' \
		'make build-app     Build "MacVM.app" in debug mode with xcodebuild' \
		'make test          Run the Xcode test suite' \
		'make test-provisioning  Syntax-check bundled and example Ansible playbooks' \
		'make test-provisioning-e2e  Create a real VM and smoke-test provisioning' \
		'make test-setup-e2e  Install one seed and soak Setup Assistant on three APFS clones' \
		'make test-docker-compat-tools  Test Docker compatibility result classification' \
		'make test-docker-e2e MACVM_DOCKER_E2E_SEED=<name>  Compare a disposable Docker VM with the host Docker endpoint' \
		'make dist          Run tests and build the signed CLI and app in dist/' \
		'make dist-cli      Run tests and build the signed dist/macvm binary' \
		'make dist-app      Run tests and build the signed "dist/MacVM.app"' \
		'make package       Build and verify local unsigned DMG and PKG release artifacts' \
		'make verify-package VERSION=X.Y.Z [VERIFY_MODE=unsigned|signed]  Verify existing release artifacts' \
		'make release       Create a GitHub release tag (VERSION=patch|minor|major|X.Y.Z)' \
		'make release-list  List the current release tag' \
		'make test-release  Run release tooling regression checks' \
		'make clean         Remove build artifacts'

build: build-cli build-app

build-cli:
	$(XCODEBUILD) -project "$(XCODE_PROJECT)" -scheme "MacVM CLI" -configuration Debug -derivedDataPath "$(XCODE_DERIVED_DATA)" $(XCODE_COMMON_FLAGS) build

build-app:
	$(XCODEBUILD) -project "$(XCODE_PROJECT)" -scheme "MacVM App" -configuration Debug -derivedDataPath "$(XCODE_DERIVED_DATA)" $(XCODE_COMMON_FLAGS) build

test:
	$(XCODEBUILD) -project "$(XCODE_PROJECT)" -scheme "MacVM App" -configuration Debug -derivedDataPath "$(XCODE_DERIVED_DATA)" $(XCODE_COMMON_FLAGS) MACVM_APP_BUNDLE_IDENTIFIER="$(MACVM_TEST_APP_BUNDLE_IDENTIFIER)" -destination '$(XCODE_DESTINATION)' $(XCODE_RESULT_BUNDLE_FLAGS) test

test-provisioning:
	@./scripts/check-provisioning-playbooks.sh

test-provisioning-e2e: build-cli
	@MACVM_E2E_BINARY="$(abspath $(XCODE_DERIVED_DATA))/Build/Products/Debug/macvm" ./scripts/test-provisioning-e2e.sh

test-setup-e2e: build-cli
	@MACVM_E2E_BINARY="$(abspath $(XCODE_DERIVED_DATA))/Build/Products/Debug/macvm" ./scripts/test-setup-e2e.sh

test-docker-compat-tools:
	@python3 tools/tests/test-docker-compat.py

test-docker-e2e: build-cli build-app test-docker-compat-tools
	@MACVM_E2E_BINARY="$(abspath $(XCODE_DERIVED_DATA))/Build/Products/Debug/macvm" \
		MACVM_E2E_APP_PATH="$(abspath $(XCODE_DERIVED_DATA))/Build/Products/Debug/MacVM.app" \
		./scripts/test-docker-e2e.sh

dist: dist-cli dist-app

dist-cli: test
	XCODE_DERIVED_DATA="$(XCODE_DERIVED_DATA)" XCODE_SOURCE_PACKAGES="$(XCODE_SOURCE_PACKAGES)" ./scripts/stage-cli.sh

dist-app: test
	XCODE_DERIVED_DATA="$(XCODE_DERIVED_DATA)" XCODE_SOURCE_PACKAGES="$(XCODE_SOURCE_PACKAGES)" ./scripts/stage-app.sh

package:
	XCODE_DERIVED_DATA="$(XCODE_DERIVED_DATA)" XCODE_SOURCE_PACKAGES="$(XCODE_SOURCE_PACKAGES)" ./scripts/package-release.sh

verify-package:
	@version="$(VERSION)"; \
	if [ -z "$$version" ]; then \
		version="$$(awk -F ' = |;' '/MARKETING_VERSION = [0-9]+[.][0-9]+[.][0-9]+;/ { print $$2; exit }' "$(XCODE_PROJECT)/project.pbxproj")"; \
	fi; \
	./scripts/verify-release-artifacts.sh \
		--mode "$(VERIFY_MODE)" \
		--version "$$version" \
		--dmg "$(PACKAGE_OUTPUT_DIR)/MacVM-$$version.dmg" \
		--pkg "$(PACKAGE_OUTPUT_DIR)/MacVM-$$version.pkg"

release-list:
	@$(RELEASE) list

release:
	@if [ -z "$(VERSION)" ]; then \
		echo "VERSION is required. Use: make release VERSION=<patch|minor|major|X.Y.Z>"; \
		exit 2; \
	fi
	@if [ -z "$(SKIP_TESTS)" ]; then \
		echo "Running release regression tests..."; \
		$(MAKE) --no-print-directory test-release; \
	fi
	@args=(release --version "$(VERSION)"); \
	if [ -n "$(DRY_RUN)" ]; then args+=(--dry-run); fi; \
	if [ "$(AUTOPUSH)" = "1" ]; then args+=(--push); fi; \
	$(RELEASE) "$${args[@]}"

test-release:
	@python3 tools/tests/test-release.py
	@python3 tools/tests/test-workflows.py
	@python3 tools/tests/test-homebrew-cask.py
	@python3 tools/tests/test-package.py

clean:
	rm -rf .build dist
