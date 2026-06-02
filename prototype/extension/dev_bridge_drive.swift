#!/usr/bin/env swift
// Dev test driver for `mouseless-bridge`.
//
// Usage:
//     swift prototype/extension/dev_bridge_drive.swift
//
// Spawns `mouseless-bridge` as a subprocess, writes one framed
// `{"cmd":"ping"}` to its stdin, reads its framed reply from stdout,
// prints both sides. End-to-end check of P1 step 2 without Chrome
// in the loop: success means
//
//     test driver ─stdio─▶ mouseless-bridge ─socket─▶ Mouseless
//     test driver ◀─stdio─ mouseless-bridge ◀─socket─ Mouseless
//
// all four hops work, framing intact in both directions.
//
// Requires Mouseless main process to be running with BridgeServer
// up (see ./run.sh).

import Foundation

let bridgePath = ".build/arm64-apple-macosx/debug/mouseless-bridge"
if !FileManager.default.isExecutableFile(atPath: bridgePath) {
    FileHandle.standardError.write(Data("bridge binary not found at \(bridgePath) — run `swift build` first\n".utf8))
    exit(1)
}

let proc = Process()
proc.executableURL = URL(fileURLWithPath: bridgePath)
let stdinPipe = Pipe()
let stdoutPipe = Pipe()
let stderrPipe = Pipe()
proc.standardInput = stdinPipe
proc.standardOutput = stdoutPipe
proc.standardError = stderrPipe
try proc.run()

// Surface bridge's stderr (its log() lines) on our stderr in real
// time so we can see "connected to Mouseless via ..." etc.
stderrPipe.fileHandleForReading.readabilityHandler = { handle in
    let data = handle.availableData
    if data.isEmpty {
        handle.readabilityHandler = nil
    } else {
        FileHandle.standardError.write(data)
    }
}

// Send {"cmd":"ping","note":"hello from dev_bridge_drive"}.
let payload = #"{"cmd":"ping","note":"hello from dev_bridge_drive"}"#
let payloadData = Data(payload.utf8)
var len = UInt32(payloadData.count)
var frame = Data()
withUnsafeBytes(of: &len) { frame.append(contentsOf: $0) }
frame.append(payloadData)
try stdinPipe.fileHandleForWriting.write(contentsOf: frame)
print("→ sent: \(payload)")

// Read one framed reply.
func readN(_ handle: FileHandle, _ n: Int) -> Data? {
    var out = Data()
    while out.count < n {
        let chunk = handle.availableData
        if chunk.isEmpty { return nil }
        out.append(chunk)
        if out.count > n { out = out.prefix(n) }   // trim if available read overshot
    }
    return out
}
guard let lenBuf = readN(stdoutPipe.fileHandleForReading, 4) else {
    print("read length failed — bridge may have exited; check stderr")
    proc.terminate()
    exit(1)
}
let replyLen = lenBuf.withUnsafeBytes { $0.load(as: UInt32.self) }
guard let body = readN(stdoutPipe.fileHandleForReading, Int(replyLen)) else {
    print("read body failed")
    proc.terminate()
    exit(1)
}
print("← recv: \(String(data: body, encoding: .utf8) ?? "<bad>")")

// Close stdin so bridge exits cleanly via "stdin EOF" path.
try stdinPipe.fileHandleForWriting.close()
proc.waitUntilExit()
print("bridge exited status=\(proc.terminationStatus)")
