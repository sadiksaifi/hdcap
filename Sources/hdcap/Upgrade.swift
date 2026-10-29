import ArgumentParser
import CryptoKit
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
    static let repository = "https://github.com/sadiksaifi/hdcap"

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

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 120
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let metadata = try await download(URL(string: "https://api.github.com/repos/sadiksaifi/hdcap/releases/latest")!, session: session)
        let release = try JSONDecoder().decode(Release.self, from: metadata)
        let latest = try StableVersion(release.tag_name)
        guard !release.draft, !release.prerelease, release.tag_name == "v\(latest.description)" else {
            throw CaptureError("invalid_release", "The latest release is not a stable hdcap version.")
        }
        guard latest > installed else {
            return UpgradeResult(method: "curl", previousVersion: current, version: current,
                                 updated: false, path: path.path)
        }
        let base = "\(repository)/releases/download/\(release.tag_name)"
        let script = try await download(URL(string: "\(base)/install.sh")!, session: session)
        let checksums = try await download(URL(string: "\(base)/checksums.txt")!, session: session)
        guard let checksumText = String(data: checksums, encoding: .utf8) else {
            throw CaptureError("invalid_checksum", "The release checksum file is not UTF-8.")
        }
        let matches = checksumText.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count == 2 && fields[1] == "install.sh" ? String(fields[0]) : nil
        }
        let digest = SHA256.hash(data: script).map { String(format: "%02x", $0) }.joined()
        guard matches.count == 1, matches[0] == digest else {
            throw CaptureError("checksum_mismatch", "The release installer failed SHA-256 verification.")
        }
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

    private static func download(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("hdcap", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url?.scheme == "https" else {
            throw CaptureError("upgrade_failed", "Cannot download a stable hdcap release.")
        }
        return data
    }

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
    }
}

private struct StableVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    init(_ text: String) throws {
        let value = text.hasPrefix("v") ? String(text.dropFirst()) : text
        let fields = value.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ field in
            !field.isEmpty && field.allSatisfy(\.isASCII) && field.allSatisfy(\.isNumber) &&
            (field.count == 1 || field.first != "0") && Int(field) != nil
        }) else {
            throw CaptureError("invalid_release", "Upgrade requires a stable semantic version.")
        }
        components = fields.map { Int($0)! }
    }

    var description: String { components.map(String.init).joined(separator: ".") }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
}
