import AppKit
import ArgumentParser
import Foundation
import HDCapture

@main
struct HDCap: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hdcap",
        abstract: "Capture HDMI and UVC video with Apple Silicon.",
        discussion: "Run devices, then modes --device NAME to discover available capture modes. Video only; audio capture is not supported.",
        version: "0.1.0",
        subcommands: [Devices.self, Modes.self, View.self, Record.self, Screenshot.self, Schema.self]
    )

    @OptionGroup var output: OutputOptions

    @MainActor static func main() {
        do {
            var command = try parseAsRoot()
            do { try command.run() }
            catch { Darwin.exit(Output.error(error)) }
        } catch {
            Darwin.exit(Output.error(error, parsing: true))
        }
    }
}

struct Devices: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List capture devices and their persistent IDs.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        let devices = DeviceCatalog.devices()
        try Output.result(devices, command: "devices") {
            devices.isEmpty ? "No video capture devices found." : table(["NAME", "ID", "TRANSPORT"], rows: devices.map { [$0.name, $0.id, $0.transportType] })
        }
    }
}

struct Modes: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List device formats and frame-rate ranges.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var selection: DeviceOptions

    mutating func validate() throws { try selection.validateSelection() }

    func run() throws {
        let modes = try DeviceCatalog.modes(deviceName: selection.device, deviceID: selection.deviceID)
        try Output.result(modes, command: "modes") {
            table(["RESOLUTION", "PIXEL FORMAT", "FPS", "PREFERRED"], rows: modes.map { mode in
                let ranges = mode.frameRateRanges.map { range in
                    range.min == range.max ? String(format: "%.3g", range.max) : String(format: "%.3g-%.3g", range.min, range.max)
                }.joined(separator: ", ")
                return ["\(mode.width)x\(mode.height)", mode.pixelFormat, ranges, mode.recommended ? "yes" : ""]
            })
        }
    }
}

struct View: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show live video in a plain window. Close it or press Ctrl-C to stop.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var capture: CaptureOptions
    @Option(help: "Stop after this many seconds of received video.") var duration: Double?

    mutating func validate() throws { try validateDuration(duration) }

    func run() throws {
        let request = try capture.request()
        let options = capture
        let duration = duration
        MainActor.assumeIsolated {
            Runtime.run(window: true) {
                let signals = SignalMonitor()
                defer { signals.cancel() }
                try await CaptureEngine.authorize(noInput: options.noInput)
                let engine = try await Task.detached { try CaptureEngine(request: request) }.value
                let mode = engine.selectedMode
                let preview = try PreviewWindow(
                    session: engine.session,
                    resolution: Resolution(width: mode.outputWidth, height: mode.outputHeight),
                    transform: request.transform, title: "hdcap: \(mode.device.name)"
                )
                defer { engine.stop(); preview.close() }
                preview.show()
                try await Runtime.start(engine, options: options)
                signals.allowGracefulStop()
                let reason = try await Runtime.wait(engine: engine, signals: signals, duration: duration, window: preview)
                let cleanup = Watchdog(seconds: 10) { CaptureError("cleanup_timeout", "The capture session did not stop within 10 seconds.") }
                defer { cleanup.cancel() }
                engine.stop()
                let result = ViewResult(capture: mode, statistics: engine.statistics, stoppedBy: reason)
                try Output.result(result, command: "view") { "Stopped preview (\(reason))." }
            }
        }
    }
}

