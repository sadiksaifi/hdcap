# hdcap

HDMI and UVC capture for Apple silicon. Live preview, hardware H.264/HEVC recording, PNG screenshots, rotation and flips.

Cheap dongles often expose a fast video format alongside a slow raw one. hdcap picks the fast format and keeps your chosen resolution and frame rate. JSON output and discoverable schemas make it usable by scripts and AI agents too.

Requires macOS 26+, Xcode and [just](https://github.com/casey/just). Video only.

```sh
hdcap devices
hdcap view --device "USB Video" --resolution 1280x720 --fps 60
```

Start with `hdcap --help` for commands and `just` for development tasks.

Copyright 2026 Sadik Saifi. Licensed under [GPL-3.0-only](LICENSE).
