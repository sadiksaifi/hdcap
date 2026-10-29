# hdcap

A macOS CLI for HDMI and UVC capture on Apple silicon.

## Architecture

- Prefer Apple frameworks and maintained libraries. Every line we own is maintenance. Put behavior and cleanup in deep modules with narrow interfaces.
- Keep continuous pixel processing on the GPU and media engine. Preserve native pixel buffers and bounded buffering through capture and recording.
- Preserve explicit device and mode selection. Keep the configuration lock across capture startup; macOS can otherwise reset the format.
- Treat JSON output as a public interface. Preserve versioned schemas, structured errors, and the separation of stdout and stderr.
- Release versions come only from Tagsmith tags. Keep the checked-in version placeholder at `0.0.0`.

## Work

- Use the Justfile for development commands.
- Verify capture changes on a real device. Check delivered frame rate, dropped frames, saved output, and orientation; report the device and macOS version tested.
