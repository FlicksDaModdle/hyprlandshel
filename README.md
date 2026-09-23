# Hyprshell

A Hyprland desktop built from a single design: a Quickshell shell, a matching
terminal, and a file manager.

    shell/    the shell — bar, dock, launcher, panels, settings, lock screen,
              plus the Hyprland and kitty configuration it assumes
    files/    the file manager, a standalone Qt 6 application

Each has its own README and its own `install.sh`. The shell works without the
file manager; the file manager works without the shell, and picks up the
shell's theme when it is there.
