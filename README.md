# hdcap

hdcap captures video from HDMI and UVC capture devices on Apple Silicon. It lists the device's actual formats, opens a plain live window, records H.264 or HEVC, and saves PNG frames.

Cheap HDMI dongles often expose two formats at the same resolution. The decoded `420v` format can deliver 60 fps, while the raw `yuvs` format may stop at 5 or 10 fps. hdcap selects the format that supports the requested frame rate and prefers `420v`. It also holds the device configuration lock while starting capture, so macOS cannot quietly switch the selected format.

Capture uses AVFoundation's native pixel buffers. Rotation and flips use the capture connection. Preview uses Apple's preview layer, recording requires the hardware encoder, and screenshots use a Metal-backed Core Image context. The application does not copy frames into CPU image arrays. PNG compression and file I/O still use the CPU.

## Build

You need an Apple Silicon Mac running macOS 27, Xcode command-line tools with Swift 6.2 or later, and a video capture device. The only package dependency is Apple's Swift Argument Parser.

```sh
swift build -c release
.build/release/hdcap --help
```

The repository also provides a `Justfile`:

```sh
just build
just test
just check
just install
```

`just install` puts the executable in `~/.local/bin`. Add that directory to your `PATH`, or use `.build/release/hdcap` directly.

The executable does not need an app bundle. Run it from your terminal. macOS grants camera permission to the terminal that launches it. If permission is denied, enable that terminal in System Settings > Privacy & Security > Camera.

A terminal signed with hardened runtime also needs a camera entitlement and a camera usage description. If macOS refuses to show the permission dialog, use Terminal or another terminal that supports camera access. Adding those settings to hdcap cannot fix the responsible terminal application.

## Capture

Start by checking the device name and modes:

```sh
hdcap devices
hdcap modes --device 'USB Video'
```

Use the exact name printed by `devices`. If two devices share a name, select one with `--device-id` instead. IDs come from AVFoundation; moving a USB device between ports may change its ID. Device list positions are not selectors.

```sh
hdcap view --device 'USB Video' --resolution 1280x720 --fps 60
hdcap record capture.mp4 --device 'USB Video' --resolution 1280x720 --fps 60
hdcap record capture.mov --device 'USB Video' --resolution 1280x720 --fps 60 --codec hevc --duration 30
hdcap screenshot frame.png --device 'USB Video' --resolution 1280x720 --fps 60
```

Close the preview window or press Ctrl-C to stop. A recording stopped with Ctrl-C or SIGTERM finishes the movie before exiting. Pass `--duration` to stop a preview or recording automatically. Duration starts when video arrives. Press Ctrl-C again to exit immediately during cleanup; an unfinished temporary movie may remain.

Capture commands require both `--resolution` and `--fps`. Unsupported combinations fail with an error. Frame rates accept integers, decimals, or fractions. Common rates such as `59.94` map to `60000/1001`.

UVC devices can advertise nominal 60 fps as 60.00024 because their frame intervals use 100 ns ticks. hdcap accepts this rounding and uses the exact advertised interval. JSON reports the requested `frameRate`, native `actualFrameRate`, and `effectiveFrameDuration` separately. It does not treat 59.94 and 60 as interchangeable.

Add `--rotate 90`, `--rotate 180`, or `--rotate 270` for clockwise rotation. Add `--flip horizontal`, `--flip vertical`, or `--flip both` to flip the result after rotation. Preview, recordings, and screenshots use the same transform. A quarter turn swaps the output dimensions.

Recording defaults to H.264. Use `--codec hevc` for HEVC and `--bitrate 12000000` to set bits per second. Files must end in `.mp4` or `.mov`. The encoder must support hardware encoding; hdcap fails instead of falling back to software. Recording is video only. Audio is not captured.

Existing files are protected. Pass `--overwrite` to replace a destination after the new output finishes successfully. Recording writes a temporary sibling file, then publishes the completed movie. An error may report `partialPath` for an unfinished recording.

## Automation

Every command accepts `--json`. Successful commands write one JSON object to stdout. Failed commands leave stdout empty, write one JSON error object to stderr, and return a nonzero exit status. JSON mode suppresses human progress messages.

```sh
hdcap devices --json | jq '.data[] | {name, id}'
hdcap modes --device 'USB Video' --json
hdcap record capture.mp4 --device 'USB Video' --resolution 1280x720 --fps 60 --duration 5 --no-input --json
hdcap schema --json
```

Results have this envelope:

```json
{"schema_version":1,"command":"devices","data":[]}
```

Errors use the same version and command fields:

```json
{"schema_version":1,"command":"record","error":{"code":"permission_required","message":"Camera permission has not been granted.","details":{}}}
```

Use `error.code` for decisions and `error.message` for display. Parser errors use `invalid_arguments`. Capture errors include `device_not_found`, `ambiguous_device`, `unsupported_mode`, `permission_required`, `permission_denied`, and `capture_timeout`. Fields may be added within schema version 1. Consumers should ignore unknown fields. `hdcap schema` prints the JSON Schema for results and errors without accessing hardware.

`--no-input` prevents camera permission prompts and fails with `permission_required` if authorization has not been granted. Run once from your terminal without that flag to authorize capture. `--timeout` sets the wait for session startup and the first frame, in seconds; the default is 10. It does not limit recording duration or the camera permission dialog. Use `--duration` for bounded recordings. Cleanup is limited to 10 seconds. If a system API stalls during startup or cleanup, hdcap exits with an error; a temporary recording may remain.

Exit status 0 means the operation finished, including a recording stopped and finalized by SIGINT or SIGTERM. Invalid command syntax returns 64. Capture or output failures return 1. An interrupted screenshot returns 130. A second signal exits immediately with 128 plus the signal number.

Capture results include the selected device and mode, measured frame rate, frame counts, dropped frames, and whether the first pixel buffer was backed by an IOSurface. Recording results also include file size, duration, codec, and the hardware-encoder requirement. Device format indexes are diagnostic values and may change between launches.

Shell completion scripts come from Argument Parser:

```sh
hdcap --generate-completion-script zsh
```

## Verify

`just check` builds the executable, tests hardware encoding with generated frames, and checks CLI contracts without opening a capture device. Run `just hardware-check` from a terminal with camera support to request permission and exercise the connected `USB Video` dongle. It saves PNGs, both video codecs, a 30-second recording, and preview statistics in `artifacts/smoke`.

Hardware verification should also exercise an interrupted recording and every rotate/flip combination. Check the result statistics and inspect the saved image or movie; successful command completion alone does not establish frame rate or image orientation.
