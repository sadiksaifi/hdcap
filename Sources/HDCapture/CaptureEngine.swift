import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

public struct FrameDurationInfo: Codable, Sendable {
    public let value: Int64
    public let timescale: Int32
}

public struct SelectedMode: Codable, Sendable {
    public let device: DeviceInfo
    public let mode: ModeInfo
    public let frameRate: FrameRate
    public let effectiveFrameDuration: FrameDurationInfo
    public let actualFrameRate: Double
    public let outputWidth: Int
    public let outputHeight: Int
    /// Native connection rotation after resolving vertical and double flips.
    public let rotation: Int
    public let mirrored: Bool
}

public struct CaptureStatistics: Codable, Sendable {
    public var framesReceived: Int = 0
    public var framesDropped: Int = 0
    public var measuredFPS: Double = 0
    public var firstFrameReceived: Bool = false
    public var pixelFormat: String?
    public var width: Int?
    public var height: Int?
    public var iosurfaceBacked: Bool?
    public var elapsedSeconds: Double = 0
}

/// Session mutations use sessionQueue. Delegate work uses frameQueue. The lock protects
/// snapshots shared with command polling; callbacks never perform pixel copies.
public final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let session = AVCaptureSession()
    public let selectedMode: SelectedMode

    private let device: AVCaptureDevice
    private let format: AVCaptureDevice.Format
    private let nativeFrameDuration: CMTime
    private let request: CaptureRequest
    private let output = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "hdcap.capture.session", qos: .userInitiated)
    private let frameQueue = DispatchQueue(label: "hdcap.capture.frames", qos: .userInteractive)
    private let frameQueueKey = DispatchSpecificKey<Bool>()
    private let lock = NSLock()
    private var storedFailure: CaptureError?
    private var storedStatistics = CaptureStatistics()
    private var handler: (@Sendable (CMSampleBuffer) -> Void)?
    private var acceptingFrames = false
    private var started = false
    private var startedAt: Double?
    private var firstPTS: Double?
    private var lastPTS: Double?
    private var observers: [NSObjectProtocol] = []

    public var failure: CaptureError? { lock.withLock { storedFailure } }

    public var statistics: CaptureStatistics {
        lock.withLock {
            var result = storedStatistics
            if let startedAt { result.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedAt }
            if let firstPTS, let lastPTS, lastPTS > firstPTS, result.framesReceived > 1 {
                result.measuredFPS = Double(result.framesReceived - 1) / (lastPTS - firstPTS)
            }
            return result
        }
    }

    public init(request: CaptureRequest) throws {
        self.request = request
        device = try DeviceCatalog.device(deviceName: request.deviceName, deviceID: request.deviceID)
        let modes = device.formats.enumerated().map { ModeInfo($0.element, index: $0.offset) }
        let mode = try DeviceCatalog.selectMode(from: modes, resolution: request.resolution, frameRate: request.frameRate)
        format = device.formats[mode.index]
        nativeFrameDuration = try DeviceCatalog.supportedDuration(for: request.frameRate,
                                                                 ranges: format.videoSupportedFrameRateRanges)
        selectedMode = SelectedMode(device: DeviceInfo(device), mode: mode, frameRate: request.frameRate,
                                    effectiveFrameDuration: FrameDurationInfo(value: nativeFrameDuration.value,
                                                                              timescale: nativeFrameDuration.timescale),
                                    actualFrameRate: 1 / nativeFrameDuration.seconds,
                                    outputWidth: request.transform.swapsDimensions ? mode.height : mode.width,
                                    outputHeight: request.transform.swapsDimensions ? mode.width : mode.height,
                                    rotation: request.transform.nativeRotation,
                                    mirrored: request.transform.nativeMirrored)
        super.init()
        frameQueue.setSpecific(key: frameQueueKey, value: true)
        try sessionQueue.sync {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                throw CaptureError("capture_configuration_failed", "Cannot add the selected capture device to the session.")
            }
            session.addInput(input)
            guard session.canAddOutput(output) else {
                throw CaptureError("capture_configuration_failed", "Cannot add video frame output to the session.")
            }
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: frameQueue)
            session.addOutput(output)
        }
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                                 object: session, queue: nil) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
            self?.fail(CaptureError("capture_failed", error?.localizedDescription ?? "The capture session failed."))
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                                                 object: device, queue: nil) { [weak self] _ in
            self?.fail(CaptureError("device_disconnected", "The selected capture device was disconnected."))
        })
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    public static func authorize(noInput: Bool) async throws {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return
        case .notDetermined:
            guard !noInput else {
                throw CaptureError("permission_required", "Camera permission has not been granted. Run once without --no-input from your terminal to request it.")
            }
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                    throw CaptureError("permission_required", "Camera permission could not be requested by this process. Run hdcap from Terminal and allow camera access for that terminal.")
                }
                throw CaptureError("permission_denied", "Camera permission was denied. Enable camera access for your terminal in System Settings > Privacy & Security > Camera.")
            }
        case .denied, .restricted:
            throw CaptureError("permission_denied", "Camera access is unavailable. Enable camera access for your terminal in System Settings > Privacy & Security > Camera.")
        @unknown default:
            throw CaptureError("permission_denied", "Camera authorization status is unavailable.")
        }
    }

    public func start(frameHandler: (@Sendable (CMSampleBuffer) -> Void)? = nil) throws {
        try sessionQueue.sync {
            guard !started else { throw CaptureError("already_running", "This capture engine has already been started.") }
            started = true
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            // macOS may reset activeFormat during startRunning unless this lock is held.
            session.beginConfiguration()
            device.activeFormat = format
            device.activeVideoMinFrameDuration = nativeFrameDuration
            device.activeVideoMaxFrameDuration = nativeFrameDuration
            let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
            guard output.availableVideoPixelFormatTypes.contains(subtype) else {
                session.commitConfiguration()
                throw CaptureError("unsupported_pixel_format", "The capture output cannot deliver the selected native pixel format.",
                                   details: ["pixelFormat": fourCC(subtype)])
            }
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: subtype]
            guard let connection = output.connection(with: .video),
                  connection.isVideoRotationAngleSupported(CGFloat(selectedMode.rotation)),
                  !selectedMode.mirrored || connection.isVideoMirroringSupported else {
                session.commitConfiguration()
                throw CaptureError("unsupported_transform", "The capture device cannot apply the requested rotation or flip.")
            }
            connection.videoRotationAngle = CGFloat(selectedMode.rotation)
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = selectedMode.mirrored }
            session.commitConfiguration()
            lock.withLock {
                handler = frameHandler
                acceptingFrames = true
                startedAt = ProcessInfo.processInfo.systemUptime
            }
            session.startRunning()
            guard session.isRunning else {
                throw failure ?? CaptureError("capture_start_failed", "The capture session did not start.")
            }
            let actual = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            guard actual.width == selectedMode.mode.width, actual.height == selectedMode.mode.height,
                  CMFormatDescriptionGetMediaSubType(device.activeFormat.formatDescription) == subtype else {
                let error = fail(CaptureError("mode_changed", "macOS changed the selected device format during startup."))
                session.stopRunning()
                throw error
            }
            let requestedDuration = nativeFrameDuration
            guard CMTimeCompare(device.activeVideoMinFrameDuration, requestedDuration) == 0,
                  CMTimeCompare(device.activeVideoMaxFrameDuration, requestedDuration) == 0 else {
                let error = fail(CaptureError("frame_rate_changed", "macOS changed the requested frame duration during startup.",
                                             details: ["requestedFPS": request.frameRate.description,
                                                       "minimumFrameDurationSeconds": String(device.activeVideoMinFrameDuration.seconds),
                                                       "maximumFrameDurationSeconds": String(device.activeVideoMaxFrameDuration.seconds)]))
                session.stopRunning()
                throw error
            }
        }
    }

    /// Stops delivery, then drains queued callbacks so callers can safely finish a writer.
    public func stop() {
        lock.withLock { acceptingFrames = false; handler = nil }
        sessionQueue.sync { if session.isRunning { session.stopRunning() } }
        if DispatchQueue.getSpecific(key: frameQueueKey) == nil { frameQueue.sync {} }
        lock.withLock {
            if let startedAt {
                storedStatistics.elapsedSeconds = ProcessInfo.processInfo.systemUptime - startedAt
                self.startedAt = nil
            }
        }
    }

    @discardableResult
    private func fail(_ error: CaptureError) -> CaptureError {
        lock.withLock {
            if storedFailure == nil { storedFailure = error }
            acceptingFrames = false
            return storedFailure ?? error
        }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let callback: (@Sendable (CMSampleBuffer) -> Void)? = lock.withLock {
            guard acceptingFrames, storedFailure == nil else { return nil }
            if !storedStatistics.firstFrameReceived {
                let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
                let subtype = fourCC(CVPixelBufferGetPixelFormatType(pixelBuffer))
                guard width == selectedMode.outputWidth, height == selectedMode.outputHeight,
                      subtype == selectedMode.mode.pixelFormat else {
                    storedFailure = CaptureError("unexpected_frame_format", "The first frame does not match the selected mode.",
                                                 details: ["actual": "\(width)x\(height) \(subtype)",
                                                           "expected": "\(selectedMode.outputWidth)x\(selectedMode.outputHeight) \(selectedMode.mode.pixelFormat)"])
                    acceptingFrames = false
                    return nil
                }
                storedStatistics.width = width
                storedStatistics.height = height
                storedStatistics.pixelFormat = subtype
                storedStatistics.iosurfaceBacked = CVPixelBufferGetIOSurface(pixelBuffer) != nil
                storedStatistics.firstFrameReceived = true
            }
            storedStatistics.framesReceived += 1
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            if pts.isFinite {
                if firstPTS == nil { firstPTS = pts }
                lastPTS = pts
            }
            return handler
        }
        callback?(sampleBuffer)
    }

    public func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        lock.withLock { storedStatistics.framesDropped += 1 }
    }
}

public enum CameraAuthorization: String, Codable, Sendable {
    case authorized, denied, restricted
    case notDetermined = "not_determined"
}

extension CaptureEngine {
    /// Camera authorization for this process's own macOS privacy identity.
    public static var cameraAuthorization: CameraAuthorization {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        @unknown default: .restricted
        }
    }

    /// Shows the system prompt only while authorization is undetermined.
    public static func requestCameraAccess() async -> CameraAuthorization {
        if cameraAuthorization == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
        return cameraAuthorization
    }
}
