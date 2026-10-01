# Hyprshell

A Hyprland desktop built from a single design: a Quickshell shell, a matching
terminal, a file manager, a task manager, a browser and a login screen.

    shell/    the shell — bar, dock, launcher, panels, settings, lock screen,
              plus the Hyprland and kitty configuration it assumes
    term/     the terminal
    files/    the file manager, a standalone Qt 6 application
    tasks/    the task manager — processes, performance, services, startup
    browser/  Hyprshell Browser — Firefox's engine with the design's interface
    greeter/  the login screen, run by greetd, in your theme

Each has its own README and its own `install.sh`. The shell works without the
file manager; the file manager works without the shell, and picks up the
shell's theme when it is there.
