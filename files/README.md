# Hyprshell Files

The file manager from the Hyprshell concept, as its own application.

    hyprshell-files [directory]

It was part of the shell to begin with. It is separate now because a file
manager is an ordinary window: the compositor should tile it, focus it and
apply window rules to it like anything else, and a drag out of it should
reach other applications. A shell surface is none of those things — a
layer-shell surface is not a drag source at all — so the window moved out
and the shell simply launches it.

## Installing

    ./install.sh              # build, install to ~/.local
    ./install.sh --check      # report what is missing, build nothing
    ./install.sh --prefix /usr/local

It needs Qt 6.2 or newer (`qt6-base`, `qt6-declarative`, with their
development parts), cmake, and a C++17 compiler. At runtime it needs `gio`,
which comes with glib and is almost certainly already there.

To make it the handler for folders:

    xdg-mime default hyprshell-files.desktop inode/directory

## What it is made of

The interface is the shell's, unchanged: the same QML, the same monoline
icon pack, the same treatment of a selected thing — a quiet fill with an
accent rule under it. What was Quickshell underneath is now about three
hundred lines of C++:

    Proc      run an argv, collect or stream its output
    Sys       the environment, a detached launch, reading and writing a file
    Watcher   tell me when this file changes

Everything that touches the disk still goes through the same tools a GTK
file manager uses:

    gio trash     gio rename    gio mkdir    gio open    gio monitor

so deleting means the real freedesktop trash, restorable from here or from
any other file manager, and files something else creates appear without a
refresh. Copy and move are `cp -a` and `mv` with `--backup=numbered`, not
`gio copy`, which cannot copy a directory at all and has no conflict policy
fit for a window.

Listing is `find -printf ... \0`, not `gio list`: one line per file cannot
represent a name containing a newline, and a line-based reader invents a
file that does not exist. Every operation is run against a directory of
deliberately awful names — newline, tab, leading dash, quote, space, and one
called `; rm -rf ~` — as part of the test suite.

## Settings

Two files, and it only ever *reads* the first:

    ~/.config/quickshell/hyprshell/theme.json    the shell's theme, followed live
    ~/.config/hyprshell-files/settings.json      its own

With no shell installed it uses the design's own colours.

From `theme.json` it takes `theme` (light / dark / auto), `accent`,
`customAccent`, `rounding`, `fontScale`, `textNative` and `translucency`.
Note that `accent`
there is an **index** into the shell's four presets, not a colour, with `-1`
meaning "use `customAccent`" — reading it as a colour is what once turned
the New button black. Changing the theme in the shell's Settings repaints
this window without restarting it. The window
remembers its view, sort order, hidden files, tile size, pinned folders and which
terminal "Open in terminal" should use.

## Blur

The window body is the shell's `sheet` colour, and `translucency` in
theme.json decides how much of it you can see through — the same slider,
the same formula, so this window and the shell's panels are the same
material. Hyprland does the rest: `decoration:blur` in `hyprland.lua` is
already on, and the compositor blurs behind any window that has
transparency, so there is no window rule to add. Setting translucency to 0
makes it solid again and the blur has nothing to work on.

## Selecting

Click, `Ctrl`-click to add one, `Shift`-click for a range from the last
thing you picked, or drag across the empty space to sweep up whatever the
band touches. `Ctrl+A` selects everything, and the right-click menu will
invert it.

Dragging carries a picture of what you are dragging: a small chip with the
file's glyph, its name, and `+n` when there is more than one. The same chip
in both views — grabbing the delegate itself gave a neat square in the grid
and a full-width strip in the list, so one gesture looked like two.

## The sidebar

PLACES is your XDG user directories, read from `user-dirs.dirs` rather
than guessed, so a translated or relocated `~/Bilder` appears under its own
name. PINNED is whatever you put there: right-click a folder and "Add to
sidebar", or `Ctrl+B` to pin the folder you are in. Take one out again from
the same menu, or with the × that appears when you hover the row — only on
pinned rows, because the standard places are not yours to remove. Dropping
files on any row moves them into that folder.

## Keys

