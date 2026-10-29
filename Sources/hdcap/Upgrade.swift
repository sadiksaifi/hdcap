import ArgumentParser
import Darwin
import Foundation
import HDCapture

struct Upgrade: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Upgrade using the owning Homebrew installation or a verified release download.")
    @OptionGroup var output: OutputOptions

    func run() throws {
        let current = HDCap.configuration.version
        MainActor.assumeIsolated {
            Runtime.run {
                let watchdog = Watchdog(seconds: 600) { Darwin.exit(Output.error(CaptureError("upgrade_timeout", "Upgrade did not finish within 10 minutes."))) }
                defer { watchdog.cancel() }
                let result = try await Task.detached { try await UpgradeInstaller.perform(current: current) }.value
                try Output.result(result, command: "upgrade") {
                    result.updated ? "Updated hdcap to \(result.version) using \(result.method)." : "hdcap \(result.version) is already up to date."
                }
            }
        }
    }
}

private struct UpgradeResult: Encodable, Sendable {
    let method: String
    let previousVersion: String
    let version: String
    let updated: Bool
    let path: String
}

private enum UpgradeInstaller {
    static func perform(current: String) async throws -> UpgradeResult {
        let path = try executableURL()
        let bin = path.deletingLastPathComponent()
        let version = bin.deletingLastPathComponent()
        let formula = version.deletingLastPathComponent()
        let cellar = formula.deletingLastPathComponent()
        if path.lastPathComponent == "hdcap", bin.lastPathComponent == "bin",
           formula.lastPathComponent == "hdcap", cellar.lastPathComponent == "Cellar" {
            let prefix = cellar.deletingLastPathComponent()
            let brew = prefix.appendingPathComponent("bin/brew")
            Output.notice("Upgrading hdcap with Homebrew...")
            for arguments in [["update"], ["upgrade", "sadiksaifi/tap/hdcap"]] {
                try run(brew, arguments: arguments)
            }
            let linkedBinary = prefix.appendingPathComponent("bin/hdcap")
            let latest = try run(linkedBinary, arguments: ["--version"], captureOutput: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try StableVersion(latest)
            return UpgradeResult(method: "homebrew", previousVersion: current, version: latest,
                                 updated: latest != current, path: linkedBinary.path)
        }
        guard !path.pathComponents.contains(".build"), let installed = try? StableVersion(current),
              installed.components != [0, 0, 0] else {
            throw CaptureError("development_build", "Install an official release before using upgrade.")
        }

        let session = ReleaseAssets.session()
        defer { session.invalidateAndCancel() }
        let metadata = try await ReleaseAssets.download(URL(string: "https://api.github.com/repos/sadiksaifi/hdcap/releases/latest")!,
                                                        session: session, failure: "upgrade_failed")
        let release = try JSONDecoder().decode(Release.self, from: metadata)
        let latest = try StableVersion(release.tag_name)
        guard !release.draft, !release.prerelease, release.tag_name == "v\(latest.description)" else {
            throw CaptureError("invalid_release", "The latest release is not a stable hdcap version.")
        }
        guard latest > installed else {
            return UpgradeResult(method: "curl", previousVersion: current, version: current,
                                 updated: false, path: path.path)
        }
        let base = ReleaseAssets.base(tag: release.tag_name)
        let script = try await ReleaseAssets.download(base.appending(path: "install.sh"), session: session, failure: "upgrade_failed")
        let checksums = try await ReleaseAssets.download(base.appending(path: "checksums.txt"), session: session, failure: "upgrade_failed")
        try ReleaseAssets.verify(script, named: "install.sh", checksums: checksums)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hdcap-upgrade-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let installer = temporary.appendingPathComponent("install.sh")
        try script.write(to: installer, options: .atomic)
        var environment = ProcessInfo.processInfo.environment
        environment["HDCAP_INSTALL_DIR"] = bin.path
        environment["HDCAP_VERSION"] = release.tag_name
        Output.notice("Upgrading hdcap to \(release.tag_name)...")
        try run(URL(fileURLWithPath: "/bin/sh"), arguments: [installer.path], environment: environment)
        let actual = try run(path, arguments: ["--version"], captureOutput: true).trimmingCharacters(in: .whitespacesAndNewlines)
        guard try StableVersion(actual) == latest else {
            throw CaptureError("upgrade_failed", "The installed hdcap version does not match the downloaded release.")
        }
        return UpgradeResult(method: "curl", previousVersion: current, version: latest.description,
                             updated: true, path: path.path)
    }

    private static func executableURL() throws -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buffer, &size) == 0 else {
            throw CaptureError("upgrade_failed", "Cannot locate the running executable.")
        }
        let name = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return URL(fileURLWithPath: name).resolvingSymlinksInPath().standardizedFileURL
    }

    @discardableResult
    private static func run(_ executable: URL, arguments: [String], captureOutput: Bool = false,
                            environment: [String: String]? = nil) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment ?? ProcessInfo.processInfo.environment
        process.standardInput = FileHandle.nullDevice
        let pipe = captureOutput || Output.json ? Pipe() : nil
        process.standardError = pipe?.fileHandleForWriting ?? FileHandle.standardError
        process.standardOutput = pipe?.fileHandleForWriting ?? FileHandle.standardError
        do { try process.run() }
        catch { throw CaptureError("upgrade_failed", "Cannot run \(executable.lastPathComponent).", details: ["reason": error.localizedDescription]) }
        try? pipe?.fileHandleForWriting.close()
        let bytes = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CaptureError("upgrade_failed", "\(executable.lastPathComponent) \(arguments.first ?? "") failed; the installation was not replaced directly.",
                               details: ["exitStatus": String(process.terminationStatus),
                                         "output": String(decoding: bytes.suffix(4096), as: UTF8.self)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }
}
