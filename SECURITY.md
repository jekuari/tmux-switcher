# Security & Privacy

This document is written for anyone auditing tmux-switcher before allowing it on
a machine — including corporate security / endpoint-management review. Every
claim below is verifiable against the source or with a shell command, and the
relevant files are small and linked.

tmux-switcher is a macOS heads-up display that shows which tmux session your
next-/previous-session keys will switch to. It is **read-only**: it observes and
displays, and never changes tmux, your configuration, or any other application.

## Permissions and capabilities

### Accessibility (required)

The app requests macOS Accessibility for exactly two read-only purposes:

1. **Reading the focused window's title**, to know which tmux session you are on.
2. **Detecting when a modifier chord is held** (Control+Option+Shift), to know
   when to show the HUD.

It watches modifier-flag **state** via
`NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged)`
([`ModifierWatcher.swift`](Sources/TmuxSwitcher/ModifierWatcher.swift)). It does
**not**:

- install a keyboard event tap (`CGEventTap`) — it deliberately avoids the
  "Input Monitoring" permission,
- log keystrokes or capture typed text,
- read the contents of other applications,
- record or capture the screen.

`.flagsChanged` events carry modifier state only, not character keys.

### Subprocess execution

The app runs exactly one external command
([`TmuxClient.swift`](Sources/TmuxSwitcherCore/TmuxClient.swift)):

```
tmux list-sessions -F "#{session_name}"
```

It is invoked with a fixed argument array via `Foundation.Process` — **no shell
is spawned**, so there is no command-injection surface — and its output is only
read, never acted on. The app never switches, creates, renames, or kills tmux
sessions, and never writes to your tmux configuration.

### Network

**The app makes no network connections.** It contains no HTTP client, no
sockets to remote hosts, no telemetry, no analytics, and no update check. Its
only inter-process communication is a **local `AF_UNIX` (filesystem) socket** at
`~/.config/tmux-switcher/notify.sock`
([`NotifyServer.swift`](Sources/TmuxSwitcher/NotifyServer.swift)), which an
optional local tmux hook can connect to in order to nudge the session-list
cache. Nothing leaves the machine.

### Filesystem

The only paths the app touches are under `~/.config/tmux-switcher/`:

- it **reads** `config.json` if present,
- it **creates** that directory and the local socket described above.

It writes nothing elsewhere on disk.

### Sandbox and runtime

The app is intentionally **not** sandboxed — App Sandbox would block both the
Accessibility API and spawning `tmux`. It carries **no entitlements file** and
requests no special capabilities. Signed release builds are compiled with the
**Hardened Runtime** enabled (a prerequisite for Apple notarization).

## Dependencies and supply chain

tmux-switcher has **zero third-party dependencies.** It builds from
[`Package.swift`](Package.swift) using only:

- first-party code in this repository (`TmuxSwitcher`, `TmuxSwitcherCore`), and
- Apple system frameworks (AppKit, Foundation, OSLog).

There is no package manager pulling in external code at build time, so there is
no third-party supply chain to vet.

## Distribution and signing

Signed releases are produced by
[`.github/workflows/release.yml`](.github/workflows/release.yml), which — when
Developer ID credentials are configured — signs the app with an **Apple
Developer ID Application certificate**, submits it to **Apple's notary service**,
and staples the resulting ticket. The published artifact is a signed, notarized
`.dmg`.

Builds without those credentials are distributed as source only, on purpose: an
unsigned, un-notarized app downloaded from the internet is quarantined and
Gatekeeper refuses to launch it, so no unsigned prebuilt binary is ever
published.

## How to verify

Against an installed copy:

```sh
# Signature: expect an "Authority=Developer ID Application" line, a Team
# Identifier, and "flags=...runtime" (Hardened Runtime) for a signed release.
codesign -dv --verbose=4 /Applications/TmuxSwitcher.app

# Gatekeeper / notarization: expect "accepted" and "source=Notarized Developer ID".
spctl -a -vvv /Applications/TmuxSwitcher.app

# Entitlements: expect an empty/near-empty set — no sandbox, no special capabilities.
codesign -d --entitlements - --xml /Applications/TmuxSwitcher.app
```

Against the source:

```sh
# No networking APIs anywhere in the app:
grep -rniE "urlsession|urlrequest|nwconnection|cfstream|af_inet|https?://" Sources/

# The only external command and the only IPC socket:
grep -rn "process.arguments" Sources/TmuxSwitcherCore/TmuxClient.swift
grep -rn "AF_UNIX" Sources/
```

## Building from source

The app builds with the standard Swift toolchain and a committed `Makefile`, so
the binary can be reproduced from the exact source you are reviewing:

```sh
make build      # swift build -c release
make test       # runs the unit test suite
make bundle     # assemble the .app
```

Organizations that prefer to control the full chain can build and sign it
internally from a pinned copy of this source rather than consuming a published
binary — see the repository's review notes or contact below.

## Reporting a vulnerability

Please report suspected security issues privately via GitHub's **Report a
vulnerability** flow (the Security tab of
<https://github.com/jekuari/tmux-switcher>) rather than opening a public issue.
