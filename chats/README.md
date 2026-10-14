# Chats

WhatsApp in a window of its own, in Hyprshell's colours.

It is WhatsApp Web, unmodified, in a sandboxed view under the same title row
as the other Hyprshell apps. Its colours are the shell's: the blue-greys
become the shell's warm greys, WhatsApp's green becomes your accent, and the
text is Inter. It follows the shell's light/dark mode, accent (preset,
custom or from the wallpaper) and text size as you change them, with no
restart.

    ./install.sh                  install (needs Electron: sudo pacman -S electron)
    ./install.sh --check          say what's missing
    ./install.sh --uninstall      remove; add --purge to sign out as well

Then open **Chats** from the launcher and link it from your phone: WhatsApp →
Settings → Linked devices → Link a device.

## What it does

- **Unread count** in the title row, the window title and the tray icon.
- **Close hides it** to the tray, so messages keep arriving; Quit is in the
  tray icon's menu, or Ctrl+Q. Start it hidden at login with
  `exec-once = hyprshell-chats --hidden` in your Hyprland config.
- **Notifications** through the desktop's notification service; clicking
  one brings the window up.
- **Voice messages** (it may use the microphone, and only WhatsApp may).
- **Links** open in your browser. **Downloads** go to ~/Downloads, each
  with a notification that shows it in Files.
- **Spell checking** with suggestions on right-click.
- **Zoom** with Ctrl + / − / 0. **Reload** with Ctrl+R or F5.
- **Offline**: a page that says so, and it reconnects by itself.
- One instance: opening it again brings up the one that's running.

## How the colours are done

`theme.js` reads WhatsApp's own stylesheets and, for every colour in them,
works out the shell's equivalent. The result is laid over WhatsApp's styles
(user-origin rules, the same selectors), so WhatsApp's own light and dark
themes and its layout keep working underneath. It goes by colour rather than
by class name, because WhatsApp's class names change with every release and
its colours rarely do — and if a release ever brings colours this doesn't
recognise, those parts simply look like stock WhatsApp, nothing breaks.

## Good to know

- Chats is not made by or affiliated with WhatsApp. It shows WhatsApp Web as
  WhatsApp serves it and doesn't automate anything, which is what browser
  wrappers like it have always done — but it is a third-party client, and
  WhatsApp's terms are WhatsApp's to apply.
- Nothing goes anywhere but WhatsApp: it talks to web.whatsapp.com and
  WhatsApp's own servers for its stylesheets, nothing else.
- It runs on the system's Electron, so Chromium's security fixes arrive with
  your normal updates (`electron` on Arch and CachyOS).
- Its session (your linked device) is kept in `~/.config/hyprshell-chats`.
