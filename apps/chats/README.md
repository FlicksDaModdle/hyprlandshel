# Chats

WhatsApp on this computer, in the shell's own design: a native window (Rust,
Slint, the apps kit) and a small service that does the WhatsApp side.

    apps/install.sh --only chats      build and install it (needs Rust and Go)
    hyprshell-chats --demo            try the window with made-up chats

Open **Chats** from the launcher and link it from your phone: WhatsApp →
Settings → Linked devices → Link a device, then scan the code — or choose
"Link with a phone number instead" on both sides and type the code Chats
shows. Your chats and their recent history arrive from the phone.

## What it does

- Your chats, newest first, with pictures, unread counts, pinned, muted and
  archived chats as your phone has them; search by name.
- Conversations with text and emoji (in colour), replies, reactions,
  photos, stickers, videos and documents (open or save to Downloads),
  voice messages (play them, or hold a conversation by recording your own),
  edited and deleted messages, delivery and read ticks, "typing…".
- Send text, replies, reactions, files and photos (the paperclip), voice
  messages (the microphone); delete your own messages for everyone; start a
  chat with a phone number.
- Notifications for new messages when the window is closed or you're
  elsewhere; clicking one opens the chat. Muted and archived chats stay
  quiet, and what you read here or on your phone is cleared.
- It follows the shell's theme, accent and text size like the other apps.

Not (yet): calls, polls and other interactive messages, status updates,
channels, community admin. **Chats Web** (`chats-web/`, `./install.sh
--chats-web`) is WhatsApp Web itself in a window, for calls and anything
else Chats doesn't do; both can be linked at once.

## How it works

`hyprshell-chatsd` (`daemon/`, Go) is a WhatsApp linked device, like
WhatsApp Web: it uses [whatsmeow](https://github.com/tulir/whatsmeow), an
open-source implementation of the protocol WhatsApp Web speaks, including
its end-to-end encryption. It keeps the session, stores the conversation,
downloads media and sends notifications, and runs as a systemd user service
so messages arrive with the window closed. (Not linked and no window open,
it stops after a minute.)

The window (`src/`, `ui/`) talks to it over a Unix socket in
`$XDG_RUNTIME_DIR`; `daemon/server.go` lists what they say. Voice messages
are Ogg Opus, encoded and decoded with the system's libopus.

Kept in `~/.local/share/hyprshell-chats`, readable only by you:
`session.db` is the linked device's keys (it can read your messages, so
treat it like a password), `chats.db` the messages, `media/` and `avatars/`
the files. **Unlink** in the ⋯ menu signs out and deletes all of it; so does
removing the device on your phone.

## Good to know

- Chats is not made by or affiliated with WhatsApp. It is an unofficial
  client, which WhatsApp's terms don't allow, and WhatsApp does sometimes
  ban accounts that use unofficial clients — mostly ones sending automated
  or bulk messages, but there is no guarantee. Use it knowing that; trying
  it on a number you can spare first is the careful way.
- It behaves like WhatsApp Web where it can: online only while the window
  is in front, read receipts only for chats you open, profile pictures
  fetched one at a time.
- When WhatsApp changes its protocol, Chats can stop connecting until
  whatsmeow catches up (usually within days); rebuilding with
  `apps/install.sh --only chats` picks up the fix. The window says so if
  WhatsApp reports the client as outdated.
- Colour emoji need a colour emoji font (`noto-fonts-emoji`) and a GPU
  renderer; without one, emoji are drawn in a single colour.
