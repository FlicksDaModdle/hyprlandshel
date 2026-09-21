# Hyprshell

A QML/Quickshell implementation of the "Hyprshell" desktop mocked up in
Claude Design (see `../chats/` and `../project/Hyprshell Live.dc.html` for
the source design and its history). Built step by step per module, wired to
real system state rather than mock data.

## Layout

```
shell/
  hypr/
    hyprland.lua        Hyprland 0.55+ Lua config (window manager)
  quickshell/
    shell.qml            Entry point
    config/
      Appearance.qml      Design tokens (colors, radii, dock/launcher geometry) — pragma Singleton
      Apps.qml             Pinned dock/launcher apps: icon, exec, appId match regex
      Commands.qml          Shell-level shortcuts shown in the launcher (theme, lock, reload)
      UiState.qml            Cross-module runtime toggles (launcher/overview/settings open)
    modules/
      dock/
        Dock.qml            The floating dock
        DockTile.qml         Reusable pinned/unpinned/utility tile
      launcher/
        Launcher.qml         Start menu / Launchpad hybrid
      icons/
        IconPaths.js          Bespoke 24x24 monoline icon pack (path data)
        MonoIcon.qml           Renders one icon from IconPaths.js as a themed Qt Quick Shape
```

## Install

```sh
mkdir -p ~/.config/hypr ~/.config/quickshell
cp shell/hypr/hyprland.lua ~/.config/hypr/hyprland.lua
cp -r shell/quickshell ~/.config/quickshell/hyprshell
```

Requires Hyprland ≥ 0.55 (Lua config) and Quickshell. `hyprland.lua`
autostarts the shell (`qs -c hyprshell`) and routes a few keybinds into it
over Quickshell's IPC (`qs ipc call shell <fn>`) — see the "KEYBINDINGS"
section for the full list.

The dock/launcher's pinned apps (`quickshell/config/Apps.qml`) assume
`foot`, `nautilus`, `firefox`, `neovide`, `obsidian`, and `ncmpcpp`. Edit
`exec` / `match` there to whatever you actually run — `match` is tested
against each window's Wayland `appId`.

Text uses Inter; install an `inter-font` / `fonts-inter` package (Quickshell
can't pull it from Google Fonts like the original browser mockup did).

## Status

Built so far:
- **Dock** — Start/launcher toggle, task-view toggle, pinned apps with live
  running/active state and window-count indicators from
  `Quickshell.Wayland.ToplevelManager`, unpinned-but-running apps, Settings
  shortcut, bottom/left positioning, auto-hide.
- **Launcher** — Start menu / Launchpad hybrid, no background blur/dim
  (click anywhere else to close). Pinned row uses the same bespoke icons as
  the dock (`Apps.pinned` + `Commands.items`: toggle theme, lock, reload
  shell — all real, in-process or `execDetached` actions). Search / "All
  apps" reads genuine installed applications from
  `Quickshell.DesktopEntries`, not mockup demo data — icons resolve via
  `Quickshell.iconPath()` with a monogram fallback. Enter launches the top
  result, or runs the typed text as a raw command if nothing matches.

Everything else the mockup shows — top bar, control center, notifications,
calendar, power menu, settings, lock screen — is still just the design, not
yet built.

Known gaps in what's built:
- "Show desktop" is a stub — Hyprland has no built-in minimize-all
  dispatcher, needs a helper script.
- The mockup's launcher also has a "Recommended / recent files" section and
  a paginated 24-item pinned grid — both were mockup demo data with no real
  backend (recent-files tracking, a broader "shortcuts" system), so they're
  left out rather than faked. Pinned is just `Apps.pinned` + `Commands.items`
  (10 real items, single page).
- Launcher clicks always launch a new instance rather than focusing an
  existing window — the dock's toplevel-matching logic (running/active
  state per pinned app) wasn't duplicated here.
- Settings/Overview toggles in `UiState.qml` have nothing to open yet —
  they'll be consumed once those modules exist.
- `Appearance.qml` isn't persisted (no `theme.json` read/write yet) —
  that lands with the Settings module, which is what actually edits it in
  the mockup.
- Untested: there's no Hyprland/Quickshell runtime available to compile
  this against here, so it's grounded in the current Quickshell/Hyprland
  docs rather than a build (the dock *has* been runtime-tested by the user
  and a few real bugs fixed from actual error output — the launcher hasn't
  been yet). Flag anything that doesn't load and it can be fixed against
  the real error.
