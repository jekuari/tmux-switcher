import AppKit
import ApplicationServices

/// Bridges to the Accessibility API to observe Ghostty's focused window.
///
/// Two facts make this component the heart of the app:
///
/// 1. The user's tmux.conf sets `set-titles on` with `set-titles-string "#S"`, so
///    the Ghostty window title *is* the current tmux session name. Reading AXTitle
///    tells us the session without asking tmux at all.
/// 2. Because of (1), `kAXTitleChangedNotification` fires exactly when the session
///    changes. That gives us an authoritative push the instant the user taps j/k —
///    no polling, and no need to predict the move or watch keystrokes. It is what
///    keeps this tool a genuine read-only observer.
@MainActor
final class AccessibilityBridge {

    struct WindowInfo {
        /// The tmux session name, assuming the window is running tmux.
        let title: String?
        /// Window frame in **Cocoa** screen coordinates (bottom-left origin).
        let frame: NSRect
    }

    /// Fired when the focused window's title changes — i.e. the session changed.
    var onTitleChanged: ((String?) -> Void)?
    /// Fired when the focused window moves or resizes while we may be showing.
    var onWindowGeometryChanged: ((NSRect) -> Void)?
    /// Fired when the app's focused window changes (e.g. another Ghostty window).
    var onFocusedWindowChanged: (() -> Void)?

    private var appElement: AXUIElement?
    private var windowElement: AXUIElement?
    private var observer: AXObserver?
    private var attachedPID: pid_t?

    // MARK: - Trust

    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// Prompts for Accessibility access. The system shows this once per app
    /// identity; if the user has already answered it is a silent no-op.
    static func promptForTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Attach / detach

    func attach(to app: NSRunningApplication) {
        let pid = app.processIdentifier
        // Re-attaching to the same process would duplicate observers.
        if attachedPID == pid, observer != nil { return }
        detach()

        let element = AXUIElementCreateApplication(pid)
        appElement = element
        attachedPID = pid

        var obs: AXObserver?
        guard AXObserverCreate(pid, axCallback, &obs) == .success, let obs else {
            Log.ax.error("AXObserverCreate failed for pid \(pid, privacy: .public)")
            return
        }
        observer = obs

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Focused-window changes are observed on the *application* element; the
        // per-window notifications get (re)bound as the focused window changes.
        AXObserverAddNotification(obs, element, kAXFocusedWindowChangedNotification as CFString, refcon)

        // .commonModes so notifications keep arriving during tracking run-loop
        // modes (menus, drags) rather than being starved until they finish.
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)

        rebindFocusedWindow()
    }

    func detach() {
        if let obs = observer {
            if let win = windowElement {
                removeWindowNotifications(obs, win)
            }
            if let app = appElement {
                AXObserverRemoveNotification(obs, app, kAXFocusedWindowChangedNotification as CFString)
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        }
        observer = nil
        appElement = nil
        windowElement = nil
        attachedPID = nil
    }

    // MARK: - Reading

    /// Current focused-window title and frame, read fresh. Returns nil when the
    /// app has no focused window (e.g. all windows minimised).
    func currentWindowInfo() -> WindowInfo? {
        guard let win = windowElement ?? copyFocusedWindow() else { return nil }
        guard let frame = frame(of: win) else { return nil }
        return WindowInfo(title: title(of: win), frame: frame)
    }

    private func copyFocusedWindow() -> AXUIElement? {
        guard let app = appElement else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func title(of window: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success,
              let string = value as? String
        else { return nil }
        return string.isEmpty ? nil : string
    }

    /// Reads AXPosition/AXSize and converts to Cocoa screen coordinates.
    ///
    /// The Accessibility API reports a top-left origin with y growing *downward*
    /// from the top-left of the primary display. Cocoa windows use a bottom-left
    /// origin with y growing *upward* from the bottom-left of the primary display.
    /// Getting this flip wrong puts the HUD off-screen or on the wrong monitor,
    /// and it is invisible on a single-display setup where the numbers happen to
    /// look plausible — so it must be verified on the external display too.
    private func frame(of window: AXUIElement) -> NSRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue,
              CFGetTypeID(posValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue as! AXValue, .cgPoint, &origin),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }

        // The Cocoa global coordinate origin is the bottom-left of the primary
        // screen, which is NSScreen.screens.first (the one owning the menu bar).
        guard let primary = NSScreen.screens.first else { return nil }
        let cocoaY = primary.frame.maxY - (origin.y + size.height)
        return NSRect(x: origin.x, y: cocoaY, width: size.width, height: size.height)
    }

    // MARK: - Notification plumbing

    private func rebindFocusedWindow() {
        guard let obs = observer else { return }
        if let old = windowElement {
            removeWindowNotifications(obs, old)
        }
        guard let win = copyFocusedWindow() else {
            windowElement = nil
            return
        }
        windowElement = win

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in Self.windowNotifications {
            AXObserverAddNotification(obs, win, name as CFString, refcon)
        }
    }

    private func removeWindowNotifications(_ obs: AXObserver, _ window: AXUIElement) {
        for name in Self.windowNotifications {
            AXObserverRemoveNotification(obs, window, name as CFString)
        }
    }

    private static let windowNotifications = [
        kAXTitleChangedNotification,
        kAXMovedNotification,
        kAXResizedNotification,
        kAXUIElementDestroyedNotification,
    ]

    fileprivate func handle(notification: String) {
        switch notification {
        case kAXFocusedWindowChangedNotification:
            rebindFocusedWindow()
            onFocusedWindowChanged?()
            // A new focused window means a (possibly) different session.
            onTitleChanged?(windowElement.flatMap { title(of: $0) })

        case kAXTitleChangedNotification:
            onTitleChanged?(windowElement.flatMap { title(of: $0) })

        case kAXMovedNotification, kAXResizedNotification:
            if let win = windowElement, let frame = frame(of: win) {
                onWindowGeometryChanged?(frame)
            }

        case kAXUIElementDestroyedNotification:
            windowElement = nil
            onTitleChanged?(nil)

        default:
            break
        }
    }
}

/// AXObserver callbacks are C function pointers and cannot capture context, so
/// `self` is smuggled through `refcon` as an unretained pointer. Unretained is
/// safe because the observer is torn down in `detach()` before the bridge dies.
private let axCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let bridge = Unmanaged<AccessibilityBridge>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    // Callbacks already arrive on the main run loop, but hopping explicitly keeps
    // the main-actor contract honest and costs a single run-loop turn.
    DispatchQueue.main.async {
        bridge.handle(notification: name)
    }
}
