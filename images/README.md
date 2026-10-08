# Hyprshell Images

The image viewer, in the shell's design and following its theme. Installing
it makes it what opens pictures.

    ./install.sh                build, install to ~/.local, make it the default
    ./install.sh --no-default   install, but leave the default viewer alone
    ./install.sh --check        what is missing, building nothing

It opens a picture and the rest of its folder with it, in the order a
person would number them (2 before 10).

| | |
|---|---|
| ← → · Page Up/Down · Space | previous and next |
| Home · End | first and last |
| wheel · pinch · + − | zoom, about the pointer |
| double-click | look closer, or fit again |
| drag · two fingers | move about a zoomed picture |
| sideways swipe | previous and next, when it fits |
| 0 · 1 | fit · one picture pixel per screen pixel |
| R · Shift+R | turn (on screen only, for now) |
| F · F11 | full screen |
| I | info |
| Ctrl+C | copy the picture |
| Delete | move it to the bin |
| Ctrl+O | open another (Hyprshell Files' dialog), or drop one on the window |

The title bar also shows it in its folder, and sets it as the shell's
wallpaper. GIF, animated WebP and APNG play.

Formats are whatever Qt can read: PNG, JPEG, GIF, BMP and more out of the
box; WebP and TIFF with qt6-imageformats; SVG with qt6-svg; AVIF, HEIC and
JPEG XL with kimageformats.

Editing is next.
