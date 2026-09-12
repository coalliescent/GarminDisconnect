#!/usr/bin/env python3
"""Tests for the remote-Mac build workflow's configuration, and for the repo
staying free of build-host details.

Which Mac this project is built on is deployment-specific (#254): it belongs in
the environment or in tools/mac_build.local.env, which is git-ignored — never
in a tracked file. Two halves here:

  * mac_build.sh's config handling, exercised for real against stub `rsync` and
    `ssh` binaries on PATH, so no Mac and no network are involved; and
  * a hygiene scan of the tracked tree for ssh destinations and mDNS hostnames,
    which is what would catch the next such detail before it is committed.

Pure stdlib, runs anywhere:  python3 tools/test_mac_build.py
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "tools" / "mac_build.sh"
CONFIG_NAME = "mac_build.local.env"

# Hostnames that are obviously placeholders rather than somebody's machine.
# Anything else matching the patterns below is a deployment detail that has
# leaked into the repo.
ALLOWED_HOSTS = {
    "mac.local",
    "your-mac.local",
    "example.com",
    "example.org",
    "example.invalid",
}

# An ssh destination: user@host.tld. Also catches git/scp-style remotes.
SSH_DEST = re.compile(r"\b[a-z_][a-z0-9_.-]*@([a-z0-9][a-z0-9.-]*\.[a-z]{2,})\b", re.I)
# A bare mDNS name, i.e. how Macs on a LAN are usually addressed.
MDNS_HOST = re.compile(r"\b([a-z0-9][a-z0-9-]*\.local)\b", re.I)

# Generated/vendored trees: not ours to police, and full of false positives.
# This file is skipped too — its own example destinations would trip the scan.
SKIP_PREFIXES = ("Resources/web/vendor/", "Resources/icon/", "tools/test_mac_build.py")
# The mDNS scan only covers the kinds of files a build host would be written
# into; `foo.local` is also perfectly ordinary Swift property access.
SCANNED_SUFFIXES = (".md", ".sh", ".py", ".env", ".example", ".txt", ".toml", ".cfg")
SCANNED_NAMES = ("Makefile",)


def is_placeholder(host):
    """example.com and friends are documentation, not a machine someone owns."""
    host = host.lower()
    return host in ALLOWED_HOSTS or any(
        host.endswith("." + allowed) for allowed in ALLOWED_HOSTS
    )


def in_git_checkout():
    """The rsync'd copy on the build host has no .git, so git-based checks skip."""
    return subprocess.run(
        ["git", "-C", str(ROOT), "rev-parse", "--is-inside-work-tree"],
        capture_output=True,
    ).returncode == 0


