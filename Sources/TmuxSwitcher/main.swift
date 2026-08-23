import AppKit
import TmuxSwitcherCore

// Line-buffer stdout: the --demo and --help paths are read from a terminal or a
// pipe, and block buffering would swallow their output if the process is killed.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

// --- One-shot notify mode -----------------------------------------------------
// This path runs from a tmux hook on every session create/close/rename. It must be
// fast, silent, and ALWAYS exit 0: a non-zero exit or stray output from a hook is
// noise in the user's tmux, and the app not running is a perfectly normal state.
if let index = arguments.firstIndex(of: "--notify") {
    let command = arguments.indices.contains(index + 1) ? arguments[index + 1] : "sessions-changed"
    _ = NotifyClient.send(command, socketPath: Config.socketPath)
    exit(0)
}

// Diagnostic: exercise the real tmux path without needing Accessibility. Also
// the first thing to reach for when the HUD shows nothing.
if arguments.contains("--probe-tmux") {
    let config = Config.load()
    let sessions = TmuxClient.listSessions(tmuxBin: config.tmuxBin, timeout: 0.5)
    print("tmux binary: \(config.tmuxBin)")
    print("sessions (\(sessions.count)), in switch-client cycle order:")
    for (index, name) in sessions.enumerated() {
        print("  [\(index)] \(name)")
    }
    if sessions.isEmpty {
        print("  (none — is a tmux server running? check TMUX_BIN in config.env)")
    }
    exit(0)
}

if arguments.contains("--version") {
    print("tmux-switcher 0.1.0")
    exit(0)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    tmux-switcher — a read-only HUD showing where Meh+j / Meh+k will take you.

    USAGE
      TmuxSwitcher                     Run the background agent (normal mode)
      TmuxSwitcher --demo [--sessions N]
                                       Pin the HUD open with synthetic data,
                                       for iterating on the visuals
      TmuxSwitcher --notify <command>  Send a command to a running agent
      TmuxSwitcher --version
      TmuxSwitcher --help

    Config: ~/.config/tmux-switcher/config.env (hot-reloaded on save)
    """)
    exit(0)
}

// --- Demo mode ----------------------------------------------------------------
var demoSessionCount: Int?
if arguments.contains("--demo") {
    var count = 4
    if let index = arguments.firstIndex(of: "--sessions"),
       arguments.indices.contains(index + 1),
       let parsed = Int(arguments[index + 1]) {
        count = max(0, parsed)
    }
    demoSessionCount = count
}

// --- Normal agent mode --------------------------------------------------------
// Top-level code in main.swift is nonisolated under language mode v5, but it does
// run on the main thread, so assuming main-actor isolation here is both correct
// and necessary to touch AppKit.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    // .accessory keeps us out of the Dock and the app switcher, and — critically —
    // means activating never steals focus from Ghostty.
    application.setActivationPolicy(.accessory)

    // NSApplication.delegate is a weak reference; `run()` blocking below is what
    // keeps this strong reference alive for the lifetime of the process.
    let delegate = AppDelegate(demoSessionCount: demoSessionCount)
    application.delegate = delegate
    application.run()
}
