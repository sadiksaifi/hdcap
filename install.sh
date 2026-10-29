#!/bin/sh
set -eu

repo=https://github.com/sadiksaifi/hdcap
install_dir=${HDCAP_INSTALL_DIR:-"$HOME/.local/bin"}

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "hdcap requires an Apple silicon Mac running macOS 26 or later." >&2
  exit 1
fi
major=$(sw_vers -productVersion | cut -d . -f 1)
case "$major" in
  ''|*[!0-9]*) echo "Cannot determine the macOS version." >&2; exit 1 ;;
esac
if [ "$major" -lt 26 ]; then
  echo "hdcap requires macOS 26 or later." >&2
  exit 1
fi

download() {
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$@"
}

# Resolve once so every download belongs to the same release.
tag=${HDCAP_VERSION:-}
if [ -z "$tag" ]; then
  release=$(download -o /dev/null -w '%{url_effective}' "$repo/releases/latest")
  tag=${release##*/}
fi
if ! printf '%s\n' "$tag" | grep -Eq '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'; then
  echo "Cannot resolve a stable hdcap release; expected vMAJOR.MINOR.PATCH." >&2
  exit 1
fi

archive=hdcap_darwin_arm64.tar.gz
base=$repo/releases/download/$tag
tmp=$(mktemp -d)
stage=
trap 'rm -rf "$tmp"; if [ -n "$stage" ]; then rm -f "$stage"; fi' 0
trap 'exit 130' INT
trap 'exit 143' TERM

download "$base/$archive" -o "$tmp/$archive"
download "$base/checksums.txt" -o "$tmp/checksums.txt"
awk -v name="$archive" '$2 == name { print; found++ } END { if (found != 1) exit 1 }' \
  "$tmp/checksums.txt" > "$tmp/selected-checksum.txt"
if command -v sha256sum >/dev/null 2>&1; then
  (cd "$tmp" && sha256sum -c selected-checksum.txt)
else
  (cd "$tmp" && shasum -a 256 -c selected-checksum.txt)
fi
tar -xzf "$tmp/$archive" -C "$tmp" hdcap
if [ ! -f "$tmp/hdcap" ] || [ -L "$tmp/hdcap" ]; then
  echo "The release archive does not contain an hdcap executable file." >&2
  exit 1
fi
if [ -d "$install_dir/hdcap" ]; then
  echo "The destination $install_dir/hdcap is a directory." >&2
  exit 1
fi
mkdir -p "$install_dir"
stage=$(mktemp "$install_dir/.hdcap.XXXXXX")
install -m 755 "$tmp/hdcap" "$stage"
mv -f "$stage" "$install_dir/hdcap"
echo "Installed hdcap $tag to $install_dir/hdcap"
case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) printf 'Add it to your PATH: export PATH="%s:%s"\n' "$install_dir" "\$PATH" ;;
esac
