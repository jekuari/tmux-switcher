import AppKit

/// Watches for the "Meh" modifier chord (Control + Option + Shift, without Command)
/// being pressed and released, and reports transitions exactly once each.
///
/// Design notes:
///
/// - We use `NSEvent.addGlobalMonitorForEvents` rather than a `CGEventTap`. A CGEventTap
///   would require the separate "Input Monitoring" TCC permission on top of Accessibility,
///   which this app already needs for its AX work. Two permissions that can each silently
///   fail (denied, or revoked later by the user/system) is strictly worse than one. The
///   global monitor only needs Accessibility to observe modifier-flag changes.
///
/// - A local monitor is also installed for completeness/symmetry, even though this app is
///   `LSUIElement` and effectively never becomes key/frontmost, so it should rarely fire.
///
/// - The watchdog poll timer exists because flagsChanged events can simply not arrive: Secure
///   Event Input (active during password entry, and in some 1Password states) suppresses
///   keyboard/modifier events from reaching event monitors, and Space switches have also been
///   observed to swallow them. If we only relied on events, a swallowed key-up would leave the
///   HUD stuck on screen forever. So while held, we poll the *hardware* modifier state via the
///   static `NSEvent.modifierFlags` (no event or permission needed to read it) and synthesize
///   the release ourselves if the chord is no longer satisfied.
@MainActor
final class ModifierWatcher {
    var onMehDown: (() -> Void)?
    var onMehUp: (() -> Void)?

    private(set) var isMehHeld: Bool = false

    private let pollIntervalMs: Int
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var watchdogTimer: Timer?

    init(pollIntervalMs: Int) {
        self.pollIntervalMs = pollIntervalMs
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return }
            // Global monitors invoke their handler on whatever thread posted the event;
            // in practice that's the main run loop, but hop explicitly to be safe since
            // this class is @MainActor.
            Task { @MainActor in
                self.handle(flags: event.modifierFlags)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(flags: event.modifierFlags)
            return event
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
        stopWatchdog()
        // Don't force an onMehUp here: stop() is a teardown call, not a modifier
        // transition. Callers that care about final state can check isMehHeld.
        isMehHeld = false
    }

    static func isMeh(_ flags: NSEvent.ModifierFlags) -> Bool {
        let m = flags.intersection(.deviceIndependentFlagsMask)
        return m.isSuperset(of: [.control, .option, .shift]) && !m.contains(.command)
    }

    // MARK: - Transition handling

    private func handle(flags: NSEvent.ModifierFlags) {
        setHeld(Self.isMeh(flags))
    }

    /// Single choke point for state changes, used by both the event monitors and the
    /// watchdog poll, so a down/up pair can never be emitted twice or out of order
    /// regardless of which path detected the transition.
    private func setHeld(_ held: Bool) {
        guard held != isMehHeld else { return }
        isMehHeld = held
        if held {
            startWatchdog()
            onMehDown?()
        } else {
            stopWatchdog()
            onMehUp?()
        }
    }

    // MARK: - Watchdog

    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        let interval = TimeInterval(max(pollIntervalMs, 1)) / 1000.0
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.pollTick()
            }
        }
        // Use .common so the timer keeps firing while the run loop is in tracking/modal
        // modes (e.g. menu tracking), which is exactly when a stuck HUD would be most
        // annoying and least likely to self-correct via a normal event.
        RunLoop.main.add(timer, forMode: .common)
        watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func pollTick() {
        // Read hardware modifier state directly; this needs no event and no permission.
        setHeld(Self.isMeh(NSEvent.modifierFlags))
    }
}
