import AVFoundation
import CoreVideo
import Darwin
import Foundation
import VideoToolbox

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264, hevc

    fileprivate var avCodec: AVVideoCodecType { self == .h264 ? .h264 : .hevc }
}

public struct RecordingOptions: Sendable {
    public let url: URL
    public let codec: VideoCodec
    public let resolution: Resolution
    public let frameRate: FrameRate
    public let bitrate: Int?
    public let overwrite: Bool

    public init(url: URL, codec: VideoCodec = .h264, resolution: Resolution,
                frameRate: FrameRate, bitrate: Int? = nil, overwrite: Bool = false) {
        self.url = url
        self.codec = codec
        self.resolution = resolution
        self.frameRate = frameRate
        self.bitrate = bitrate
        self.overwrite = overwrite
    }
}

public struct RecordingResult: Codable, Sendable {
    public let path: String
    public let codec: VideoCodec
    public let hardwareRequired: Bool
    public let framesWritten: Int
    public let framesDropped: Int
    public let duration: Double
    public let sizeBytes: Int64
    public let resolution: Resolution
    public let frameRate: FrameRate
}

/// Serializes synchronous frame submission and status reads without retaining a frame queue.
public final class MovieRecorder: @unchecked Sendable {
    private let options: RecordingOptions
    private let temporaryURL: URL
    private let writer: AVAssetWriter
    private let receiver: AVAssetWriterInput.PixelBufferReceiver
    private let lock = NSLock()
    private var storedFailure: CaptureError?
    private var written = 0
    private var dropped = 0
    private var firstPTS: CMTime?
    private var previousPTS: CMTime?
    private var lastEnd: CMTime?
    private var finishing = false

    public var failure: CaptureError? { lock.withLock { storedFailure } }
    public var framesWritten: Int { lock.withLock { written } }
    public var framesDropped: Int { lock.withLock { dropped } }

    deinit {
        if writer.status == .writing || writer.status == .unknown { writer.cancelWriting() }
    }