| | |
|---|---|
| `Ctrl+A` | select all |
| `Ctrl+C` / `X` / `V` | copy, cut, paste |
| `Ctrl+D` | duplicate |
| `Ctrl+N` | new folder |
| `Ctrl+F` | filter this folder |
| `Ctrl+L` | type a path |
| `Ctrl+I` | properties |
| `Ctrl+B` | put this folder in the sidebar, or take it out |
| `Ctrl` `+` / `-` / `0` | tile size, and back to normal |
| `Ctrl+H` | hidden files |
| `F2` | rename |
| `F5` | reload |
| `Delete` | to the trash |
| `Shift+Delete` | delete permanently, after asking |
| `Backspace` | up a folder |
| `Enter` | open |
| `Home` / `End` | first, last — with `Shift` to extend |
| `Page Up` / `Down` | a screenful |
| any letter | jump to the next name starting with it |
| `Escape` | unwinds: a confirmation, properties, the filter, the selection, the window |

Right-click a file or the folder's empty space for the rest: open with,
copy path, duplicate, rename, trash, delete permanently, properties, and on
a folder, add it to the sidebar; and on the folder's own space, new folder,
new file, paste, open in terminal, add this folder to the sidebar, select
all, invert, hidden files.

## Icons

Every glyph is drawn from the pack in `qml/IconPaths.js` — a 24-unit grid,
a 2-unit ink stroke and one accent element that is the identifying mark.
Nothing is loaded from an icon theme, so the window looks the same on any
machine.

What a file *is* gets decided in this order, and the Type column follows
exactly the same route so the words and the glyph cannot disagree:

1. the whole name — `Makefile`, `LICENSE`, `README`, `.gitignore`
2. a checksum list, by pattern — `SHA256SUMS`, `sha512sum.txt`, `MD5SUM`
3. a two- or three-part suffix — `.tar.gz` is a tar, not a gzip
4. the last suffix
5. the execute bit, from `find`'s `%m` — a downloaded binary with no
   suffix is a **Program**, not a blank page

Archives and packages are deliberately different glyphs: "can I open this"
and "can I run this" are not the same question. `iconcheck.js` asserts that
every name the tables ask for exists in the pack, because `MonoIcon` draws
an unknown name as nothing at all and says nothing about it.

### Why they are not SVG files

They are vectors already. Every glyph is SVG path data — `PathSvg` inside a
`QtQuick.Shapes.Shape` — rasterised by Qt at whatever size it is asked for.
There is no bitmap anywhere and nothing to lose by scaling. Loading the same
paths from `.svg` files through `Image` would change nothing about sharpness
and would cost two things worth keeping: the ink/accent split, which lets a
glyph follow the theme's accent live, and the pre-merging that draws a whole
glyph in two or three `Shape`s instead of one per stroke.

So the softness was never the format. It was the stroke width:

    stroke in device pixels  =  2 units × size / 24  =  size / 12

At size 13 that is 1.08 pixels, at 17 it is 1.42. A stroke thinner than two
pixels cannot be drawn solid by any renderer — it lands across two pixel
rows at partial coverage, so instead of a line you get two grey half-lines.
That is what "low quality" looked like, and no amount of vector purity
fixes it.

`MonoIcon` now compensates: the authored stroke widens as the glyph shrinks,
so every glyph lands **2 device pixels** wide whatever its size, and keeps
the authored proportion above size 24 where that is already thicker.
Measured on the same glyph at the same 17px, that is 29% more ink on the
screen. It also asks for `Shape.CurveRenderer`, which antialiases curves
analytically in the shader rather than triangulating them — set from JS
behind a guard, because naming that property is a load error on Qt below
6.6 and this still has to run there.

`monocheck.sh` asserts the 2px floor across ten sizes in both copies of the
pack, and that every `Shape` asks for the curve renderer.

### Sizes

With the stroke fixed, the sizes went up too: the list draws its glyph at 22
in a 34px plate on a 46px row, the grid at 30 in a 52px plate, the sidebar
at 20, and the chrome at 15–20 in 30px buttons.

The view switch used `layout` for its list mode — four blocks of different
sizes, which beside `grid`'s four blocks made a segmented control whose two
options looked identical. The concept draws it that way too; it is a `list`
glyph here instead, on the grounds that a control you cannot read is not a
design decision worth keeping.

## Measurements

The window follows the concept's own numbers rather than approximating
them: a 192px sidebar, a 48px toolbar ruled off from the view, 28px
controls, a breadcrumb that is the hover tint with a hairline rather than a
solid fill, the view switch as one segmented group, icon plates with a 1px
inset rule, 11px tile labels on one line, and a 32px status bar. The plates
are the one departure: the concept's 38px grid plate and its 26px row plate
both drew their glyph too faintly to tell one file from another, so they
are 44 and 30.

