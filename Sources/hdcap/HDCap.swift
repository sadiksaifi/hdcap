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
        version: BuildVersion.current,
        subcommands: [Devices.self, Modes.self, View.self, Record.self, Screenshot.self, Setup.self, Schema.self, Upgrade.self]
    )

    @OptionGroup var output: OutputOptions

    @MainActor static func main() {
        do {
            // Argument Parser's built-in version flag has no configurable short name.
            var optionsEnded = false
            let arguments = CommandLine.arguments.dropFirst().map { argument in
                if argument == "--" { optionsEnded = true }
                return !optionsEnded && argument == "-v" ? "--version" : argument
            }
            var command = try parseAsRoot(arguments)
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
                    range.min == range.max ? String(format: "%.6g", range.max) : String(format: "%.6g-%.6g", range.min, range.max)
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
        let job = try ViewJob(capture: capture.request(), duration: duration)
        MainActor.assumeIsolated {
            Runtime.capture(job, command: "view", window: true) { "Stopped preview (\($0.stoppedBy))." }
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
        let job = RecordJob(capture: request, path: url.path, codec: codec, bitrate: bitrate, duration: duration, overwrite: overwrite)
        MainActor.assumeIsolated {
            Runtime.capture(job, command: "record") { result in
                "Saved \(result.movie.path) (\(result.movie.framesWritten) frames, \(String(format: "%.2f", result.movie.duration)) seconds)."
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
        let job = ScreenshotJob(capture: request, path: url.path, overwrite: overwrite)
        MainActor.assumeIsolated {
            Runtime.capture(job, command: "screenshot") { "Saved \($0.image.path) (\($0.image.width)x\($0.image.height))." }
        }
    }
}
