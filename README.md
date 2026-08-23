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
curl -fsSL https://raw.githubusercontent.com/jekuari/tmux-switcher/main/install.sh | bash
```

That downloads the latest release, builds it, signs it, and installs it to
`/Applications`. It needs the Command Line Tools and the macOS 26 SDK to build
(the app *runs* on macOS 14+; only building needs the newer SDK, because the
Liquid Glass code path references a macOS 26 API behind an availability check).
It checks for both up front and says so rather than dumping compiler errors on
you.

If piping a script into your shell makes you twitch — reasonable — read it
first, or clone and build by hand:

```sh
git clone https://github.com/jekuari/tmux-switcher && cd tmux-switcher
make cert      # one-time: create a stable, self-signed signing identity
make install   # build, bundle, sign, and install to /Applications
```

The installer takes a few environment variables: `TMUX_SWITCHER_VERSION=v0.2.0`
pins a release, `TMUX_SWITCHER_REF=main` builds a branch,
`TMUX_SWITCHER_URL=...` points at an arbitrary source tarball, and
`TMUX_SWITCHER_INSTALL_DIR=...` chooses where the app lands. Release
downloads are verified against the `SHA256SUMS` published with them; branch
installs fall back to TLS alone, and the script says which one happened rather
than implying an integrity check that did not occur.

### Installing without admin rights

On a machine where `/Applications` needs elevated privileges, the installer
does not fail and does not try to prompt for a password — it falls back to
`~/Applications` and says so. That is not a compromise: macOS treats
`~/Applications` as a first-class app location, and Login Items, the
Privacy & Security → Accessibility list and LaunchServices all handle it
identically. Force it explicitly with:

```sh
TMUX_SWITCHER_INSTALL_DIR=~/Applications \
  curl -fsSL https://raw.githubusercontent.com/jekuari/tmux-switcher/main/install.sh | bash
```

If you specifically need it in `/Applications` on such a machine, use a
checkout and elevate **only the copy**:

```sh
make install SUDO=sudo
```

Do not run `sudo make install`. That builds and signs as root, and the
`tmux-switcher-dev` identity lives in *your* login keychain, not root's — so
signing fails outright. `SUDO=sudo` exists precisely to keep the build and the
signature unprivileged while elevating just the install step.

### Why it builds instead of downloading a binary

Because a downloaded binary would not run. macOS quarantines anything fetched
over the network, and Gatekeeper then demands a Developer ID signature plus a
notarization ticket — both of which need a paid Apple Developer Program
membership this project does not have. Code compiled on the machine it runs on
is never quarantined, so Gatekeeper never gets involved. See
[Releasing](#releasing) for the full picture.

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
make icon    # regenerate Resources/AppIcon.icns
make bundle  # assemble the .app without signing/installing
make sign    # sign the assembled bundle
make dmg     # package the already-signed bundle as a .dmg
make run     # install, then open the app
make demo    # run the visual harness: swift run TmuxSwitcher --demo
make logs    # stream this app's unified logs
make hooks   # re-print the optional tmux hook snippet
make clean   # remove .build and dist
```

Two variables are worth knowing about. `UNIVERSAL=1` builds arm64 and x86_64
and `lipo`s them into one binary (off by default: it doubles compile time for
no local benefit). `VERSION=1.2.3 BUILD_NUMBER=42` stamps those into the
bundle's `Info.plist` copy — never back into `Resources/Info.plist`, so a
release build leaves the working tree clean.

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

tmux-switcher reads `~/.config/tmux-switcher/config.json` and hot-reloads it on
save — no restart needed. The file is optional; every key is optional too, so it
only ever needs to mention the knobs you actually want to change.

```jsonc
{
  // Raise this if quick Meh chords flash the HUD.
  "dwellMs": 250,
  "maxRadius": 6,
  "tmuxBin": "/opt/homebrew/bin/tmux"
}
```

Parsing is JSON5-tolerant: `//` and `/* */` comments, trailing commas and
unquoted keys are all accepted. Plain JSON has no comment syntax, which would
have made it a strictly worse format than the `KEY=value` file it replaced for
something whose whole purpose is to be hand-edited and annotated.

| Key | Type | Default | Meaning |
| --- | --- | --- | --- |
| `dwellMs` | int | `150` | How long Meh must be held before the HUD appears. Raise it if quick Meh chords flash the HUD; `0` shows it instantly. |
| `idleHideMs` | int | `2000` | Fallback for a *missed* Meh release: hides this long after the last session change, but only if the hardware says Meh is no longer held. Deliberately holding Meh to read the list keeps it up. |
| `maxDisplayMs` | int | `0` | Absolute cap on how long the HUD may stay up, enforced unconditionally. `0` disables it, so holding Meh keeps the HUD up indefinitely. |
| `modifierPollMs` | int | `100` | Poll interval for detecting whether Meh is still held. |
| `maxRadius` | int | `4` | Maximum number of sessions shown on either side of the current one. |
| `tmuxBin` | string | `/opt/homebrew/bin/tmux` | Path to the `tmux` binary to invoke. |
| `ghosttyBundleID` | string | `com.mitchellh.ghostty` | Bundle identifier used to detect that Ghostty is the focused app. |
| `showDirectionHints` | bool | `true` | Whether to show up/down direction indicators in the HUD. |
| `animate` | bool | `true` | Whether HUD show/hide transitions are animated. |
| `scrollAnimationMs` | int | `200` | Duration of the one-row slide when the session changes. `0` makes it instant. |
| `useLiquidGlass` | bool | `true` | Use macOS 26 Liquid Glass for the pills. `false` gives plain translucent capsules. |

