import Foundation

/// One tool call from the helper to the app, as one JSON line over the bridge socket.
public struct BridgeRequest: Hashable, Sendable, Codable {
    public var tool: String
    public var arguments: JSONValue

    public init(tool: String, arguments: JSONValue) {
        self.tool = tool; self.arguments = arguments
    }
}

public enum BridgeError: Error, Equatable, Sendable, CustomStringConvertible {
    case pathTooLong(String)
    case socket(String, errno: Int32)
    /// Nothing listens on the socket: the app is not running or the bridge is turned off.
    case notListening
    case timedOut
    case malformedReply

    public var description: String {
        switch self {
        case let .pathTooLong(path): return "The socket path is too long: \(path)"
        case let .socket(call, code): return "\(call) failed: \(String(cString: strerror(code)))"
        case .notListening: return "Purser is not listening"
        case .timedOut: return "Purser did not answer in time"
        case .malformedReply: return "Purser sent a reply that cannot be read"
        }
    }
}

/// The Unix domain socket between the `purser-mcp` helper and the running app, in the App Group container (the one
/// place the sandboxed app and the helper both reach). The server refuses peers of another user; it cannot tell
/// which program started the helper.
public enum BridgeSocket {
    /// Info.plist key with the App Group id (the helper sits in the app bundle, so `Bundle.main` is the app).
    public static let appGroupInfoKey = "PurserAppGroup"
    public static let fileName = "mcp.sock"

    public static func path(inGroupContainer container: URL) -> String {
        container.appendingPathComponent(fileName, isDirectory: false).path
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        // One byte stays for the terminating NUL.
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw BridgeError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    static func open() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw BridgeError.socket("socket", errno: errno) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    /// Reads up to the first newline (not included); nil when the peer closed before sending one or the read failed.
    static func readLine(_ descriptor: Int32, limit: Int = 8 << 20) -> String? {
        var collected = Data()
        var buffer = [UInt8](repeating: 0, count: 64 << 10)
        while collected.count < limit {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                collected.append(contentsOf: buffer[..<newline])
                return String(data: collected, encoding: .utf8)
            }
            collected.append(contentsOf: buffer[..<count])
        }
        return nil
    }

    @discardableResult
    static func writeLine(_ descriptor: Int32, _ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes[offset...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }
}

/// The helper's side: one connection per tool call.
public enum BridgeClient {
    public static func call(_ request: BridgeRequest, socketPath: String, timeout: TimeInterval = 180) throws -> ToolResult {
        var address = try BridgeSocket.address(socketPath)
        let descriptor = try BridgeSocket.open()
        defer { close(descriptor) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            if [ENOENT, ECONNREFUSED, ENOTSOCK].contains(errno) { throw BridgeError.notListening }
            throw BridgeError.socket("connect", errno: errno)
        }
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        guard let data = try? JSONEncoder().encode(request), BridgeSocket.writeLine(descriptor, String(decoding: data, as: UTF8.self)) else {
            throw BridgeError.socket("write", errno: errno)
        }
        guard let line = BridgeSocket.readLine(descriptor) else {
            throw errno == EAGAIN || errno == EWOULDBLOCK ? BridgeError.timedOut : BridgeError.malformedReply
        }
        guard let result = try? JSONDecoder().decode(ToolResult.self, from: Data(line.utf8)) else { throw BridgeError.malformedReply }
        return result
    }
}

/// The app's side: listens on the socket and answers each connection's one request with `handler`.
public final class BridgeServer: @unchecked Sendable {
    public typealias Handler = @Sendable (BridgeRequest) async -> ToolResult

    private let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1

    public init(socketPath: String, handler: @escaping Handler) {
        self.path = socketPath
        self.handler = handler
    }

    deinit { stop() }

    public var isRunning: Bool { lock.withLock { listener >= 0 } }

    public func start() throws {
        guard !isRunning else { return }
        var address = try BridgeSocket.address(path)
        // A socket file left by a run that crashed would make bind fail.
        unlink(path)
        let descriptor = try BridgeSocket.open()
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw BridgeError.socket("bind", errno: code)
        }
        chmod(path, 0o600)
        guard listen(descriptor, 8) == 0 else {
            let code = errno
            close(descriptor)
            unlink(path)
            throw BridgeError.socket("listen", errno: code)
        }
        lock.withLock { listener = descriptor }
        let thread = Thread { [weak self] in self?.acceptLoop(descriptor) }
        thread.name = "purser-mcp-bridge"
        thread.start()
    }

    public func stop() {
        let descriptor = lock.withLock { () -> Int32 in
            defer { listener = -1 }
            return listener
        }
        guard descriptor >= 0 else { return }
        // Wakes the blocked accept, which then fails and ends its thread.
        shutdown(descriptor, SHUT_RDWR)
        close(descriptor)
        unlink(path)
    }

    private func acceptLoop(_ descriptor: Int32) {
        while true {
            let connection = accept(descriptor, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return
            }
            guard lock.withLock({ listener == descriptor }) else {
                close(connection)
                return
            }
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [handler] in Self.serve(connection, handler: handler) }
        }
    }

    private static func serve(_ connection: Int32, handler: @escaping Handler) {
        var peer: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(connection, &peer, &group) == 0, peer == getuid() else {
            close(connection)
            return
        }
        var limit = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        guard let line = BridgeSocket.readLine(connection),
              let request = try? JSONDecoder().decode(BridgeRequest.self, from: Data(line.utf8)) else {
            reply(connection, .failure("Purser could not read the request."))
            return
        }
        Task.detached {
            reply(connection, await handler(request))
        }
    }

    private static func reply(_ connection: Int32, _ result: ToolResult) {
        defer { close(connection) }
        guard let data = try? JSONEncoder().encode(result) else { return }
        BridgeSocket.writeLine(connection, String(decoding: data, as: UTF8.self))
    }
}
