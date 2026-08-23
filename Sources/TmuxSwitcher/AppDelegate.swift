import AppKit
import TmuxSwitcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let demoSessionCount: Int?

    private var config: Config
    private var panel: OverlayPanel!
    private var ax: AccessibilityBridge!
    private var state: OverlayState!
    private var modifiers: ModifierWatcher!
    private var focus: FocusWatcher!
    private var notifyServer: NotifyServer?
    private var configWatcher: ConfigWatcher?
    private var trustTimer: Timer?

    init(demoSessionCount: Int?) {
        self.demoSessionCount = demoSessionCount
        // A broken config at startup falls back to defaults rather than
        // refusing to launch: a background agent that silently fails to appear
        // is far harder to diagnose than one running on defaults. The reason
        // is logged from `beginNormalOperation`, once logging is meaningful.
        self.config = (try? Config.load()) ?? .defaults
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = OverlayPanel(config: config)
        ax = AccessibilityBridge()

        if let count = demoSessionCount {
            runDemo(sessionCount: count)
            return
        }

        startWhenTrusted()
    }

    /// Accessibility is the app's single required permission — it covers both the
    /// AX window reads and the global modifier monitoring.
    ///
    /// Rather than showing a dead-end alert and quitting, we prompt once and then
    /// wait: a TCC grant takes effect for the already-running process, so there is
    /// no need to make the user relaunch. As a background agent, idling until the
    /// permission arrives costs nothing.
    private func startWhenTrusted() {
        if AccessibilityBridge.isTrusted() {
            beginNormalOperation()
            return
        }

        Log.app.error("Accessibility not granted — prompting and waiting")
        AccessibilityBridge.promptForTrust()

        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard AccessibilityBridge.isTrusted() else { return }
                timer.invalidate()
                self?.trustTimer = nil
                Log.app.info("Accessibility granted")
                self?.beginNormalOperation()
            }
        }
    }

    private func beginNormalOperation() {
        state = OverlayState(panel: panel, ax: ax, config: config)
        wireAccessibility()
        wireFocus()
        wireModifiers()
        startNotifyServer()
        startConfigWatcher()

        reportConfigProblems()

        Log.app.info("tmux-switcher started; watching \(self.config.ghosttyBundleID, privacy: .public)")
    }

    /// Surfaces the two ways a user can believe they have configured this app
    /// while it is actually running on defaults.
    private func reportConfigProblems() {
        do {
            _ = try Config.load()
        } catch {
            Log.app.error(
                "config at \(Config.configURL.path, privacy: .public) is invalid, running on defaults: \(String(describing: error), privacy: .public)"
            )
        }

        // config.env was the format before config.json. Nothing reads it now,
        // so a leftover one is settings the user thinks are in effect and
        // aren't -- worth a log line rather than silent indifference.
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: Config.configURL.path),
           fileManager.fileExists(atPath: Config.legacyConfigURL.path) {
            Log.app.error(
                "found a legacy \(Config.legacyConfigURL.lastPathComponent, privacy: .public) but no \(Config.configURL.lastPathComponent, privacy: .public); it is ignored -- port your settings to JSON (see the README)"
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        modifiers?.stop()
        focus?.stop()
        notifyServer?.stop()
        configWatcher?.stop()
        trustTimer?.invalidate()
        ax?.detach()
    }

    // MARK: - Wiring

    private func wireAccessibility() {
        ax.onTitleChanged = { [weak self] title in
            self?.state.titleChanged(title)
        }
        ax.onWindowGeometryChanged = { [weak self] frame in
            self?.state.geometryChanged(frame)
        }
    }

    private func wireFocus() {
        focus = FocusWatcher(targetBundleID: config.ghosttyBundleID)
        focus.onFrontmostChanged = { [weak self] isTarget in
            guard let self else { return }
            if isTarget, let app = self.focus.targetApp {
                self.ax.attach(to: app)
            } else if !isTarget {
                // Keep the AX observers attached: re-attaching on every app switch
                // is wasteful, and the bridge is cheap to leave bound.
                Log.state.debug("target app no longer frontmost")
            }
            self.state.frontmostChanged(isTarget: isTarget)
        }
        focus.start()

        // Seed: if Ghostty is already frontmost at launch, attach immediately
        // rather than waiting for the user to switch away and back.
        if focus.isTargetFrontmost, let app = focus.targetApp {
            ax.attach(to: app)
            state.frontmostChanged(isTarget: true)
        }
    }

    private func wireModifiers() {
        modifiers = ModifierWatcher(pollIntervalMs: config.modifierPollMs)
        modifiers.onMehDown = { [weak self] in self?.state.mehPressed() }
        modifiers.onMehUp = { [weak self] in self?.state.mehReleased() }
        modifiers.start()
    }

    private func startNotifyServer() {
        let server = NotifyServer(socketPath: Config.socketPath)
        server.onCommand = { [weak self] command in
            switch command {
            case "sessions-changed":
                self?.state.sessionsInvalidated()
            default:
                Log.ipc.debug("ignoring unknown command \(command, privacy: .public)")
            }
        }
        do {
            try server.start()
            notifyServer = server
            Log.ipc.info("listening on \(Config.socketPath, privacy: .public)")
        } catch {
            // Non-fatal: the socket only keeps the session cache warm. Every Meh
            // press re-queries tmux anyway, so the app stays correct without it.
            Log.ipc.error("notify socket unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func startConfigWatcher() {
        configWatcher = ConfigWatcher(url: Config.configURL) { [weak self] in
            guard let self else { return }
            let updated: Config
            do {
                updated = try Config.load()
            } catch {
                // Hold on to the config already in effect. A JSON document is
                // parsed whole, so an editor that saves mid-keystroke produces
                // a file that is briefly invalid -- snapping every setting back
                // to its default on the way past would be worse than waiting
                // for the next save.
                Log.app.error(
                    "config reload failed, keeping the previous one: \(String(describing: error), privacy: .public)"
                )
                return
            }
            guard updated != self.config else { return }
            self.config = updated
            self.state.configChanged(updated)
            Log.app.info("config reloaded")
        }
        configWatcher?.start()
    }

    // MARK: - Demo

    /// Pins the HUD open with synthetic data so the visuals can be iterated on
    /// without holding Meh. Renders the real panel over the real window, which a
    /// static preview canvas could not do.
    private func runDemo(sessionCount: Int) {
        let names = ["Dotfiles", "omniwm", "tmux", "vigia", "notes", "scratch", "api", "web", "infra"]
        let sessions = Array(names.prefix(max(0, sessionCount)))
        let current = sessions.isEmpty ? 0 : min(1, sessions.count - 1)

        guard let window = SessionRing.window(
            sessions: sessions,
            currentIndex: current,
            maxRadius: config.maxRadius
        ) else {
            print("demo: nothing to show for \(sessionCount) session(s)")
            NSApp.terminate(nil)
            return
        }

        let target = NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == config.ghosttyBundleID }

        var rect = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        if let target {
            ax.attach(to: target)
            if let info = ax.currentWindowInfo() { rect = info.frame }
        }

        panel.render(window: window, config: config, scroll: .none)
        panel.present(centeredIn: rect, animate: false)

        print("demo: \(sessions.count) session(s), current=\(sessions.isEmpty ? "-" : sessions[current])")
        print("rows top-to-bottom: \(window.visible.map(\.name).joined(separator: " | "))")
        print("Ctrl-C to exit.")
    }
}

/// Watches the config file so timing knobs can be tuned without a rebuild.
///
/// Editors typically save by writing a temp file and renaming over the target,
/// which invalidates the original file descriptor. So we re-arm on delete/rename
/// as well as write — a naive single-fd watch silently stops working after the
/// first save.
@MainActor
final class ConfigWatcher {
    private let url: URL
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
    }

    func start() {
        arm()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    private func arm() {
        source?.cancel()
        source = nil

        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // File may not exist yet; retry rather than giving up permanently.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.arm() }
            return
        }

        let fd = descriptor
        let newSource = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = newSource.data
            self.onChange()
            if flags.contains(.delete) || flags.contains(.rename) {
                // The fd now points at the old inode — rebind to the new file.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.arm() }
            }
        }
        newSource.setCancelHandler { close(fd) }
        newSource.resume()
        source = newSource
    }
}
