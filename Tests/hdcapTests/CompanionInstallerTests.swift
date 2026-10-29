import CompanionIPC
import Foundation
import HDCapture
import Testing
@testable import hdcap

private func run(_ tool: String, _ arguments: String...) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "\(tool) \(arguments)")
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "hdcap-installer-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

/// Builds a release-shaped archive around a re-signed copy of a system executable.
private func archive(identifier: String = CompanionProtocol.bundleIdentifier, version: String = "1.2.3",
                     tamper: Bool = false, member: String = "HDCap.app") throws -> Data {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appending(path: member)
    let executable = app.appending(path: "Contents/MacOS/HDCap")
    try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: executable)
    let info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "HDCap", "CFBundlePackageType": "APPL",
                               "CFBundleShortVersionString": version, "CFBundleVersion": version]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: app.appending(path: "Contents/Info.plist"))
    try run("/usr/bin/codesign", "--force", "--sign", "-", app.path)
    if tamper {
        let handle = try FileHandle(forWritingTo: executable)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("tampered".utf8))
        try handle.close()
    }
    let output = root.appending(path: CompanionInstaller.archiveName)
    try run("/usr/bin/tar", "-czf", output.path, "-C", root.path, member)
    return try Data(contentsOf: output)
}

private func installedApplication() throws -> (directory: URL, app: URL) {
    let directory = try temporaryDirectory()
    let app = directory.appending(path: "HDCap.app")
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
    try Data("previous".utf8).write(to: app.appending(path: "marker"))
    return (directory, app)
}

@Test func replacesTheInstalledCompanionWithAVerifiedArchive() throws {
    let (directory, app) = try installedApplication()
    defer { try? FileManager.default.removeItem(at: directory) }
    try CompanionInstaller.install(archive: archive(), version: "1.2.3", at: app)
    #expect(try CompanionInstaller.verify(app) == "1.2.3")
    #expect(!FileManager.default.fileExists(atPath: app.appending(path: "marker").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["HDCap.app"])
}

enum Defect: CaseIterable { case identifier, signature, version, member }

@Test(arguments: Defect.allCases)
func keepsTheInstalledCompanionWhenAnArchiveFailsVerification(defect: Defect) throws {
    let (directory, app) = try installedApplication()
    defer { try? FileManager.default.removeItem(at: directory) }
    let data = switch defect {
    case .identifier: try archive(identifier: "com.example.other")
    case .signature: try archive(tamper: true)
    case .version: try archive(version: "1.2.4")
    case .member: try archive(member: "Other.app")
    }
    #expect(throws: CaptureError.self) { try CompanionInstaller.install(archive: data, version: "1.2.3", at: app) }
    #expect(try String(contentsOf: app.appending(path: "marker"), encoding: .utf8) == "previous")
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["HDCap.app"])
}
