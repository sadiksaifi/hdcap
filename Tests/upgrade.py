#!/usr/bin/env python3
"""Exercise Homebrew ownership and failure handling without a network update."""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

BINARY = pathlib.Path(sys.argv.pop(1) if len(sys.argv) > 1 else ".build/debug/hdcap").resolve()


class UpgradeContract(unittest.TestCase):
    def test_homebrew_uses_owning_prefix_and_never_replaces_directly(self):
        for failure in ("", "update", "upgrade", "missing"):
            with self.subTest(failure=failure), tempfile.TemporaryDirectory(prefix="hdcap brew ") as directory:
                prefix = pathlib.Path(directory)
                executable = prefix / "Cellar/hdcap/0.1.0/bin/hdcap"
                executable.parent.mkdir(parents=True)
                shutil.copy2(BINARY, executable)
                original = executable.read_bytes()
                (prefix / "bin").mkdir()
                linked = prefix / "bin/hdcap"
                linked.write_text("#!/bin/sh\nprintf '0.2.0\\n'\n")
                linked.chmod(0o755)
                brew = prefix / "bin/brew"
                if failure != "missing":
                    brew.write_text("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$HDCAP_TEST_LOG\"\nprintf 'brew progress\\n'\n"
                                    "if [ \"$1\" = \"$HDCAP_TEST_FAILURE\" ]; then exit 7; fi\n")
                    brew.chmod(0o755)
                env = os.environ | {"HDCAP_TEST_LOG": str(prefix / "commands"), "HDCAP_TEST_FAILURE": failure}
                result = subprocess.run([str(executable), "upgrade", "--json"], capture_output=True, text=True, env=env, timeout=15)
                if failure:
                    self.assertEqual(result.returncode, 1, result)
                    self.assertEqual(result.stdout, "")
                    error = json.loads(result.stderr)
                    self.assertEqual(error["error"]["code"], "upgrade_failed")
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    data = json.loads(result.stdout)["data"]
                    self.assertEqual(data["method"], "homebrew")
                    self.assertEqual(data["version"], "0.2.0")
                    self.assertTrue(data["updated"])
                    self.assertEqual(result.stderr, "")
                self.assertEqual(executable.read_bytes(), original)
                if failure != "missing":
                    expected = "update\n" if failure == "update" else "update\nupgrade sadiksaifi/tap/hdcap\n"
                    self.assertEqual((prefix / "commands").read_text(), expected)

    def test_development_build_is_rejected_before_network_access(self):
        version = subprocess.run([str(BINARY), "--version"], capture_output=True, text=True, check=True, timeout=5).stdout.strip()
        if "-dev." not in version and version != "0.0.0":
            self.skipTest("This check requires a development build.")
        result = subprocess.run([str(BINARY), "upgrade", "--json"], capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertEqual(json.loads(result.stderr)["error"]["code"], "development_build")


if __name__ == "__main__":
    unittest.main()
