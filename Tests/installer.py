#!/usr/bin/env python3
"""Exercise release downloads and installation without network access."""
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

INSTALLER = Path(__file__).resolve().parents[1] / "install.sh"


class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.bin = self.root / "tools"
        self.bin.mkdir()
        self.destination = self.root / "install with spaces"
        self.destination.mkdir()
        self.executable = self.destination / "hdcap"
        self.executable.write_text("old binary")
        self.payload = b"#!/bin/sh\nprintf 'v0.1.0\\n'\n"
        self.archive = self.root / "hdcap_darwin_arm64.tar.gz"
        with tarfile.open(self.archive, "w:gz") as archive:
            member = tarfile.TarInfo("hdcap")
            member.size = len(self.payload)
            member.mode = 0o755
            archive.addfile(member, io.BytesIO(self.payload))
        checksum = hashlib.sha256(self.archive.read_bytes()).hexdigest()
        (self.root / "checksums.txt").write_text(f"{checksum}  {self.archive.name}\n")
        self.env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                        HDCAP_INSTALL_DIR=str(self.destination), FIXTURES=str(self.root))
        self.env.pop("HDCAP_VERSION", None)
        self.stub("uname", 'case "$1" in -s) echo "${TEST_OS:-Darwin}";; -m) echo "${TEST_ARCH:-arm64}";; esac')
        self.stub("sw_vers", 'echo "${TEST_MACOS:-26.0}"')
        self.stub("curl", '''
printf '%s\\n' "$*" >> "$FIXTURES/requests"
case "$*" in
  *"releases/latest"*) printf 'https://github.com/sadiksaifi/hdcap/releases/tag/v0.1.0'; exit 0;;
esac
source=
destination=
while [ "$#" -gt 0 ]; do
  case "$1" in
    https://*) source=${1##*/}; release=$1;;
    -o) shift; destination=$1;;
  esac
  shift
done
case "$release" in
  */releases/download/v0.1.0/*) ;;
  *) exit 20;;
esac
cp "$FIXTURES/$source" "$destination"
''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
        path.chmod(0o755)

    def run_installer(self, **environment):
        return subprocess.run(["/bin/sh", str(INSTALLER)], env=self.env | environment,
                              capture_output=True, text=True, timeout=10)

    def test_latest_release_is_verified_and_installed_atomically(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.executable.read_bytes(), self.payload)
        self.assertTrue(os.access(self.executable, os.X_OK))
        requests = (self.root / "requests").read_text()
        self.assertEqual(requests.count("releases/latest"), 1)
        self.assertIn("releases/download/v0.1.0/hdcap_darwin_arm64.tar.gz", requests)
        self.assertEqual(list(self.destination.glob(".hdcap.*")), [])

    def test_explicit_version_skips_latest_lookup(self):
        result = self.run_installer(HDCAP_VERSION="v0.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("releases/latest", (self.root / "requests").read_text())

    def test_bad_or_ambiguous_checksums_preserve_existing_binary(self):
        for contents in ("0" * 64 + f"  {self.archive.name}\n",
                         (self.root / "checksums.txt").read_text() * 2):
            with self.subTest(contents=contents):
                (self.root / "checksums.txt").write_text(contents)
                result = self.run_installer()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.executable.read_text(), "old binary")

    def test_unsupported_platforms_fail_before_download(self):
        for environment in ({"TEST_OS": "Linux"}, {"TEST_ARCH": "x86_64"},
                            {"TEST_MACOS": "25.6"}):
            with self.subTest(environment=environment):
                result = self.run_installer(**environment)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.executable.read_text(), "old binary")
                self.assertFalse((self.root / "requests").exists())

    def test_invalid_versions_fail_before_download(self):
        for version in ("v0.1.0-beta.1", "main", "v00.1.0", "../../main"):
            with self.subTest(version=version):
                result = self.run_installer(HDCAP_VERSION=version)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.executable.read_text(), "old binary")
                self.assertFalse((self.root / "requests").exists())


if __name__ == "__main__":
    unittest.main()
