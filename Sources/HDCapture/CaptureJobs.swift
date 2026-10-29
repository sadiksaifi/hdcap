import CoreMedia
import Foundation

/// Process services a capture job needs from the process that runs it.
public protocol CaptureHost: Sendable {
    /// The first stop signal received, such as SIGINT.
    var stopSignal: Int32? { get }
    /// Called once a stop request can finish the job and keep its output.
    func allowGracefulStop()
    func notice(_ text: String)
    /// Ends the process when a system call blocks past its deadline.
    func abandon(_ error: CaptureError) -> Never
}

/// A camera operation that runs after authorization and returns a result for JSON output.
public protocol CaptureJob: Codable, Sendable {
    associatedtype Result: Codable, Sendable
    var capture: CaptureRequest { get }
    @MainActor func run(host: any CaptureHost) async throws -> Result
}

public struct ViewJob: CaptureJob {
    public let capture: CaptureRequest
    public let duration: Double?

    public init(capture: CaptureRequest, duration: Double?) {
        self.capture = capture
        self.duration = duration
    }

    @MainActor public func run(host: any CaptureHost) async throws -> ViewResult {
        let engine = try await makeEngine(capture)
        let mode = engine.selectedMode
        let preview = try PreviewWindow(
            session: engine.session,
            resolution: Resolution(width: mode.outputWidth, height: mode.outputHeight),
            transform: capture.transform, title: "hdcap: \(mode.device.name)"
        )
        defer { engine.stop(); preview.close() }
        preview.show()
        try await start(engine, timeout: capture.timeout, host: host)
        host.allowGracefulStop()
        let reason = try await wait(engine: engine, host: host, duration: duration, window: preview)
        let cleanup = Watchdog(seconds: 10) { host.abandon(CaptureError("cleanup_timeout", "The capture session did not stop within 10 seconds.")) }
        defer { cleanup.cancel() }
        engine.stop()
        return ViewResult(capture: mode, statistics: engine.statistics, stoppedBy: reason)
    }
}

public struct RecordJob: CaptureJob {
    public let capture: CaptureRequest
    public let path: String
    public let codec: VideoCodec
    public let bitrate: Int?
    public let duration: Double?
    public let overwrite: Bool

    public init(capture: CaptureRequest, path: String, codec: VideoCodec, bitrate: Int?, duration: Double?, overwrite: Bool) {
        self.capture = capture
        self.path = path
        self.codec = codec
        self.bitrate = bitrate
        self.duration = duration
        self.overwrite = overwrite
    }

    @MainActor public func run(host: any CaptureHost) async throws -> RecordResult {
        let engine = try await makeEngine(capture)
        defer { engine.stop() }
        let mode = engine.selectedMode
        let url = URL(fileURLWithPath: path)
        let recorder = try MovieRecorder(options: RecordingOptions(
            url: url, codec: codec,
            resolution: Resolution(width: mode.outputWidth, height: mode.outputHeight),
            frameRate: capture.frameRate, bitrate: bitrate, overwrite: overwrite
        ))
        do {
            try await start(engine, timeout: capture.timeout, host: host) { recorder.append($0) }
            host.allowGracefulStop()
            host.notice("Recording \(codec.rawValue) to \(url.path). Press Ctrl-C to finish.")
            let reason = try await wait(engine: engine, host: host, duration: duration, additionalFailure: { recorder.failure })
            let cleanup = Watchdog(seconds: 10) { host.abandon(CaptureError("cleanup_timeout", "Recording did not finish within 10 seconds.")) }
            defer { cleanup.cancel() }
            engine.stop()
            if let failure = recorder.failure { throw failure }
            let movie = try await recorder.finish()
            return RecordResult(capture: mode, movie: movie, statistics: engine.statistics, stoppedBy: reason)
        } catch {
            let cleanup = Watchdog(seconds: 10) { host.abandon(CaptureError("cleanup_timeout", "Recording cleanup did not finish within 10 seconds.")) }
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

public struct ScreenshotJob: CaptureJob {
    public let capture: CaptureRequest
    public let path: String
    public let overwrite: Bool

    public init(capture: CaptureRequest, path: String, overwrite: Bool) {
        self.capture = capture
        self.path = path
        self.overwrite = overwrite
    }

    @MainActor public func run(host: any CaptureHost) async throws -> ScreenshotCompletion {
        let engine = try await makeEngine(capture)
        defer { engine.stop() }
        let frame = ScreenshotFrame()
        try await start(engine, timeout: capture.timeout, host: host) { frame.receive($0) }
        if let signal = host.stopSignal { throw CaptureError.interrupted(signal: signal, "Screenshot was interrupted.") }
        engine.stop()
        let url = URL(fileURLWithPath: path)
        let overwrite = overwrite
        let image = try await Task.detached { try frame.write(to: url, overwrite: overwrite) }.value
        return ScreenshotCompletion(capture: engine.selectedMode, image: image, statistics: engine.statistics)
    }
}

public struct ViewResult: Codable, Sendable {
    public let capture: SelectedMode
    public let statistics: CaptureStatistics
    public let stoppedBy: String
}

public struct RecordResult: Codable, Sendable {
    public let capture: SelectedMode
    public let movie: RecordingResult
    public let statistics: CaptureStatistics
    public let stoppedBy: String
}

public struct ScreenshotCompletion: Codable, Sendable {
    public let capture: SelectedMode
    public let image: ScreenshotResult
    public let statistics: CaptureStatistics
}

extension CaptureError {
    /// Carries the signal so the CLI exits with the conventional 128 + signal status.
    public static func interrupted(signal: Int32, _ message: String = "Capture was interrupted.") -> CaptureError {
        CaptureError("interrupted", message, details: ["signal": String(signal)])
    }
}

/// A blocked system API cannot be cancelled safely. Bound that wait at the process boundary.
public final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))

