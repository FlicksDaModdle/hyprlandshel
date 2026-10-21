# Boot menu theme (Limine)

Your desktop's wallpaper and accent in the Limine boot menu.

    sudo shell/limine/install.sh              install the helper (once)
    sudo shell/limine/install.sh --check      what it would write to; changes nothing
    sudo shell/limine/install.sh --uninstall  put the boot menu back and remove it

Then **Settings → Wallpaper → Boot menu → Update**, and again whenever you
want the boot menu to follow a new wallpaper. It asks for your password
each time: it writes to the boot partition.

## What it does

The shell makes a still of whatever the desktop shows: the picture itself,
a frame of the live video, or the gradient, map or animation it draws,
filled to the main display's size (at most 2560 wide). It goes to
`hyprshell-limine-theme`, a small root helper run through pkexec, which:

- writes it to `<boot partition>/hyprshell/wallpaper.png`;
- puts a block of global options at the top of `limine.conf`, between
  `# >>> hyprshell` and `# <<< hyprshell`: the wallpaper, a dark veil
  behind the menu's text, and your accent for the title and highlights;
- keeps `limine.conf` as it was before the first change beside it, as
  `limine.conf.hyprshell-orig`.

Nothing else in `limine.conf` is touched, and **Remove** takes the block and
the picture out again.

The helper takes the picture on stdin, never a path, and checks it is a PNG
under 16 MB; the colours are checked to be colours. It refuses a Limine 7
style config, and a config whose checksum is enrolled into Limine (Secure
Boot) unless `limine-enroll-config` is there to enroll the new one; if that
fails, the old file is put back.

If your distribution regenerates `limine.conf` on kernel updates and drops
the block, press Update again.
