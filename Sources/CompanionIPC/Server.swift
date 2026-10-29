import Darwin
import Foundation
import HDCapture

/// Runs one companion request. Throw CaptureError to report a structured failure.
public protocol CompanionService: Sendable {
    func handle(_ request: CompanionRequest, host: any CaptureHost) async throws -> CompanionResult
}

/// Serves one request per connection and runs camera requests one at a time.
public final class CompanionServer: @unchecked Sendable {
    private let listener: MessageListener
    private let version: String
    private let service: any CompanionService
    private let onConnectionCount: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var exclusive = false
    private var connections = 0

    /// `onConnectionCount` runs while the server holds its lock and must not call back into the server.
    public init(socket: URL, version: String, service: some CompanionService,
                onConnectionCount: @escaping @Sendable (Int) -> Void = { _ in }) throws {
        listener = try MessageListener(socket: socket)
        self.version = version
        self.service = service
        self.onConnectionCount = onConnectionCount
        Thread.detachNewThread { [self] in
            while let channel = try? listener.accept() {
                count(+1)
                Task {
                    await serve(channel)
                    count(-1)
                }
            }
        }
    }

    public func stop() { listener.close() }

    /// Reports counts under the lock so the idle timer never sees a stale zero after a new connection.
    private func count(_ change: Int) {
        lock.withLock {
            connections += change
            onConnectionCount(connections)
        }
    }

    private func serve(_ channel: MessageChannel) async {
        defer { channel.close() }
        channel.deadline = .now + .seconds(5)
        guard case .hello(let versions, _)? = try? await channel.receive(ClientMessage.self) else { return }
        guard versions.contains(CompanionProtocol.version) else {
            try? channel.send(CompanionMessage.error(CaptureError(
                "companion_incompatible", "The hdcap companion does not support this CLI. Run hdcap setup to update it.",
                details: ["companionProtocol": String(CompanionProtocol.version), "companionVersion": version,
                          "clientProtocols": versions.map(String.init).joined(separator: ",")])))
            return
        }
        try? channel.send(CompanionMessage.welcome(protocolVersion: CompanionProtocol.version, companionVersion: version,
                                                   capabilities: CompanionRequest.capabilities))
        guard case .request(let request)? = try? await channel.receive(ClientMessage.self) else { return }
        channel.deadline = nil
        if request.isExclusive {
            guard lock.withLock({ exclusive ? false : { exclusive = true; return true }() }) else {
                try? channel.send(CompanionMessage.error(CaptureError(
                    "companion_busy", "The hdcap companion is already running a capture for another command. Try again after it finishes.")))
                return
            }
        }
        let host = ConnectionHost(channel: channel)
        Task.detached { await host.watchForStop() }
        let message: CompanionMessage
        do {
            message = .result(try await service.handle(request, host: host))
        } catch {
            message = .error(error as? CaptureError ?? CaptureError("operation_failed", error.localizedDescription))
        }
        try? channel.send(message)
        // A companion that quits keeps its capture slot so no new capture starts before it exits.
        if request.isExclusive, !(request.capability == "quit" && message.succeeded) {
            lock.withLock { exclusive = false }
        }
    }
}

/// Reports job progress to the CLI and turns its stop request or disconnection into a stop signal.
private final class ConnectionHost: CaptureHost, @unchecked Sendable {
    private let channel: MessageChannel
    private let lock = NSLock()
    private var signal: Int32?

    init(channel: MessageChannel) { self.channel = channel }

    var stopSignal: Int32? { lock.withLock { signal } }
    func allowGracefulStop() { try? channel.send(CompanionMessage.graceful) }
    func notice(_ text: String) { try? channel.send(CompanionMessage.notice(message: text)) }

    func abandon(_ error: CaptureError) -> Never {
        try? channel.send(CompanionMessage.error(error))
        exit(1)
    }

    func watchForStop() async {
        while true {
            let message = try? await channel.receive(ClientMessage.self)
            switch message {
            case .stop(let number)?:
                stop(number)
            case .some:
                continue
            case nil:
                // A disconnected CLI cannot receive a result, so finish and keep the output.
                stop(SIGTERM)
                return
            }
        }
    }

    private func stop(_ number: Int32) {
        lock.withLock { if signal == nil { signal = number } }
    }
}

private extension CompanionMessage {
    var succeeded: Bool {
        if case .result = self { true } else { false }
    }
}
