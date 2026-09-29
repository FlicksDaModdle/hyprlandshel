# Hyprshell Browser

Firefox's engine and interface, rebuilt to the concept's Firefox window and
installed as an application of its own.

```sh
./install.sh                 # built on the Firefox you already have
./install.sh --import        # …starting from a copy of your Firefox profile
./install.sh --default       # …and made the default browser
./install.sh --download      # built on Mozilla's current release instead
./install.sh --uninstall     # remove it (--purge also deletes its profile)
```

Then start **Hyprshell Browser** from the launcher, or run `hyprshell-browser`.
The dock's Web tile opens it once it is installed.

## What it is

Not a theme. A theme can only restyle the elements Firefox already has, which
is why the old `firefox/userChrome.css` could never get the address bar, the
menus or the icons right. This runs code inside the browser, with the same
privileges as Firefox's own interface, and changes the interface itself:

- **Title row, 40px** — the accent bead, tabs as 28px pills with an accent rail
  under the current one, new tab, and the concept's window buttons.
- **Toolbar, 44px** — back, forward, reload, home, the address, downloads,
  add-ons, a hairline, the menu; in that order, set once and yours to change
  afterwards with Firefox's own Customize.
- **The address** — a rounded pill with an accent shield and a hairline; at rest
  the host in full ink and the rest quieter, drawn by the browser rather than
  by Firefox's formatter; an accent ring when focused; selections in the accent.
- **Menus and panels** — the shell's menu: 14px corners, the accent seam, 29px
  rows with a soft wash under the pointer, shortcuts at the right.
- **Symbols** — every control in the shell's own icon language (2px strokes,
  one accent detail) at 20px, generated from the shell's `IconPaths.js` by
  `tools/gen-icons.js`, so the two can never drift apart. They take the accent
  live.
- **Settings and Add-ons** — `about:preferences` and `about:addons` in the
  palette: the sheet colour, hairline cards, the shell's radii, a wash and an
  accent underline on the current section, and the accent on every switch,
  checkbox and primary button. They follow the shell's theme live too.
- **New tab and home page** — Firefox Home in the palette, with the fox and
  the wordmark taken off it; also live.
- **Colour, live** — the palette the shell writes
  (`~/.config/quickshell/hyprshell/firefox-colors.css`) is reloaded the moment
  it changes, into every open window. Web pages follow the shell's light or
  dark too.
- **Its own app** — its own install, profile, app id (`hyprshell-browser`), icon,
  desktop entry and name in the title bar, beside Firefox rather than instead
  of it.

Extensions, sync, passwords, DRM and everything else are Firefox's own and
work as they do there.

## How it is put together

```
app/
  defaults/pref/autoconfig.js   tells Firefox to run hyprshell.cfg at startup
  hyprshell.cfg                 maps resource://hyprshell/ and starts the loader
  hyprshell/
    Loader.sys.mjs              finds each browser window as it opens
    Window.sys.mjs              the bead, the hairline, the window title
    Pages.sys.mjs               Settings and Add-ons, as they open
    NewTab.sys.mjs              the new tab page, which lives in another process
    Layout.sys.mjs              the toolbar order, once per profile
    UrlView.sys.mjs             the address at rest
    Theme.sys.mjs               the palette, and reloading it live
    css/defaults.css            the concept's colours, light and dark
    css/chrome.css              the interface
    css/pages.css               Settings and Add-ons
    css/newtab.css              the new tab page
    icons/                      generated — see tools/gen-icons.js
branding/                       the app icon, from the shell's globe glyph
hyprshell-browser               the launcher
install.sh
```

It rides on Firefox's autoconfig, the mechanism enterprises use to configure
it, loaded from this install's own directory — which is why it needs an
install of its own and cannot be added to an existing Firefox.

**Built on the system Firefox** it is an overlay: every file links back to
`/usr/lib/firefox` except the executable, which is copied, because Firefox
finds the rest of itself next to wherever its executable really is. The
launcher re-links on every start, so a package upgrade never leaves it behind.

**Built on the download** it is Mozilla's release tarball in
`~/.local/lib/hyprshell-browser`, updating itself through Mozilla's signed
updater. The launcher lays the interface back over it if an update ever
replaces one of its files.

## Not a source fork

It is not compiled from Firefox's source. A compiled fork would add a
different name in the About dialog and room for changes below the interface,
at the cost of a 30–40GB build and rebuilding it yourself for every Firefox
security release, every four weeks. Everything here is written so that a
fork would compile these same files in unchanged.

## After changing a symbol

```sh
node tools/gen-icons.js
```

It reads the shell's `IconPaths.js` and writes `app/hyprshell/icons/`.

## When a site works in Firefox but not here

```sh
./doctor.sh --ab            # Gemini in Firefox and here, side by side,
                            # each on a fresh profile, this one without
                            # its interface layer
./doctor.sh --ab URL        # the same for another site
./doctor.sh                 # what differs between the two: versions, the
                            # install, prefs that affect pages, add-ons
HYPRSHELL_BROWSER_PLAIN=1 hyprshell-browser   # your profile, no interface layer
```

