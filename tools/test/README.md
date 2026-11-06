# Testing the Rust rewrite, and switching to it

Two things, both through `tools/hyprshell-dev`:

## Switching between the Quickshell shell and the Rust one

```sh
tools/hyprshell-dev status              # which is in use
tools/hyprshell-dev use rust            # the Rust shell and Settings, now
tools/hyprshell-dev use quickshell      # back
tools/hyprshell-dev use rust settings   # only Settings (from the Quickshell shell)
tools/hyprshell-dev use rust greeter    # the login screen too (sudo; from next boot)
tools/hyprshell-dev build               # after pulling: rebuild what the switch runs
tools/hyprshell-dev logs                # the Rust shell's log
```

The choice is kept in `~/.config/hyprshell/engine`, and `start-shell.sh` reads
it whenever the shell starts (at login too). If the Rust shell keeps
crashing — three times in two minutes — the Quickshell one takes over by
itself and a notification says so, so trying it can't leave you without a
desktop. The Rust programs run from `~/.local/share/hyprshell/rust/bin`,
built from this checkout.

## The tests

```sh
tools/hyprshell-dev test                # everything
tools/hyprshell-dev test lock greeter   # some areas: unit lock greeter settings shell
tools/hyprshell-dev test --list         # what each area tests
tools/hyprshell-dev test --accept       # this run's screenshots become the references
tools/hyprshell-dev test --keep         # keep the test folder afterwards
```

Needs `sway`, `grim` and `python3` besides cargo (`sudo pacman -S --needed
sway grim python`). Nothing shows on screen and nothing of yours is touched:
the tests run in a private headless sway with their own home folder, and
only ever stop programs they started themselves.

What it does: builds the shell (with `--features test-hooks`, in its own
target folder — the only build with stand-ins for PAM and the clock), then
drives the shell, Settings and the login screen with a virtual pointer and
keyboard, against stand-ins for what can't be there: `hyprshell-daemon`,
`hyprctl`, `pactl`, `systemctl`, greetd and PAM (`fakes/`). Each test checks
what happened — a password refused, a session started with the right
command, a setting written, nothing left running, nothing crashed — and
takes screenshots, compared with the last accepted ones.

Screenshots are compared per machine (fonts and rendering differ between
machines): the first run on yours makes the references, in
`~/.local/share/hyprshell/test-ref`, and later runs report any screenshot
that differs. After a change that's meant to look different, look at the
report and run `--accept`.

The report is printed, and written with each failure's screenshots, the
differences drawn in red, and the logs, to
`$XDG_RUNTIME_DIR/hyprshell-test/`. Exit status 0 when everything passed.

The same runs on every push (`.github/workflows/test.yml`).

## Adding a test

A test is a `test_…` function in `scenarios/<area>.sh`; `lib.sh` lists what
it can use (start the shell, Settings or the login screen, send a command,
click, type, wait, check a log, take a screenshot). The stand-in PAM accepts
the password `testpw`; the stand-in greetd wants `testpw` then the code
`123456`.

What these can't test: your own hardware (the G14, NVIDIA, HDR, the IR
camera, asusd, real sound), Hyprland itself (sway stands in, and Hyprland's
commands are stood in for), and greetd starting at boot.