struct Record: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Record an MP4 or MOV using the hardware H.264 or HEVC encoder.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var capture: CaptureOptions
    @Argument(help: "Destination .mp4 or .mov file.") var path: String
    @Option(help: "Video codec: h264 or hevc.") var codec: VideoCodec = .h264
    @Option(help: "Video bitrate in bits per second.") var bitrate: Int?
    @Option(help: "Stop after this many seconds of received video.") var duration: Double?
    @Flag(help: "Replace the destination after recording finishes successfully.") var overwrite = false

    mutating func validate() throws {
        try validateDuration(duration)
        if let bitrate, bitrate <= 0 { throw ValidationError("Bitrate must be positive.") }
    }

    func run() throws {
        let request = try capture.request()
        let url = try outputURL(path, extensions: ["mp4", "mov"], overwrite: overwrite)
        let options = capture
        let codec = codec
        let bitrate = bitrate
        let duration = duration
        let overwrite = overwrite
        MainActor.assumeIsolated {
            Runtime.run {
                let signals = SignalMonitor()
                defer { signals.cancel() }
                try await CaptureEngine.authorize(noInput: options.noInput)
                let engine = try await Task.detached { try CaptureEngine(request: request) }.value
                defer { engine.stop() }
                let mode = engine.selectedMode
                let recorder = try MovieRecorder(options: RecordingOptions(
                    url: url, codec: codec,
                    resolution: Resolution(width: mode.outputWidth, height: mode.outputHeight),
                    frameRate: request.frameRate, bitrate: bitrate, overwrite: overwrite
                ))
                do {
                    try await Runtime.start(engine, options: options) { recorder.append($0) }
                    signals.allowGracefulStop()
                    Output.notice("Recording \(codec.rawValue) to \(url.path). Press Ctrl-C to finish.")
                    let reason = try await Runtime.wait(engine: engine, signals: signals, duration: duration, additionalFailure: { recorder.failure })
                    let cleanup = Watchdog(seconds: 10) { CaptureError("cleanup_timeout", "Recording did not finish within 10 seconds.") }
                    defer { cleanup.cancel() }
                    engine.stop()
                    if let failure = recorder.failure { throw failure }
                    let movie = try await recorder.finish()
                    try Output.result(RecordResult(capture: mode, movie: movie, statistics: engine.statistics, stoppedBy: reason), command: "record") {
                        "Saved \(movie.path) (\(movie.framesWritten) frames, \(String(format: "%.2f", movie.duration)) seconds)."
                    }
                } catch {
                    let cleanup = Watchdog(seconds: 10) { CaptureError("cleanup_timeout", "Recording cleanup did not finish within 10 seconds.") }
                    defer { cleanup.cancel() }
                    engine.stop()
                    do {
                        _ = try await recorder.finish()
                    } catch let finalization as CaptureError {
                        if let original = error as? CaptureError {
                            throw CaptureError(original.code, original.message, details: original.details.merging(finalization.details) { original, _ in original })
                        }
                        throw finalization
                    }
                    throw error
                }
            }
        }
    }
}

struct Screenshot: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Save a received video frame as a PNG.")
    @OptionGroup var output: OutputOptions
    @OptionGroup var capture: CaptureOptions
    @Argument(help: "Destination .png file.") var path: String
    @Flag(help: "Replace the destination after the PNG is ready.") var overwrite = false

    func run() throws {
        let request = try capture.request()
        let url = try outputURL(path, extensions: ["png"], overwrite: overwrite)
        let options = capture
        let overwrite = overwrite
        MainActor.assumeIsolated {
            Runtime.run {
                let signals = SignalMonitor()
                defer { signals.cancel() }
                try await CaptureEngine.authorize(noInput: options.noInput)
                let engine = try await Task.detached { try CaptureEngine(request: request) }.value
                defer { engine.stop() }
                let frame = ScreenshotFrame()
                try await Runtime.start(engine, options: options) { frame.receive($0) }
                if signals.received != nil { throw CaptureError("interrupted", "Screenshot was interrupted.") }
                engine.stop()
                let image = try await Task.detached { try frame.write(to: url, overwrite: overwrite) }.value
                let result = ScreenshotCompletion(capture: engine.selectedMode, image: image, statistics: engine.statistics)
                try Output.result(result, command: "screenshot") { "Saved \(image.path) (\(image.width)x\(image.height))." }
            }
        }
    }
}

private struct ViewResult: Encodable {
    let capture: SelectedMode
    let statistics: CaptureStatistics
    let stoppedBy: String
}

private struct RecordResult: Encodable {
    let capture: SelectedMode
    let movie: RecordingResult
    let statistics: CaptureStatistics
    let stoppedBy: String
}

private struct ScreenshotCompletion: Encodable {
    let capture: SelectedMode
    let image: ScreenshotResult
    let statistics: CaptureStatistics
}
