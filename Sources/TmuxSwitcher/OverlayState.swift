import AppKit
import TmuxSwitcherCore

/// The show/hide state machine.
///
/// Showing requires ALL of: Meh held, Ghostty frontmost, the dwell delay elapsed,
/// and the focused window's title matching a known tmux session. There are several
/// independent ways to hide, and they can race with each other and with in-flight
/// async work, so every transition is guarded and `hide()` is idempotent.
@MainActor
final class OverlayState {

    private let panel: OverlayPanel
    private let ax: AccessibilityBridge
    private var config: Config

    // Inputs
    private var mehHeld = false
    private var ghosttyFrontmost = false

    // Derived
    private var isVisible = false
    private var dwellElapsed = false
    private var sessions: [String] = []

    /// What the last render showed, used to derive the scroll direction. We only
    /// animate when the session list is byte-identical and the index moved by
    /// exactly one step — anything else (list changed, big jump, first show) is
    /// not a scroll and animating it would be a lie about what happened.
    private var previousIndex: Int?
    private var previousSessions: [String]?

    /// Earliest moment the HUD may be dismissed; see `hide()`.
    private var minimumVisibleUntil = Date.distantPast

    // Timers
    private var dwellWork: DispatchWorkItem?
    private var idleTimer: Timer?
    private var capTimer: Timer?

    /// Bumped on every Meh press and every hide. Async work captures the value it
    /// was issued under and discards itself if the generation has moved on — this
    /// is what stops a slow `tmux list-sessions` from a previous hold popping the
    /// HUD up after the user has already let go.
    private var generation: UInt64 = 0

    private let queryQueue = DispatchQueue(label: "com.rferegrino.tmux-switcher.tmux", qos: .userInitiated)

    init(panel: OverlayPanel, ax: AccessibilityBridge, config: Config) {
        self.panel = panel
        self.ax = ax
        self.config = config
    }

    // MARK: - Inputs

    func mehPressed() {
        guard !mehHeld else { return }   // belt-and-braces; the watcher also dedupes
        mehHeld = true
        guard ghosttyFrontmost else { return }

        generation &+= 1
        let gen = generation
        dwellElapsed = false

        refreshSessions(generation: gen)
        scheduleDwell(generation: gen)
    }

    func mehReleased() {
        guard mehHeld else { return }
        mehHeld = false
        hide()
    }

    func frontmostChanged(isTarget: Bool) {
        ghosttyFrontmost = isTarget
        if !isTarget {
            hide()
        } else if mehHeld {
            // Meh was already down when Ghostty came forward — treat as a fresh press.
            mehHeld = false
            mehPressed()
        }
    }

    /// The focused window's title changed, which (given `set-titles-string "#S"`)
    /// means the tmux session changed. Authoritative, and the reason we don't poll.
    func titleChanged(_ title: String?) {
        guard mehHeld, ghosttyFrontmost else { return }
        // An actual switch happened, so there's nothing left to disambiguate:
        // show immediately rather than making a quick Meh+j wait out the dwell.
        dwellElapsed = true
        tryShow()
    }

    func geometryChanged(_ frame: NSRect) {
        guard isVisible else { return }
        panel.present(centeredIn: frame, animate: false)
    }

