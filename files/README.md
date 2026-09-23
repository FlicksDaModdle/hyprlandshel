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
`customAccent`, `rounding`, `fontScale` and `textNative`. Note that `accent`
there is an **index** into the shell's four presets, not a colour, with `-1`
meaning "use `customAccent`" — reading it as a colour is what once turned
the New button black. Changing the theme in the shell's Settings repaints
this window without restarting it. The window
remembers its view, sort order, hidden files, tile size, bookmarks and which
terminal "Open in terminal" should use.

## Keys

`Ctrl+A` select all · `Ctrl+C`/`X`/`V` copy, cut, paste · `Ctrl+H` hidden
files · `Ctrl+L` type a path · `F2` rename · `Delete` to trash · `Backspace`
up · `Enter` open · `Escape` clear the selection, then close.

Right-click a file or the folder's empty space for the rest.

## Seeing it without a display

    HYPRSHELL_FILES_SHOT=/tmp/x.png QT_QPA_PLATFORM=offscreen \
        QT_QUICK_BACKEND=software hyprshell-files ~/Downloads

Grabs the window once the first frame has settled, writes the PNG and exits.
This is how the screenshots in this repository are made, and how a rendering
problem gets looked at from a terminal.

## Not in this version

Thumbnails for anything but images, mounting removable or network volumes,
tabs, split panes, search, and archive extraction.
