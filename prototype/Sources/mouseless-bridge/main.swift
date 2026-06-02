// mouseless-bridge — Chrome Native Messaging host.
//
// Browser launches this binary (per `chrome.runtime.connectNative(...)`)
// and gives us its stdin/stdout. Our job: be a transparent pipe between
// those and the Unix-domain socket Mouseless main process is listening
// on. Same wire format both sides (4-byte native-byte-order uint32
// length + UTF-8 JSON body), so we don't parse — just shovel bytes.
//
// Lifecycle: the browser spawns one bridge per `connectNative` call
// and reaps us when the extension's port disconnects (extension
// unloaded, tab closed if the port lived in a content script, etc.).
// We additionally exit on Mouseless socket close.

import Foundation
import Darwin

let SOCKET_PATH = NSHomeDirectory() + "/Library/Application Support/Mouseless/bridge.sock"

// MARK: - Stderr logging
// Chrome captures stderr; appears in chrome://extensions when the
// extension is opened in "inspect views: service worker".
func log(_ msg: String) {
    let line = "[mouseless-bridge] \(msg)\n"
    _ = line.withCString { ptr in
        write(2, ptr, strlen(ptr))
    }
}

// MARK: - Native-messaging framing helpers

/// Read exactly `count` bytes from `fd`, or return nil on EOF / error.
func readFull(_ fd: Int32, _ count: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: count)
    var done = 0
    while done < count {
        let n = buf.withUnsafeMutableBufferPointer { p in
            read(fd, p.baseAddress! + done, count - done)
        }
        if n == 0 { return nil }    // EOF
        if n < 0 {
            if errno == EINTR { continue }
            return nil
        }
        done += n
    }
    return buf
}

/// Write all of `bytes` to `fd`. Returns false on broken pipe / error.
func writeFull(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
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

/// Read one framed message: 4-byte length + body. nil on EOF.
func readMessage(_ fd: Int32) -> [UInt8]? {
    guard let lenBuf = readFull(fd, 4) else { return nil }
    let len = lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }
    // Native-messaging spec caps at 1 MB extension→host; be a touch
    // more permissive for host→extension. Anything larger is almost
    // certainly a framing error, not a legitimate huge JSON.
    if len == 0 || len > 4 * 1024 * 1024 {
        log("bad incoming length \(len) — bailing")
        return nil
    }
    guard let body = readFull(fd, Int(len)) else { return nil }
    var out = lenBuf
    out.append(contentsOf: body)
    return out
}

// MARK: - Socket connect

func connectSocket() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        log("socket() failed errno=\(errno)")
        return nil
    }
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    let pathBytes = Array(SOCKET_PATH.utf8)
    guard pathBytes.count < pathCapacity else {
        log("socket path too long: \(SOCKET_PATH)")
        close(fd)
        return nil
    }
    _ = SOCKET_PATH.withCString { src in
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            memcpy(UnsafeMutableRawPointer(dst), src, strlen(src))
        }
    }
    let addrSize = socklen_t(MemoryLayout<sockaddr_un>.size)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, addrSize)
        }
    }
    guard r == 0 else {
        log("connect() failed errno=\(errno) path=\(SOCKET_PATH) — is Mouseless running?")
        close(fd)
        return nil
    }
    return fd
}

// MARK: - Main

// SIGPIPE: if stdout (Chrome) or socket (Mouseless) closes during a
// write we'd get killed. Ignore globally; SO_NOSIGPIPE on the socket
// belt-and-suspenders. stdout/stderr also covered by signal handler.
signal(SIGPIPE, SIG_IGN)

guard let sockFD = connectSocket() else {
    // Surface the error to the extension: write one error message
    // back via stdout before exiting so the JS side sees something
    // structured instead of a silent disconnect.
    let err = #"{"type":"bridge_error","reason":"cannot_connect_main_process","socket":"\#(SOCKET_PATH)"}"#
    let body = Array(err.utf8)
    var len = UInt32(body.count)
    let lenBytes = withUnsafeBytes(of: &len) { Array($0) }
    _ = writeFull(1, lenBytes)
    _ = writeFull(1, body)
    exit(1)
}
log("connected to Mouseless via \(SOCKET_PATH)")

// Two relay loops, one per direction. Run on background queues
// (`DispatchQueue.global`) so each blocks only its own thread. First
// to EOF / error tears down everything via `done`.
let group = DispatchGroup()
let done = DispatchSemaphore(value: 0)

// stdin (Chrome) → socket (Mouseless)
group.enter()
DispatchQueue.global(qos: .userInteractive).async {
    defer { group.leave(); done.signal() }
    while let frame = readMessage(0) {
        if !writeFull(sockFD, frame) {
            log("write to socket failed — exiting")
            return
        }
    }
    log("stdin EOF — chrome disconnected")
}

// socket (Mouseless) → stdout (Chrome)
group.enter()
DispatchQueue.global(qos: .userInteractive).async {
    defer { group.leave(); done.signal() }
    while let frame = readMessage(sockFD) {
        if !writeFull(1, frame) {
            log("write to stdout failed — exiting")
            return
        }
    }
    log("socket EOF — Mouseless main process disconnected")
}

// Park main thread until either direction ends, then shut down.
done.wait()
close(sockFD)
// stdin closed by browser; stdout flush by exit().
exit(0)
