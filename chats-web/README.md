# Chats Web

WhatsApp Web in a window of its own, in Hyprshell's colours: the companion
to **Chats** (`apps/chats`), the native client.

Chats is the one to use day to day: it is a native app, light on memory,
drawn entirely in the shell's design. Chats Web is for what only WhatsApp
Web can do, voice and video calls above all, and for anything WhatsApp adds
before Chats catches up. Both can be linked at once; each is a linked device
of its own on your phone.

    ./install.sh                  install (needs Electron: sudo pacman -S electron)
    ./install.sh --check          say what's missing
    ./install.sh --uninstall      remove; add --purge to sign out as well

Or from the top folder: `./install.sh --chats-web`.

Then open **Chats Web** from the launcher and link it from your phone:
WhatsApp → Settings → Linked devices → Link a device.

## What it does

- WhatsApp Web, unmodified, in a sandboxed view under the same title row as
  the other Hyprshell apps.
- Its colours are the shell's: the blue-greys become the shell's warm greys,
  WhatsApp's green becomes your accent, the text is Inter. It follows the
  shell's light/dark mode, accent and text size live.
- Unread count in the title row and the tray; close hides it to the tray
  (Quit is in the tray menu, or Ctrl+Q).
- Notifications, microphone and camera, spell checking, downloads to
  ~/Downloads, links in your browser, zoom (Ctrl + / − / 0), an offline page
  that reconnects by itself, one instance.

## How the colours are done

`theme.js` reads WhatsApp's own stylesheets and, for every colour in them,
works out the shell's equivalent. The result is laid over WhatsApp's styles
(user-origin rules, the same selectors), so WhatsApp's own light and dark
themes keep working underneath. It goes by colour rather than by class name,
because WhatsApp's class names change with every release and its colours
rarely do; colours it doesn't recognise simply stay WhatsApp's.

## Good to know

- Not made by or affiliated with WhatsApp. It shows WhatsApp Web as WhatsApp
  serves it and automates nothing, but it is still a third-party client and
  WhatsApp's terms apply.
- It talks to web.whatsapp.com and WhatsApp's servers, nothing else.
- It runs on the system's Electron, so Chromium's security fixes arrive with
  your normal updates.
- Its session is kept in `~/.config/hyprshell-chats-web`.
