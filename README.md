# hdcap

hdcap captures video from HDMI and UVC devices on Apple silicon Macs.

## What it does

- Lists devices and their available resolutions and frame rates.
- Shows the live feed in a plain window.
- Records H.264 or HEVC using the hardware encoder.
- Saves PNG screenshots and supports rotation and flips.
- Provides JSON output for scripts and AI agents.

## Requirements

- An Apple silicon Mac running macOS 27 or later.
- Xcode with the macOS 27 SDK and [just](https://github.com/casey/just) to build it.

## Install

```sh
just install
```

This builds hdcap and installs it in `~/.local/bin`. Add that directory to your `PATH`.

## Capture

```sh
hdcap devices
hdcap modes --device "USB Video"
hdcap view --device "USB Video" --resolution 1280x720 --fps 60
hdcap record capture.mp4 --device "USB Video" --resolution 1280x720 --fps 60
hdcap screenshot frame.png --device "USB Video" --resolution 1280x720 --fps 60
```

Use the device name shown by `devices`. Allow camera access for your terminal when macOS asks. Close the preview window or press Ctrl-C to stop; recordings finish saving before exiting.

Add `--rotate 180` to turn the image upside down, `--flip horizontal` to mirror it, or `--codec hevc` to record HEVC. Use `--duration 30` for a timed recording. Capture is video only.

## Scripts and agents

Add `--json` for structured results and errors. Use `--no-input` to prevent permission prompts and `--duration` to bound recordings.

```sh
hdcap devices --json
hdcap schema --json
hdcap record --help
```

## Development

```sh
just build
just check
just hardware-check
```

`just check` runs tests. `just hardware-check` exercises the connected capture device and saves results in `artifacts/smoke`.
