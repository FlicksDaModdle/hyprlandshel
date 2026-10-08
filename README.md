# Hyprshell

A Hyprland desktop built from a single design: a Quickshell shell, a matching
terminal, a file manager, an image viewer, a task manager, an email app, a
browser and a login screen.

    shell/    the shell — bar, dock, launcher, panels, settings, lock screen,
              plus the Hyprland and kitty configuration it assumes
    term/     the terminal
    files/    the file manager, a standalone Qt 6 application
    images/   Images — the image viewer, and what opens pictures
    tasks/    the task manager — processes, performance, services, startup
    mail/     Mail — Gmail, Outlook and IMAP, with its own background service
    browser/  Hyprshell Browser — Firefox's engine with the design's interface
    greeter/  the login screen, run by greetd, in your theme

![The desktop: bar, dock and Settings → Appearance](docs/screenshots/settings.png)

<table>
<tr>
<td><img src="docs/screenshots/control-center.png" alt="Control center"><br><sub>Control center</sub></td>
<td><img src="docs/screenshots/launcher.png" alt="Launcher, grown out of the dock"><br><sub>Launcher, grown out of the dock</sub></td>
</tr>
<tr>
<td><img src="docs/screenshots/snip.png" alt="Super+Shift+S freezes the screen to choose a shot"><br><sub>Super+Shift+S: the screen frozen to choose a shot</sub></td>
<td><img src="docs/screenshots/notifications.png" alt="Notifications"><br><sub>Notifications</sub></td>
</tr>
<tr>
<td><img src="docs/screenshots/files.png" alt="Files"><br><sub>Files</sub></td>
<td><img src="docs/screenshots/images.png" alt="Images"><br><sub>Images</sub></td>
</tr>
<tr>
<td><img src="docs/screenshots/terminal.png" alt="Terminal"><br><sub>Terminal</sub></td>
<td><img src="docs/screenshots/tasks.png" alt="Task manager"><br><sub>Task manager</sub></td>
</tr>
</table>

<sub>Taken in a headless test compositor without a GPU, so without the blur
behind the bar, dock and panels that Hyprland draws on a real machine.</sub>

## Installing

    ./install.sh

asks which parts you want: a checklist with everything but the login screen
ticked, and an option to install the packages they need first. Or say it on
the command line:

    ./install.sh --all --deps          everything, packages included
    ./install.sh --shell               just the shell
    ./install.sh --shell-only          the shell, keeping your Hyprland config
    ./install.sh --terminal --files    any mix: --shell --terminal --files
                                       --images --mail --tasks --browser
                                       --greeter
    ./install.sh --check --all         what each part is missing, changing nothing
    ./install.sh --list                what is installed already

`--deps` uses pacman on Arch and CachyOS, and paru or yay for anything (such
as quickshell) that is only in the AUR. A part that fails does not stop the
others; the summary at the end says how each went.

Each part also has its own README and its own `install.sh`, which still work
on their own. The shell works without the file manager; the file manager
works without the shell, and picks up the shell's theme when it is there.
