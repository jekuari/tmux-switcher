# AGENTS.md

Guidance for AI agents working in this repository. The README is written for
users; this file is the operational knowledge that is easy to get wrong and
expensive to rediscover.

## What this project is

A macOS background agent (`LSUIElement`, no Dock icon, no menu bar item) that
draws a read-only HUD over Ghostty showing which tmux session `Meh+j` / `Meh+k`
will take you to. It is a **visualizer, not a switcher**. The only tmux command
it ever runs is `list-sessions`.

- `Sources/TmuxSwitcherCore` — pure logic, no AppKit. Everything unit-testable
  lives here.
- `Sources/TmuxSwitcher` — the agent: AppKit, Accessibility, event monitoring,
  the notify socket.
- `Tests/TmuxSwitcherCoreTests` — swift-testing (`@Test`/`#expect`), 61 tests.

## Build and test

Use the Makefile targets, not raw `swift` invocations:

```sh
make build    # swift build -c release
make test     # swift test, with a workaround you need (see below)
make demo     # pin the HUD open with synthetic data
make install  # build, bundle, sign, install to /Applications
make logs     # stream this app's unified logs
```

**Always `make test`, never a bare `swift test`.** On a CommandLineTools-only
toolchain SwiftPM does not wire up search paths for swift-testing even though
it ships in CLT, so `swift test` fails with "no such module 'Testing'". The
target passes the `-F` and *two* `-rpath` flags that fix both compiling and a
separate runtime dyld failure, and falls back to plain `swift test` on a full
Xcode toolchain. A SourceKit diagnostic saying `No such module 'Testing'` in
the editor is this same quirk and is not a real error.

**Building requires the macOS 26 SDK**, even though the deployment target is
macOS 14. `OverlayView.swift` references `NSGlassEffectView` behind
`#available(macOS 26.0, *)`, and a symbol behind an availability guard still
has to exist in the SDK at compile time. CI must run on `macos-26`.

