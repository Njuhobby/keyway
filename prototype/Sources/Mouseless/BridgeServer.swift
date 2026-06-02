import Foundation
import Darwin

/// Unix-domain socket server for the browser-extension bridge.
///
/// Listens on `~/Library/Application Support/Mouseless/bridge.sock`.
/// Accepts multiple concurrent connections (one per open browser
/// instance). Per connection: read length-prefixed JSON, hand to the
/// caller-supplied handler, write the handler's response back using
/// the same framing.
///
/// Frame format: **`[4-byte native-byte-order uint32 length][UTF-8 JSON body]`**
/// — exactly the same wire format Chrome Native Messaging uses on
/// stdio. The bridge CLI (P1 step 2) can therefore be a byte-for-byte
/// relay: extension `port.postMessage(json)` → browser writes
/// `[len][json]` to bridge stdin → bridge forwards bytes verbatim to
/// this socket. No re-parsing in the bridge.
///
/// Threading: accept loop on `acceptQueue`. Per-connection read loops
/// on per-connection queues (slow client doesn't block other clients).
/// All socket reads/writes are blocking but live in their own queue,
/// never on the main thread. Handler runs on the connection's queue;
/// hopping to MainActor for app-state mutation is the handler's
/// responsibility.
final class BridgeServer: @unchecked Sendable {
    static let shared = BridgeServer()

    /// Handler signature: `(incomingMessage, reply)`. The handler is
    /// expected to either call `reply(responseDict)` (sync or async)
    /// or drop the reply (one-way message). `reply` is safe to call
    /// from any thread; it serializes the dict to JSON and writes
    /// using the connection's framing.
    typealias Handler = @Sendable (_ message: [String: Any], _ reply: @escaping @Sendable ([String: Any]) -> Void) -> Void

    private var handler: Handler = { _, _ in }
    private var listenFD: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "mouseless.bridge.accept", qos: .utility)

    private static var socketPath: String {
        let dir = NSHomeDirectory() + "/Library/Application Support/Mouseless"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/bridge.sock"
    }

    /// Begin listening. Idempotent: re-entry without `stop()` first
    /// is a no-op. Stale `bridge.sock` file from a previous run is
    /// unlinked at the top — otherwise bind() would EADDRINUSE.
    func start(handler: @escaping Handler) {
        guard listenFD < 0 else { return }
        // Writing to a closed peer would normally raise SIGPIPE and
        // kill the process. Globally ignore; also set SO_NOSIGPIPE
        // per-socket below as belt + suspenders.
        signal(SIGPIPE, SIG_IGN)

        self.handler = handler
        let path = Self.socketPath
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            print("[bridge] socket() failed errno=\(errno)")
            return
        }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < pathCapacity else {
            print("[bridge] socket path too long (\(pathBytes.count) >= \(pathCapacity)): \(path)")
            close(fd)
            return
        }
        // `sun_path` is a fixed-size tuple in the Swift importer —
        // memcpy via a raw pointer is the standard idiom.
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                memcpy(UnsafeMutableRawPointer(dst), src, strlen(src))
            }
        }
        let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, addrSize)
            }
        }
        guard bindResult == 0 else {
            print("[bridge] bind() failed errno=\(errno) path=\(path)")
            close(fd)
            return
        }
        guard listen(fd, 8) == 0 else {
            print("[bridge] listen() failed errno=\(errno)")
            close(fd)
            return
        }

        listenFD = fd
        print("[bridge] listening on \(path)")
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(Self.socketPath)
    }

    private func acceptLoop() {
        while true {
            let fd = listenFD
            if fd < 0 { return }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                // EBADF here means stop() closed the listening socket
                // — clean shutdown, not an error.
                if errno != EBADF {
                    print("[bridge] accept() failed errno=\(errno)")
                }
                return
            }
            var one: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            print("[bridge] client connected fd=\(client)")
            let q = DispatchQueue(label: "mouseless.bridge.conn.\(client)", qos: .utility)
            q.async { [weak self] in
                self?.connectionLoop(client: client)
            }
        }
    }

    private func connectionLoop(client: Int32) {
        defer {
            close(client)
            print("[bridge] client disconnected fd=\(client)")
        }
        while true {
            var lenBytes = [UInt8](repeating: 0, count: 4)
            guard readFull(client, into: &lenBytes, count: 4) else { return }
            let len = lenBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            // Sanity cap. 1 MB is far above any realistic hint list
            // and protects against a misbehaving client sending
            // garbage length prefixes.
            if len == 0 || len > 1024 * 1024 {
                print("[bridge] bad message length \(len) fd=\(client) — closing")
                return
            }
            var body = [UInt8](repeating: 0, count: Int(len))
            guard readFull(client, into: &body, count: Int(len)) else { return }
            let data = Data(body)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[bridge] bad JSON fd=\(client)")
                return
            }
            print("[bridge] recv fd=\(client) msg=\(obj)")
            self.handler(obj) { [weak self] reply in
                guard let self else { return }
                guard let replyData = try? JSONSerialization.data(withJSONObject: reply) else {
                    print("[bridge] reply serialization failed")
                    return
                }
                self.writeMessage(client: client, data: replyData)
            }
        }
    }

    private func readFull(_ fd: Int32, into buf: inout [UInt8], count: Int) -> Bool {
        var done = 0
        while done < count {
            let n = buf.withUnsafeMutableBufferPointer { p in
                read(fd, p.baseAddress! + done, count - done)
            }
            if n == 0 { return false }   // EOF
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            done += n
        }
        return true
    }

    private func writeMessage(client: Int32, data: Data) {
        var len = UInt32(data.count)
        let lenBytes = withUnsafeBytes(of: &len) { Array($0) }
        guard writeFull(client, lenBytes) else { return }
        let bodyBytes = [UInt8](data)
        _ = writeFull(client, bodyBytes)
    }

    private func writeFull(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var done = 0
        while done < bytes.count {
            let n = bytes.withUnsafeBufferPointer { p in
                write(fd, p.baseAddress! + done, bytes.count - done)
            }
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            done += n
        }
        return true
    }
}
