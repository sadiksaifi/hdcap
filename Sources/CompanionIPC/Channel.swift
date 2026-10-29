import Darwin
import Foundation
import HDCapture

/// Newline-delimited JSON over a Unix stream socket whose peer runs as the current user.
/// One reader and any number of writers may use a channel at the same time.
public final class MessageChannel: @unchecked Sendable {
    static let maximumMessageBytes = 1 << 20

    private let descriptor: Int32
    private let writeLock = NSLock()
    private let stateLock = NSLock()
    private let readQueue = DispatchQueue(label: "hdcap.companion.channel")
    private var buffer = Data()
    private var storedDeadline: ContinuousClock.Instant?

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0, user == geteuid() else {
            Darwin.close(descriptor)
            throw CaptureError("companion_untrusted", "The companion socket peer is not the current user.")
        }
    }

    deinit { Darwin.close(descriptor) }

    /// Pending and later receives fail with companion_unresponsive after this instant.
    public var deadline: ContinuousClock.Instant? {
        get { stateLock.withLock { storedDeadline } }
        set { stateLock.withLock { storedDeadline = newValue } }
    }

    public static func connect(to socket: URL) throws -> MessageChannel {
        let descriptor = try makeSocket()
        let connected = try withSocketAddress(socket) { Darwin.connect(descriptor, $0, $1) }
        guard connected == 0 else {
            let code = errno
            Darwin.close(descriptor)
            if code == ENOENT || code == ECONNREFUSED {
                throw CaptureError("companion_not_running", "The hdcap companion is not running.")
            }
            throw CaptureError("companion_unavailable", "Cannot connect to the hdcap companion.",
                               details: ["path": socket.path, "reason": String(cString: strerror(code))])
        }
        return try MessageChannel(descriptor: descriptor)
    }

    public func send<T: Encodable>(_ message: T) throws {
        var bytes = try JSONEncoder().encode(message)
        bytes.append(10)
        try writeLock.withLock {
            try bytes.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                    if written < 0 {
                        if errno == EINTR { continue }
                        throw CaptureError("companion_disconnected", "The hdcap companion connection closed.")
                    }
                    offset += written
                }
            }
        }
    }

    /// Blocks until a message arrives. Returns nil when the peer closes the connection.
    public func receive<T: Decodable>(_ type: T.Type) throws -> T? {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                do { return try JSONDecoder().decode(T.self, from: line) } catch {
                    throw CaptureError("companion_protocol_error", "Received an invalid message from the hdcap companion connection.",
                                       details: ["reason": String(describing: error)])
                }
            }
            guard buffer.count < Self.maximumMessageBytes else {
                throw CaptureError("companion_protocol_error", "A companion message exceeded \(Self.maximumMessageBytes) bytes.")
            }
            try waitForInput()
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    public func receive<T: Decodable & Sendable>(_ type: T.Type) async throws -> T? {
        try await withCheckedThrowingContinuation { continuation in
            readQueue.async { continuation.resume(with: Result { try self.receive(type) }) }
        }
    }

    /// Ends both directions and wakes a pending receive. The descriptor closes on release.
    public func close() { shutdown(descriptor, SHUT_RDWR) }

    private func waitForInput() throws {
        while true {
            if let deadline, ContinuousClock.now >= deadline {
                throw CaptureError("companion_unresponsive", "The hdcap companion did not respond in time.")
            }
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&request, 1, 100)
            if ready > 0 || (ready < 0 && errno != EINTR) { return }
        }
    }
}

/// Accepts current-user connections on a socket inside a private directory.
public final class MessageListener: @unchecked Sendable {
    private let descriptor: Int32
    private let socket: URL
    private let lock = NSLock()
    private var closed = false

    public init(socket: URL) throws {
        try Self.preparePrivateDirectory(socket.deletingLastPathComponent())
        if (try? MessageChannel.connect(to: socket)) != nil {
            throw CaptureError("companion_running", "Another hdcap companion is already listening.", details: ["path": socket.path])
        }
        unlink(socket.path)
        let descriptor = try makeSocket()
        let previous = umask(0o177)
        let bound = try withSocketAddress(socket) { bind(descriptor, $0, $1) }
        umask(previous)
        guard bound == 0, listen(descriptor, 8) == 0 else {
            let reason = String(cString: strerror(errno))
            Darwin.close(descriptor)
            throw CaptureError("companion_listen_failed", "Cannot listen for hdcap commands.", details: ["path": socket.path, "reason": reason])
        }
        self.descriptor = descriptor
        self.socket = socket
    }

    deinit {
        close()
        Darwin.close(descriptor)
    }

    /// Blocks until a current-user client connects. Throws once the listener closes.
    public func accept() throws -> MessageChannel {
        while true {
            guard !lock.withLock({ closed }) else {
                throw CaptureError("companion_stopped", "The companion listener closed.")
            }
            var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&request, 1, 100) > 0 else { continue }
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else { continue }
            if let channel = try? MessageChannel(descriptor: client) { return channel }
        }
    }

    public func close() {
        let first = lock.withLock {
            defer { closed = true }
            return !closed
        }
        if first { unlink(socket.path) }
    }

    private static func preparePrivateDirectory(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var status = stat()
        guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR, status.st_uid == geteuid(),
              chmod(directory.path, 0o700) == 0 else {
            throw CaptureError("companion_socket_unsafe", "The companion socket directory must be a directory owned by the current user.",
                               details: ["path": directory.path])
        }
    }
}

private func makeSocket() throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw CaptureError("companion_unavailable", "Cannot create a local socket.", details: ["reason": String(cString: strerror(errno))])
    }
    return descriptor
}

private func withSocketAddress(_ socket: URL, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) throws -> Int32 {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let path = Array(socket.path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard path.count < capacity else {
        throw CaptureError("companion_socket_unsafe", "The companion socket path is longer than \(capacity - 1) bytes.", details: ["path": socket.path])
    }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
}
