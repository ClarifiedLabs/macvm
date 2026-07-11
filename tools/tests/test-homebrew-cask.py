#!/usr/bin/env python3
"""Tests for Homebrew cask generation and release publishing wiring."""

from __future__ import annotations

import os
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
CASK_SCRIPT = REPO_ROOT / "scripts" / "homebrew-cask.sh"
RELEASE_WORKFLOW = REPO_ROOT / ".github" / "workflows" / "release.yml"


class HomebrewCaskTestCase(unittest.TestCase):
    def test_generates_cask_for_release_package(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            tap_dir = pathlib.Path(tempdir)
            env = os.environ | {
                "TAG": "v1.2.3",
                "PKG_SHA256": "a" * 64,
                "TAP_DIR": str(tap_dir),
            }

            subprocess.run([CASK_SCRIPT], check=True, env=env)

            cask = (tap_dir / "Casks" / "macvm.rb").read_text()
            self.assertIn('version "1.2.3"', cask)
            self.assertIn(f'sha256 "{"a" * 64}"', cask)
            self.assertIn("releases/download/v#{version}/MacVM-#{version}.pkg", cask)
            self.assertIn('depends_on arch: :arm64', cask)
            self.assertIn('depends_on macos: :tahoe', cask)
            self.assertIn('brew install ansible', cask)
            self.assertNotIn('depends_on formula: "ansible"', cask)
            self.assertIn('uninstall pkgutil: "dev.macvm.macvm.pkg"', cask)

    def test_rejects_invalid_checksum(self) -> None:
        with tempfile.TemporaryDirectory() as tempdir:
            env = os.environ | {
                "TAG": "v1.2.3",
                "PKG_SHA256": "not-a-checksum",
                "TAP_DIR": tempdir,
            }

            result = subprocess.run([CASK_SCRIPT], env=env, capture_output=True, text=True)

            self.assertEqual(result.returncode, 2)
            self.assertIn("Invalid package SHA-256", result.stderr)

    def test_release_workflow_uses_tap_github_app(self) -> None:
        workflow = RELEASE_WORKFLOW.read_text()

        self.assertIn("homebrew-publish:", workflow)
        self.assertIn("secrets.HOMEBREW_TAP_APP_CLIENT_ID", workflow)
        self.assertIn("secrets.HOMEBREW_TAP_APP_PRIVATE_KEY", workflow)
        self.assertIn("repository: ClarifiedLabs/homebrew-tap", workflow)
        self.assertIn('git add Casks/macvm.rb', workflow)


if __name__ == "__main__":
    unittest.main()
