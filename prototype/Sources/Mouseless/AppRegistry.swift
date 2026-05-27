import Cocoa

/// Per-app routing decisions for the OmniParser fall-through.
///
/// **Design rationale**: framework-based routing (Electron / Catalyst /
/// WKWebView heuristics) turned out to be the wrong abstraction —
/// WeChat is genuine native AppKit yet has terrible AX coverage on
/// chat content because messages are custom-drawn NSViews. Many other
/// Chinese consumer apps (QQ, DingTalk, etc.) follow the same pattern.
/// "Native ≠ AX-good" — so framework detection can't gate routing.
///
/// New model: **OmniParser is the default** for the focused-app
/// subtree. AX walk for the focused-app subtree only runs for apps
/// explicitly known to have excellent AX coverage. Dock / menu bar /
/// menu extras AX walks always run regardless — OmniParser only sees
/// inside the focused window.
///
/// The whitelist is small and grows slowly (we add an app only after
/// using it under Mouseless and confirming AX coverage is genuinely
/// good). Wrong direction (whitelist missing an AX-good app) just
/// means we pay an extra 80-90ms for OP — acceptable. Wrong direction
/// (whitelist including an AX-bad app) means the user sees missing
/// hints on that app — directly observable, easy to fix.
///
/// See `specs/omniparser-fallback-design.md` §4.4.
@MainActor
enum AppRegistry {
    /// Apps whose focused-app subtree we trust to AX walk instead of
    /// running OmniParser. Conservative initial list: Apple-built
    /// AppKit apps with excellent AX coverage. Third-party apps
    /// must earn their way onto this list via direct verification.
    static let axFocusedWhitelist: Set<String> = [
        // Apple native AppKit
        "com.apple.finder",
        "com.apple.mail",
        "com.apple.Safari",          // chrome AppKit; web content's a separate matter
        "com.apple.TextEdit",
        "com.apple.Preview",
        "com.apple.calculator",
        "com.apple.Terminal",
        "com.apple.Console",
        "com.apple.ActivityMonitor",

        // Apple productivity (iWork etc.)
        "com.apple.Pages",
        "com.apple.Keynote",
        "com.apple.Numbers",
        "com.apple.iCal",            // Calendar
        "com.apple.iWork.Numbers",   // older bundle id fallback

        // Apple developer tools
        "com.apple.dt.Xcode",

        // Notes app (Catalyst variants — may need to drop if hints regress)
        "com.apple.Notes",

        // Third-party (verified AX-good)
        "net.kovidgoyal.kitty",      // kitty terminal
    ]

    /// Routing decision for the focused-app subtree.
    /// Returns `true` if AX walk should be used, `false` to route to
    /// OmniParser. Dock / menubar / extras AX walk runs regardless of
    /// this decision — they have no OP equivalent.
    static func shouldUseAXForFocused(bundleID: String) -> Bool {
        return axFocusedWhitelist.contains(bundleID)
    }
}