    public init(seconds: Double, expired: @escaping @Sendable () -> Void) {
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.lock.withLock({
                guard self.active else { return false }
                self.active = false
                return true
            }) else { return }
            expired()
        }
        timer.resume()
    }

    public func cancel() { lock.withLock { active = false }; timer.cancel() }
    deinit { timer.cancel() }
}

private func makeEngine(_ request: CaptureRequest) async throws -> CaptureEngine {
    try await Task.detached { try CaptureEngine(request: request) }.value
}

@MainActor
private func start(_ engine: CaptureEngine, timeout: Double, host: any CaptureHost,
                   frameHandler: (@Sendable (CMSampleBuffer) -> Void)? = nil) async throws {
    let started = ContinuousClock.now
    let watchdog = Watchdog(seconds: timeout) {
        host.abandon(CaptureError("capture_timeout", "The capture session did not finish starting before the timeout."))
    }
    defer { watchdog.cancel() }
    try await Task.detached { try engine.start(frameHandler: frameHandler) }.value
    watchdog.cancel()
    while !engine.statistics.firstFrameReceived {
        if let failure = engine.failure { throw failure }
        if let signal = host.stopSignal { throw CaptureError.interrupted(signal: signal) }
        if ContinuousClock.now - started > .seconds(timeout) {
            throw CaptureError("capture_timeout", "No video frame arrived before the timeout.")
        }
        try await Task.sleep(for: .milliseconds(20))
    }
    let mode = engine.selectedMode
    host.notice("Capturing \(mode.device.name): \(mode.mode.width)x\(mode.mode.height) at \(mode.frameRate) fps.")
}

@MainActor
private func wait(engine: CaptureEngine, host: any CaptureHost, duration: Double?, window: PreviewWindow? = nil,
                  additionalFailure: (() -> CaptureError?)? = nil) async throws -> String {
    let ready = ContinuousClock.now
    while true {
        if let signal = host.stopSignal {
            host.notice("Stopping capture and finalizing output.")
            return signal == SIGTERM ? "sigterm" : "sigint"
        }
        if window?.isClosed == true { return "window_closed" }
        if let duration, ContinuousClock.now - ready >= .seconds(duration) { return "duration" }
        if let failure = engine.failure { throw failure }
        if let failure = additionalFailure?() { throw failure }
        try await Task.sleep(for: .milliseconds(20))
    }
}

private final class ScreenshotFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var sample: CMSampleBuffer?

    func receive(_ sample: CMSampleBuffer) {
        lock.withLock { if self.sample == nil { self.sample = sample } }
    }

    func write(to url: URL, overwrite: Bool) throws -> ScreenshotResult {
        guard let sample = lock.withLock({ self.sample }) else {
            throw CaptureError("capture_failed", "No screenshot frame is available.")
        }
        return try ScreenshotWriter.write(sampleBuffer: sample, to: url, overwrite: overwrite)
    }
}
