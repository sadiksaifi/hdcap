import AppKit
import CoreMedia
import Foundation
import HDCapture

@MainActor
enum Runtime {
    static func run(window: Bool = false, operation: @escaping @MainActor () async throws -> Void) -> Never {
        if window {
            NSApplication.shared.setActivationPolicy(.regular)
        }
        Task { @MainActor in
            do {
                try await operation()
                Darwin.exit(0)
            } catch {
                Darwin.exit(Output.error(error))
            }
        }
        if window { NSApplication.shared.run() }
        dispatchMain()
    }

    static func start(_ engine: CaptureEngine, options: CaptureOptions, frameHandler: (@Sendable (CMSampleBuffer) -> Void)? = nil) async throws {
        let started = ContinuousClock.now
        let watchdog = Watchdog(seconds: options.timeout) {
            CaptureError("capture_timeout", "The capture session did not finish starting before the timeout.")
        }
        defer { watchdog.cancel() }
        try await Task.detached { try engine.start(frameHandler: frameHandler) }.value
        watchdog.cancel()
        while !engine.statistics.firstFrameReceived {
            if let failure = engine.failure { throw failure }
            if ContinuousClock.now - started > .seconds(options.timeout) {
                throw CaptureError("capture_timeout", "No video frame arrived before the timeout.")
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Output.notice("Capturing \(engine.selectedMode.device.name): \(engine.selectedMode.mode.width)x\(engine.selectedMode.mode.height) at \(engine.selectedMode.frameRate) fps.")
    }

    static func wait(engine: CaptureEngine, signals: SignalMonitor, duration: Double?, window: PreviewWindow? = nil,
                     additionalFailure: (() -> CaptureError?)? = nil) async throws -> String {
        let ready = ContinuousClock.now
        while true {
            if let signal = signals.received {
                Output.notice("Stopping capture and finalizing output.")
                return signal == SIGTERM ? "sigterm" : "sigint"
            }
            if window?.isClosed == true { return "window_closed" }
            if let duration, ContinuousClock.now - ready >= .seconds(duration) { return "duration" }
            if let failure = engine.failure { throw failure }
            if let failure = additionalFailure?() { throw failure }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

final class SignalMonitor: @unchecked Sendable {
    private var sources: [DispatchSourceSignal] = []
    private let lock = NSLock()
    private var storedSignal: Int32?
    private var graceful = false

    var received: Int32? { lock.withLock { storedSignal } }
    func allowGracefulStop() { lock.withLock { graceful = true } }

    func cancel() {
        sources.forEach { $0.cancel() }
        Darwin.signal(SIGINT, SIG_DFL)
        Darwin.signal(SIGTERM, SIG_DFL)
    }

    init() {
        for number in [SIGINT, SIGTERM] {
            Darwin.signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let force = self.lock.withLock {
                    let force = self.storedSignal != nil || !self.graceful
                    self.storedSignal = number
                    return force
                }
                if force {
                    Darwin.exit(Output.error(CaptureError("interrupted", "Capture was interrupted.", details: ["signal": String(number)])))
                }
            }
            source.resume()
            sources.append(source)
        }
    }
}

/// A blocked system API cannot be cancelled safely. Bound that wait at the process boundary.
final class Watchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))

    init(seconds: Double, error: @escaping @Sendable () -> CaptureError) {
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in
            guard let self, self.lock.withLock({
                guard self.active else { return false }
                self.active = false
                return true
            }) else { return }
            Darwin.exit(Output.error(error()))
        }
        timer.resume()
    }

    func cancel() { lock.withLock { active = false }; timer.cancel() }
    deinit { timer.cancel() }
}

final class ScreenshotFrame: @unchecked Sendable {
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
