import Foundation
import CoreMedia

public struct CaptureError: Error, LocalizedError, Codable, Sendable {
    public let code: String
    public let message: String
    public let details: [String: String]

    public init(_ code: String, _ message: String, details: [String: String] = [:]) {
        self.code = code
        self.message = message
        self.details = details
    }

    public var errorDescription: String? { message }
}

public struct Resolution: Codable, Equatable, Sendable, CustomStringConvertible {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public init(_ text: String) throws {
        let pieces = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard pieces.count == 2, let w = Int(pieces[0]), let h = Int(pieces[1]),
              w > 0, h > 0, w <= 16384, h <= 16384 else {
            throw CaptureError("invalid_resolution", "Resolution must be WIDTHxHEIGHT, for example 1280x720.")
        }
        self.init(width: w, height: h)
    }

    public var description: String { "\(width)x\(height)" }
}

public struct FrameRate: Codable, Equatable, Sendable, CustomStringConvertible {
    public let numerator: Int32
    public let denominator: Int32

    public init(numerator: Int32, denominator: Int32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    public init(_ text: String) throws {
        let common: [String: (Int32, Int32)] = [
            "23.976": (24000, 1001), "29.97": (30000, 1001),
            "59.94": (60000, 1001), "119.88": (120000, 1001),
        ]
        if let pair = common[text] {
            self.init(numerator: pair.0, denominator: pair.1)
            return
        }
        let pieces = text.split(separator: "/", omittingEmptySubsequences: false)
        if pieces.count == 2, let n = Int32(pieces[0]), let d = Int32(pieces[1]), n > 0, d > 0,
           Double(n) / Double(d) <= 1000 {
            self.init(numerator: n, denominator: d)
            return
        }
        if pieces.count == 1, let rate = Double(text), rate.isFinite, rate > 0, rate <= 1000 {
            let scale: Int32 = 1_000_000
            let n = Int64((rate * Double(scale)).rounded())
            guard n > 0 else { throw CaptureError("invalid_fps", "Frame rate is too small.") }
            var a = n
            var b = Int64(scale)
            while b != 0 { (a, b) = (b, a % b) }
            self.init(numerator: Int32(n / a), denominator: Int32(Int64(scale) / a))
            return
        }
        throw CaptureError("invalid_fps", "Frame rate must be positive, for example 60, 59.94, or 60000/1001.")
    }

    public var value: Double { Double(numerator) / Double(denominator) }
    public var frameDuration: CMTime { CMTime(value: CMTimeValue(denominator), timescale: numerator) }
    public var description: String {
        denominator == 1 ? "\(numerator)" : "\(numerator)/\(denominator)"
    }
}

public enum Flip: String, Codable, CaseIterable, Sendable {
    case none, horizontal, vertical, both
}

public struct VideoTransform: Codable, Equatable, Sendable {
    public let rotation: Int
    public let flip: Flip

    public init(rotation: Int = 0, flip: Flip = .none) throws {
        guard [0, 90, 180, 270].contains(rotation) else {
            throw CaptureError("invalid_rotation", "Rotation must be 0, 90, 180, or 270 degrees clockwise.")
        }
        self.rotation = rotation
        self.flip = flip
    }

    public var swapsDimensions: Bool { rotation == 90 || rotation == 270 }

    public var nativeMirrored: Bool { flip == .horizontal || flip == .vertical }

    /// AVCapture mirrors before rotating. Reverse the angle when mirroring so
    /// callers consistently get clockwise rotation followed by output-axis flips.
    public var nativeRotation: Int {
        let normalized = (rotation + (flip == .vertical || flip == .both ? 180 : 0)) % 360
        return nativeMirrored ? (360 - normalized) % 360 : normalized
    }
}

public struct CaptureRequest: Sendable {
    public let deviceName: String?
    public let deviceID: String?
    public let resolution: Resolution
    public let frameRate: FrameRate
    public let transform: VideoTransform
    public let timeout: Double
    public let noInput: Bool

    public init(deviceName: String?, deviceID: String?, resolution: Resolution,
                frameRate: FrameRate, transform: VideoTransform, timeout: Double = 10,
                noInput: Bool = false) {
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.resolution = resolution
        self.frameRate = frameRate
        self.transform = transform
        self.timeout = timeout
        self.noInput = noInput
    }
}
