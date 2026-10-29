set shell := ["zsh", "-euo", "pipefail", "-c"]
set positional-arguments

# Show development commands.
default:
    @just --list

# Build the optimized CLI.
build:
    swift build -c release >&2

# Build with debug symbols.
dev:
    swift build

# Run tests without capture hardware.
test: dev
    swift test
    python3 Tests/cli.py .build/debug/hdcap
    python3 Tests/installer.py
    python3 Tests/upgrade.py .build/debug/hdcap

# Run tests and build the release binary and companion app.
check: test build companion-bundle

# Build the companion app bundle at .build/HDCap.app.
companion-bundle: build
    sh .github/scripts/bundle-companion.sh .build/release/hdcap-companion 0.0.0 .build/HDCap.app

# Install a development companion at ~/Applications/HDCap.app. Run hdcap setup afterward.
companion: companion-bundle
    #!/usr/bin/env bash
    set -euo pipefail
    app="$HOME/Applications/HDCap.app"
    pkill -f "$app/Contents/MacOS/HDCap" || true
    while pgrep -f "$app/Contents/MacOS/HDCap" > /dev/null; do sleep 0.1; done
    mkdir -p "$HOME/Applications"
    rm -rf "$app"
    ditto .build/HDCap.app "$app"
    echo "Installed $app. macOS asks for camera access again after each rebuild."

# Run the optimized CLI, for example: just run devices --json.
run *args: build
    .build/release/hdcap "$@"

# List connected video capture devices.
devices: build
    .build/release/hdcap devices

# List every advertised format and frame-rate range for a device.
modes device="USB Video": build
    .build/release/hdcap modes --device {{quote(device)}}

# Test PNG, transforms, and both hardware encoders with the real dongle.
smoke device="USB Video": build
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p artifacts/smoke
    binary=.build/release/hdcap
    "$binary" devices --json > artifacts/smoke/devices.json
    "$binary" modes --device {{quote(device)}} --json > artifacts/smoke/modes.json
    "$binary" screenshot artifacts/smoke/frame.png --device {{quote(device)}} --resolution 1280x720 --fps 60 --overwrite --no-input --json
    "$binary" screenshot artifacts/smoke/rotated.png --device {{quote(device)}} --resolution 1280x720 --fps 60 --rotate 90 --flip horizontal --overwrite --no-input --json
    for codec in h264 hevc; do
        "$binary" record "artifacts/smoke/$codec.mp4" --device {{quote(device)}} --resolution 1280x720 --fps 60 --codec "$codec" --duration 5 --overwrite --no-input --json
    done

# Request terminal camera permission, then exercise the connected device.
hardware-check device="USB Video": build
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p artifacts/smoke
    binary=.build/release/hdcap
    "$binary" screenshot artifacts/smoke/permission.png --device {{quote(device)}} --resolution 1280x720 --fps 60 --overwrite --json > artifacts/smoke/permission.json
    just smoke {{quote(device)}}
    "$binary" record artifacts/smoke/sustained.mp4 --device {{quote(device)}} --resolution 1280x720 --fps 60 --codec hevc --duration 30 --overwrite --no-input --json > artifacts/smoke/sustained.json
    "$binary" view --device {{quote(device)}} --resolution 1280x720 --fps 60 --duration 3 --no-input --json > artifacts/smoke/view.json
    echo "Hardware results saved in artifacts/smoke."

# Install the release executable into a user-owned directory.
install prefix=(env("HOME") / ".local"): build
    install -d {{quote(prefix)}}/bin
    install -m 755 .build/release/hdcap {{quote(prefix)}}/bin/hdcap

# Remove generated build files.
clean:
    swift package clean
