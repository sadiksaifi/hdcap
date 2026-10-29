import Darwin
import Foundation
import Testing
import HDCapture
@testable import CompanionIPC

/// Records how the server delivered each request, and holds capture requests until stopped.
private final class FakeService: CompanionService, @unchecked Sendable {
    private let lock = NSLock()
    private var signals: [Int32] = []
    private var started = 0

    var stopSignals: [Int32] { lock.withLock { signals } }
    var captureCount: Int { lock.withLock { started } }

    func handle(_ request: CompanionRequest, host: any CaptureHost) async throws -> CompanionResult {
        switch request {
        case .authorize:
            return .authorization(status: .denied)
        default:
            lock.withLock { started += 1 }
            host.allowGracefulStop()
            // Give up instead of hanging the suite when a stop never arrives.
            for _ in 0..<300 where host.stopSignal == nil { try await Task.sleep(for: .milliseconds(10)) }
            guard let signal = host.stopSignal else { throw CaptureError("fake_stop_timeout", "No stop arrived.") }
            lock.withLock { signals.append(signal) }
            throw CaptureError.interrupted(signal: signal)
        }
    }
}

/// Unix socket paths are limited to 104 bytes, so tests avoid the long per-user temporary directory.
private func socketURL() -> URL {
    URL(fileURLWithPath: "/tmp/hdcap-\(UUID().uuidString.prefix(8))/companion.sock")
}

private func job() -> ScreenshotJob {
    ScreenshotJob(capture: CaptureRequest(deviceName: "Fake", deviceID: nil, resolution: Resolution(width: 640, height: 480),
                                          frameRate: FrameRate(numerator: 30, denominator: 1), transform: try! VideoTransform()),
                  path: "/tmp/unused.png", overwrite: false)
}

private func eventually(_ condition: () -> Bool) async throws {
    for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    #expect(condition())
}

private func expectError(_ code: String, _ operation: () async throws -> Void) async {
    do {
        try await operation()
        Issue.record("Expected \(code)")
    } catch let error as CaptureError {
        #expect(error.code == code)
    } catch {
        Issue.record("Unexpected \(error)")
    }
}

@Test func negotiatesProtocolAndReturnsTypedResults() async throws {
    let socket = socketURL()
    let server = try CompanionServer(socket: socket, version: "1.2.3", service: FakeService())
    defer { server.stop() }
    let session = try await CompanionSession.connect(socket: socket, clientVersion: "9.9.9")
    #expect(session.welcome.protocolVersion == CompanionProtocol.version)
    #expect(session.welcome.companionVersion == "1.2.3")
    let result = try await session.send(.authorize(prompt: false))
    guard case .authorization(let status) = result else { Issue.record("Unexpected \(result)"); return }
    #expect(status == .denied)
}

@Test func reportsMissingCompanionSeparately() async {
    await expectError("companion_not_running") { _ = try await CompanionSession.connect(socket: socketURL(), clientVersion: "1.0.0") }
}

@Test func rejectsClientsWithoutACommonProtocolVersion() async throws {
    let socket = socketURL()
    let server = try CompanionServer(socket: socket, version: "1.0.0", service: FakeService())
    defer { server.stop() }
    let channel = try MessageChannel.connect(to: socket)
    try channel.send(ClientMessage.hello(protocolVersions: [CompanionProtocol.version + 1], clientVersion: "2.0.0"))
    guard case .error(let error) = try await channel.receive(CompanionMessage.self) else { Issue.record("Expected an error"); return }
    #expect(error.code == "companion_incompatible")
}

@Test func rejectsCommandsTheCompanionDoesNotAdvertise() async throws {
    let socket = socketURL()
    let listener = try MessageListener(socket: socket)
    Thread.detachNewThread {
        guard let channel = try? listener.accept() else { return }
        _ = try? channel.receive(ClientMessage.self)
        try? channel.send(CompanionMessage.welcome(protocolVersion: CompanionProtocol.version, companionVersion: "1.0.0", capabilities: ["authorize"]))
        _ = try? channel.receive(ClientMessage.self)
    }
    let session = try await CompanionSession.connect(socket: socket, clientVersion: "1.0.0")
    await expectError("companion_incompatible") { _ = try await session.send(.screenshot(job: job())) }
}

