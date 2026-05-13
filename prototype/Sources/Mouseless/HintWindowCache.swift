import Cocoa
import ApplicationServices

/// Per-`AXWindow` cache of walked hint targets. Lets sticky rescan reuse
/// untouched windows instead of re-walking the entire focused app.
///
/// Invalidation model (no AX observers — see `specs/hint-discovery.md`):
///
/// 1. **Focused app changed** → `syncFocusedApp(pid)` blows the whole cache.
/// 2. **AXWindows diff** → `pruneTo(currentWindows:)` drops entries whose
///    window ref is no longer in the app's current `AXWindows` list. This
///    is the cheap signal that catches "popup closed".
/// 3. **User click** → `HintMode.commit` calls `markDirty(window:)` on the
///    clicked target's source window. The next reuse on that window
///    short-circuits (returns nil), forcing a fresh walk.
///
/// Storage is window-local: each cached target stores `(element, offset,
/// size, role)` where `offset` is the target's screen origin minus the
/// window's screen origin at scan time. On reuse we read the window's
/// current `AXPosition` (1 IPC) and add it back to recover an up-to-date
/// screen rect — this naturally handles window-move without any
/// invalidation logic.
@MainActor
final class HintWindowCache {
    static let shared = HintWindowCache()
    private init() {}

    struct ReusedTarget {
        let element: AXUIElement
        let rect: CGRect
        let role: String
    }

    /// Generic target shape we accept on store / produce on reuse. The
    /// caller's richer struct (`ElementCandidate`) wraps these and adds
    /// `sourceWindow` for the dirty-marking round trip.
    struct StoredTarget {
        let element: AXUIElement
        let rect: CGRect      // screen-space (top-left origin) at scan time
        let role: String
    }

    private struct CachedTarget {
        let element: AXUIElement
        let offsetFromWindow: CGPoint   // target.origin - window.origin (scan time)
        let size: CGSize
        let role: String
    }

    private struct Entry {
        var targets: [CachedTarget]
        var dirty: Bool
    }

    /// `AXUIElement` is a CF ref; identity is via `CFEqual` / `CFHash`.
    /// `Dictionary` needs `Hashable`, so wrap it.
    private struct WindowKey: Hashable {
        let element: AXUIElement
        static func == (lhs: WindowKey, rhs: WindowKey) -> Bool {
            CFEqual(lhs.element, rhs.element)
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(CFHash(element))
        }
    }

    private var cachedAppPID: pid_t?
    private var entries: [WindowKey: Entry] = [:]

    // MARK: - Lifecycle

    func clear() {
        entries.removeAll()
        cachedAppPID = nil
    }

    /// Call at the start of every focused-app collect. If the focused app
    /// changed since last time, the previous app's window cache is no
    /// longer trustworthy (we've been blind during the gap) — drop it.
    func syncFocusedApp(pid: pid_t) {
        if cachedAppPID != pid {
            entries.removeAll()
            cachedAppPID = pid
        }
    }

    // MARK: - Diff & reuse

    /// Drop entries for windows that disappeared from `AXWindows`. Catches
    /// "popup closed" without any AX subscription work.
    func pruneTo(currentWindows: [AXUIElement]) {
        let currentKeys = Set(currentWindows.map { WindowKey(element: $0) })
        for k in entries.keys where !currentKeys.contains(k) {
            entries.removeValue(forKey: k)
        }
    }

    /// Returns the cached targets for `window` with screen rects recomputed
    /// from the window's *current* origin. nil if uncached, dirty, or the
    /// origin lookup fails (in which case the caller should walk fresh).
    func reuse(window: AXUIElement, ipcCount: inout Int) -> [ReusedTarget]? {
        let key = WindowKey(element: window)
        guard let entry = entries[key], !entry.dirty else { return nil }
        guard let origin = readScreenOrigin(window, ipcCount: &ipcCount) else { return nil }
        return entry.targets.map { t in
            ReusedTarget(
                element: t.element,
                rect: CGRect(
                    x: origin.x + t.offsetFromWindow.x,
                    y: origin.y + t.offsetFromWindow.y,
                    width: t.size.width,
                    height: t.size.height
                ),
                role: t.role
            )
        }
    }

    /// Store a freshly-walked window's targets. Stores window-local offsets
    /// (so window-move is handled by `reuse` recomputing screen coords) and
    /// clears any prior dirty flag for this window.
    func store(window: AXUIElement, targets: [StoredTarget], ipcCount: inout Int) {
        guard let origin = readScreenOrigin(window, ipcCount: &ipcCount) else { return }
        let cached = targets.map { t in
            CachedTarget(
                element: t.element,
                offsetFromWindow: CGPoint(
                    x: t.rect.minX - origin.x,
                    y: t.rect.minY - origin.y
                ),
                size: t.rect.size,
                role: t.role
            )
        }
        entries[WindowKey(element: window)] = Entry(targets: cached, dirty: false)
    }

    /// Mark a window's cache as needing a fresh walk on next collect. Called
    /// from `HintMode.commit` because a click can change the clicked
    /// window's contents (selection, list reload, disclosure toggle, ...).
    /// Other windows are presumed unchanged.
    func markDirty(window: AXUIElement) {
        entries[WindowKey(element: window)]?.dirty = true
    }

    // MARK: - Helpers

    private func readScreenOrigin(_ element: AXUIElement, ipcCount: inout Int) -> CGPoint? {
        ipcCount += 1
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &posRef) == .success,
              let p = posRef,
              CFGetTypeID(p) == AXValueGetTypeID()
        else { return nil }
        let v = p as! AXValue
        guard AXValueGetType(v) == .cgPoint else { return nil }
        var origin = CGPoint.zero
        guard AXValueGetValue(v, .cgPoint, &origin) else { return nil }
        return origin
    }
}
