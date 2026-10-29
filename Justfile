set shell := ["zsh", "-euo", "pipefail", "-c"]

# Show development commands.
default:
    @just --list

# Build the optimized CLI.
build:
    swift build -c release

# Build with debug symbols.
dev:
    swift build

# Run tests without capture hardware.
test:
    swift test

# Run tests and build the release binary.
check: test build

# Run the optimized CLI, for example: just run devices --json.
run *args: build
    .build/release/hdcap {{args}}

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

# Install the release executable into a user-owned directory.
install prefix=(env("HOME") / ".local"): build
    install -d {{quote(prefix)}}/bin
    install -m 755 .build/release/hdcap {{quote(prefix)}}/bin/hdcap

# Remove generated build files.
clean:
    swift package clean
