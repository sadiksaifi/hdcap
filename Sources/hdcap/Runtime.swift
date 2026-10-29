import AppKit
import CompanionIPC
import Foundation
import HDCapture

@MainActor
enum Runtime {
    // Keep these entrypoints returning Void. Inferring Never through assumeIsolated
    // lets optimized builds discard captured job storage before the task uses it.
    static func run(window: Bool = false, operation: @escaping @MainActor () async throws -> Void) {
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

    static func capture<Job: CompanionJob>(_ job: Job, command: String, window: Bool = false,
                                           text: @escaping (Job.Result) -> String) {
        let route: CaptureRoute
        do { route = try CaptureRoute.current() } catch { Darwin.exit(Output.error(error)) }
        switch route {
        case .direct:
            run(window: window) {
                let host = TerminalHost()
                defer { host.cancel() }
                try await CaptureEngine.authorize(noInput: job.capture.noInput)
                let result = try await job.run(host: host)
                try Output.result(result, command: command) { text(result) }
            }
        case .companion:
            // The companion owns the camera and any preview window. It never prompts for permission.
            run {
                let signals = SignalMonitor()
                defer { signals.cancel() }
                let session = try await CompanionLauncher.connect()
                let result = try await session.run(job, stopSignal: { signals.received },
                                                   onNotice: { Output.notice($0) }, onGraceful: { signals.allowGracefulStop() })
                try Output.result(result, command: command) { text(result) }
            }
        }
    }
}

/// Runs capture jobs in this process, stopping them on SIGINT or SIGTERM.
final class TerminalHost: CaptureHost {
    let signals = SignalMonitor()

    var stopSignal: Int32? { signals.received }
    func allowGracefulStop() { signals.allowGracefulStop() }
    func notice(_ text: String) { Output.notice(text) }
    func abandon(_ error: CaptureError) -> Never { Darwin.exit(Output.error(error)) }
    func cancel() { signals.cancel() }
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
                    Darwin.exit(Output.error(CaptureError.interrupted(signal: number)))
                }
            }
            source.resume()
            sources.append(source)
        }
    }
}
