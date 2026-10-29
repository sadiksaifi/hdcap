import AVFoundation
import CoreMedia
import Foundation

public struct DeviceInfo: Codable, Sendable {
    public let id: String
    public let name: String
    public let manufacturer: String
    public let modelID: String
    public let transportType: String

    init(_ device: AVCaptureDevice) {
        id = device.uniqueID
        name = device.localizedName
        manufacturer = device.manufacturer
        modelID = device.modelID
        transportType = fourCC(UInt32(bitPattern: device.transportType))
    }
}

public struct FrameRateRangeInfo: Codable, Equatable, Sendable {
    public let min: Double
    public let max: Double

    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }
}

public struct ModeInfo: Codable, Equatable, Sendable {
    public let id: String
    public let index: Int
    public let width: Int
    public let height: Int
    public let pixelFormat: String
    public let frameRateRanges: [FrameRateRangeInfo]
    public let recommended: Bool

    public init(id: String, index: Int, width: Int, height: Int, pixelFormat: String,
                frameRateRanges: [FrameRateRangeInfo], recommended: Bool = false) {
        self.id = id
        self.index = index
        self.width = width
        self.height = height
        self.pixelFormat = pixelFormat
        self.frameRateRanges = frameRateRanges
        self.recommended = recommended
    }

    init(_ format: AVCaptureDevice.Format, index: Int) {
        let description = format.formatDescription
        let size = CMVideoFormatDescriptionGetDimensions(description)
        let subtype = fourCC(CMFormatDescriptionGetMediaSubType(description))
        self.init(id: "\(index):\(size.width)x\(size.height):\(subtype)", index: index,
                  width: Int(size.width), height: Int(size.height), pixelFormat: subtype,
                  frameRateRanges: format.videoSupportedFrameRateRanges.map {
                      FrameRateRangeInfo(min: $0.minFrameRate, max: $0.maxFrameRate)
                  }, recommended: subtype == "420v")
    }
}

public enum DeviceCatalog {
    static func captureDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera],
                                         mediaType: .video, position: .unspecified).devices
            .sorted { $0.localizedName == $1.localizedName ? $0.uniqueID < $1.uniqueID : $0.localizedName < $1.localizedName }
    }

    public static func devices() -> [DeviceInfo] { captureDevices().map(DeviceInfo.init) }

    static func device(deviceName: String?, deviceID: String?) throws -> AVCaptureDevice {
        guard deviceName == nil || deviceID == nil else {
            throw CaptureError("conflicting_device_selection", "Use either --device or --device-id.")
        }
        let devices = captureDevices()
        let matches: [AVCaptureDevice]
        if let deviceID {
            matches = devices.filter { $0.uniqueID == deviceID }
        } else if let deviceName {
            let exact = devices.filter { $0.localizedName == deviceName }
            matches = exact.isEmpty ? devices.filter { $0.localizedName.localizedCaseInsensitiveContains(deviceName) } : exact
        } else {
            matches = devices.filter { $0.deviceType == .external }
        }
        guard !matches.isEmpty else {
            throw CaptureError("device_not_found", "No capture device matches the selection.",
                               details: ["devices": devices.map { "\($0.localizedName) [\($0.uniqueID)]" }.joined(separator: ", ")])
        }
        guard matches.count == 1 else {
            throw CaptureError("ambiguous_device", "More than one device matches; use an exact name or --device-id.",
                               details: ["matches": matches.map { "\($0.localizedName) [\($0.uniqueID)]" }.joined(separator: ", ")])
        }
        return matches[0]
    }

    public static func modes(deviceName: String?, deviceID: String?) throws -> [ModeInfo] {
        try device(deviceName: deviceName, deviceID: deviceID).formats.enumerated().map {
            ModeInfo($0.element, index: $0.offset)
        }
    }

    /// Selects the native capture format, rather than asking a session preset to choose it.
    public static func selectMode(from modes: [ModeInfo], resolution: Resolution,
                                  frameRate: FrameRate) throws -> ModeInfo {
        let matches = modes.filter {
            $0.width == resolution.width && $0.height == resolution.height &&
            $0.frameRateRanges.contains { range in
                frameRate.value >= range.min - 0.000_001 && frameRate.value <= range.max + 0.000_001
            }
        }
        guard let selected = matches.min(by: {
            let lhs = preference($0.pixelFormat), rhs = preference($1.pixelFormat)
            return lhs == rhs ? $0.index < $1.index : lhs < rhs
        }) else {
            throw CaptureError("unsupported_mode", "The device does not support \(resolution) at \(frameRate) fps.")
        }
        return selected
    }

    private static func preference(_ subtype: String) -> Int {
        switch subtype {
        case "420v": 0
        case "420f": 1
        case "x420": 2
        case "2vuy": 3
        case "yuvs": 4
        default: 5
        }
    }
}

func fourCC(_ value: FourCharCode) -> String {
    String(bytes: [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255),
                   UInt8((value >> 8) & 255), UInt8(value & 255)], encoding: .ascii) ?? String(value)
}
