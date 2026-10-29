import Foundation
import HDCapture

/// One CLI request to a running companion, after a protocol and capability handshake.
public final class CompanionSession: Sendable {
    public struct Welcome: Sendable {
        public let protocolVersion: Int
        public let companionVersion: String
        public let capabilities: [String]
    }

    public let welcome: Welcome
    private let channel: MessageChannel

    private init(welcome: Welcome, channel: MessageChannel) {
        self.welcome = welcome
        self.channel = channel
    }

    /// Throws companion_not_running when nothing listens, so the caller can launch the companion.
    public static func connect(socket: URL, clientVersion: String, timeout: Duration = .seconds(5)) throws -> CompanionSession {
        let channel = try MessageChannel.connect(to: socket)
        channel.deadline = .now + timeout
        try channel.send(ClientMessage.hello(protocolVersions: [CompanionProtocol.version], clientVersion: clientVersion))
        switch try channel.receive(CompanionMessage.self) {
        case .welcome(let version, let companionVersion, let capabilities)?:
            guard version == CompanionProtocol.version else {
                throw incompatible("The hdcap companion chose an unsupported protocol.", details: ["companionProtocol": String(version)])
            }
            channel.deadline = nil
            return CompanionSession(welcome: Welcome(protocolVersion: version, companionVersion: companionVersion,
                                                     capabilities: capabilities), channel: channel)
        case .error(let error)?:
            throw error
        case nil:
            throw CaptureError("companion_disconnected", "The hdcap companion closed the connection during the handshake.")
        default:
            throw CaptureError("companion_protocol_error", "The hdcap companion sent an unexpected handshake message.")
        }
    }

    /// Sends one request and waits for its result. The first stop signal is forwarded so the
    /// companion can finish the job; after that the companion has a bounded time to reply.
    public func send(_ request: CompanionRequest, stopSignal: @escaping @Sendable () -> Int32? = { nil },
                     onNotice: @escaping @Sendable (String) -> Void = { _ in },
                     onGraceful: @escaping @Sendable () -> Void = {}) async throws -> CompanionResult {
        guard welcome.capabilities.contains(request.capability) else {
            throw Self.incompatible("The hdcap companion does not support \(request.capability).",
                                    details: ["companionVersion": welcome.companionVersion])
        }
        try channel.send(ClientMessage.request(request))
        let channel = channel
        let forwarder = Task.detached {
            while !Task.isCancelled {
                if let signal = stopSignal() {
                    try? channel.send(ClientMessage.stop(signal: signal))
                    channel.deadline = .now + CompanionProtocol.stopTimeout
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        defer {
            forwarder.cancel()
            channel.close()
        }
        while true {
            switch try await channel.receive(CompanionMessage.self) {
            case .notice(let message)?: onNotice(message)
            case .graceful?: onGraceful()
            case .result(let result)?: return result
            case .error(let error)?: throw error
            case .welcome?: throw CaptureError("companion_protocol_error", "The hdcap companion repeated its handshake.")
            case nil: throw CaptureError("companion_disconnected", "The hdcap companion closed the connection before returning a result.")
            }
        }
    }

    public func run<Job: CompanionJob>(_ job: Job, stopSignal: @escaping @Sendable () -> Int32?,
                                       onNotice: @escaping @Sendable (String) -> Void,
                                       onGraceful: @escaping @Sendable () -> Void) async throws -> Job.Result {
        let result = try await send(job.request, stopSignal: stopSignal, onNotice: onNotice, onGraceful: onGraceful)
        guard let value = Job.result(from: result) else {
            throw CaptureError("companion_protocol_error", "The hdcap companion returned a result for a different command.")
        }
        return value
    }

    private static func incompatible(_ message: String, details: [String: String]) -> CaptureError {
        CaptureError("companion_incompatible", message + " Run hdcap setup to update it.", details: details)
    }
}
