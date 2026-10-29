#!/usr/bin/env python3
"""Check the executable's machine interface without opening capture hardware."""
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

BINARY = str(pathlib.Path(sys.argv.pop(1) if len(sys.argv) > 1 else ".build/debug/hdcap").resolve())


class CLIContract(unittest.TestCase):
    def invoke(self, *args):
        return subprocess.run([BINARY, *args], capture_output=True, text=True, timeout=10)

    def assert_error(self, args, code):
        result = self.invoke(*args)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stdout, "")
        error = json.loads(result.stderr)
        self.assertEqual(error["schema_version"], 1)
        self.assertEqual(error["error"]["code"], code)
        self.assertTrue(error["error"]["message"])
        return result, error

    def test_json_parse_errors_before_or_after_command(self):
        for args in [("--json", "unknown"), ("record", "--json", "--unknown"), ("--json", "record")]:
            with self.subTest(args=args):
                result, _ = self.assert_error(args, "invalid_arguments")
                self.assertEqual(result.returncode, 64)

    def test_invalid_capture_requests_fail_before_permission(self):
        base = ["screenshot", "unused.png", "--device", "imaginary", "--json", "--no-input"]
        cases = [
            (["--resolution", "0x720", "--fps", "60"], "invalid_resolution"),
            (["--resolution", "1280x720", "--fps", "nan"], "invalid_fps"),
            (["--resolution", "1280x720", "--fps", "60", "--rotate", "45"], "invalid_rotation"),
            (["--resolution", "1280x720", "--fps", "60", "--timeout", "0"], "invalid_timeout"),
            (["--resolution", "1280x720", "--fps", "60", "--device-id", "duplicate"], "invalid_arguments"),
        ]
        for extra, code in cases:
            with self.subTest(extra=extra):
                self.assert_error(base + extra, code)

    def test_existing_output_is_protected_before_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "existing.png"
            path.write_bytes(b"existing file")
            self.assert_error([
                "screenshot", str(path), "--device", "imaginary", "--resolution", "1280x720", "--fps", "60", "--no-input", "--json"
            ], "output_exists")
            self.assertEqual(path.read_bytes(), b"existing file")

    def test_schema_is_discoverable_without_hardware(self):
        result = self.invoke("schema", "--json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        envelope = json.loads(result.stdout)
        self.assertEqual(envelope["schema_version"], 1)
        self.assertEqual(envelope["command"], "schema")
        schema = envelope["data"]
        self.assertEqual(schema["$schema"], "https://json-schema.org/draft/2020-12/schema")
        self.assertEqual(set(schema["properties"]["command"]["enum"]), {"hdcap", "devices", "modes", "view", "record", "screenshot", "schema"})
        self.assertIn("error", schema["$defs"])
        self.assertIn("frameRate", schema["$defs"])

    def test_help_and_version_are_clean_exits(self):
        for args in [("--help",), ("record", "--help"), ("--version",)]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout)
                self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