Durations clamp at `0` and `maxRadius` clamps at `1`, since a zero radius would
render a HUD with no rows in it. Unknown keys are ignored, so a config written
for a newer build will not break an older binary.

### On invalid config

A JSON document is parsed as a whole, so a single typo invalidates the entire
file — unlike the old `KEY=value` format, where a bad line could just be
skipped. Silently falling back to defaults would therefore mean silently
discarding *every* setting over one misplaced comma, so instead:

- **At startup**, a broken file logs an error naming the offending key and the
  app runs on defaults. It never refuses to launch — a background agent that
  silently fails to appear is much harder to diagnose than one running on
  defaults.
- **On hot-reload**, a broken file is ignored and the config already in effect
  is kept. Editors save mid-keystroke often enough that a briefly invalid file
  is normal; reverting every setting on the way past would be worse than
  waiting for the next save.

Either way the reason lands in `make logs`. `TmuxSwitcher --probe-tmux` also
reports it, since "the HUD shows nothing" and "my config has a typo" are the
same symptom from the outside.

> **Upgrading?** The format changed from `config.env` (`KEY=value`, uppercase
> keys) to `config.json` (camelCase keys). Nothing reads `config.env` any more.
> If one is still sitting there with no `config.json` beside it, the app logs a
> warning at startup rather than appearing to ignore settings you believe are in
> effect. Port it by hand — `DWELL_MS=250` becomes `"dwellMs": 250`.

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
and that `tmuxBin` in your config points at the same `tmux` your shell
uses. Remember: the app only ever calls `tmux list-sessions` — it never
creates, kills, or renames sessions, so it cannot be the cause of any
session-state change itself.

**No signing identity found / `make sign` refuses to run.**
Run `make cert`. If it says trust could not be established non-interactively,
ignore it — that is a note, not a failure. Trust only affects Gatekeeper
assessment (`spctl`), which never runs on locally built code because locally
built code is never quarantined. The designated requirement that actually
protects your Accessibility grant is a hash comparison against the leaf
certificate and never walks a trust chain. What matters is that the identity
exists at all, which is what both `make cert` and `make sign` check.

## Releasing

Pushing a `v*` tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml),
which tests, builds a universal bundle, and publishes a GitHub Release.

What that release contains depends on whether Developer ID credentials are
configured as repository secrets, and the reason is worth spelling out, because
it is the one thing about macOS distribution that catches people out.

**The self-signed `tmux-switcher-dev` identity only works on the machine that
created it.** `scripts/make-cert.sh` finishes with `security add-trusted-cert`,
which tells *your* login keychain to trust that root. The certificate travels
inside the `.app`; that trust decision does not.

That alone is survivable — but two separate mechanisms are in play, and they
fail differently:

- **Gatekeeper** only inspects *quarantined* code. Anything a browser downloads
  gets the `com.apple.quarantine` attribute, and macOS then demands a Developer
  ID signature *plus* a notarization ticket before it will launch. A self-signed
  build has neither. Since macOS 15 the Control-click → Open escape hatch is
  gone, so the user has to dig through System Settings → Privacy & Security to
  approve it — a miserable first run for an `LSUIElement` agent that shows no
  window either way. A locally compiled build is never quarantined, which is
  precisely why `make install` works and a downloaded build would not.
- **TCC / Accessibility** is indifferent to trust. The designated requirement
  this project is careful to keep stable is a hash comparison against the leaf
  certificate; it never validates the chain. So the grant-survives-rebuild
  property holds on any machine.

So the pipeline never publishes an unsigned `.app`. Without credentials it
publishes a **source tarball** and points users at `make cert && make install`.
With credentials it additionally publishes a **Developer ID-signed,
Apple-notarized `.dmg`** that opens with no warning.

To turn the signed path on, enroll in the Apple Developer Program ($99/year)
and add five repository secrets — `MACOS_CERT_P12`, `MACOS_CERT_PASSWORD`,
`NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_ISSUER_ID`. The workflow header
documents exactly how to produce each one. Nothing else changes; the next tag
picks them up.

> ⚠️ The first signed release revokes every existing user's Accessibility
> grant, exactly once. Switching from `tmux-switcher-dev` to a Developer ID
> certificate changes the app's designated requirement, and a changed DR is
> indistinguishable from a different app as far as TCC is concerned. It does
> not recur on later updates.

`workflow_dispatch` runs the same job as a dry run: it builds everything and
uploads the results as workflow artifacts without creating a release.

## License

MIT — see [LICENSE](LICENSE).