    /// A tmux hook told us sessions were created/closed/renamed. Purely a cache
    /// refresh — the app is still correct without it, since every Meh press
    /// re-queries anyway.
    func sessionsInvalidated() {
        let gen = generation
        queryQueue.async { [config] in
            let result = TmuxClient.listSessions(tmuxBin: config.tmuxBin, timeout: 0.5)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.sessions = result
                if self.isVisible { self.tryShow() }
            }
        }
    }

    func configChanged(_ newConfig: Config) {
        config = newConfig
        if isVisible { tryShow() }
    }

    // MARK: - Scheduling

    private func scheduleDwell(generation gen: UInt64) {
        dwellWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation else { return }
            self.dwellElapsed = true
            self.tryShow()
        }
        dwellWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(config.dwellMs),
            execute: work
        )
    }

    private func refreshSessions(generation gen: UInt64) {
        queryQueue.async { [config] in
            let result = TmuxClient.listSessions(tmuxBin: config.tmuxBin, timeout: 0.5)
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.generation else { return }
                self.sessions = result
                // Note where we are before anything is shown. If the user then
                // does a quick switch, the HUD can animate FROM here instead of
                // popping up already-switched with no motion.
                if !self.isVisible { self.recordBaseline() }
                // The query can land either side of the dwell timer; tryShow is
                // idempotent and checks every precondition, so both paths call it.
                self.tryShow()
            }
        }
    }

    // MARK: - Show / hide

    private func tryShow() {
        guard mehHeld, ghosttyFrontmost, dwellElapsed else { return }
        guard !sessions.isEmpty else { return }
        guard let info = ax.currentWindowInfo(), let title = info.title else { return }

        // The window title is the session name. If it doesn't match a live session
        // this Ghostty window isn't running tmux — show nothing, by design.
        guard let index = sessions.firstIndex(of: title) else {
            Log.state.debug("title \(title, privacy: .public) matches no session; not showing")
            return
        }
        guard let window = SessionRing.window(
            sessions: sessions,
            currentIndex: index,
            maxRadius: config.maxRadius
        ) else { return }

        var step = 0
        if let previous = previousIndex, previousSessions == sessions {
            step = SessionRing.ringStep(from: previous, to: index, count: sessions.count)
        }
        let scroll: ScrollDirection
        switch (config.animate, step) {
        case (true, 1):  scroll = .next        // Meh+j — names slide up
        case (true, -1): scroll = .previous    // Meh+k — names slide down
        default:         scroll = .none
        }

        let firstShow = !isVisible
        if firstShow,
           scroll != .none,
           let previous = previousIndex,
           let seed = SessionRing.window(
               sessions: sessions,
               currentIndex: previous,
               maxRadius: config.maxRadius
           ) {
            // Put the panel on screen still showing where we *were*, then animate
            // to where we are. Otherwise a quick Meh+j appears already-switched
            // and the pills never visibly move.
            panel.render(window: seed, config: config, scroll: .none)
            panel.present(centeredIn: info.frame, animate: config.animate)
            panel.render(window: window, config: config, scroll: scroll)
        } else {
            panel.render(window: window, config: config, scroll: scroll)
            panel.present(centeredIn: info.frame, animate: config.animate && firstShow)
        }

        previousIndex = index
        previousSessions = sessions
        // Keep it up at least long enough for the pills to finish travelling,
        // even if Meh is released immediately.
        minimumVisibleUntil = Date().addingTimeInterval(TimeInterval(config.scrollAnimationMs) / 1000.0)

        if firstShow {
            isVisible = true
            startCapTimer()
        }
        resetIdleTimer()
    }

    /// Idempotent. Cancels everything and invalidates in-flight async work.
    private func hide() {
        dwellWork?.cancel()
        dwellWork = nil
        dwellElapsed = false
        idleTimer?.invalidate()
        idleTimer = nil
        capTimer?.invalidate()
        capTimer = nil
        generation &+= 1

        previousIndex = nil
        previousSessions = nil

        guard isVisible else { return }
        isVisible = false

        // Releasing Meh must not cut a slide short: wait out whatever remains of
        // the minimum display time, then wait for the pills to settle, and only
        // then dismiss. Animation completion takes precedence over the release.
        let remaining = max(0, minimumVisibleUntil.timeIntervalSinceNow)
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.dismissWhenSettled()
            }
        } else {
            dismissWhenSettled()
        }
    }

    /// Second half of `hide()`: dismiss once the pills have stopped moving.
    /// Bails if the HUD was re-shown while we were waiting, so a fast
    /// release-then-press reads as continuous rather than flickering.
    private func dismissWhenSettled() {
        guard !isVisible else { return }
        panel.afterScrollSettles { [weak self] in
            guard let self, !self.isVisible else { return }
            self.panel.dismiss(animate: self.config.animate, completion: nil)
        }
    }

    /// Records the current session index without showing anything, so a later
    /// switch has a starting point to animate from.
    private func recordBaseline() {
        guard let info = ax.currentWindowInfo(),
              let title = info.title,
              let index = sessions.firstIndex(of: title) else { return }
        previousIndex = index
        previousSessions = sessions
    }

    // MARK: - Safety nets

    /// Fires `idleHideMs` after the last render. Its purpose is recovering from a
    /// *missed release* — so if the hardware says Meh is genuinely still held, it
    /// re-arms instead of hiding. Otherwise deliberately holding Meh to read the
    /// list would yank the HUD away mid-glance.
    private func resetIdleTimer() {
        idleTimer?.invalidate()
        let interval = TimeInterval(config.idleHideMs) / 1000.0
        idleTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if ModifierWatcher.isMeh(NSEvent.modifierFlags) {
                    self.resetIdleTimer()   // still held for real; keep showing
                } else {
                    Log.state.debug("idle fallback fired — release was missed")
                    self.mehHeld = false
                    self.hide()
                }
            }
        }
    }

    /// Absolute cap. Unlike the idle timer this one is unconditional: whatever the
    /// state of the world, the HUD is gone after `maxDisplayMs`.
    ///
    /// Disabled by default (`MAX_DISPLAY_MS=0`): the 100ms modifier poll already
    /// reads hardware state directly and hides within a frame or two of a real
    /// release, so the cap was only insurance against that poll itself lying —
    /// and it came at the cost of yanking the HUD away from someone deliberately
    /// holding Meh to read the list. Set it to a positive value to re-arm it.
    private func startCapTimer() {
        capTimer?.invalidate()
        capTimer = nil
        guard config.maxDisplayMs > 0 else { return }
        let interval = TimeInterval(config.maxDisplayMs) / 1000.0
        capTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Log.state.debug("max display cap reached")
                self.mehHeld = false
                self.hide()
            }
        }
    }
}
