## Install

Download `TmuxSwitcher-VERSION_PLACEHOLDER.dmg`, open it, and drag
**TmuxSwitcher** to Applications. The app is signed with a Developer ID
certificate and notarized by Apple, so it opens with no Gatekeeper warning.

Then grant Accessibility access — the app needs it to observe the Meh modifier
and to read the focused Ghostty window's title:

**System Settings → Privacy & Security → Accessibility → enable TmuxSwitcher**

Remember that the HUD only appears if tmux is setting the window title to the
session name. See the README for the two load-bearing tmux settings.

> **Upgrading from a `make install` build?** The signing identity changed from
> the local `tmux-switcher-dev` certificate to a Developer ID one. That changes
> the app's designated requirement, so macOS revokes the old Accessibility
> grant. Remove the old TmuxSwitcher entry from the Accessibility list and
> re-add the new app once. This is a one-time cost — it will not recur on
> future updates.