Selection is marked the way the concept marks it — a rule inset 10px from
each side and lifted 3px off the bottom, over a quiet fill. Not a
full-width underline, which reads as a divider between rows rather than a
mark on one. In the list the fill carries it alone, since every row there
is already ruled.

## The list view

Click a column heading to sort by it, click it again to reverse. Name, Size,
Type and Modified — the concept has three, and Type is the one addition,
styled to match.

Names sort the way you would count them: `hyprshell(2).bundle` before
`hyprshell(10).bundle`, not after it. Qt's JavaScript engine has no
numeric collation — `localeCompare` accepts the option and ignores it — so
the comparison is written out: a name is split into runs of digits and
runs of everything else, digit runs compare as numbers, and equal numbers
fall back to the padding, so `01` sorts before `1` exactly as `ls -v`
does. In the trash the columns are replaced by where each thing
came from, because that is the only question worth asking about something
you have deleted.

## Grouping by date

Sort by Modified and the listing breaks into Today, Yesterday, Earlier this
week, Last week, Earlier this month, Earlier this year and Older — the same
bands Windows Explorer uses, because forty rows of timestamps read as forty
rows of timestamps otherwise. Folders keep their own band at the top, since
they sort ahead of files regardless.

The boundaries are local midnights, not "24 hours ago": a file from 11pm
last night is Yesterday at 9am, not Today. Right-click the folder's empty
space to turn it off; the option only appears under the date sort, where it
does something.

The headings are a lookup beside the list rather than rows spliced into it
— selection, shift-ranges, type-ahead and the drag all index into the same
entry list, and every one of them would otherwise have to learn to step
over a heading.

## Show in file manager

"Open Containing Folder" in Firefox, "Show in file manager" anywhere else,
and `gio open` on a selection do not run a command — they call
`org.freedesktop.FileManager1` over D-Bus. Dolphin and Nautilus register
it, which is why they kept answering even after this became the default
handler for `inode/directory`: the MIME default decides who opens a
*folder*, and that interface decides who is asked to *reveal* something.
Two questions; the answer had only been given to one.

This registers it now, with the three methods the spec names —
`ShowFolders`, `ShowItems`, `ShowItemProperties` — and a D-Bus service file
so the bus can start it when nothing is running. `ShowItems` goes to the
containing folder and selects the item; `ShowItemProperties` opens the
sheet on it as well.

If Dolphin or Nautilus is already running it will have taken the name
first, and this says so on stdout rather than failing quietly — the symptom
otherwise is "it still opens the wrong thing".

## The list view's columns

Drag the divider to the left of a heading to resize that column. Name has
no width of its own — it takes whatever is left — so widening Size narrows
Name, which is what dragging the divider between them means. Widths are
kept between 56 and 280 and remembered in settings.json.

Hovering a name that was too long for its column shows the whole thing
after a moment. Only when it is actually elided: a tooltip repeating a
name you can already read is noise on every row you pass over.

## Archives

Laid out the way 7-Zip lays it out, in the shell's colours.

Right-click → **7-Zip ▸** is 7-Zip's Explorer menu: **Open archive**,
**Extract files…**, **Extract Here**, **Extract to "name/"**, **Test
archive**, **Add to archive…**, **Add to "name.7z"**, **Add to "name.zip"**
and **CRC SHA ▸** (CRC-32, CRC-64, SHA-1, SHA-256, BLAKE2sp, or all of them,
in 7-Zip's "Checksum information" window, with Copy).

**Add to Archive** is 7-Zip's dialog: archive name and "…", format (7z, zip,
tar, wim, tar.gz/xz/zst/bz2), compression level (Store to Ultra), method,
dictionary, word and solid block sizes (filled in with 7-Zip's own defaults
for the level), CPU threads, its memory estimates, split to volumes,
parameters; update mode, path mode, delete files after compression; and the
Encryption box — password twice, show password, method (ZipCrypto or AES-256
for zip) and encrypt file names (7z).

**Extract** is 7-Zip's too: extract to (with "…" and the folder-name box),
path mode, eliminate duplication of root folder, overwrite mode (ask, overwrite,
skip, auto rename, auto rename existing) and password. "Ask before overwrite"
puts up 7-Zip's **Confirm File Replace** — Yes, Yes to All, No, No to All, Auto
Rename, Cancel — with both files' sizes and dates.