**Universal builds use `--triple`, not SwiftPM's `--arch`.** `swift build
--arch arm64 --arch x86_64` routes through `xcbuild`, which ships only with
full Xcode, so it fails outright under CommandLineTools. `make build-universal`
builds each triple separately and `lipo`s the slices together, which works on
both.

`make install` runs `pkill -x TmuxSwitcher` and does **not** relaunch. If you
install during a task, the user's HUD is now dead until someone runs
`open -a TmuxSwitcher`. Use `make run` if you want it back up.

## Invariants — do not break these

### 1. Signing identity stability (the big one)

The app must be signed with a certificate-anchored identity, never ad-hoc.
Ad-hoc signing (`codesign -s -`) derives the app's identity from a hash of the
binary, which changes on every rebuild. macOS ties Accessibility (TCC) grants
to that identity, so an ad-hoc-signed build **silently loses its Accessibility
permission on every rebuild** — no error, just a HUD that stops appearing.

The designated requirement to preserve looks like:

```
identifier "com.rferegrino.tmux-switcher" and certificate leaf = H"<sha1>"
```

Anything that changes the bundle identifier or the signing certificate revokes
every existing user's grant. That is the one-time cost of ever moving to a
Developer ID certificate, and it must be called out in release notes when it
happens.

### 2. `security find-identity` — never use `-v`

`-v` lists only certificates that are explicitly **trusted**, and trust is
irrelevant here. The designated requirement above is a hash comparison against
the leaf certificate; it never walks a trust chain, so an untrusted self-signed
certificate protects the grant exactly as well as a trusted one. Trust only
affects Gatekeeper assessment (`spctl`), which never runs on locally built code
because locally built code is never quarantined.

Using `-v` is what made `make cert` exit 1 on machines where signing worked
perfectly. `make sign`, `make cert` and `install.sh` all check the non-`-v`
condition. Keep it that way.

### 3. The app never mutates tmux state

It runs `tmux list-sessions` and nothing else. It does not switch, create,
rename or kill sessions, and it never writes to the user's `tmux.conf` —
`make hooks` prints a snippet for the user to paste themselves. If a task
seems to call for changing tmux state, that is a sign the task is wrong.

### 4. Session order is consumed positionally, never re-sorted

In tmux 3.6 both `switch-client -n/-p` and `list-sessions` go through
`sort_get_sessions()`, and with no `-O` flag that leaves `RB_FOREACH` order,
which is `strcmp` by session name. The HUD consumes `list-sessions` output
positionally so it agrees with where the keys actually go. Sorting the list
would silently desynchronise the display from reality.

### 5. The window title is load-bearing

The app identifies the current session by reading the focused Ghostty window's
title via the Accessibility API, which requires the user to have
`set -g set-titles-string "#S"`. Without it the HUD deliberately shows nothing
rather than displaying a list it cannot anchor. Do not add a fallback that
guesses.

### 6. No sandbox, no entitlements

App Sandbox would block both the Accessibility API and spawning `tmux`. There
is deliberately no entitlements file and no sandbox keys in
`Resources/Info.plist`. Hardened runtime (`--options runtime`) is on, which
notarization requires and which does not interfere with either need.

## Configuration

`~/.config/tmux-switcher/config.json`, hot-reloaded on save. camelCase keys,
all optional, merged onto `Config.defaults`. Parsing is JSON5-tolerant
(comments, trailing commas, unquoted keys) because plain JSON's lack of
comments would make it a worse format than the `KEY=value` file it replaced.

`Config.parse` **throws** rather than silently falling back. A JSON document
parses as a whole, so ignoring an error would discard every setting over one
typo. Callers differ deliberately:

- **Startup** logs the reason and runs on defaults. Never refuse to launch — a
  background agent that silently fails to appear is far harder to diagnose.
- **Hot-reload** keeps the config already in effect, because editors save
  mid-keystroke and a briefly invalid file is normal.

`config.env` is the pre-JSON format. Nothing reads it; a leftover one is
detected at startup and reported.

## Distribution reality

This is the thing most likely to be reasoned about incorrectly.

- macOS quarantines anything downloaded. Gatekeeper then demands a Developer ID
  signature **plus** a notarization ticket. This project has neither (they need
  a paid Apple Developer Program membership), so **never publish an unsigned
  `.app`** — it would only hand users a dead end. Since macOS 15 the
  Control-click → Open bypass is gone.
- Locally compiled code is never quarantined, so Gatekeeper never runs on it.
  That is the entire reason `install.sh` builds from source instead of
  unpacking a binary.
- The tag-triggered workflow in `.github/workflows/release.yml` publishes a
  source tarball plus `SHA256SUMS` always, and additionally a signed, notarized
  `.dmg` when Developer ID secrets are configured. `workflow_dispatch` runs the
  same job as a dry run without creating a release.
- If notarizing: notarize and staple the `.app` **before** it goes into the
  disk image, then sign, notarize and staple the image separately. Stapling
  only the image leaves the app ticketless once dragged to `/Applications`,
  forcing an online check that fails if the machine is offline on first launch.

## Shell gotchas that have already bitten this repo twice

**`set -o pipefail` plus `grep -q`.** `grep -q` exits the instant it matches,
the upstream command takes SIGPIPE, and the pipeline reports failure *precisely
when the match succeeded*. It appears to work while output is small enough to
fit the pipe buffer, which is not a property to depend on. Use a here-string:

```sh
# wrong under pipefail
if some-command | grep -q "pattern"; then

# right
if grep -q "pattern" <<< "$(some-command || true)"; then
```

**`curl | bash` scripts** must wrap everything in `main()` invoked on the last
line, so a truncated download cannot execute a half-read script, and must never
`read` from stdin — stdin holds the script itself when piped.

## Conventions

- Swift language mode v5 is deliberate (see `Package.swift`). The app is
  overwhelmingly main-actor; thread discipline is enforced by review, so
  anything touching UI or shared mutable state must be on the main queue.
- Comments in this codebase explain **why**, especially for non-obvious
  platform behaviour, and are dense. Match that; a change that removes the
  reasoning behind a workaround is a regression even if the code still works.
- Version lives in `Resources/Info.plist`. `make bundle` stamps `VERSION` and
  `BUILD_NUMBER` into the bundle's **copy**, never back into the checked-in
  file, so a release build leaves the tree clean.
- `TmuxSwitcher --probe-tmux` is the first diagnostic to reach for: it
  exercises the real tmux path without needing Accessibility, and reports
  config errors.
