#!/bin/sh
set -eu

executable=$1
version=$2
app=$3
case "$app" in
  *.app) ;;
  *) echo "Expected an .app destination, got: $app" >&2; exit 1 ;;
esac
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
install -m 755 "$executable" "$app/Contents/MacOS/HDCap"
cp Companion/Info.plist "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
# Ad-hoc signing gives the app a stable bundle identity for camera permission.
# It does not authenticate a publisher, and macOS may ask again after an update.
codesign --force --sign - --options runtime --entitlements Companion/HDCap.entitlements "$app"
codesign --verify --strict "$app"