@Test func forwardsStopSignalsAndRejectsConcurrentCaptures() async throws {
    let socket = socketURL()
    let service = FakeService()
    let server = try CompanionServer(socket: socket, version: "1.0.0", service: service)
    defer { server.stop() }
    let signal = SignalBox()
    let graceful = SignalBox()
    let first = Task {
        try await CompanionSession.connect(socket: socket, clientVersion: "1.0.0")
            .send(.screenshot(job: job()), stopSignal: { signal.value }, onGraceful: { graceful.value = 1 })
    }
    try await eventually { graceful.value == 1 }
    await expectError("companion_busy") {
        _ = try await CompanionSession.connect(socket: socket, clientVersion: "1.0.0").send(.screenshot(job: job()))
    }
    let authorization = try await CompanionSession.connect(socket: socket, clientVersion: "1.0.0").send(.authorize(prompt: false))
    guard case .authorization = authorization else { Issue.record("Authorization should not wait for capture"); return }
    signal.value = SIGINT
    await expectError("interrupted") { _ = try await first.value }
    #expect(service.stopSignals == [SIGINT])
    #expect(service.captureCount == 1)
}

@Test func stopsCaptureWhenTheClientDisconnects() async throws {
    let socket = socketURL()
    let service = FakeService()
    let server = try CompanionServer(socket: socket, version: "1.0.0", service: service)
    defer { server.stop() }
    let channel = try MessageChannel.connect(to: socket)
    try channel.send(ClientMessage.hello(protocolVersions: [CompanionProtocol.version], clientVersion: "1.0.0"))
    _ = try await channel.receive(CompanionMessage.self)
    try channel.send(ClientMessage.request(.screenshot(job: job())))
    guard case .graceful = try await channel.receive(CompanionMessage.self) else { Issue.record("Expected graceful"); return }
    channel.close()
    try await eventually { service.stopSignals == [SIGTERM] }
    // The capture slot is free again once the abandoned request finishes.
    var outcome: CaptureError?
    for _ in 0..<300 {
        do {
            _ = try await CompanionSession.connect(socket: socket, clientVersion: "1.0.0").send(.screenshot(job: job()), stopSignal: { SIGINT })
        } catch let error as CaptureError {
            outcome = error
        }
        if outcome?.code != "companion_busy" { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(outcome?.code == "interrupted")
}

@Test func reportsACompanionThatExitsBeforeAResult() async throws {
    let socket = socketURL()
    let listener = try MessageListener(socket: socket)
    Thread.detachNewThread {
        guard let channel = try? listener.accept() else { return }
        _ = try? channel.receive(ClientMessage.self)
        try? channel.send(CompanionMessage.welcome(protocolVersion: CompanionProtocol.version, companionVersion: "1.0.0", capabilities: CompanionRequest.capabilities))
        _ = try? channel.receive(ClientMessage.self)
        channel.close()
    }
    let session = try await CompanionSession.connect(socket: socket, clientVersion: "1.0.0")
    await expectError("companion_disconnected") { _ = try await session.send(.screenshot(job: job())) }
}

@Test func restrictsTheSocketToOneListenerAndTheCurrentUser() throws {
    let socket = socketURL()
    let server = try CompanionServer(socket: socket, version: "1.0.0", service: FakeService())
    defer { server.stop() }
    #expect(throws: CaptureError.self) { try MessageListener(socket: socket) }
    let directory = try FileManager.default.attributesOfItem(atPath: socket.deletingLastPathComponent().path)
    let file = try FileManager.default.attributesOfItem(atPath: socket.path)
    #expect(directory[.posixPermissions] as? Int == 0o700)
    #expect(file[.posixPermissions] as? Int == 0o600)
}

private final class SignalBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32?
    var value: Int32? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
