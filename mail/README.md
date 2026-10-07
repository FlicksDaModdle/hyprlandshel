# Hyprshell Mail

An email app in the shell's design, for Gmail, Outlook and any IMAP account
(school, work, iCloud, Fastmail, your own server).

```sh
./mail/install.sh --check   # what's missing
./mail/install.sh           # build and install to ~/.local
```

It is two programs:

- **hyprshell-mail**, the window.
- **hyprshell-maild**, a background service that keeps every account in
  step with its server, sends scheduled mail, brings snoozed mail back and
  says when new mail arrives — with the window closed too. The installer runs
  it as a systemd user service; the app also starts it if it isn't running.

## What it does

- **One inbox for every account**, and each account's own folders. Mail
  arrives the moment it is sent (IMAP IDLE); everything else is looked at
  every five minutes.
- **Conversations**: replies grouped with what they answer, older messages
  folded to a line.
- **Formatted mail shown in full, safely** (with Qt WebEngine): no scripts,
  nothing fetched from the internet. Pictures that load from elsewhere — which
  tell the sender you opened the message — stay hidden until you say *Show*,
  or *Always from this sender*. Links open in your browser, never in the
  message. Without WebEngine, formatted mail is shown simplified.
- **Search** across all of it, instantly, from a local index:
  words, `"exact phrases"`, `from:carol`, `subject:report`, `has:attachment`,
  `is:unread`, `is:starred`, `is:invite`.
- **Writing**: address suggestions from the people you write to, Cc/Bcc,
  attachments (button or drag and drop), replies quoted, forwards with their
  attachments, a signature per account, templates, drafts saved as you type.
- **Undo send** (5 seconds by default) and **send later** (tomorrow morning,
  next week, or a time of your choosing).
- **Snooze**: a conversation leaves the inbox and comes back, with a
  notification, when you said.
- **Calendar invitations**: what, when, where and who, with Yes / Maybe / No.
  Your answer goes to the organiser as a proper calendar reply, and the event
  shows in the shell's calendar panel.
- **Shell**: unread count in the bar (Settings → Bar → Mail), new-mail
  notifications with *Open*, `mailto:` links open a new message, and the
  commands `openMail` and `composeMail [address]` for keybinds.

### Keys

| Key | |
|---|---|
| `c` / Ctrl+N | write a message |
| `/` / Ctrl+F | search |
| `j` `k` / ↓ ↑ | next / previous conversation |
| Enter / `o` | open |
| `e` | archive |
| `#` / Delete | move to the bin |
| `!` | junk |
| `s` | flag |
| `u` / `i` | mark unread / read |
| `r` `a` `f` | reply, reply all, forward |
| Ctrl+Enter | send (while writing) |
| Esc | close the conversation |
| F5 | check for mail |

## Adding accounts

**Other (IMAP)** — school, work, anything else: your address and password.
The servers are looked up from the address (Thunderbird's database of
providers, or where the domain's mail goes); *Server settings* lets you
correct them. A school or workplace whose mail is really Google Workspace or
Microsoft 365 is recognised as such and offered that sign-in instead.

**Gmail** — two ways:

- *App password* (quickest): turn on 2-Step Verification for your Google
  account, then make one at <https://myaccount.google.com/apppasswords> and
  use it as the password.
- *Sign in with Google*: needs a client ID of your own, below.

**Outlook / Hotmail / Microsoft 365** — Microsoft no longer accepts
passwords from mail apps, so: *Sign in with Microsoft*, which needs a client
ID of your own, below.

### Making a Google client ID

Once, free, about five minutes:

1. Go to <https://console.cloud.google.com> and create a project (any name).
2. *APIs & Services → Library*: find **Gmail API** and enable it.
3. *Google Auth Platform* (the OAuth consent screen): app name anything,
   audience **External**, your address as the support contact.
   - Under *Audience*, add your Gmail address as a **test user**.
   - Then press **Publish app** (to "In production"). While an app is
     "Testing", Google makes its sign-ins expire every 7 days. Published but
     unverified is fine for your own use: Google shows a "hasn't verified this
     app" page the first time — *Advanced → Go to (your app)*.
4. *Clients → Create client*: type **Desktop app**. Copy the **Client ID**
   and **Client secret** into Mail (Settings → Sign-in apps, or the prompt
   when adding the account). The "secret" of a desktop client isn't secret —
   Google says so — but Mail keeps it to itself anyway.

### Making a Microsoft client ID

1. Go to <https://entra.microsoft.com> (or portal.azure.com) → *App
   registrations → New registration*.
2. Name: anything. Supported account types: **Accounts in any organizational
   directory and personal Microsoft accounts**.
3. Redirect URI: platform **Public client/native (mobile & desktop)**,
   value `http://localhost`.
4. *API permissions → Add a permission → APIs my organization uses →*
   **Office 365 Exchange Online** → Delegated → `IMAP.AccessAsUser.All` and
   `SMTP.Send`. (`offline_access`, `openid` and `email` are asked for at sign-in.)
5. Copy the **Application (client) ID** into Mail. There is no secret.

School and work accounts: your IT department decides whether apps may sign
in. If it says "needs admin approval", that's theirs to grant. Some Microsoft
365 schools also switch off sending through SMTP; then mail arrives but
sending says the server refused — ask them to enable *Authenticated SMTP* for
your mailbox.

## Privacy and where things are

- **Passwords and sign-ins** are in the desktop keyring (the Secret Service:
  gnome-keyring, KeePassXC, KWallet), never in a file or on a command line.
  The shell's `hyprland.lua` starts gnome-keyring at login if it is installed
  and nothing else is.
- **Mail kept on this computer**: the last 60 days of each folder (whole
  messages up to 512 KB; bigger ones are fetched when opened), in
  `~/.local/share/hyprshell/mail/mail.db`, readable only by you. Opened
  attachments are under `~/.cache/hyprshell/mail/`.
- Nothing is ever sent anywhere but your mail servers, Google's or
  Microsoft's sign-in, and — when adding an account — Thunderbird's provider
  database and a DNS lookup, to find the servers for your address.

Removing an account removes its mail from this computer and its password from
the keyring; nothing is deleted on the server.

## Uninstall

```sh
systemctl --user disable --now hyprshell-maild.service
rm ~/.config/systemd/user/hyprshell-maild.service
rm ~/.local/bin/hyprshell-mail ~/.local/bin/hyprshell-maild \
   ~/.local/share/applications/hyprshell-mail.desktop
rm -r ~/.local/share/hyprshell/mail ~/.cache/hyprshell/mail   # the mail kept here
```

## For development

The service speaks JSON a line at a time on
`$XDG_RUNTIME_DIR/hyprshell-mail.sock` — `mail/core/src/proto.rs` lists every
command. `HYPRSHELL_MAIL_SOCKET` points the app at another socket;
`hyprshell-maild --socket PATH --data DIR` runs a separate instance.
`HYPRSHELL_MAIL_SHOT=out.png` makes the app save a screenshot and quit.
