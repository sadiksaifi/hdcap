import AppKit
import ArgumentParser
import CompanionIPC
import Darwin
import Foundation
import HDCapture

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Install or update the HDCap companion app and route capture commands through it.",
        discussion: """
        Run this from Terminal. Setup installs a verified companion at ~/Applications/HDCap.app, launches it, and asks macOS \
        for camera access for HDCap. Tools that run hdcap in the background can then capture without camera access of their own. \
        Setup updates the companion only when it is missing, damaged, or incompatible. Set HDCAP_CAPTURE=direct to capture \
        in the calling process instead.
        """
    )
    @OptionGroup var output: OutputOptions
    @Flag(help: "Report camera access without showing the macOS permission prompt.") var noInput = false
    @Flag(help: "Remove the macOS quarantine attribute from the installed companion without asking.") var removeQuarantine = false

    func run() throws {
        let current = HDCap.configuration.version
        let interactive = !noInput
        let removeQuarantine = removeQuarantine
        MainActor.assumeIsolated {
            Runtime.run {
                let watchdog = Watchdog(seconds: 600) { Darwin.exit(Output.error(CaptureError("setup_timeout", "Setup did not finish within 10 minutes."))) }
                defer { watchdog.cancel() }
                let result = try await CompanionSetup.perform(current: current, interactive: interactive, removeQuarantine: removeQuarantine)
                try Output.result(result, command: "setup") { result.summary }
            }
        }
    }
}

struct SetupResult: Encodable, Sendable {
    let path: String
    let version: String
    let protocolVersion: Int
    let updated: Bool
    let cameraAuthorization: CameraAuthorization
    let capture: CaptureRoute

    var summary: String {
        let state = updated ? "Installed HDCap \(version)" : "HDCap \(version) is already installed"
        let access = switch cameraAuthorization {
        case .authorized: "Camera access is allowed. Capture commands now run through HDCap."
        case .notDetermined: "Camera access has not been requested. Run hdcap setup without --no-input from Terminal."
        case .denied, .restricted: "Camera access for HDCap is off. Turn on HDCap in System Settings > Privacy & Security > Camera."
        }
        return "\(state) at \(path). \(access)"
    }
}

@MainActor
enum CompanionSetup {
    static func perform(current: String, interactive: Bool, removeQuarantine: Bool) async throws -> SetupResult {
        let app = CompanionPaths.application
        var session: CompanionSession?
        if (try? CompanionInstaller.verify(app)) != nil {
            try clearQuarantine(app, remove: removeQuarantine, interactive: interactive)
            do {
                let running = try await CompanionLauncher.connect()
                if Set(CompanionRequest.capabilities).isSubset(of: running.welcome.capabilities) { session = running }
            } catch let error as CaptureError where ["companion_incompatible", "companion_protocol_error", "companion_unresponsive",
                                                     "companion_disconnected"].contains(error.code) {
                // An incompatible companion is replaced below.
            }
        }
        let updated = session == nil
        if updated {
            try await update(app, current: current)
            try clearQuarantine(app, remove: removeQuarantine, interactive: interactive)
            let installed = try await CompanionLauncher.connect()
            guard Set(CompanionRequest.capabilities).isSubset(of: installed.welcome.capabilities) else {
                throw CaptureError("companion_incompatible", "The downloaded HDCap companion does not support this CLI.",
                                   details: ["companionVersion": installed.welcome.companionVersion])
            }
            session = installed
        }
        guard let session else { preconditionFailure("Setup has a compatible companion session.") }
        guard case .authorization(let status) = try await session.send(.authorize(prompt: interactive)) else {
            throw CaptureError("companion_protocol_error", "The hdcap companion returned a result for a different command.")
        }
        try CompanionSettings(capture: .companion).save()
        return SetupResult(path: app.path, version: session.welcome.companionVersion, protocolVersion: session.welcome.protocolVersion,
                           updated: updated, cameraAuthorization: status, capture: .companion)
    }

    /// Downloads the companion built with this CLI release, then replaces the installed app.
    private static func update(_ app: URL, current: String) async throws {
        guard let version = try? StableVersion(current), version.components != [0, 0, 0] else {
            throw CaptureError("development_build", "Development builds cannot download the companion. Run just companion to install a local build, then run hdcap setup again.")
        }
        Output.notice("Downloading the HDCap \(version) companion...")
        let downloads = ReleaseAssets.session()
        defer { downloads.invalidateAndCancel() }
        let base = ReleaseAssets.base(tag: "v\(version)")
        let archive = try await ReleaseAssets.download(base.appending(path: CompanionInstaller.archiveName), session: downloads, failure: "setup_failed")
        let checksums = try await ReleaseAssets.download(base.appending(path: "checksums.txt"), session: downloads, failure: "setup_failed")
        try ReleaseAssets.verify(archive, named: CompanionInstaller.archiveName, checksums: checksums)
        try await quitRunningCompanion()
        try CompanionInstaller.install(archive: archive, version: version.description, at: app)
    }

