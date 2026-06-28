import Foundation

/// Lightweight leveled logging.
///
/// Default level is `.info` — a quiet happy path (errors, warnings, and a few
/// lifecycle lines only). Set `KEYWAY_LOG=debug|info|warn|error` in the
/// environment to change it; `debug` turns on the full per-operation
/// diagnostics (scan timings, AX walk steps, settle-watch polls, …).
///
/// Messages are built lazily via `@autoclosure`, so the string interpolation
/// for a filtered-out level costs nothing.
///
/// Every emitted line goes two places: stdout (visible when run from a
/// terminal) **and** a rotating file at
/// `~/Library/Logs/Keyway/keyway.log`. The file is what users attach to bug
/// reports — when Keyway is launched from Finder there's no terminal to see
/// stdout, so without the file there'd be nothing to send. The previous run's
/// log is kept as `keyway.log.1` (rolled at launch) so a crash-and-relaunch
/// doesn't erase the evidence.
enum Log {
    enum Level: Int, Comparable {
        case error = 0, warn = 1, info = 2, debug = 3
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    static let level: Level = {
        switch ProcessInfo.processInfo.environment["KEYWAY_LOG"]?.lowercased() {
        case "debug":            return .debug
        case "info":             return .info
        case "warn", "warning":  return .warn
        case "error":            return .error
        default:                 return .info
        }
    }()

    static func error(_ msg: @autoclosure () -> String) { emit(.error, msg) }
    static func warn(_ msg: @autoclosure () -> String)  { emit(.warn, msg) }
    static func info(_ msg: @autoclosure () -> String)  { emit(.info, msg) }
    static func debug(_ msg: @autoclosure () -> String) { emit(.debug, msg) }

    private static func emit(_ messageLevel: Level, _ msg: () -> String) {
        guard messageLevel <= level else { return }
        let line = msg()
        print(line)
        FileSink.shared.write(line)
    }
}

/// Serial file writer for the on-disk log. `@unchecked Sendable` because the
/// `FileHandle` is only ever touched on `queue` (a serial DispatchQueue) after
/// construction, so there's no data race despite the non-Sendable handle.
private final class FileSink: @unchecked Sendable {
    static let shared = FileSink()

    private let queue = DispatchQueue(label: "com.keyway.log.file", qos: .utility)
    private let handle: FileHandle?

    private init() {
        handle = FileSink.openRotated()
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String {
            write("=== Keyway \(v) — log start ===")
        } else {
            write("=== Keyway (dev) — log start ===")
        }
    }

    func write(_ line: String) {
        // Everything runs on the serial queue: the FileHandle write AND the
        // stamp() call (DateFormatter isn't thread-safe). Capture self (which
        // is @unchecked Sendable) rather than the non-Sendable handle directly.
        queue.async { [self] in
            guard let handle else { return }
            let stamped = FileSink.stamp() + " " + line + "\n"
            if let data = stamped.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    }

    /// Open `~/Library/Logs/Keyway/keyway.log` for appending, after rolling
    /// any existing file to `keyway.log.1`. Best-effort: returns nil (logging
    /// silently disabled) if the directory or file can't be created.
    private static func openRotated() -> FileHandle? {
        let fm = FileManager.default
        guard let logs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Logs/Keyway", isDirectory: true)
        else { return nil }
        try? fm.createDirectory(at: logs, withIntermediateDirectories: true)

        let current = logs.appendingPathComponent("keyway.log")
        let previous = logs.appendingPathComponent("keyway.log.1")
        if fm.fileExists(atPath: current.path) {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: current, to: previous)
        }
        fm.createFile(atPath: current.path, contents: nil)
        return try? FileHandle(forWritingTo: current)
    }

    /// `HH:mm:ss.SSS` timestamp prefix. Cached formatter; only ever touched on
    /// the serial `queue` (inside `write`), so no thread-safety concern.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private static func stamp() -> String { formatter.string(from: Date()) }
}
