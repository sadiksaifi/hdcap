#!/bin/sh
set -eu

python3 - "$@" <<'PY'
import hashlib
import pathlib
import re
import sys

tag, archive, tap = sys.argv[1:]
pattern = r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
match = re.fullmatch(pattern, tag)
if not match:
    sys.exit(f'Expected a stable hdcap release tag, got: {tag}')
version = tag[1:]
formula = pathlib.Path(tap) / 'Formula' / 'hdcap.rb'
if formula.exists():
    current = re.search(r'^  version "([0-9]+\.[0-9]+\.[0-9]+)"$', formula.read_text(), re.MULTILINE)
    if not current:
        sys.exit('Cannot determine the current Homebrew formula version.')
    if tuple(map(int, current[1].split('.'))) > tuple(map(int, version.split('.'))):
        print(f'Skipping {tag}: the tap already has hdcap {current[1]}.')
        sys.exit(0)
with open(archive, 'rb') as source:
    digest = hashlib.file_digest(source, 'sha256').hexdigest()
formula.parent.mkdir(parents=True, exist_ok=True)
formula.write_text(f'''class Hdcap < Formula
  desc "HDMI and UVC capture with Apple silicon hardware encoding"
  homepage "https://github.com/sadiksaifi/hdcap"
  url "https://github.com/sadiksaifi/hdcap/releases/download/{tag}/hdcap_darwin_arm64.tar.gz"
  version "{version}"
  sha256 "{digest}"
  license "GPL-3.0-only"

  depends_on :macos
  depends_on arch: :arm64
  on_macos do
    depends_on macos: :tahoe
  end

  def install
    bin.install "hdcap"
  end

  test do
    assert_match version.to_s, shell_output("#{{bin}}/hdcap --version")
    assert_match "Capture HDMI and UVC", shell_output("#{{bin}}/hdcap --help")
  end
end
''')
PY
