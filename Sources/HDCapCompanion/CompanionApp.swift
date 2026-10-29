import AppKit
import CompanionIPC
import Foundation
import HDCapture
import os

/// A windowless app that captures under its own camera permission for hdcap commands.
@main
enum CompanionApp {
    static let log = Logger(subsystem: CompanionProtocol.bundleIdentifier, category: "companion")

    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let idle = IdleExit(after: 60)
        do {
            let server = try CompanionServer(socket: CompanionPaths.socket, version: version,
                                             service: CaptureService(), onConnectionCount: idle.update)
            withExtendedLifetime(server) { application.run() }
        } catch {
            log.error("Cannot serve hdcap commands: \(String(describing: error), privacy: .public)")
            exit(1)
        }
    }
}

struct CaptureService: CompanionService {
    func handle(_ request: CompanionRequest, host: any CaptureHost) async throws -> CompanionResult {
        switch request {
        case .authorize(let prompt):
            return .authorization(status: prompt ? await CaptureEngine.requestCameraAccess() : CaptureEngine.cameraAuthorization)
        case .view(let job):
            try requireAuthorization()
            defer { Task { @MainActor in NSApplication.shared.setActivationPolicy(.accessory) } }
            return .view(result: try await job.run(host: host))
        case .record(let job):
            try requireAuthorization()
            return .record(result: try await job.run(host: host))
        case .screenshot(let job):
            try requireAuthorization()
            return .screenshot(result: try await job.run(host: host))
        case .quit:
            // Leave time for the reply to reach the CLI.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
            return .quit
        }
    }

    /// Capture commands never prompt; only hdcap setup requests camera access.
    private func requireAuthorization() throws {
        switch CaptureEngine.cameraAuthorization {
        case .authorized:
            return
        case .notDetermined:
            throw CaptureError("permission_required", "HDCap has not been allowed to use the camera. Run hdcap setup from Terminal to request access.")
        case .denied, .restricted:
            throw CaptureError("permission_denied", "Camera access for HDCap is off. Turn on HDCap in System Settings > Privacy & Security > Camera, then run hdcap setup.")
        }
    }
}

/// Quits after a period with no connected commands, so the app runs only on demand.
final class IdleExit: @unchecked Sendable {
    private let seconds: Double
    private let lock = NSLock()
    private var generation = 0

    init(after seconds: Double) {
        self.seconds = seconds
        update(0)
    }

    func update(_ connections: Int) {
        let current = lock.withLock {
            generation += 1
            return generation
        }
        guard connections == 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            // Exit while holding the lock, so a connection either counts first or never starts.
            lock.withLock { if generation == current { exit(0) } }
        }
    }
}
