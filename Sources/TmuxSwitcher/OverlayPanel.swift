import AppKit
import TmuxSwitcherCore

/// Direction of a scroll transition between two renders. The current session is
/// always the middle row, so it's never the highlight that moves — it's every
/// *name* shifting by one row height. `.none` means show the new content with no
/// animation (first render, a geometry-only reposition, a config reload, or a
/// row-count change, where a one-row slide would be meaningless).
enum ScrollDirection {
    case none
    case next        // Meh+j — names slide UP, new name enters from the BOTTOM
    case previous    // Meh+k — names slide DOWN, new name enters from the TOP
}

/// The HUD window itself: a borderless, non-activating panel that floats above
/// everything (including fullscreen Ghostty) without ever taking key focus or
/// intercepting clicks. Built once and reused; `present`/`dismiss`/`render` only
/// mutate the existing window and view tree so the show path (triggered on a
/// keypress) never pays for window/view allocation.
@MainActor
final class OverlayPanel: NSPanel {

    private let overlayView: OverlayView

    /// Tracks the fade-out animation in flight, if any, so a `present` that
    /// interrupts a `dismiss` can cancel it deliberately rather than racing it.
    private var isFadingOut = false

    private(set) var isPresented: Bool = false

    init(config: Config) {
        overlayView = OverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        contentView = overlayView
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // MARK: - Rendering

    /// Re-renders content in place. Safe to call while the panel is already
    /// visible (sessions can change under the user as they tap j/k) — the panel
    /// resizes/repositions around its current center rather than jumping.
    func render(window: RingWindow, config: Config, scroll: ScrollDirection) {
        let size = OverlayView.preferredSize(for: window, config: config)

        // Keep the panel's center fixed as its size changes so a resize while
        // visible doesn't visibly shift position, only grow/shrink in place.
        let previousFrame = frame
        let center = NSPoint(x: previousFrame.midX, y: previousFrame.midY)
        var newFrame = NSRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )

        if let screen = screenContaining(point: center) ?? NSScreen.main {
            newFrame = Self.clamp(newFrame, to: screen.visibleFrame)
        }

        setFrame(newFrame, display: false)
        overlayView.frame = NSRect(origin: .zero, size: newFrame.size)
        overlayView.configure(window: window, config: config, scroll: scroll)
    }

    /// Invokes `completion` once no pill animation is in flight — immediately
    /// if idle. Lets a Meh release be deferred so releasing the keys can't cut
    /// a slide short.
    ///
    /// Forwards to `OverlayView.afterAnimationSettles`, which guarantees the
    /// same contract: called synchronously if idle; otherwise queued and
    /// fired exactly once, on the main thread, when the in-flight slide
    /// settles — whether that's a natural completion or an early finalize
    /// (a subsequent `render`, or `dismiss`). Never dropped, never called
    /// twice.
    func afterScrollSettles(_ completion: @escaping () -> Void) {
        overlayView.afterAnimationSettles(completion)
    }

    // MARK: - Presentation

    /// Centers the panel within `rect` (already in Cocoa screen coordinates —
    /// no flipping needed here) and clamps it to stay fully inside the
    /// visible frame of whichever screen contains `rect`'s center.
    func present(centeredIn rect: NSRect, animate: Bool) {
        // Disarm any in-flight fade-out from a previous `dismiss` so its
        // completion handler becomes a no-op (see the `isFadingOut` check in
        // `dismiss`) instead of ordering the window out right after we show it.
        isFadingOut = false

        let center = NSPoint(x: rect.midX, y: rect.midY)
        let currentSize = frame.size
        var newFrame = NSRect(
            x: center.x - currentSize.width / 2,
            y: center.y - currentSize.height / 2,
            width: currentSize.width,
            height: currentSize.height
        )

        let screen = screenContaining(point: center) ?? NSScreen.main
        if let screen {
            newFrame = Self.clamp(newFrame, to: screen.visibleFrame)
        }

        setFrame(newFrame, display: false)
        overlayView.frame = NSRect(origin: .zero, size: newFrame.size)

        isPresented = true

        // Setting `alphaValue` directly (not through `.animator()`) overrides
        // whatever an in-flight fade-out animation was interpolating toward,
        // taking effect immediately. Combined with disarming `isFadingOut`
        // above, this guarantees the panel is never left stuck at a partial
        // alpha because a dismiss's fade got interrupted by a new present.
        alphaValue = 1
        orderFrontRegardless()
    }

    /// Hides the panel. Idempotent — safe to call when already hidden — and
    /// always calls `completion` exactly once on the main queue, whether or
    /// not animation actually ran.
    func dismiss(animate: Bool, completion: (() -> Void)? = nil) {
        // A slide in flight must not survive a dismiss: settle it immediately
        // so a later re-present never inherits a stale mid-slide offset.
        overlayView.finalizeInFlightAnimation()

        guard isPresented else {
            // Already hidden: still fulfil the completion contract.
            if let completion {
                DispatchQueue.main.async { completion() }
            }
            return
        }

        isPresented = false

        guard animate else {
            isFadingOut = false
            alphaValue = 0
            orderOut(nil)
            if let completion {
                DispatchQueue.main.async { completion() }
            }
            return
        }

        isFadingOut = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.08
            self.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // AppKit calls this handler back on the main thread; the compiler
            // just can't see that through the framework's (unannotated)
            // closure type, hence the explicit main-actor assumption here.
            MainActor.assumeIsolated {
                guard let self else {
                    completion?()
                    return
                }
                // If a new `present` interrupted this fade (setting isFadingOut
                // back to false and alphaValue back to 1), don't let the stale
                // completion of THIS fade order the window out from under it.
                guard self.isFadingOut else {
                    completion?()
                    return
                }
                self.isFadingOut = false
                self.orderOut(nil)
                completion?()
            }
        })
    }

    // MARK: - Screen geometry

    private func screenContaining(point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// Clamps `rect` so it lies fully within `bounds`, preferring to keep it
    /// centered where possible but sliding it back on-screen when the panel
    /// would otherwise overhang an edge (e.g. Ghostty window near a display's
    /// border, or a HUD wider than a small display's visible area).
    private static func clamp(_ rect: NSRect, to bounds: NSRect) -> NSRect {
        var result = rect

        if result.width > bounds.width {
            result.size.width = bounds.width
        }
        if result.height > bounds.height {
            result.size.height = bounds.height
        }

        if result.minX < bounds.minX {
            result.origin.x = bounds.minX
        } else if result.maxX > bounds.maxX {
            result.origin.x = bounds.maxX - result.width
        }

        if result.minY < bounds.minY {
            result.origin.y = bounds.minY
        } else if result.maxY > bounds.maxY {
            result.origin.y = bounds.maxY - result.height
        }

        return result
    }
}