    /// Asks a running companion to quit, or waits for its idle exit when it cannot confirm that it is
    /// idle. Setup never terminates a companion, because that would discard a capture in progress.
    private static func quitRunningCompanion() async throws {
        func running() -> Bool {
            !NSRunningApplication.runningApplications(withBundleIdentifier: CompanionProtocol.bundleIdentifier).isEmpty
        }
        guard running() else { return }
        // Connect after downloading, so the companion's handshake deadline cannot expire first.
        if let session = try? await CompanionSession.connect(socket: CompanionPaths.socket, clientVersion: BuildVersion.current),
           session.welcome.capabilities.contains("quit") {
            _ = try await session.send(.quit)
        } else {
            Output.notice("Waiting for the running HDCap to finish its work and quit...")
        }
        // The companion quits after 60 seconds without a command.
        let deadline = ContinuousClock.now + .seconds(90)
        while running() {
            guard ContinuousClock.now < deadline else {
                throw CaptureError("companion_running", "HDCap is still running, possibly capturing for another command. Quit HDCap and run hdcap setup again.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Removes quarantine from the installed companion only, and only with the user's confirmation.
    /// This does not change Gatekeeper settings or grant camera access.
    private static func clearQuarantine(_ app: URL, remove: Bool, interactive: Bool) throws {
        let attribute = "com.apple.quarantine"
        let executable = app.appending(path: "Contents/MacOS/HDCap")
        guard [app, executable].contains(where: { getxattr($0.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }) else { return }
        var confirmed = remove
        if !confirmed, interactive, !Output.json, isatty(STDIN_FILENO) == 1 {
            FileHandle.standardError.write(Data("""
            macOS quarantined \(app.path), which can stop it from launching.
            Setup can remove the quarantine attribute from this app only. Gatekeeper stays on.
            Remove it? [y/N]
            """.utf8))
            confirmed = ["y", "yes"].contains(readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "")
        }
        guard confirmed else {
            throw CaptureError("companion_quarantined", "macOS quarantined HDCap.app, which can stop it from launching. Run hdcap setup --remove-quarantine, or remove the attribute with the command in details.",
                               details: ["path": app.path, "command": "xattr -dr \(attribute) '\(app.path)'"])
        }
        try CompanionInstaller.tool("/usr/bin/xattr", "-dr", attribute, app.path)
    }
}

enum CompanionInstaller {
    static let archiveName = "hdcap-companion_darwin_arm64.tar.gz"

    /// Returns the bundle version after checking the bundle identifier and code signature.
    /// An ad-hoc signature proves the bundle is intact; it does not authenticate a publisher.
    static func verify(_ app: URL) throws -> String {
        var status = stat()
        guard lstat(app.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
              let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == CompanionProtocol.bundleIdentifier,
              let version = info["CFBundleShortVersionString"] as? String else {
            throw CaptureError("companion_invalid", "HDCap.app is not a valid hdcap companion.", details: ["path": app.path])
        }
        try tool("/usr/bin/codesign", "--verify", "--strict", "--deep",
                 "-R=identifier \"\(CompanionProtocol.bundleIdentifier)\"", app.path)
        return version
    }

    /// Extracts and verifies a release archive beside the destination, then swaps it in.
    /// The installed app stays in place when any step fails.
    static func install(archive: Data, version: String, at destination: URL) throws {
        let files = FileManager.default
        let staging = destination.deletingLastPathComponent().appending(path: ".hdcap-setup-\(UUID().uuidString)")
        try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: staging) }
        let file = staging.appending(path: archiveName)
        try archive.write(to: file)
        try tool("/usr/bin/tar", "-xzf", file.path, "-C", staging.path, "HDCap.app")
        let staged = staging.appending(path: "HDCap.app")
        let actual = try verify(staged)
        guard actual == version else {
            throw CaptureError("companion_invalid", "The downloaded companion has the wrong version.", details: ["expected": version, "actual": actual])
        }
        // Exchange the two directories in one step, so an interruption leaves one complete app in place.
        // The previous app ends up in staging and is removed with it.
        var status = stat()
        let exists = lstat(destination.path, &status) == 0
        let moved = exists ? renamex_np(staged.path, destination.path, UInt32(RENAME_SWAP)) : rename(staged.path, destination.path)
        guard moved == 0 else {
            throw CaptureError("setup_failed", "Cannot install HDCap.app.", details: ["path": destination.path, "reason": String(cString: strerror(errno))])
        }
    }

    static func tool(_ path: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CaptureError("companion_invalid", "\(URL(fileURLWithPath: path).lastPathComponent) rejected the HDCap companion.",
                               details: ["output": String(decoding: output.suffix(4096), as: UTF8.self)])
        }
    }
}
