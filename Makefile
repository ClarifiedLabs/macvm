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
XCODE_COMMON_FLAGS = -clonedSourcePackagesDirPath "$(XCODE_SOURCE_PACKAGES)" -skipPackagePluginValidation -skipMacroValidation
XCODE_RESULT_BUNDLE_FLAGS = $(if $(XCODE_RESULT_BUNDLE),-resultBundlePath "$(XCODE_RESULT_BUNDLE)",)

.PHONY: all build build-cli build-app test dist-cli app dev-app package release release-list test-release clean help

all: dist-cli

help:
	@printf '%s\n' \
		'make               Run tests and build the signed dist/macvm binary' \
		'make build         Build the CLI and app in debug mode with xcodebuild' \
		'make build-cli     Build the macvm CLI in debug mode with xcodebuild' \
		'make build-app     Build "MacVM Manager.app" in debug mode with xcodebuild' \
		'make test          Run the Xcode test suite' \
		'make dist-cli      Run tests and build the signed dist/macvm binary' \
		'make app           Run tests and build the signed "dist/MacVM Manager.app"' \
		'make dev-app       Build a signed debug "dist/MacVM Manager.app" (no tests)' \
		'make package       Build a local unsigned installer package for payload testing' \
		'make release       Create a GitHub release tag (VERSION=patch|minor|major|X.Y.Z)' \
		'make release-list  List the current release tag' \
		'make test-release  Run release tooling regression checks' \
		'make clean         Remove build artifacts'

build: build-cli build-app

build-cli:
	$(XCODEBUILD) -project "$(XCODE_PROJECT)" -scheme macvm -configuration Debug -derivedDataPath "$(XCODE_DERIVED_DATA)" $(XCODE_COMMON_FLAGS) build

build-app:
	$(XCODEBUILD) -project "$(XCODE_PROJECT)" -scheme "MacVM Manager" -configuration Debug -derivedDataPath "$(XCODE_DERIVED_DATA)" $(XCODE_COMMON_FLAGS) build

test:
	$(XCODEBUILD) -project "$(XCODE_PROJECT)" -scheme "MacVM Manager" -configuration Debug -derivedDataPath "$(XCODE_DERIVED_DATA)" $(XCODE_COMMON_FLAGS) -destination '$(XCODE_DESTINATION)' $(XCODE_RESULT_BUNDLE_FLAGS) test

dist-cli: test
	XCODE_DERIVED_DATA="$(XCODE_DERIVED_DATA)" XCODE_SOURCE_PACKAGES="$(XCODE_SOURCE_PACKAGES)" ./scripts/build-release.sh

app: test
	XCODE_DERIVED_DATA="$(XCODE_DERIVED_DATA)" XCODE_SOURCE_PACKAGES="$(XCODE_SOURCE_PACKAGES)" ./scripts/build-app.sh

dev-app:
	CONFIG=Debug XCODE_DERIVED_DATA="$(XCODE_DERIVED_DATA)" XCODE_SOURCE_PACKAGES="$(XCODE_SOURCE_PACKAGES)" ./scripts/build-app.sh

package:
	XCODE_DERIVED_DATA="$(XCODE_DERIVED_DATA)" XCODE_SOURCE_PACKAGES="$(XCODE_SOURCE_PACKAGES)" ./scripts/package-release.sh

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

clean:
	rm -rf .build dist
