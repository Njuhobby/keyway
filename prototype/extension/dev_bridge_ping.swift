#!/usr/bin/env swift
// Dev test client for BridgeServer.
//
// Usage:
//     swift prototype/extension/dev_bridge_ping.swift
//
// Connects to the Keyway main process's Unix domain socket at
// `~/Library/Application Support/Keyway/bridge.sock`, sends a
// single `{"cmd":"ping"}`, prints the response, and exits.
//
// Used to verify P1 step 1 in isolation — before the bridge CLI and
// the browser extension are wired up. If this script sees a `pong`
// the server side of the bridge is healthy.

import Foundation
import Darwin

let SOCK = NSHomeDirectory() + "/Library/Application Support/Keyway/bridge.sock"

let fd = socket(AF_UNIX, SOCK_STREAM, 0)
guard fd >= 0 else { print("socket() failed errno=\(errno)"); exit(1) }
defer { close(fd) }

var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
let pathBytes = Array(SOCK.utf8)
guard pathBytes.count < pathCapacity else {
    print("socket path too long: \(SOCK)")
    exit(1)
}
_ = SOCK.withCString { src in
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
    print("connect() failed errno=\(errno) — is Keyway running and is BridgeServer up?")
    exit(1)
}

// Send `{"cmd":"ping","note":"hello from dev_bridge_ping"}`.
let body = #"{"cmd":"ping","note":"hello from dev_bridge_ping"}"#
let bodyData = Data(body.utf8)
var lenLE = UInt32(bodyData.count)   // native byte order
let lenBytes = withUnsafeBytes(of: &lenLE) { Array($0) }
_ = lenBytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, 4) }
_ = bodyData.withUnsafeBytes { write(fd, $0.baseAddress, bodyData.count) }
print("→ sent: \(body)")

// Read response — same framing.
func readN(_ fd: Int32, _ n: Int) -> [UInt8]? {
    var buf = [UInt8](repeating: 0, count: n)
    var done = 0
    while done < n {
        let got = buf.withUnsafeMutableBufferPointer { read(fd, $0.baseAddress! + done, n - done) }
        if got <= 0 { return nil }
        done += got
    }
    return buf
}
guard let lenBuf = readN(fd, 4) else { print("read length failed"); exit(1) }
let replyLen = lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }
guard let replyBuf = readN(fd, Int(replyLen)) else { print("read body failed"); exit(1) }
print("← recv: \(String(data: Data(replyBuf), encoding: .utf8) ?? "<bad>")")