def tracked_text_files():
    out = subprocess.run(
        ["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True, check=True
    ).stdout.split("\n")
    for name in filter(None, out):
        if name.startswith(SKIP_PREFIXES):
            continue
        try:
            yield name, (ROOT / name).read_text()
        except (UnicodeDecodeError, FileNotFoundError):
            continue  # binary, or a path that only exists in the index


class ScriptHarness(unittest.TestCase):
    """Runs mac_build.sh in a throwaway tree with rsync/ssh stubbed out."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="mac_build_test_"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "tools").mkdir()
        shutil.copy2(SCRIPT, self.tmp / "tools" / SCRIPT.name)
        # Stubs log their argv instead of touching the network. They must be
        # found before the real binaries, hence PATH order below.
        self.log = self.tmp / "calls.log"
        (self.tmp / "bin").mkdir()
        for name in ("rsync", "ssh"):
            stub = self.tmp / "bin" / name
            stub.write_text(f'#!/bin/sh\necho "{name} $*" >> "{self.log}"\n')
            stub.chmod(0o755)

    def run_script(self, *args, env=None):
        environ = dict(os.environ)
        environ.pop("MAC_BUILD_HOST", None)
        environ.pop("MAC_BUILD_DIR", None)
        environ["PATH"] = f"{self.tmp / 'bin'}:{environ['PATH']}"
        environ.update(env or {})
        return subprocess.run(
            ["bash", str(self.tmp / "tools" / SCRIPT.name), *args],
            capture_output=True,
            text=True,
            env=environ,
        )

    def write_config(self, body):
        (self.tmp / "tools" / CONFIG_NAME).write_text(body)

    def calls(self):
        return self.log.read_text() if self.log.exists() else ""


class TestHostConfiguration(ScriptHarness):
    def test_unconfigured_host_fails_before_doing_anything(self):
        r = self.run_script()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("MAC_BUILD_HOST", r.stderr)
        self.assertIn(CONFIG_NAME, r.stderr)
        self.assertEqual(self.calls(), "", "must not sync anything without a host")

    def test_no_default_host_is_compiled_in(self):
        """The bug behind #254: a default host means a real machine's name in git."""
        defaulted = [
            line.strip()
            for line in SCRIPT.read_text().splitlines()
            if re.search(r"MAC_BUILD_HOST:-[^}\s]", line)
        ]
        self.assertEqual(defaulted, [], "mac_build.sh must not default the host")

    def test_help_works_without_any_configuration(self):
        r = self.run_script("--help")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("MAC_BUILD_HOST", r.stdout)
        self.assertIn("rsync + build", r.stdout)

    def test_local_env_file_supplies_the_host(self):
        self.write_config("MAC_BUILD_HOST=builder@somewhere.example.com\n")
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("builder@somewhere.example.com", self.calls())

    def test_environment_beats_the_local_env_file(self):
        self.write_config("MAC_BUILD_HOST=fromfile@example.com\n")
        r = self.run_script(env={"MAC_BUILD_HOST": "fromenv@example.com"})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("fromenv@example.com", self.calls())
        self.assertNotIn("fromfile@example.com", self.calls())

    def test_build_dir_default_and_override(self):
        self.write_config("MAC_BUILD_HOST=h@example.com\n")
        self.assertIn("~/build/GarminDisconnect", self.calls() + self.run_script().stdout)
        self.log.unlink()
        self.write_config("MAC_BUILD_HOST=h@example.com\nMAC_BUILD_DIR=/tmp/elsewhere\n")
        self.assertIn("/tmp/elsewhere", self.run_script().stdout + self.calls())

    def test_example_file_sources_cleanly_and_keeps_tildes_intact(self):
        """An unquoted `~` in the config file expands to the *local* home, which
        then gets handed to the remote host as a path that isn't there."""
        example = SCRIPT.parent / f"{CONFIG_NAME}.example"
        body = example.read_text()
        # Uncomment every assignment, so the commented-out optional ones are
        # checked too, then source it and see what the values became.
        live = "\n".join(
            line.lstrip("#") if line.lstrip("#").startswith("MAC_BUILD_") else line
            for line in body.splitlines()
        )
        (self.tmp / "tools" / CONFIG_NAME).write_text(live)
        r = self.run_script()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn(str(Path.home()), self.calls(), "a local path leaked to the remote")
        self.assertIn("~/build/GarminDisconnect", self.calls())

    def test_example_file_is_tracked_and_real_file_is_not(self):
        if not in_git_checkout():
            self.skipTest("not a git checkout")
        example = f"tools/{CONFIG_NAME}.example"
        tracked = subprocess.run(
            ["git", "-C", str(ROOT), "ls-files", "--error-unmatch", example],
            capture_output=True,
        )
        self.assertEqual(tracked.returncode, 0, f"{example} should be committed")
        ignored = subprocess.run(
            ["git", "-C", str(ROOT), "check-ignore", "-q", f"tools/{CONFIG_NAME}"]
        )
        self.assertEqual(ignored.returncode, 0, f"tools/{CONFIG_NAME} must be gitignored")


class TestRepoCarriesNoHostDetails(unittest.TestCase):
    def setUp(self):
        if not in_git_checkout():
            self.skipTest("not a git checkout")

    def test_no_ssh_destinations_outside_the_placeholder_list(self):
        found = []
        for name, text in tracked_text_files():
            for lineno, line in enumerate(text.splitlines(), 1):
                for m in SSH_DEST.finditer(line):
                    if not is_placeholder(m.group(1)):
                        found.append(f"{name}:{lineno}: {m.group(0)}")
        self.assertEqual(found, [], "ssh destinations in tracked files: " + "; ".join(found))

    def test_no_mdns_hostnames_outside_the_placeholder_list(self):
        found = []
        for name, text in tracked_text_files():
            if not (name.endswith(SCANNED_SUFFIXES) or Path(name).name in SCANNED_NAMES):
                continue
            for lineno, line in enumerate(text.splitlines(), 1):
                for m in MDNS_HOST.finditer(line):
                    if not is_placeholder(m.group(1)):
                        found.append(f"{name}:{lineno}: {m.group(1)}")
        self.assertEqual(found, [], "hostnames in tracked files: " + "; ".join(found))


if __name__ == "__main__":
    unittest.main(verbosity=2, argv=[sys.argv[0]])
