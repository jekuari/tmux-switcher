# tmux-switcher

A small background agent for macOS that shows a read-only HUD over
[Ghostty](https://ghostty.org) listing which tmux session `Meh+j` / `Meh+k`
will move you to. ("Meh" = Ctrl+Alt+Shift held together, without Cmd.)

It runs as an `LSUIElement` app: no Dock icon, no menu bar item, no app
switcher entry. Hold Meh and tap `j`/`k` to preview the session you'd land on
before you commit to switching; release to dismiss the HUD. The app never
switches sessions or drives tmux itself — it only ever runs `tmux
list-sessions` to know what to display.

It is unsandboxed by necessity: it needs the Accessibility API to observe
global key state and to know which window is focused, and it needs to spawn
`tmux` as a subprocess. App Sandbox would block both, so there is no
entitlements file and no sandbox keys in `Resources/Info.plist`.

## What this expects from your setup

tmux-switcher is a **visualizer, not a switcher**. It assumes you already have
session switching bound to a key chord, and it draws a picture of where those
bindings lead. It will never create, change, or invoke a binding for you — the
only tmux command it ever runs is `list-sessions`.

Two pieces of tmux configuration are load-bearing.

### 1. The window title must be the session name

```tmux
set -g set-titles on
set -g set-titles-string "#S"
```

This is how the app knows which session you are on: it reads the focused
Ghostty window's title through the Accessibility API rather than asking tmux.
It is also what makes the HUD track your switches instantly — macOS posts a
title-change notification the moment the title changes, so the display updates
from an authoritative push instead of polling or guessing.

**Without this the HUD simply never appears.** The title won't match any
session name, and the app deliberately shows nothing rather than displaying a
list it can't anchor to your current position.

### 2. Session switching bound to `switch-client -n` / `-p`

The bindings this was built around:

```tmux
bind -n C-M-S-j switch-client -n   # next session
bind -n C-M-S-k switch-client -p   # previous session
```

Any keys work so long as they sit on the Meh layer (Ctrl+Alt+Shift, no Cmd) and
drive `switch-client -n`/`-p`. The app watches for the Meh modifier itself; the
`j`/`k` keys are entirely tmux's business.

The order the HUD lists sessions in is not a guess — it is the same order tmux
cycles them. In tmux 3.6, `switch-client -n/-p` and `list-sessions` both go
through `sort_get_sessions()`, and with no `-O` flag that leaves the list in
`RB_FOREACH` order, which is `strcmp` by session name. So the app consumes
`list-sessions` output positionally and never re-sorts it.

> ⚠️ Adding `-O` or `-r` to your `switch-client` bindings changes that cycle
> order and the HUD will quietly disagree with where the keys actually take you.

### What it does not do

It only visualizes **session** switching. Window and pane navigation (`Meh+h`
/`Meh+l`, pane selection, resizing) are untouched — the HUD has no opinion about
them and won't appear for them.

## Install

```sh
make cert      # one-time: create a stable, self-signed signing identity
make install   # build, bundle, sign, and install to /Applications
```

`make cert` creates a self-signed code-signing identity named
`tmux-switcher-dev` in your login keychain. This matters more than it
sounds: ad-hoc signing (`codesign -s -`) derives the app's identity from a
hash of the binary, which changes on every rebuild — so macOS silently
revokes the Accessibility grant every time you rebuild the app, and the HUD
just stops showing up with no error message anywhere. A self-signed
certificate gives a stable *designated requirement* derived from the leaf
certificate instead, so the same TCC grant survives rebuilds. `make cert` is
idempotent; run it again any time and it will just confirm the identity is
already there.

After installing, grant Accessibility access:

1. Open **System Settings → Privacy & Security → Accessibility**.
2. Enable **TmuxSwitcher**.
3. You should only need to do this once, ever, as long as the app keeps
   being signed with the `tmux-switcher-dev` identity (see Troubleshooting
   below if it seems to have been revoked).

Other useful targets:

```sh
make build   # swift build -c release
make test    # swift test
make bundle  # assemble the .app without signing/installing
make sign    # sign the assembled bundle
make run     # install, then open the app
make demo    # run the visual harness: swift run TmuxSwitcher --demo
make logs    # stream this app's unified logs
make hooks   # re-print the optional tmux hook snippet
make clean   # remove .build
```

## Optional tmux hooks

tmux-switcher works fully without any tmux configuration — it reads session
state on demand. The hooks below are purely an optimization: they nudge the
app to refresh its session-list cache the moment sessions are created,
closed, or renamed, instead of waiting for its own polling. `make install`
and `make hooks` print this snippet; the app never writes to your tmux
config for you — paste it in yourself:

```
set-hook -ga session-created "run -b '/Applications/TmuxSwitcher.app/Contents/MacOS/TmuxSwitcher --notify sessions-changed'"
set-hook -ga session-closed  "run -b '/Applications/TmuxSwitcher.app/Contents/MacOS/TmuxSwitcher --notify sessions-changed'"
set-hook -ga session-renamed "run -b '/Applications/TmuxSwitcher.app/Contents/MacOS/TmuxSwitcher --notify sessions-changed'"
```

Reload after adding them:

```sh
tmux source-file ~/.config/tmux/tmux.conf
```

(`-ga` appends rather than replacing, so it won't clobber any hooks you
already have set for the same event.)

## Configuration

tmux-switcher reads `~/.config/tmux-switcher/config.env` and hot-reloads it
on save — no restart needed. Recognized keys:

| Key | Meaning |
| --- | --- |
| `DWELL_MS=150` | How long Meh must be held before the HUD appears. Raise it if quick Meh chords flash the HUD; `0` shows it instantly. |
| `IDLE_HIDE_MS=2000` | Fallback for a *missed* Meh release: hides this long after the last session change, but only if the hardware says Meh is no longer held. Deliberately holding Meh to read the list keeps it up. |
| `MAX_DISPLAY_MS=0` | Absolute cap on how long the HUD may stay up, enforced unconditionally. `0` (the default) disables it, so holding Meh keeps the HUD up indefinitely. |
| `MODIFIER_POLL_MS=100` | Poll interval for detecting whether Meh is still held. |
| `MAX_RADIUS=4` | Maximum number of sessions shown on either side of the current one. |
| `TMUX_BIN` | Path to the `tmux` binary to invoke, if not the one on `PATH`. |
| `GHOSTTY_BUNDLE_ID` | Bundle identifier used to detect that Ghostty is the focused app. |
| `SHOW_DIRECTION_HINTS` | Whether to show up/down direction indicators in the HUD. |
| `ANIMATE` | Whether HUD show/hide transitions are animated. |
| `SCROLL_ANIMATION_MS=200` | Duration of the one-row slide when the session changes. `0` makes it instant. |
| `USE_LIQUID_GLASS=1` | Use macOS 26 Liquid Glass for the pills. Set `0` for plain translucent capsules. |

## Troubleshooting

**HUD stopped appearing after a rebuild.**
This is almost always a lost Accessibility grant. Re-add TmuxSwitcher under
**System Settings → Privacy & Security → Accessibility** (remove and re-add
it if simply toggling it doesn't help). Then confirm the binary is actually
signed with the stable identity, not an ad-hoc signature:

```sh
codesign -dvvv /Applications/TmuxSwitcher.app
```

Look for `Authority=tmux-switcher-dev` in the output. If instead you see
`Signature=adhoc` or no `Authority=` line at all, the app was built/signed
without `make sign`/`make install` (or `make cert` was never run) — redo
`make cert && make install` and re-grant Accessibility once more.

**tmux-switcher isn't reflecting session changes.**
Confirm the optional tmux hooks are installed (`make hooks` reprints them),
and that `TMUX_BIN` in your config points at the same `tmux` your shell
uses. Remember: the app only ever calls `tmux list-sessions` — it never
creates, kills, or renames sessions, so it cannot be the cause of any
session-state change itself.

**No signing identity found / `make sign` refuses to run.**
Run `make cert`. If it reports that non-interactive trust could not be
established, follow the manual Keychain Access steps it prints (Keychain
Access → login keychain → My Certificates → `tmux-switcher-dev` → Trust →
Code Signing → Always Trust).

## License

MIT — see [LICENSE](LICENSE).
