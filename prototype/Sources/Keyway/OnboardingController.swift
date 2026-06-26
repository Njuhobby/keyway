import Cocoa
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// First-run permission onboarding.
///
/// Keyway needs TWO permissions and neither is optional: **Accessibility**
/// (the event tap + synthesizing clicks/keys) and **Screen Recording** (the
/// OmniParser vision fallback + the content-settle watch). Relying on macOS's
/// one-shot TCC prompts is hostile: the user doesn't know two are needed, the
/// Screen-Recording prompt only ever fires once (miss it and you're stuck on a
/// silent red badge), and granting either needs a relaunch because macOS
/// caches the status per process.
///
/// So instead of blind prompts we show one window that:
///   - lists both permissions with a live ✓/✗ status,
///   - has a button per row that opens the exact Settings pane,
///   - polls status so Accessibility flips to ✓ the moment it's granted,
///   - and offers a single **Restart Keyway** button to apply everything
///     (Screen Recording can't be re-read in the running process, so a clean
///     relaunch is the reliable way to pick it up).
@MainActor
final class OnboardingController {
    static let shared = OnboardingController()
    private init() {}

    private var window: NSWindow?
    private var timer: Timer?
    private var axIcon: NSImageView!
    private var srIcon: NSImageView!
    private var hint: NSTextField!

    /// Invoked when BOTH permissions read as granted while the window is open
    /// (the Accessibility-live path). Screen Recording normally needs the
    /// Restart button, so this is the rare "everything already true" case.
    var onReady: (() -> Void)?

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }

    func present() {
        if window == nil { buildWindow() }
        // LSUIElement apps are `.accessory` (no Dock icon, windows can't take
        // focus cleanly). Become a regular app for the duration of setup so
        // the window reliably comes to the front, then drop back on dismiss.
        NSApp.setActivationPolicy(.regular)
        refresh()
        startPolling()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func dismiss() {
        stopPolling()
        window?.orderOut(nil)
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Window construction

    private func buildWindow() {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 340))

        let title = label("Keyway needs two permissions", size: 20, weight: .bold)
        let subtitle = label("Both are required. Grant each below, then restart Keyway.",
                             size: 13, weight: .regular, color: .secondaryLabelColor)

        axIcon = statusIcon()
        srIcon = statusIcon()

        let axRow = permissionRow(
            icon: axIcon,
            name: "Accessibility",
            desc: "Read on-screen controls, move the cursor, and click for you.",
            action: #selector(openAccessibility))
        let srRow = permissionRow(
            icon: srIcon,
            name: "Screen Recording",
            desc: "See Electron / web content and detect when the screen settles.",
            action: #selector(openScreenRecording))

        hint = label("", size: 12, weight: .regular, color: .tertiaryLabelColor)
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 2

        let restart = NSButton(title: "Restart Keyway", target: self, action: #selector(restart))
        restart.bezelStyle = .rounded
        restart.keyEquivalent = "\r"   // default button (Return)
        let quit = NSButton(title: "Quit", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        let footer = NSStackView(views: [quit, NSView(), restart])
        footer.orientation = .horizontal
        footer.distribution = .fill

        let stack = NSStackView(views: [title, subtitle, axRow, srRow, hint, NSView(), footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 28, bottom: 24, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56),
        ])

        let w = NSWindow(
            contentRect: content.frame,
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        w.title = "Keyway Setup"
        w.contentView = content
        w.isReleasedWhenClosed = false
        window = w
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight,
                       color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    private func statusIcon() -> NSImageView {
        let iv = NSImageView()
        iv.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iv.widthAnchor.constraint(equalToConstant: 22),
            iv.heightAnchor.constraint(equalToConstant: 22),
        ])
        return iv
    }

    private func permissionRow(icon: NSImageView, name: String, desc: String,
                               action: Selector) -> NSView {
        let nameLabel = label(name, size: 14, weight: .semibold)
        let descLabel = label(desc, size: 12, weight: .regular, color: .secondaryLabelColor)
        let textStack = NSStackView(views: [nameLabel, descLabel])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let button = NSButton(title: "Open Settings", target: self, action: action)
        button.bezelStyle = .rounded
        button.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [icon, textStack, button])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: 464).isActive = true
        return row
    }

    // MARK: - Status polling

    private func startPolling() {
        stopPolling()
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let ax = Self.accessibilityGranted
        let sr = Self.screenRecordingGranted
        setIcon(axIcon, granted: ax)
        setIcon(srIcon, granted: sr)

        if ax && sr {
            // Both live-true (only happens if SR was already granted before
            // this launch). Hand back to the app and close.
            hint.stringValue = "All set. Starting Keyway…"
            onReady?()
            dismiss()
            return
        }
        if sr && !ax {
            hint.stringValue = "Enable Accessibility above to finish."
        } else if ax && !sr {
            hint.stringValue = "Screen Recording only takes effect after a restart — click Restart Keyway."
        } else {
            hint.stringValue = "Enable both above, then click Restart Keyway."
        }
    }

    private func setIcon(_ iv: NSImageView, granted: Bool) {
        let symbol = granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        iv.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        iv.contentTintColor = granted ? .systemGreen : .systemOrange
    }

    // MARK: - Actions

    @objc private func openAccessibility() {
        // Fire the TCC prompt (adds Keyway to the list pre-toggled) AND open
        // the pane, so the user lands exactly where the toggle is.
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        openPane("Privacy_Accessibility")
    }

    @objc private func openScreenRecording() {
        // CGRequestScreenCaptureAccess() alone often fails to register an
        // ad-hoc app in the Screen Recording list (the user is left hunting
        // for the "+" button). Actually touching ScreenCaptureKit forces TCC
        // to register Keyway and fire the prompt, so the entry shows up
        // pre-listed and the user just flips the toggle.
        CGRequestScreenCaptureAccess()
        SCShareableContent.getWithCompletionHandler { _, _ in }
        openPane("Privacy_ScreenCapture")
    }

    private func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func restart() {
        let path = Bundle.main.bundlePath
        // `swift run` dev layout has no .app to relaunch; just tell the user.
        guard path.hasSuffix(".app") else {
            hint.stringValue = "Quit and rerun (./run.sh) to apply the new permissions."
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; open -n \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
