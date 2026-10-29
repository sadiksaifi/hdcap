#!/bin/sh
set -eu

tag=$1
out=$2
if ! printf '%s\n' "$tag" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
  echo "Expected a stable hdcap release tag, got: $tag" >&2
  exit 1
fi
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "Release archives must be built on an Apple silicon Mac." >&2
  exit 1
fi
version=${tag#v}
original=$(mktemp)
cp Sources/hdcap/BuildVersion.swift "$original"
trap 'cp "$original" Sources/hdcap/BuildVersion.swift; rm -f "$original"' 0
trap 'exit 130' INT
trap 'exit 143' TERM
python3 - "$version" <<'PY'
import pathlib
import sys

path = pathlib.Path('Sources/hdcap/BuildVersion.swift')
source = path.read_text()
placeholder = 'static let release = "0.0.0"'
if source.count(placeholder) != 1:
    sys.exit('Expected one release version placeholder in BuildVersion.swift.')
path.write_text(source.replace(placeholder, f'static let release = "{sys.argv[1]}"'))
PY
just check

mkdir -p "$out/stage"
install -m 755 .build/release/hdcap "$out/stage/hdcap"
cp LICENSE "$out/stage/LICENSE"
# Sign the final bytes before calculating either archive or installer checksums.
codesign --force --sign - "$out/stage/hdcap"
codesign --verify --strict "$out/stage/hdcap"
if [ "$("$out/stage/hdcap" --version)" != "$version" ]; then
  echo "The release executable has the wrong version." >&2
  exit 1
fi
if ! xcrun vtool -show-build "$out/stage/hdcap" | grep -Eq 'minos[[:space:]]+26\.0'; then
  echo "The release executable must support macOS 26.0." >&2
  exit 1
fi
tar -czf "$out/hdcap_darwin_arm64.tar.gz" -C "$out/stage" hdcap LICENSE

# hdcap setup downloads the companion separately; install.sh installs only the CLI.
app="$out/stage/HDCap.app"
sh .github/scripts/bundle-companion.sh .build/release/hdcap-companion "$version" "$app"
if [ "$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist")" != "$version" ]; then
  echo "The companion app has the wrong version." >&2
  exit 1
fi
if ! xcrun vtool -show-build "$app/Contents/MacOS/HDCap" | grep -Eq 'minos[[:space:]]+26\.0'; then
  echo "The companion app must support macOS 26.0." >&2
  exit 1
fi
# Leave out AppleDouble metadata, which would invalidate the bundle signature.
COPYFILE_DISABLE=1 tar --no-mac-metadata -czf "$out/hdcap-companion_darwin_arm64.tar.gz" -C "$out/stage" HDCap.app

cp install.sh "$out/install.sh"
(cd "$out" && shasum -a 256 hdcap_darwin_arm64.tar.gz hdcap-companion_darwin_arm64.tar.gz install.sh > checksums.txt)
rm -rf "$out/stage"