    public init(options: RecordingOptions) throws {
        guard options.resolution.width > 0, options.resolution.height > 0,
              options.resolution.width % 2 == 0, options.resolution.height % 2 == 0,
              options.frameRate.numerator > 0, options.frameRate.denominator > 0,
              options.bitrate.map({ $0 > 0 }) ?? true else {
            throw CaptureError("invalid_recording_options", "Recording requires positive even dimensions, a positive frame rate, and a positive bitrate.")
        }
        guard options.url.isFileURL else {
            throw CaptureError("invalid_output", "Recording output must be a local file.")
        }
        let fileType: AVFileType
        switch options.url.pathExtension.lowercased() {
        case "mp4": fileType = .mp4
        case "mov": fileType = .mov
        default: throw CaptureError("invalid_output", "Recording output must end in .mp4 or .mov.")
        }
        if FileManager.default.fileExists(atPath: options.url.path), !options.overwrite {
            throw CaptureError("output_exists", "Output already exists. Use --overwrite to replace it.", details: ["path": options.url.path])
        }
        self.options = options
        temporaryURL = options.url.deletingLastPathComponent().appendingPathComponent(
            ".hdcap-\(UUID().uuidString).partial.\(options.url.pathExtension)"
        )
        do {
            writer = try AVAssetWriter(outputURL: temporaryURL, fileType: fileType)
            var compression: [String: any Sendable] = [
                AVVideoExpectedSourceFrameRateKey: options.frameRate.value,
                // Keep encoder buffering bounded and preserve capture PTS without reordering delay.
                AVVideoAllowFrameReorderingKey: false,
            ]
            if let bitrate = options.bitrate { compression[AVVideoAverageBitRateKey] = bitrate }
            let settings: [String: any Sendable] = [
                AVVideoCodecKey: options.codec.avCodec.rawValue,
                AVVideoWidthKey: options.resolution.width,
                AVVideoHeightKey: options.resolution.height,
                AVVideoCompressionPropertiesKey: compression,
                AVVideoEncoderSpecificationKey: [
                    kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true,
                ],
            ]
            guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
                throw CaptureError("unsupported_recording", "The requested recording settings are not supported.")
            }
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            // This API attaches the input itself. The source buffers require no allocation pool.
            receiver = writer.inputPixelBufferReceiver(for: input, pixelBufferAttributes: nil)
            try writer.start()
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw Self.recordingError(error)
        }
    }

    /// Called directly on the capture delegate queue. A rejected frame is counted, never queued.
    public func append(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            guard !finishing, storedFailure == nil else { return }
            do {
                guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                    throw CaptureError("invalid_frame", "The captured sample has no image buffer.")
                }
                guard CVPixelBufferGetWidth(pixels) == options.resolution.width,
                      CVPixelBufferGetHeight(pixels) == options.resolution.height else {
                    throw CaptureError("unexpected_frame_size", "The captured frame dimensions do not match the recording dimensions.")
                }
                let format = CVPixelBufferGetPixelFormatType(pixels)
                guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
                      format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else {
                    throw CaptureError("unexpected_pixel_format", "Hardware recording requires native 420v or 420f frames.")
                }
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard pts.isNumeric, previousPTS.map({ CMTimeCompare(pts, $0) > 0 }) ?? true else {
                    throw CaptureError("invalid_frame_timestamp", "Capture timestamps must be numeric and strictly increasing.")
                }
                if firstPTS == nil {
                    writer.startSession(atSourceTime: pts)
                    firstPTS = pts
                }
                previousPTS = pts
                // Capture owns immutable frame storage; retaining it prevents pool reuse.
                // The C sample-buffer getter cannot express that ownership to Swift.
                nonisolated(unsafe) let immutablePixels = pixels
                let readOnly = CVReadOnlyPixelBuffer(unsafeBuffer: immutablePixels)
                if try receiver.appendImmediately(readOnly, with: pts) {
                    written += 1
                    let duration = CMSampleBufferGetDuration(sampleBuffer)
                    lastEnd = CMTimeAdd(pts, duration.isNumeric && duration > .zero ? duration : options.frameRate.frameDuration)
                } else {
                    dropped += 1
                }
            } catch {
                storedFailure = Self.recordingError(error)
            }
        }
    }

    /// Call after capture has stopped and its delegate queue has drained.
    public func finish() async throws -> RecordingResult {
        let snapshot = try lock.withLock { () throws -> (written: Int, dropped: Int, duration: Double, failure: CaptureError?) in
            guard !finishing else { throw CaptureError("recording_finished", "Recording finalization has already started.") }
            finishing = true
            guard written > 0, let firstPTS, let lastEnd else {
                writer.cancelWriting()
                throw storedFailure ?? CaptureError("no_frames", "No frames were recorded.")
            }
            writer.endSession(atSourceTime: lastEnd)
            receiver.finish()
            return (written, dropped, CMTimeSubtract(lastEnd, firstPTS).seconds, storedFailure)
        }
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw Self.recordingError(writer.error ?? CaptureError("recording_failed", "The recording could not be finalized."), partialURL: temporaryURL)
        }
        if let error = snapshot.failure {
            throw Self.recordingError(error, partialURL: temporaryURL)
        }
        do {
            if options.overwrite {
                guard rename(temporaryURL.path, options.url.path) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: options.url)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: options.url.path)
            return RecordingResult(path: options.url.path, codec: options.codec, hardwareRequired: true,
                                   framesWritten: snapshot.written, framesDropped: snapshot.dropped,
                                   duration: snapshot.duration, sizeBytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0,
                                   resolution: options.resolution, frameRate: options.frameRate)
        } catch {
            throw Self.recordingError(error, partialURL: temporaryURL)
        }
    }

    private static func recordingError(_ error: Error, partialURL: URL? = nil) -> CaptureError {
        let existing = error as? CaptureError
        var details = existing?.details ?? [:]
        if let partialURL, FileManager.default.fileExists(atPath: partialURL.path) {
            details["partialPath"] = partialURL.path
        }
        let nsError = error as NSError
        details["domain"] = nsError.domain
        details["underlyingCode"] = String(nsError.code)
        return CaptureError(existing?.code ?? "recording_failed", existing?.message ?? error.localizedDescription, details: details)
    }
}
