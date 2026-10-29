# hdcap

HDMI and UVC capture for Apple silicon. Live preview, hardware H.264/HEVC recording, PNG screenshots, rotation and flips.

Cheap dongles often expose a fast video format alongside a slow raw one. hdcap picks the fast format and keeps your chosen resolution and frame rate. JSON output and discoverable schemas make it usable by scripts and AI agents too.

Requires macOS 26 or later. Video only.

## Install

### Homebrew

```sh
brew install sadiksaifi/tap/hdcap
```

### curl

```sh
curl -fsSL https://github.com/sadiksaifi/hdcap/releases/latest/download/install.sh | sh
```

Installs to `~/.local/bin`.

## Usage

| Command | What it does |
| --- | --- |
| `hdcap devices` | List capture devices. |
| `hdcap modes --device "USB Video"` | List resolutions and frame rates. |
| `hdcap view --device "USB Video" --resolution 1280x720 --fps 60` | Show the live feed. |
| `hdcap record capture.mp4 --device "USB Video" --resolution 1280x720 --fps 60` | Record video. |
| `hdcap screenshot frame.png --device "USB Video" --resolution 1280x720 --fps 60` | Save a PNG. |
| `hdcap upgrade` | Upgrade through Homebrew or a verified release download. |
| `hdcap schema --json` | Describe structured output for scripts and agents. |

Add `--json` for machine-readable results. Start with `hdcap --help` for options and `just` for development tasks.

Releases use [Tagsmith](https://tagsmith.site/): `npx tagsmith@latest`.

Copyright 2026 Sadik Saifi. Licensed under [GPL-3.0-only](LICENSE).
