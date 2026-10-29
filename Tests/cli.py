#!/usr/bin/env python3
"""Check the executable's machine interface without opening capture hardware."""
import json
import os
import pathlib
import socket
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
        self.assertEqual(set(schema["properties"]["command"]["enum"]), {"hdcap", "devices", "modes", "view", "record", "screenshot", "setup", "schema", "upgrade"})
        self.assertIn("error", schema["$defs"])
        self.assertEqual(set(schema["$defs"]["setup"]["properties"]["cameraAuthorization"]["enum"]), {"authorized", "not_determined", "denied", "restricted"})
        self.assertIn("frameRate", schema["$defs"])

    def companion_request(self, *args):
        with tempfile.TemporaryDirectory(prefix="hdcap-", dir="/tmp") as directory, socket.socket(socket.AF_UNIX) as listener:
            address = pathlib.Path(directory) / "Library/Application Support/hdcap/companion.sock"
            address.parent.mkdir(parents=True)
            listener.bind(str(address))
            listener.listen(1)
            listener.settimeout(10)
            env = os.environ | {"HOME": directory, "CFFIXED_USER_HOME": directory, "HDCAP_CAPTURE": "companion"}
            process = subprocess.Popen([BINARY, *args], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
            try:
                with listener.accept()[0] as connection:
                    connection.settimeout(10)
                    with connection.makefile("rwb") as stream:
                        self.assertIn("hello", json.loads(stream.readline()))
                        stream.write(b'{"welcome":{"protocolVersion":1,"companionVersion":"1.0.0","capabilities":["view","record","screenshot"]}}\n')
                        stream.flush()
                        request_line = stream.readline()
                        self.assertTrue(request_line, "CLI disconnected before sending the capture request")
                        request = json.loads(request_line)["request"]["_0"]
                        stream.write(b'{"error":{"_0":{"code":"test_complete","message":"Request checked","details":{}}}}\n')
                        stream.flush()
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 1, stderr)
                self.assertEqual(stdout, "")
                self.assertEqual(json.loads(stderr)["error"]["code"], "test_complete")
                return request
            finally:
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=10)

    def test_capture_commands_preserve_options_sent_to_companion(self):
        for command in ("view", "record", "screenshot"):
            for option, field in (("--device", "deviceName"), ("--device-id", "deviceID")):
                with self.subTest(command=command, option=option), tempfile.TemporaryDirectory() as directory:
                    path = pathlib.Path(directory) / ("capture.png" if command == "screenshot" else "capture.mp4")
                    args = [command] + ([] if command == "view" else [str(path), "--overwrite"])
                    args += [option, "Selected capture device", "--resolution", "1920x1080", "--fps", "60000/1001",
                             "--rotate", "90", "--flip", "horizontal", "--timeout", "7", "--no-input", "--json"]
                    if command != "screenshot":
                        args += ["--duration", "2"]
                    if command == "record":
                        args += ["--codec", "hevc", "--bitrate", "8000000"]
                    job = self.companion_request(*args)[command]["job"]
                    self.assertEqual(job["capture"], {
                        field: "Selected capture device", "resolution": {"width": 1920, "height": 1080},
                        "frameRate": {"numerator": 60000, "denominator": 1001},
                        "transform": {"rotation": 90, "flip": "horizontal"}, "timeout": 7, "noInput": True,
                    })
                    if command != "view":
                        self.assertEqual(job["path"], str(path))
                        self.assertTrue(job["overwrite"])
                    if command != "screenshot":
                        self.assertEqual(job["duration"], 2)
                    if command == "record":
                        self.assertEqual(job["codec"], "hevc")
                        self.assertEqual(job["bitrate"], 8000000)

    def test_help_and_version_are_clean_exits(self):
        for args in [("--help",), ("record", "--help"), ("--version",)]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertTrue(result.stdout)
                self.assertEqual(result.stderr, "")

    def test_short_version_matches_long_version(self):
        expected = self.invoke("--version").stdout
        for args in [("-v",), ("record", "-v"), ("--json", "-v")]:
            with self.subTest(args=args):
                result = self.invoke(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)
                self.assertEqual(result.stderr, "")
        self.assertNotEqual(self.invoke("--", "-v").returncode, 0)


if __name__ == "__main__":
    unittest.main()
