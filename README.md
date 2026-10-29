# hdcap

HDMI and UVC capture for Apple silicon. Live preview, hardware H.264/HEVC recording, PNG screenshots, rotation and flips.

> Cheap dongles often expose a fast video format alongside a slow raw one. hdcap picks the fast format and keeps your chosen resolution and frame rate. JSON output and discoverable schemas make it usable by scripts and AI agents too.

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
| `hdcap setup` | Install the companion app so background tools can capture. |
| `hdcap upgrade` | Upgrade through Homebrew or a verified release download. |
| `hdcap schema --json` | Describe structured output for scripts and agents. |

Add `--json` for machine-readable results. Start with `hdcap --help` for options and `just` for development tasks.

## Capture from background tools

macOS grants camera access per app. Run hdcap from Terminal and Terminal gets the prompt. Run it from a background server or an AI agent, and macOS may refuse to show a prompt at all, so capture fails with `permission_required`.

Run setup once from Terminal:

```sh
hdcap setup
```

Setup downloads a small companion app, checks its checksum and signature, installs it at `~/Applications/HDCap.app`, and asks macOS for camera access for HDCap. After that, `record`, `screenshot`, and `view` hand the camera work to HDCap. Commands, flags, JSON output, and exit codes stay the same, so the tools that call hdcap need no changes.

HDCap has no window or Dock icon. It starts when a command needs it and quits after a minute without one. It adds no login item.

Homebrew and curl install only the CLI. The companion is ad-hoc signed and not notarized, so macOS treats each new version as a new app and asks for camera access again after setup updates it. Set `HDCAP_CAPTURE=direct` to capture in the calling process instead.

Releases use [Tagsmith](https://tagsmith.site/): `npx tagsmith@latest`.

Copyright 2026 Sadik Saifi. Licensed under [GPL-3.0-only](LICENSE).
