import Foundation
import HDCapture

public enum CompanionProtocol {
    /// Increment when a message changes incompatibly. Release versions do not need to match.
    public static let version = 1
    public static let bundleIdentifier = "dev.sadiksaifi.hdcap.companion"
    /// Bounds a capture's finalization after the CLI forwards a stop request.
    public static let stopTimeout: Duration = .seconds(30)
}

public enum CompanionPaths {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    public static var application: URL { home.appending(path: "Applications/HDCap.app", directoryHint: .isDirectory) }
    public static var support: URL { home.appending(path: "Library/Application Support/hdcap", directoryHint: .isDirectory) }
    public static var socket: URL { support.appending(path: "companion.sock") }
}

public enum ClientMessage: Codable, Sendable {
    case hello(protocolVersions: [Int], clientVersion: String)
    case request(CompanionRequest)
    case stop(signal: Int32)
}

public enum CompanionMessage: Codable, Sendable {
    case welcome(protocolVersion: Int, companionVersion: String, capabilities: [String])
    case notice(message: String)
    /// A stop request now finishes the job and keeps its output.
    case graceful
    case result(CompanionResult)
    case error(CaptureError)
}

public enum CompanionRequest: Codable, Sendable {
    case authorize(prompt: Bool)
    case view(job: ViewJob)
    case record(job: RecordJob)
    case screenshot(job: ScreenshotJob)
    case quit

    public static let capabilities = ["authorize", "view", "record", "screenshot", "quit"]

    public var capability: String {
        switch self {
        case .authorize: "authorize"
        case .view: "view"
        case .record: "record"
        case .screenshot: "screenshot"
        case .quit: "quit"
        }
    }

    /// Requests that use the camera or end the companion run one at a time.
    var isExclusive: Bool {
        if case .authorize = self { false } else { true }
    }
}

public enum CompanionResult: Codable, Sendable {
    case authorization(status: CameraAuthorization)
    case view(result: ViewResult)
    case record(result: RecordResult)
    case screenshot(result: ScreenshotCompletion)
    case quit
}

/// A capture job the companion can run on behalf of the CLI.
public protocol CompanionJob: CaptureJob {
    var request: CompanionRequest { get }
    static func result(from: CompanionResult) -> Result?
}

extension ViewJob: CompanionJob {
    public var request: CompanionRequest { .view(job: self) }
    public static func result(from result: CompanionResult) -> ViewResult? {
        if case .view(let value) = result { value } else { nil }
    }
}

extension RecordJob: CompanionJob {
    public var request: CompanionRequest { .record(job: self) }
    public static func result(from result: CompanionResult) -> RecordResult? {
        if case .record(let value) = result { value } else { nil }
    }
}

extension ScreenshotJob: CompanionJob {
    public var request: CompanionRequest { .screenshot(job: self) }
    public static func result(from result: CompanionResult) -> ScreenshotCompletion? {
        if case .screenshot(let value) = result { value } else { nil }
    }
}
