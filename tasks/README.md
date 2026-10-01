# Task Manager

`hyprshell-tasks` — what is running, what it costs, and why the machine is
slow. A standalone Qt 6 application in the shell's design; it picks up the
shell's theme when the shell is installed. The feature list started from
[tmog.org](https://tmog.org/)'s and was rebuilt for Linux.

    ./install.sh            build and install to ~/.local
    ./install.sh --check    say what is missing

With the shell's Hyprland config, **Ctrl+Shift+Esc** opens it.

## Views

- **Summary** — one sentence on whether anything is holding the machine up
  (from the kernel's pressure-stall figures, memory, swap, disks, heat,
  throttling, battery), the devices at a glance, and what is busiest.
- **Processes** — grouped by app (windows matched to their processes), as a
  tree, or flat. CPU, memory, disk, GPU and a power estimate per row, heat
  tinted; ended processes linger briefly so you see what just quit. End,
  kill, suspend, priority, CPU affinity, efficiency mode, open the file
  location, go to the window — "as administrator" through polkit when the
  process is someone else's.
- **Performance** — processor (per core), memory, each disk, each network
  interface, each GPU (a sleeping NVIDIA card is read without waking it),
  battery.
- **App history** — the CPU time, GPU time and disk traffic each app has used, kept across
  restarts.
- **Startup apps** — the XDG autostart entries: turn off, add, remove.
- **Services** — systemd system and user units: start, stop, restart,
  enable, disable, logs.
- **Users** — sessions and what each user is running.
- **System info** — hardware, firmware, kernel, distribution.

And under *More*: **Power & frequency** (platform profile, governor and
energy preference, per-core clocks, charge limit, temperatures, fans),
**Connections** (every socket and the process that owns it), **Installed
apps** (pacman and Flatpak, with sizes), **Drivers** (devices and the kernel
module bound to each), **Disk space** (what fills each filesystem, as a
treemap), **Benchmarks** (processor, memory, disk — each result kept to
compare against) and the **Flight recorder**.

## Flight recorder

Turned on in its view, a small background service
(`hyprshell-tasks-recorder.service`, lowest CPU and I/O priority) samples
the whole machine every 5 seconds and keeps the last few days in
`~/.local/share/hyprshell-tasks/recorder/`. After a stall, open the day and
move along the graphs: each moment shows what was busiest.

## Command line

    hyprshell-tasks --view performance       open on a view
    hyprshell-tasks --bench cpu|memory|disk [folder]
    hyprshell-tasks --record                 the recorder itself

Settings live in `$XDG_CONFIG_HOME/hyprshell-tasks/settings.json`.

## What it needs

Qt 6.2+ (Base, Declarative), and at run time whatever each feature reads:
systemd for services and the recorder, polkit (`pkexec`) for administrator
actions, pacman/flatpak for installed apps, `nvidia-smi` for NVIDIA cards,
`hwdata` for device names. Each missing one only takes away its own feature.

Administrator actions need a polkit agent. The shell has one built in
(Quickshell's polkit service); if your Quickshell build lacks it, run any
other agent, such as `hyprpolkitagent`.
