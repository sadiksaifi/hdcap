import AppKit
import CompanionIPC
import Foundation
import HDCapture

/// Chooses whether capture commands open the camera in this process or in the companion.
enum CaptureRoute: String, Codable {
    case direct, companion

    /// HDCAP_CAPTURE overrides the route that hdcap setup saves.
    static func current() throws -> CaptureRoute {
        if let value = ProcessInfo.processInfo.environment["HDCAP_CAPTURE"] {
            guard let route = CaptureRoute(rawValue: value) else {
                throw CaptureError("invalid_capture_route", "HDCAP_CAPTURE must be direct or companion.", details: ["value": value])
            }
            return route
        }
        return try CompanionSettings.load()?.capture ?? .direct
    }
}

struct CompanionSettings: Codable {
    var capture: CaptureRoute

    static var url: URL { CompanionPaths.support.appending(path: "config.json") }

    static func load() throws -> CompanionSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do { return try JSONDecoder().decode(CompanionSettings.self, from: data) } catch {
            throw CaptureError("invalid_configuration", "The hdcap configuration is not valid. Run hdcap setup to replace it.", details: ["path": url.path])
        }
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
    }
}

enum CompanionLauncher {
    /// Connects to the running companion, launching it through LaunchServices when needed.
    /// LaunchServices makes the app its own responsible process for camera permission.
    static func connect() async throws -> CompanionSession {
        if let session = try await attempt() { return session }
        try await launch()
        let deadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            if let session = try await attempt() { return session }
        }
        throw CaptureError("companion_unresponsive", "HDCap started but did not accept commands within 10 seconds.",
                           details: ["path": CompanionPaths.application.path])
    }

    static func launch() async throws {
        let app = CompanionPaths.application
        guard FileManager.default.fileExists(atPath: app.appending(path: "Contents/Info.plist").path) else {
            throw CaptureError("companion_missing", "The HDCap companion is not installed. Run hdcap setup from Terminal, or set HDCAP_CAPTURE=direct.",
                               details: ["path": app.path])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        do {
            _ = try await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
        } catch {
            throw CaptureError("companion_launch_failed", "macOS did not launch HDCap. If macOS blocked it, choose Open Anyway for HDCap in System Settings > Privacy & Security, then run hdcap setup from Terminal.",
                               details: ["path": app.path, "reason": error.localizedDescription])
        }
    }

    private static func attempt() async throws -> CompanionSession? {
        do {
            return try await CompanionSession.connect(socket: CompanionPaths.socket, clientVersion: BuildVersion.current)
        } catch let error as CaptureError where error.code == "companion_not_running" {
            return nil
        }
    }
}
