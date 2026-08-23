## Install

This release ships **source only**, on purpose. An unsigned `.app` downloaded
from the internet is quarantined by macOS, and Gatekeeper refuses to launch
anything lacking both a Developer ID signature and a notarization ticket — so a
prebuilt download here would be a dead end rather than a convenience. Building
on your own machine sidesteps that entirely: locally compiled code is never
quarantined, so Gatekeeper never runs on it.

```sh
tar xzf tmux-switcher-VERSION_PLACEHOLDER.tar.gz
cd tmux-switcher-VERSION_PLACEHOLDER
make cert      # one-time: stable self-signed identity, so the
               # Accessibility grant survives rebuilds
make install   # build, bundle, sign, install to /Applications
```

Then grant Accessibility access:

**System Settings → Privacy & Security → Accessibility → enable TmuxSwitcher**

Remember that the HUD only appears if tmux is setting the window title to the
session name. See the README for the two load-bearing tmux settings.
