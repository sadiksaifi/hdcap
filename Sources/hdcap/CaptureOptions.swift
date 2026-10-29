import ArgumentParser
import Foundation
import HDCapture

struct DeviceOptions: ParsableArguments {
    @Option(help: "Select an exact device name.")
    var device: String?

    @Option(name: .customLong("device-id"), help: "Select the device ID printed by devices.")
    var deviceID: String?

    func validateSelection() throws {
        guard (device != nil) != (deviceID != nil) else {
            throw ValidationError("Pass exactly one of --device NAME or --device-id ID.")
        }
    }
}

struct CaptureOptions: ParsableArguments {
    @OptionGroup var selection: DeviceOptions

    @Option(help: "Capture resolution as WIDTHxHEIGHT, for example 1280x720.")
    var resolution: String

    @Option(help: "Frame rate, for example 60, 59.94, or 60000/1001.")
    var fps: String

    @Option(help: "Clockwise rotation: 0, 90, 180, or 270 degrees.")
    var rotate = 0

    @Option(help: "Flip after rotation: none, horizontal, vertical, or both.")
    var flip: Flip = .none

    @Option(help: "Seconds to wait for the first frame.")
    var timeout: Double = 10

    @Flag(help: "Fail if camera permission requires a system prompt.")
    var noInput = false

    mutating func validate() throws {
        try selection.validateSelection()
    }

    func request() throws -> CaptureRequest {
        guard timeout.isFinite, timeout > 0, timeout <= Double(Int64.max) / 1_000_000_000 else {
            throw CaptureError("invalid_timeout", "Timeout must be a positive, representable number of seconds.")
        }
        return try CaptureRequest(
            deviceName: selection.device, deviceID: selection.deviceID,
            resolution: Resolution(resolution), frameRate: FrameRate(fps),
            transform: VideoTransform(rotation: rotate, flip: flip),
            timeout: timeout, noInput: noInput
        )
    }
}

extension Flip: ExpressibleByArgument {}
extension VideoCodec: ExpressibleByArgument {}

func validateDuration(_ duration: Double?) throws {
    if let duration, !duration.isFinite || duration <= 0 || duration > Double(Int64.max) / 1_000_000_000 {
        throw ValidationError("Duration must be a positive number of seconds.")
    }
}

func outputURL(_ path: String, extensions: [String], overwrite: Bool) throws -> URL {
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard extensions.contains(url.pathExtension.lowercased()) else {
        throw CaptureError("invalid_output", "Output must have extension \(extensions.map { "." + $0 }.joined(separator: " or ")).")
    }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path, isDirectory: &directory), directory.boolValue else {
        throw CaptureError("invalid_output", "Output directory does not exist.", details: ["path": url.deletingLastPathComponent().path])
    }
    if FileManager.default.fileExists(atPath: url.path), !overwrite {
        throw CaptureError("output_exists", "Output already exists. Pass --overwrite to replace it.", details: ["path": url.path])
    }
    return url
}
