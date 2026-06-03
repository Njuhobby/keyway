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

    /// FD of the client that **most recently reported user focus**
    /// (via `{type: "i_am_active"}`). Multiple clients can connect at
    /// once — one per Chrome profile, one per separate browser binary
    /// — and only the one whose window the user is currently looking
    /// at should answer hint requests. The extension's
    /// `chrome.windows.onFocusChanged` listener tells us when this
    /// changes; we trust it because the extension's own profile
    /// knows what's focused in that browser, and macOS can't (Chrome
    /// profiles share one PID, so AX can't distinguish them).
    ///
    /// `-1` when no client has reported activity. Cleared when the
    /// client at this fd disconnects.
    private var activeFD: Int32 = -1
    private let stateLock = NSLock()

    /// Per-client identity (browser kind + free-form session id) so
    /// Mouseless's `sendToActive(expectingBrowser:)` can refuse to
    /// route, e.g., Safari-frontmost hint requests to a Chrome bridge.
    /// Populated when a client's `{cmd: "ping"}` carries a `browser`
    /// field. Cleared on disconnect.
    struct ClientIdentity: @unchecked Sendable {
        let browser: String?    // "chrome" / "edge" / "brave" / "safari" / "arc" / nil
    }
    private var clientIdentities: [Int32: ClientIdentity] = [:]

    /// One-shot continuations keyed by expected `type` field of the
    /// incoming response. Each entry is (token, continuation): the
    /// token disambiguates the timeout path from the response path
    /// when two waiters for the same type churn quickly. Single
    /// waiter per type — a second `awaitResponse(ofType:)` for the
    /// same type while one is pending displaces the prior (which
    /// resolves with nil).
    /// Sendable wrapper so the `[String: Any]` payload (which contains
    /// JSON-deserialized Foundation values — thread-safe in practice
    /// but invisible to Swift's checker) can ride across a continuation
    /// without tripping the `sending` diagnostic.
    struct ResponseBody: @unchecked Sendable {
        let body: [String: Any]
    }
    private struct Waiter {
        let token: UInt64
        let continuation: CheckedContinuation<ResponseBody?, Never>
    }
    private var waiters: [String: Waiter] = [:]
    private var nextWaiterToken: UInt64 = 1

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
            // Don't set activeFD on accept any more. Multiple browsers /
            // profiles can connect concurrently; only one is the user's
            // current frontmost. The client itself signals that via
            // `{type:"i_am_active"}` on Chrome's onFocusChanged. Until
            // then this fd doesn't get routed any outbound traffic.
            let q = DispatchQueue(label: "mouseless.bridge.conn.\(client)", qos: .utility)
            q.async { [weak self] in
                self?.connectionLoop(client: client)
            }
        }
    }

    private func connectionLoop(client: Int32) {
        defer {
            close(client)
            stateLock.lock()
            if activeFD == client { activeFD = -1 }
            clientIdentities[client] = nil
            stateLock.unlock()
            print("[bridge] client disconnected fd=\(client)")
        }
        while true {
            var lenBytes = [UInt8](repeating: 0, count: 4)
            guard readFull(client, into: &lenBytes, count: 4) else { return }
            let len = lenBytes.withUnsafeBytes { $0.load(as: UInt32.self) }
            // Sanity cap raised to 16 MB because hint lists for big SPA
            // pages (e.g., GitHub PR diff with many comments) can run
            // 200-500 KB; 1 MB was fine for ping but tight for hints.
            if len == 0 || len > 16 * 1024 * 1024 {
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
            // Cheap log line: full dict for small messages, type+size
            // for big ones so a 500 KB hint dump doesn't smear stdout.
            // Keepalive pings (every 20s from extension SW) skipped —
            // not interesting noise.
            let isKeepalive = (obj["cmd"] as? String) == "keepalive"
            if !isKeepalive {
                let preview: String
                if body.count < 256 {
                    preview = "\(obj)"
                } else {
                    preview = "\(obj["type"] ?? obj["cmd"] ?? "?") (\(body.count) bytes)"
                }
                print("[bridge] recv fd=\(client) msg=\(preview)")
            }

            // If this message is a response someone is awaiting
            // (matched by `type`), resume the continuation and skip
            // the user handler. Otherwise treat it as a request and
            // let the handler decide whether to reply.
            if let type = obj["type"] as? String,
               let waiter = takeWaiter(forType: type) {
                waiter.continuation.resume(returning: ResponseBody(body: obj))
                continue
            }

            // Infrastructure messages — handled by BridgeServer
            // itself, never escalated to the user handler.
            //
            // `{type: "i_am_active"}`: extension's window just gained
            // user focus. This is the routing pointer for outbound
            // `list_hints` requests. Without this, Mouseless can't
            // tell which of N concurrent connections (one per Chrome
            // profile) belongs to the user's foreground window.
            if (obj["type"] as? String) == "i_am_active" {
                stateLock.lock()
                let prev = activeFD
                activeFD = client
                let identity = clientIdentities[client]
                stateLock.unlock()
                if prev != client {
                    print("[bridge] activeFD ← fd=\(client) browser=\(identity?.browser ?? "?")")
                }
                continue
            }

            // Capture identity carried on the initial ping (and any
            // later ping) so `sendToActive(expectingBrowser:)` can
            // refuse to route to a mismatched browser (e.g., Safari
            // is frontmost but only Chrome's bridge is connected).
            // Falls through — user handler still gets the ping and
            // sends pong.
            if (obj["cmd"] as? String) == "ping",
               let browser = obj["browser"] as? String {
                stateLock.lock()
                clientIdentities[client] = ClientIdentity(browser: browser)
                stateLock.unlock()
                print("[bridge] client identity fd=\(client) browser=\(browser)")
            }

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

    // MARK: - Outbound (Mouseless → extension)

    /// Send a JSON message to the client that most recently reported
    /// focus (`i_am_active`). Returns false if no active client, the
    /// write failed, or — if `expectingBrowserBundleID` is supplied —
    /// the active client identifies as a different browser than the
    /// caller wants.
    ///
    /// The bundleID guard catches "Mouseless is on Safari but only
    /// Chrome's bridge is connected" — we don't want to silently send
    /// Chrome the request and overlay its hints on Safari. Returns
    /// false instead so `BrowserProvider` can fall back to OP.
    @discardableResult
    func sendToActive(_ message: [String: Any],
                      expectingBrowserBundleID bundleID: String? = nil) -> Bool {
        stateLock.lock()
        let fd = activeFD
        let identity = (fd >= 0) ? clientIdentities[fd] : nil
        stateLock.unlock()
        guard fd >= 0 else { return false }
        if let bundleID {
            let expected = Self.browserKeyForBundleID(bundleID)
            if let identityBrowser = identity?.browser,
               expected != identityBrowser {
                print("[bridge] sendToActive: bundleID=\(bundleID) wants browser=\(expected) but activeFD=\(fd) is browser=\(identityBrowser) — refusing")
                return false
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        writeMessage(client: fd, data: data)
        return true
    }

    /// Map a macOS bundle identifier to the short browser key the
    /// extension self-reports as. Keep in sync with the `BROWSER` const
    /// in `extension/background.js`. Unknown bundles return a sentinel
    /// that won't match anything — the guard then fails closed.
    private static func browserKeyForBundleID(_ bundleID: String) -> String {
        switch bundleID {
        case "com.google.Chrome",
             "com.google.Chrome.canary",
             "com.google.Chrome.beta":
            return "chrome"
        case "com.microsoft.edgemac":     return "edge"
        case "com.brave.Browser":         return "brave"
        case "company.thebrowser.Browser": return "arc"
        case "com.apple.Safari":          return "safari"
        default:                          return "unknown"
        }
    }

    /// Wait up to `timeout` seconds for the next incoming message whose
    /// `type` field equals `type`. Returns the message dict or nil on
    /// timeout. A new awaiter for the same type displaces the old one
    /// (old resolves nil).
    func awaitResponse(ofType type: String, timeout: TimeInterval) async -> [String: Any]? {
        let resp: ResponseBody? = await withCheckedContinuation { (cont: CheckedContinuation<ResponseBody?, Never>) in
            stateLock.lock()
            let token = nextWaiterToken
            nextWaiterToken &+= 1
            let prior = waiters[type]
            waiters[type] = Waiter(token: token, continuation: cont)
            stateLock.unlock()
            // Resolve any displaced waiter so its caller doesn't hang.
            prior?.continuation.resume(returning: nil)

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self else { return }
                if let stale = self.takeWaiter(forType: type, withToken: token) {
                    stale.continuation.resume(returning: nil)
                }
            }
        }
        return resp?.body
    }

    /// Atomically remove + return the waiter for `type`. If `withToken`
    /// is supplied, only return the waiter when its token matches
    /// (timeout path so it doesn't yank a newer waiter that displaced
    /// the one whose deadline we're firing).
    private func takeWaiter(forType type: String, withToken token: UInt64? = nil) -> Waiter? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let w = waiters[type] else { return nil }
        if let token, w.token != token { return nil }
        waiters[type] = nil
        return w
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
