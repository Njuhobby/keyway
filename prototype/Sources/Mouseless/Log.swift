import Foundation

/// Lightweight leveled logging.
///
/// Default level is `.info` — a quiet happy path (errors, warnings, and a few
/// lifecycle lines only). Set `MOUSELESS_LOG=debug|info|warn|error` in the
/// environment to change it; `debug` turns on the full per-operation
/// diagnostics (scan timings, AX walk steps, settle-watch polls, …).
///
/// Messages are built lazily via `@autoclosure`, so the string interpolation
/// for a filtered-out level costs nothing.
enum Log {
    enum Level: Int, Comparable {
        case error = 0, warn = 1, info = 2, debug = 3
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    static let level: Level = {
        switch ProcessInfo.processInfo.environment["MOUSELESS_LOG"]?.lowercased() {
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
        print(msg())
    }
}