Double-clicking an archive opens it as 7-Zip's file manager does: Extract,
Test, Delete and Info on the toolbar, the path inside the archive with ↑, and
its columns — Name, Size, Packed Size, Modified, Attributes, Encrypted, CRC,
Method — sortable, with ctrl- and shift-click selection and the status bar
counts. A file inside opens by double-click (unpacked to a temporary folder,
as 7-Zip does). An encrypted archive asks for its password first.

Work shows in 7-Zip's progress window: elapsed and remaining time, files,
total size, speed, processed, compression ratio and compressed size, the file
it is on, and **Background**, **Pause** and **Cancel**. It closes itself when
the job succeeds; a test stays to say "There are no errors", a failure stays
with 7-Zip's errors. Sent to the background, a job becomes a card in the
corner with Show, Pause and Cancel. A cancelled or failed new archive is not
left behind half-written, and adding to an existing one never deletes it.

[7-Zip](https://www.7-zip.org) does the work — `7zz` (the `7zip` package) or
`7z` (p7zip) — and so everything it reads opens: RAR, ISO, CAB, WIM, DEB, JAR
and more. tar formats go through GNU tar. Without 7-Zip, tar archives still
work and ZIP and 7z say what to install. Passwords are handed to 7-Zip on its
stdin, never on its command line, where any user on the machine could read
them.

## Properties

`Ctrl+I`, or the menu. Type, size, location, modified, permissions, owner,
and for a symlink what it points at. A folder's size is counted properly —
`du` over everything inside it, not the size of the directory entry — which
is why it says "counting…" for a moment on a large one.

## Seeing it without a display

    HYPRSHELL_FILES_SHOT=/tmp/x.png QT_QPA_PLATFORM=offscreen \
        QT_QUICK_BACKEND=software hyprshell-files ~/Downloads

Grabs the window once the first frame has settled, writes the PNG and exits.
This is how the screenshots in this repository are made, and how a rendering
problem gets looked at from a terminal.

## "Could NOT find WrapVulkanHeaders"

Qt 6 Gui asks CMake for the Vulkan headers whether or not anything uses
them, and prints this when they are absent. Nothing here touches Vulkan.
On most builds of Qt the line is a status message and the build carries on
— verified by removing the headers, configuring (exit 0), building, and
running the result. On a Qt that marks the dependency required it stops the
configure instead, and the message looks identical either way, so
`install.sh` now tells you which one you are looking at.

Installing them settles it in both cases:

    sudo pacman -S --needed vulkan-headers      # Arch
    sudo apt install libvulkan-dev              # Debian, Ubuntu
    sudo dnf install vulkan-headers             # Fedora
    sudo zypper install vulkan-devel            # openSUSE

`Could NOT find XKB` from the same configure is the same kind of line and
needs nothing.

## If a keybind launches nothing

Almost always PATH. `install.sh` puts the binary in `~/.local/bin` by
default, and that directory is frequently absent from the environment
Hyprland itself was started in — which is not the one your terminal has. So
the command works when you type it and does nothing from a bind.

    hyprshell-files            # works in a terminal
    Super + E                  # ...and does nothing

The shell's keybind and dock tile look on PATH first and then in
`~/.local/bin`, `/usr/local/bin` and `/usr/bin`, so this should not bite.
To check what Hyprland can see:

    hyprctl dispatch exec 'sh -c "command -v hyprshell-files > /tmp/found; \
        echo $PATH >> /tmp/found"' && cat /tmp/found

Installing to a prefix already on PATH avoids the question entirely:

    ./install.sh --prefix /usr/local     # needs write access there

## "Could not register app ID"

    qt.qpa.services: Failed to register with host portal
    QDBusError(... "App info not found for 'hyprshell-files'")

Harmless. Qt tells the desktop portal which application it is so that file
choosers and notifications can attribute themselves; the portal answers that
it has no record of one by that name. The window opens and everything works
regardless — it is a line on stderr, not a failure.

It goes away once the desktop entry is somewhere the portal looks and the
database has been refreshed, which `install.sh` does:

    update-desktop-database ~/.local/share/applications

Some portal builds only consult the system directories, in which case
installing with `--prefix /usr/local` silences it and nothing else changes.

## Not in this version

Thumbnails for anything but images, mounting removable or network volumes,
tabs, split panes, search, and archive extraction.
