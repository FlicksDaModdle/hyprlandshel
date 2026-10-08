# Hyprshell greeter

The login screen, in the shell's own design — drawn by the same file as the
lock screen (`shell/quickshell/modules/common/LoginView.qml`), so the two are
one design: a light clock high up, a frosted card with your picture, name
and the password field, sleep / restart / shut down in the corner — over
your desktop's own wallpaper (the live video, picture, animation, contour
map or gradient, `Ground.qml`), in your theme: accent, light or dark,
fonts, corner rounding. Run by [greetd](https://sr.ht/~kennylevinsen/greetd/),
the same way Noctalia's greeter is.

**It follows your shell.** Change the accent, theme or wallpaper in
Settings and the next login screen has it: your shell keeps a copy of your
theme, wallpaper and picture in `/var/lib/hyprshell-greeter/users/<you>`
(`services/GreeterSync.qml`), the one place both it and the greeter can
reach, and the greeter shows whoever is picked in their own. Someone who has
never run the shell gets the greeter's own look (`--theme`).

**Your login unlocks the keyring** — where Mail, the browser and Wi-Fi keep
passwords: the installer adds `pam_gnome_keyring` to `/etc/pam.d/greetd`
(the old file is kept as `greetd.before-hyprshell`; `--no-keyring` skips
it). For that the keyring's password has to be your login password; if it
isn't, change it in Passwords and Keys (seahorse): right-click *Login* →
*Change Password*.

```sh
sudo ./install.sh              # install it and point greetd at it
sudo ./install.sh --enable     # …and make greetd the display manager
sudo ./install.sh --theme      # after changing your theme, give it the new one
sudo ./install.sh --uninstall  # put greetd's previous config back
./install.sh --status          # what greetd will start, and whether it is this
```

**Reboot after installing.** greetd reads its config when it starts and keeps
it, so logging out still brings back the greeter it started with — Noctalia's,
say. A reboot starts it on the new one (or, from a text console on
Ctrl+Alt+F2, `sudo systemctl restart greetd`, which ends every session).

Needs `greetd`, `quickshell` and Hyprland — all of which a Hyprshell setup
already has, except perhaps greetd (`pacman -S greetd`). If you came from
Noctalia's greeter, greetd is already installed and enabled, and installing
this simply replaces it; its config is kept beside it with
`.before-hyprshell` added, which `--uninstall` puts back.

Which file that is: greetd reads `/etc/greetd/greetd.conf` when it exists —
Noctalia's setup writes that one — and `config.toml` only when it does not
(or whatever its service passes with `--config`). The installer writes
whichever greetd will actually read.

To look at it without logging out: `qs -p greeter/shell.qml`. It takes the
screen; Escape on an empty field leaves. Nothing logs in from a preview.

## Using it

- **Type your password** — there is no field to click first — and Enter.
- **Someone else:** the arrows beside the name, or Up and Down.
- **Another session:** click the session under the card, or Tab.
- **The eye** shows what you typed, for when Caps Lock is on.
- **Sleep, restart, shut down:** bottom right.

It remembers who logged in last and into what. A PAM step after the password
— a one-time code, a new password when yours has expired — is asked in the
same field.

## How it is put together

```
greetd  →  Hyprland, /etc/hyprshell-greeter/hyprland.lua
        →  quickshell -p /usr/share/hyprshell-greeter/shell.qml
```

```
shell.qml          one window per screen; the card on the first
GreeterState.qml   users, sessions, the choice remembered, and greetd
Surface.qml        a screen: the shell's LoginView, fed the greeter's state
GreeterWindow.qml  the window, as a layer holding the keyboard (Wayland)
GreeterWindowX11.qml  the same without a layer shell, for tests
hyprland.lua       the compositor greetd runs it in — no keybinds
install.sh
shell → ../shell/quickshell   the theme, components and wallpaper it is drawn with
```

The greeter runs as greetd's own unprivileged user. It reads `/etc/passwd`
for the people who can log in (uid 1000 and up, with a login shell),
`/usr/share/wayland-sessions` for what they can log into, and
`/var/lib/AccountsService/icons` for their pictures; `install.sh` puts your
`~/.face` there if nothing is. Your password goes to greetd, which checks it
with PAM and starts the session as you.

It is drawn with the shell's own `config/` and `modules/common` and
`modules/icons`, not a copy of them, which is why it looks the same.
Quickshell only loads files inside the folder a config lives in, so the repo
reaches them through the `shell` link and `install.sh` copies them in.

`/etc/hyprshell-greeter/hyprland.lua` is written with the keyboard layout
you are using when you install, so your password is typed on the same one.
Edit it there to change it.

## If the login screen does not come up

Switch to a text console with Ctrl+Alt+F2, log in, and either run
`sudo ./install.sh --uninstall`, or put the old config back by hand:

```sh
sudo cp /etc/greetd/greetd.conf.before-hyprshell /etc/greetd/greetd.conf   # or config.toml
sudo systemctl restart greetd
```

`journalctl -u greetd -b` says what went wrong.
