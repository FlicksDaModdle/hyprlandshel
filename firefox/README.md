# Firefox, in the shell's design language

The browser's chrome given the same vocabulary as the bar, the dock and
the panels: 14px on anything that reads as a surface and 9px on anything
that reads as a tile, one accent that marks what is selected and nothing
else, ink in three weights, and the 2px accent seam under the top chrome.

```
./install.sh          into every Firefox profile it can find
./install.sh --list   what it found, changing nothing
./install.sh --uninstall
```

Then **restart Firefox**.

## What is in here

| | |
|---|---|
| `userChrome.css` | the browser: tabs, toolbar, address bar, menus, sidebar, findbar |
| `userContent.css` | the pages Firefox draws itself: new tab, error pages, reader, view-source |
| `preview.html` | a drawing of the result, to look at without installing |
| `hyprshell-defaults.css` | the palette when the shell has not written one — light and dark, following the system |
| `install.sh` | finds the profiles, installs, flips the one pref that is needed |
| `doctor.sh` | why it is not themed yet — walks the chain and names the broken link |

The colours are not in any of these. The shell writes them to
`~/.config/quickshell/hyprshell/firefox-colors.css` and the stylesheets
import it — the same split kitty's palette uses, so the part you might
edit stays where you left it and the part the shell owns is rewritten
underneath. Change the accent in Settings and this changes with it.

## Where it looks

There is no single place a Firefox profile lives. `~/.mozilla/firefox` is
the old answer; a Firefox built with XDG base directories — which is what
Arch and its derivatives ship — puts it under `~/.config/mozilla/firefox`
instead, and Flatpak, snap and every Gecko fork have trees of their own.
`install.sh` knows the usual ones and then searches `$HOME` for a
`profiles.ini` if none of them turn up, so a browser it has never heard
of still works.

If it still finds nothing, Firefox will tell you itself: open
`about:profiles` and read the **Root Directory** row, then

```
./install.sh --profile <that path>
```

Note that is the *Root* directory and not the *Local* one. The local one
is under `~/.cache` and holds a second copy of the profile with the same
name; installing into that does nothing and looks like it worked.

## Two prefs, not one

`install.sh` sets both, in each profile's `user.js`.

`toolkit.legacyUserProfileCustomizations.stylesheets` lets Firefox read
`chrome/userChrome.css` at all; it has been off by default since Firefox
69.

`widget.gtk.native-context-menus` is the one that is not obvious. With it
on — the default on Linux — a right-click menu is a real GTK menu widget
rather than a XUL popup, drawn by the toolkit, and **no chrome CSS can
touch it**. Every menu rule here is inert while it is true, which looks
exactly like the rules being wrong. Turning it off hands the menu back to
Firefox to draw, and then the stylesheet reaches it.

## Two things to know

**Firefox reads chrome stylesheets once, at startup.** A theme change in
the shell lands in the colours file immediately and in the browser at its
next launch. There is no supported way to make a running Firefox notice —
kitty has a signal for it, Firefox has nothing.

That goes for every theme change, not only the first install. Changing
the accent, the rounding or light/dark rewrites the palette immediately,
and the browser picks it up at its next launch. The corner radius does
follow the shell's rounding slider — 0% gives square corners, 160% gives
22px — but you will not see it move until you restart the browser.

## If it looks like nothing happened

```
./doctor.sh
```

Six separate things have to be true before any of this shows up, and all
six fail the same way from the outside — a browser that looks exactly
like stock Firefox, with no error anywhere, in any log. `doctor.sh` walks
the chain and names the broken link: the palette, the profile Firefox is
actually using, whether the stylesheet is there, whether its `@import`
was substituted, whether the pref is set, and whether the browser has
been restarted since.

That last one catches most of it. Firefox reads chrome CSS once, on the
way up, and closing the window does not always end the process — check
with `pgrep -x firefox`.

## Light against dark

The palette follows **the shell**, not Firefox and not GTK. If the shell
is light and Firefox is dark you get a light address bar with Firefox's
own white icons on it, and a menu with the platform's dark box and this
theme's dark text inside it — which reads as a broken theme rather than
as two settings disagreeing. Nothing is broken; the chrome is exactly the
colour it was told to be.

`./doctor.sh` prints all four opinions — this theme's palette, the shell,
GTK, and Firefox's own theme — and says when they disagree. Put the shell
in the mode you want (Settings → Appearance) and the browser follows it
at its next start.

When the shell has never written a palette, `hyprshell-defaults.css`
stands in, and that one follows the system — with no shell to ask, it is
the only opinion available.

**A shell that was already running when you installed this has no Firefox
support in it**, so it will never write a palette and `syncTheming` on it
does nothing. Reload it first — `super+shift+R`, or `qs -c hyprshell ipc
call shell reloadShell` — and then restart Firefox.

## Two places that need more than a colour

**Menus are painted by GTK, not by Firefox.** A `menupopup` on Linux has
`appearance: auto`, which means the platform draws the box and a
background colour set on it is ignored. Every menu rule here turns that
off first with `appearance: none`, and then has to supply the border, the
radius and the padding itself, because those were the platform's too.

**The top strip is a lightweight theme.** Firefox's built-in Light and
Dark are lightweight themes, and which element their accent colour lands
on has moved between releases — so setting `--lwt-accent-color` and
stopping there left the strip in Firefox's own grey while everything
below it took the shell's. Every box in that strip is named directly,
`background-image` is turned off alongside the colour (an image over the
right colour looks exactly like the wrong colour), and
`--lwt-accent-color-inactive` is set as well, or an unfocused window is
the one part still looking like stock Firefox.

## What this can and cannot match

It can give Firefox the shell's colours, radii, spacing, weights and the
accent seam. It **recolours** Firefox's icons; it does not replace them
with the shell's own monoline glyphs. Doing that means overriding
`list-style-image` on every button with an inline SVG, which is possible
— the pack is right there in `shell/quickshell/modules/icons` — but it is
thirty-odd icons and a half-finished set looks worse than a consistent
borrowed one. Ask if you want it.

Web content is never touched, and neither is anything a page draws for
itself.

## If something looks wrong

The stylesheets name Firefox's own internal element ids, and Firefox
renames them between releases without notice — it is not a public
interface. When a release moves one, the rule that named it stops
matching and that one piece of chrome goes back to looking like stock
Firefox while everything around it stays themed.

That is the expected way this breaks, and it is easy to chase:

1. open the Browser Toolbox — `Ctrl+Shift+Alt+I`, after enabling it in
   Settings → Developer, or set `devtools.chrome.enabled` to true
2. inspect the piece that went back to stock
3. the id or class it really has now goes in the matching section here

Each section of `userChrome.css` is labelled for that reason. Firefox's
own `--toolbar-*`, `--tab-*` and `--panel-*` variables are set as well as
the explicit rules: where those still exist they do the work for free,
including in places these files never name, and where one has been
renamed it is simply ignored.

There is deliberately no `@namespace` line at the top. The usual advice
adds one for the XUL namespace and it breaks the address bar, which is an
HTML input — with a XUL-only namespace every selector below silently
stops matching it.

## What this does not touch

Web content. `userContent.css` restyles `about:` pages, the error pages,
the reader and view-source, and nothing else — a site's own colours are
the site's business.
