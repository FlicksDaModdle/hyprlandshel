.pragma library

// Which of the shell's glyphs (IconPaths.js) stands for a window class or a
// program name. The first block is the dock's own list, kept the same so an
// app looks the same here as it does there (shell/quickshell/config/
// Apps.qml, glyphHints); the second covers what the dock never shows —
// daemons, shells and the like.
var hints = [
    { re: /term|foot|kitty|alacritty|wezterm|konsole|tmux/i,        icon: "terminal" },
    { re: /nautilus|thunar|dolphin|nemo|pcmanfm|files|ranger/i,     icon: "folder" },
    { re: /firefox|chrom|brave|epiphany|zen|browser|webkit/i,       icon: "globe" },
    { re: /code|nvim|neovide|vim|zed|jetbrains|emacs|idea|studio/i, icon: "code" },
    { re: /obsidian|logseq|notes|texteditor|gedit|writer/i,         icon: "stickyNote" },
    { re: /spotify|music|mpd|ncmpcpp|audacious|amberol|rhythmbox/i, icon: "music" },
    { re: /pavucontrol|volume|audio|helvum|easyeffects/i,           icon: "sliders" },
    { re: /settings|control|config|tweaks/i,                        icon: "settings" },
    { re: /image|viewer|loupe|eog|imv|gwenview|gimp|inkscape/i,     icon: "image" },
    { re: /video|mpv|vlc|celluloid|obs/i,                           icon: "monitor" },
    { re: /discord|telegram|signal|element|slack|chat|mail|thunderbird/i, icon: "stickyNote" },
    { re: /steam|game|lutris|heroic|wine|proton/i,                  icon: "gamepad" },
    { re: /bluetooth|blueman/i,                                     icon: "bluetooth" },
    { re: /network|nm-|wifi|wpa_supplicant|iwd/i,                   icon: "wifi" },
    { re: /screenshot|grim|slurp|capture|flameshot/i,               icon: "camera" },
    { re: /pkg|package|software|discover|store|pamac|pacman|yay|paru/i, icon: "package" },
    { re: /monitor|htop|btop|system|resources|task/i,               icon: "cpu" },

    { re: /^(pipewire|wireplumber|pulseaudio)/i,                    icon: "volume" },
    { re: /^(bash|zsh|fish|sh|dash|nu|elvish)$/i,                   icon: "terminal" },
    { re: /^(hyprland|xwayland|qs|quickshell|hypridle|hyprlock)$/i, icon: "monitor" },
    { re: /^(systemd|dbus|polkit|udev|login|journald)/i,            icon: "settings" },
    { re: /^(sshd?|gpg|keyring|ssh-agent|gnome-keyring)/i,          icon: "key" },
    { re: /^(python|node|java|ruby|perl|php|deno|bun)/i,            icon: "code" },
    { re: /^(docker|containerd|podman)/i,                           icon: "package" },
    { re: /^(cups|printer)/i,                                       icon: "file" },
    { re: /^(upower|power|tlp|asusd|supergfxd)/i,                   icon: "zap" },
    { re: /^kernel$/i,                                              icon: "cpu" }
];

function forHint(hint) {
    hint = hint || "";
    for (var i = 0; i < hints.length; ++i) if (hints[i].re.test(hint)) return hints[i].icon;
    return "square";
}
