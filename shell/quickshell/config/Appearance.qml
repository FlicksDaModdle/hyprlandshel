pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Design tokens, ported from the Claude Design mockup's CSS custom
// properties ([data-shell] / [data-shell="dark"] in Hyprshell Live.dc.html),
// plus every knob the mockup's Settings → Appearance / Bar / Dock /
// Notifications panes can turn.
//
// Everything the user can change is persisted to theme.json (the same file
// the mockup's Files window shows in ~/.config/quickshell) via a JsonAdapter,
// so a shell reload keeps your theme. Derived colors/radii below are read-only
// and recompute from those values.
Singleton {
    id: root

    // ── persistence ───────────────────────────────────────────────────────
    readonly property string configDir: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
                                        + "/quickshell/hyprshell"

    // Whether it is safe yet to tell the compositor anything derived from
    // these settings.
    //
    // theme.json is read asynchronously, so for the first moments of a
    // session every property here holds its default rather than the
    // user's value. Most of what reads them can wait a frame and look
    // right afterwards. Reserving screen space cannot: a dock that
    // reserved its strip on a default of "auto-hide off" pushed every
    // window aside, and the correction a moment later never reached the
    // compositor — the session stayed offset until auto-hide was toggled
    // by hand. Changing it *after* the surfaces exist does work, which is
    // what toggling by hand was doing.
    //
    // Set by the FileView below when the file has actually been read, with
    // a timer behind it: a read that never finishes — a file on a mount
    // that is not there, a permission that is wrong — would otherwise
    // leave the dock reserving nothing for the rest of the session. The
    // timer is longer than any local read and does no harm when the
    // signal has already done the job.
    property bool settingsReady: false

    // Another theme file to show, read only — the greeter's: the person
    // picked at the login screen's own copy of their theme, kept up to date
    // by their shell (services/GreeterSync.qml). Nothing is written while
    // it is set; if it is not there, the usual file is read instead.
    property string themeFile: ""
    readonly property bool readOnly: themeFile !== ""

    Timer {
        running: !root.settingsReady
        interval: 3000
        onTriggered: root.settingsReady = true
    }

    // Saving, and hearing back about it.
    //
    // Every change used to write the file at once, and the watcher below
    // reported each of those writes as a change from outside and reloaded
    // the file — sometimes a copy from a write or two back. Several values
    // set together (an import, a reset) then lost some of them to an older
    // copy of themselves. Now changes made together go out as one write, a
    // moment later, and the watcher ignores the file changing just after
    // the shell wrote it. An edit by hand still reloads.
    property real lastWrite: 0
    Timer {
        id: saveSoon
        interval: 150
        onTriggered: {
            root.lastWrite = Date.now();
            store.writeAdapter();
        }
    }
    // A change made just before a reload or quit still reaches the file.
    Component.onDestruction: if (saveSoon.running && !root.readOnly) store.writeAdapter()

    FileView {
        id: store
        path: root.themeFile !== "" ? root.themeFile : root.configDir + "/theme.json"
        watchChanges: true
        printErrors: false
        onFileChanged: {
            if (saveSoon.running || Date.now() - root.lastWrite < 2000) return;
            reload();
        }
        onAdapterUpdated: if (!root.readOnly) saveSoon.restart()
        onLoaded: root.settingsReady = true
        // A missing file is normal on first run: write defaults out so the
        // file exists and is editable by hand.
        onLoadFailed: error => {
            if (root.readOnly) {
                // Someone else's theme that isn't there: the usual one.
                root.themeFile = "";
                return;
            }
            if (error === FileViewError.FileNotFound) writeAdapter();
            // Defaults are the answer either way, and they are already
            // here, so nothing is waiting on a file that is not coming.
            root.settingsReady = true;
        }

        JsonAdapter {
            id: prefs

            // Appearance
            property string theme: "light"          // "light" | "dark" | "auto"
            property int accent: 0                    // index into accentPresets, -1 = custom
            property string customAccent: "#3b6ef5"
            // The accent taken from the wallpaper instead (off unless
            // chosen; services/WallpaperAccent.qml): the switch, and the
            // last colours found — one for each theme — with the picture
            // they came from, so a restart does not wait for it again.
            property bool accentFromWallpaper: false
            property string wallAccentLight: ""
            property string wallAccentDark: ""
            property string wallAccentFor: ""
            property int translucency: 50             // 0-100 %, how much shows through panels
            property int rounding: 100                // 0-160 %
            property string tint: "Warm"              // "Warm" | "Neutral" | "Cool"
            property string wallpaper: ""             // absolute path; empty = tinted gradient
            // With no image: the tinted gradient, or a contour map drawn by a
            // shader (modules/background/Topography.qml).
            // gradient | topo | aurora | blobs | waves | stars | synth | cells
            property string wallpaperStyle: "gradient"
            property int topoSeed: 1                  // which terrain
            property int topoScale: 100               // 25-300 %, size of the hills
            property int topoDetail: 4                // 1-6, roughness
            property int topoFlow: 45                 // 0-100 %, how much the ridges wander
            property int topoLevels: 18               // contour lines, lowest to highest
            property real topoWidth: 1.2              // px
            property int topoMajor: 5                 // every Nth line heavier; 0 = none
            property string topoLine: "ink"           // ink | accent | custom
            property string topoLineCustom: "#3b6ef5"
            property int topoStrength: 30             // 5-100 %, lines' opacity
            property string topoShade: "smooth"       // flat | smooth | bands
            property string topoGround: "theme"       // theme | custom
            property string topoLow: "#1d2022"        // custom ground, low and high
            property string topoHigh: "#3a4146"
            property bool topoDrift: true             // the map moving at all
            property int topoSpeed: 30                // 5-100 %
            property string topoMotion: "both"        // drift | flow | both
            property int topoGlow: 0                  // 0-100 %, light around the lines
            // The animated wallpapers (modules/background/AnimatedWallpaper.qml):
            // a palette (a preset's key, "theme" or "custom", with the five
            // custom colours), speed, size, density, glow and brightness in
            // %, a variation, frames a second, and whether to move on battery.
            property string animPalette: "theme"
            property string animBg1: "#0b1020"
            property string animBg2: "#1b2440"
            property string animC1: "#5b8cff"
            property string animC2: "#c36bff"
            property string animC3: "#44e0c8"
            property int animWallSpeed: 100
            property int animScale: 100
            property int animDensity: 50
            property int animGlow: 50
            property int animIntensity: 70
            property int animSeed: 1
            property int animFps: 30
            property bool animOnBattery: false
            property bool animPauseCovered: true     // still behind windows that fill the screen
            // The map's "Animate" was off by default once, so a map chosen
            // for its motion sat still; set on once, the first time round.
            property bool animMigrated: false
            property string animLastStyle: "topo"
            // A video playing on the desktop, drawn over the ground by
            // mpvpaper (services/LiveWallpaper.qml): its path. Empty = none.
            property string liveWallpaper: ""
            // The last image and live wallpaper, so switching Settings →
            // Wallpaper to Gradient and back does not lose them.
            property string wallpaperLast: ""
            property string liveLast: ""
            // Where the videos are: JSON arrays of folders (empty = the
            // default, ~/Videos/Wallpapers) and of single files.
            property string liveFolders: ""
            property string liveFiles: ""
            property bool liveSound: false
            property int liveVolume: 50               // 0-100 %, with sound on
            // Stop playing while windows cover it (LiveWallpaper.paused):
            // "covered" — a tiled, maximised or fullscreen window on every
            // screen it is on — "windows" for any window at all, "never".
            property string livePauseCovered: "covered"
            property bool livePauseOnBattery: false
            property string liveScaling: "fill"       // fill | fit | stretch
            // "same" on every screen, or "each" its own, from
            // liveScreens: { "<output>": "<video>" }.
            property string liveLayout: "same"
            property string liveScreens: ""
            // Moving on to another video every so often.
            property bool liveRotate: false
            property int liveDelay: 30                // minutes
            property string liveOrder: "sequential"   // sequential | random

            // Bar
            property int barHeight: 40                // 32-56 px
            property int workspaceScale: 100          // 60-160 % of the switcher
            // One multiplier over every animation in the shell. 0 turns
            // them off outright rather than making them very fast, since
            // "instant" is what people who turn animations down want.
            property int animSpeed: 100               // 0-250 %
            // Black rounded corners over the screen's own, for a panel
            // whose corners are square against a rounded-looking desktop.
            property bool screenCorners: false
            property int screenCornerRadius: 14       // 2-64 px
            property bool screenCornerTL: true
            property bool screenCornerTR: true
            property bool screenCornerBL: true
            property bool screenCornerBR: true
            property string screenCornerScreens: "builtin" // builtin | all
            // Per-output shell scale, as {"eDP-1": 85, "DP-1": 100}. The
            // compositor's own scale makes everything on that output
            // bigger, the shell included; this is how much of that the
            // shell gives back.
            property string screenScales: ""
            // The bar gets out of the way like the dock does. Off by
            // default: a bar is the thing you glance at, and one that has
            // to be summoned is a choice rather than a kindness.
            property bool barHide: false
            // ms the pointer has to rest on the top edge before a hidden
            // bar comes out; 0 is straight away.
            property int barRevealDelay: 350
            // Sound: how far one press of a volume key moves the level, in
            // percent; whether it may go past 100% (PipeWire's software
            // boost — louder, at the cost of clipping); and a tick from the
            // speakers on each press, so a level can be judged by ear.
            property int volumeStep: 5
            property bool volumeBoost: false
            property bool volumeFeedback: false
            // Battery saver (services/PowerSaver.qml): when it comes on —
            // "battery", "low" (below saverBelow %), "always", "never" —
            // and what it turns off.
            property string saverMode: "battery"
            property int saverBelow: 30
            property bool saverBlur: true
            property bool saverShadows: true
            property bool saverOpacity: true
            property bool saverAnimations: false
            property bool saverStill: false
            property bool saverProfile: false
            // The most a level may be set to, in percent: under 100 as a
            // hearing limit, up to 150 as software boost.
            property int volumeMax: 100
            // Settings → Sound's own bookkeeping: devices hidden from its
            // lists and names given to them (JSON), and switching to a
            // Bluetooth or USB device when it connects.
            property string soundHidden: "[]"
            property string soundNames: "{}"
            property bool soundAutoSwitch: false
            // The live level meters in Settings → Sound (only offered on a
            // Quickshell whose peak monitor is safe; see Audio.qml).
            property bool soundMeters: true
            // Clipboard history (services/Clipboard.qml): on or off, and
            // how many entries it keeps.
            property bool clipboardHistory: true
            // USB sticks and SD cards (services/Usb.qml): mounted when
            // plugged in, and a notification saying so.
            property bool usbAutomount: true
            property bool usbNotify: true
            // Notification history (rust/daemon/src/nhist.rs): kept, and
            // for how many days.
            property bool notifHistory: true
            property int notifHistoryDays: 7
            // Focus (services/Focus.qml): quiet hours as JSON
            // [{ id, name, from, to, days, on }], whether urgent ones get
            // through while quiet, how each app is treated (JSON
            // { app: rule }), and the apps that have sent anything.
            property string focusSchedules: "[]"
            property bool focusUrgent: true
            property string notifRules: "{}"
            property string notifApps: "[]"
            // Updates (services/Updates.qml): check on a timer, how often
            // (hours), say when some appear, show the count in the bar.
            property bool updatesAuto: true
            property int updatesEvery: 3
            property bool updatesNotify: true
            property bool updatesInBar: true
            property bool mailInBar: true             // Mail's unread count, while Mail runs
            // Capture (services/Capture.qml): seconds before a shot, the
            // pointer in it, the editor after every shot ("always") or
            // only from the notification ("ask"), a recording's sound
            // ("none" | "desktop" | "mic"), what a bare record captures,
            // and the OCR language (tesseract's code).
            property int captureDelay: 0
            property bool capturePointer: false
            property string captureEdit: "ask"
            property string captureAudio: "none"
            property string captureRecordMode: "screen"
            property string captureOcrLang: "eng"
            // Night light (services/NightLight.qml): off, on, sunset to
            // sunrise, or set times; the warmth; the times; and a place
            // for sunset (empty: the time zone's city).
            // Idle (services/Idle.qml, built in): minutes before lock,
            // screen off and sleep (0 = never); holding them while media
            // plays or a window is fullscreen; hypridle's timings taken over.
            property int idleLock: 10
            property int idleOff: 12
            property int idleSuspend: 30
            property bool idleHoldMedia: true
            property bool idleHoldFullscreen: true
            property bool idleMigrated: false
            property string nightMode: "off"
            property int nightTemp: 3400
            property string nightFrom: "20:00"
            property string nightTo: "07:00"
            property string nightLat: ""
            property string nightLon: ""
            // ROG laptops (services/Rog.qml): the keyboard light in the
            // accent colour.
            property bool rogKbdAccent: false
            property int clipboardMax: 100
            property string soundTab: "output"
            // The equalizer (services/AudioFx.qml): on or off, ten band
            // gains in dB, a preamp, the preset they came from, and the
            // real output it passes the sound on to.
            property bool eqEnabled: false
            property string eqGains: "0,0,0,0,0,0,0,0,0,0"
            property real eqPreamp: 0
            property string eqPreset: "Flat"
            property string eqTarget: ""
            // The parametric equalizer (services/EqMath.js): its bands, as
            // JSON — "" until the ten-band gains above are carried over —
            // the presets you saved, and how tall the graph's scale is.
            property string peqBands: ""
            property string peqPresets: "[]"
            property int eqRange: 12
            // What the equalizer is applied to: "all" (it is the output
            // everything plays into) or "apps" (only those in eqApps, by
            // their stream's node name; everything else plays straight to
            // the device).
            property string eqScope: "all"
            property string eqApps: "[]"
            // Microphone noise suppression: on or off, how sure it must be
            // that it is hearing a voice before letting sound through, and
            // the real microphone it listens to.
            property bool nsEnabled: false
            property int nsThreshold: 50
            property string nsTarget: ""
            property bool clock24: true
            property bool showTray: true
            property bool trayOpen: false
            property bool showTasks: false

            // Dock
            property string dockPosition: "Bottom"    // "Bottom" | "Left"
            property int dockSize: 42                 // 34-58 px
            property int dockIcon: 50                 // 30-72 %
            property bool dockLabels: true
            // Hover a running app's tile for a live picture of each of its
            // windows, and click one to go to it.
            property bool dockPreviews: true
            // "workspace": a dock shows only the windows on the workspace
            // its own monitor is showing, like Windows 11's taskbar with
            // "only on the desktop I'm using". "all": every window.
            property string dockScope: "workspace"

            // Alt+Tab
            property bool altTabEnabled: true
            property string altTabMod: "ALT"          // ALT | SUPER | CTRL
            property string altTabScope: "workspace"  // workspace | monitor | all
            property string altTabStyle: "thumbnails" // thumbnails | icons | list
            property bool altTabGroup: false          // one entry per app
            property bool altTabSpecial: true         // scratchpad windows too
            property bool altTabHold: true            // releasing the modifier switches
            property int altTabDelay: 100             // ms before it appears
            property int altTabSize: 100              // % of the default picture size
            property bool altTabWorkspaceTags: true   // workspace number on each entry
            property bool dockHide: false
            // Over a fullscreen app: out when the pointer reaches the edge.
            property bool dockOverFullscreen: true
            // The pinned apps, as a JSON array of
            // { key, label, icon, exec[], match } — empty means "use the
            // defaults in config/Apps.qml". Carried as text because a
            // JsonAdapter property is a scalar and `match` is a regex
            // source, which has no JSON form of its own.
            property string dockPinned: ""

            // Input devices. These are applied to Hyprland at startup and
            // whenever they change — Hyprland's config is write-only over
            // IPC, so the shell has to be the thing that remembers them.
            property int repeatRate: 25
            property int repeatDelay: 600
            property bool numlock: false
            property int followMouse: 1
            property real sensitivity: 0
            property string accelProfile: "adaptive"
            property bool leftHanded: false
            property bool mouseNaturalScroll: false
            property real mouseScrollFactor: 1
            property bool hideCursorOnKey: true
            // The pointer (services/Cursor.qml): "accent", the shell's own
            // set drawn in the accent colour, or "system", the theme named
            // in cursorSystemTheme.
            property string cursorTheme: "accent"
            property string cursorSystemTheme: "Adwaita"
            property string cursorFill: "auto"        // auto | dark | light: the body
            property string cursorOutline: "auto"     // (no longer used)
            property int cursorSize: 24
            property int cursorTimeout: 0
            property bool tapToClick: true
            property bool tapAndDrag: true
            property bool dragLock: false
            property bool padNaturalScroll: true
            property real padScrollFactor: 1
            // The touchpad's own speed and acceleration. Unset (-2 and "")
            // until changed, and until then they follow the mouse's, which
            // is what one shared setting did before these existed.
            property real padSensitivity: -2
            property string padAccelProfile: ""
            property bool disableWhileTyping: true
            property bool clickfinger: false
            property string tapButtonMap: "lrm"
            property bool middleEmulation: false

            // Per-output display state, as JSON. Every key inside an
            // entry is spelled the way Hyprland's monitor rule spells it,
            // so Devices.displaySpec can copy them straight across:
            //   { "DP-1": { "mode": "2560x1440@165", "scale": 1.25,
            //               "position": "0x0", "bitdepth": 10,
            //               "cm": "hdr", "sdrbrightness": 1.2 }, ... }
            // Re-applied at startup, since Hyprland goes back to whatever
            // hyprland.lua says on every launch.
            property string displays: ""

            // key → accelerator, for shortcuts changed from their default.
            // Only overrides are stored, so the defaults can move without
            // stranding anyone on an old value.
            property string keybinds: ""

            // Which modifier the Windows key actually sends. SUPER (Mod4) is
            // the normal answer, but a keyboard remapped in xkb, a Mac
            // layout, or kb_options like altwin:swap_alt_win can put it
            // somewhere else — and then every SUPER bind silently matches
            // nothing. Written into the generated binds in place of SUPER.
            property string modKey: "SUPER"

            // Typography
            property int fontScale: 100               // 75-150 %
            property int barFontSize: 12              // 10-18 px
            property int barTitleSize: 12             // window title beside the app name
            property int barAppSize: 16               // the focused app's name
            property int barMenuSize: 13              // the "Window" menu button
            property int barClockSize: 13             // the clock's time
            property int barBadgeSize: 11             // notification count
            property int dockLabelSize: 12            // dock tooltips and the active label
            property int barIcon: 100                 // 60-180 % of the bar's glyphs
            property int dockGap: 16                  // 0-40 px around the dock
            // "off" | "layer" | "curve" — see MonoIcon.
            property string iconSmoothing: "layer"
            // The launcher grows out of the dock's pill rather than
            // appearing above it.
            property bool launcherMorph: true
            // Files under home in the launcher's results (hyprshell-daemon).
            property bool launcherFiles: true
            property int launcherTitleSize: 13        // launcher entry names
            property int launcherMetaSize: 11         // launcher categories and hints

            // How glyphs are rasterised.
            //
            // Qt Quick's default is a distance field: one texture per glyph,
            // scaled and rotated freely, and slightly soft at the small
            // sizes a shell is made of. "native" hands rasterising to the
            // platform's font engine, which hints stems onto the pixel grid
            // — noticeably crisper, at the cost of looking wrong under a
            // fractional scale, because it cannot be resampled.
            property bool textNative: true

            // Write the shell's palette into kdeglobals, so Dolphin, Ark and
            // the rest of the KDE applications take their colours from the
            // same theme the shell does. Off by default: it rewrites a file
            // outside this shell's own config.
            property bool themeQtApps: false

            // Generate a Kvantum theme from this one and select it. Kvantum
            // is a Qt style that draws widgets from an SVG, so this changes
            // how KDE applications are *drawn*, not only their colours —
            // which is as close as a file manager gets to the design without
            // being rewritten.
            property bool kvantumTheme: false


            // Subpixel order, written to fontconfig for every app, not just
            // this one: "" leaves your existing setting alone, "none" is
            // grayscale antialiasing, and rgb/bgr/vrgb/vbgr name the stripe
            // order of the panel.
            //
            // Grayscale is the right answer on most OLED panels: their
            // subpixels are not in a straight RGB row (WRGB, or a pentile
            // diamond), so a renderer that assumes one paints colour fringes
            // onto every edge.
            property string subpixel: ""
            property bool fontHinting: true

            // Launcher geometry: one number.
            //
            // Width, height, tile and icon were separately settable, then a
            // layout picker and a size. Both are gone. Everything below is
            // one shape scaled evenly, because every combination that was
            // not that shape looked wrong and none of them was worth a
            // control.
            property int launcherSize: 145            // 70-220 % of the base

            // Optional, on top of the overall size. These stretch the panel
            // in one direction without touching the other or the content:
            // the type and the padding stay put, the room around them grows.
            property int launcherWide: 100             // 50-200 % width
            property int launcherTall: 100             // 50-200 % height
            property int launcherIconScale: 100        // 50-200 % glyph

            // How much of the window shows through a dropdown or the colour
            // picker. 0 is fully opaque.
            // Settings as a floating layer-shell surface (the design's own
            // window, above everything, movable between monitors) or as an
            // ordinary toplevel the compositor tiles like any other app.
            property bool settingsTiled: false

            property int menuTranslucency: 8          // 0-60 %
            property bool menuBlur: true              // frost what's behind a popup

            // Hyprland window frame and behaviour
            property int gapsIn: 4
            property int gapsOut: 8
            property int borderSize: 1
            property bool borderFollowsAccent: true
            // Brightness of each border colour, as a percentage: 100 is the
            // colour itself, lower a darker shade of it, higher a lighter.
            property int activeBorderPct: 100
            property int inactiveBorderPct: 100
            property int hyprRounding: 14
            property bool hyprBlur: true
            // What the shell's own surfaces blur:
            //   auto       the bar and dock blur what is behind them; menus
            //              blur the windows under them when there are any,
            //              and the wallpaper (blurred once, kept) when the
            //              desktop is bare
            //   wallpaper  everything blurs the wallpaper, even over a
            //              window (cheapest, but a menu over an app shows
            //              the desktop instead of the app)
            //   live       everything blurs what is behind it, every frame
            // (A new name: "shellBlur" was wallpaper/live, and wallpaper was
            // the default, so everyone starts again from auto.)
            property string shellBlurMode: "auto"
            property int hyprBlurSize: 4
            property int hyprBlurPasses: 2
            property bool hyprShadow: true
            property int hyprAnimSpeed: 100          // 25-300 %
            property bool hyprAnimEnabled: true
            property string hyprLayout: "dwindle"    // dwindle | master
            property int hyprInactiveOpacity: 100    // 40-100 %
            property bool hyprFocusFollowsMouse: true

            // Notifications
            property bool dnd: false
            property bool badges: true
            property string grouping: "App"           // "App" | "Time"
            property int popupTimeout: 5              // seconds a banner stays up

            // Shell state, not a device reading: see ControlCenter's tile.
            property bool gameMode: false
        }
    }

    // Persisted values are exposed as plain aliases so call sites read
    // `Appearance.barHeight`, not `Appearance.prefs.barHeight`.
    property alias theme: prefs.theme
    property alias accentIndex: prefs.accent
    property alias customAccent: prefs.customAccent
    property alias accentFromWallpaper: prefs.accentFromWallpaper
    property alias wallAccentLight: prefs.wallAccentLight
    property alias wallAccentDark: prefs.wallAccentDark
    property alias wallAccentFor: prefs.wallAccentFor
    // In use: switched on, and a colour found. Your own accent stays as it
    // was underneath, and comes back when this goes off.
    readonly property bool wallAccentOn: accentFromWallpaper && wallAccentLight !== "" && wallAccentDark !== ""
    property alias translucency: prefs.translucency
    property alias roundingPct: prefs.rounding
    property alias tint: prefs.tint
    property alias wallpaper: prefs.wallpaper
    property alias wallpaperStyle: prefs.wallpaperStyle
    property alias topoSeed: prefs.topoSeed
    property alias topoMotion: prefs.topoMotion
    property alias topoGlow: prefs.topoGlow
    property alias animPalette: prefs.animPalette
    property alias animBg1: prefs.animBg1
    property alias animBg2: prefs.animBg2
    property alias animC1: prefs.animC1
    property alias animC2: prefs.animC2
    property alias animC3: prefs.animC3
    property alias animWallSpeed: prefs.animWallSpeed
    property alias animScale: prefs.animScale
    property alias animDensity: prefs.animDensity
    property alias animGlow: prefs.animGlow
    property alias animIntensity: prefs.animIntensity
    property alias animSeed: prefs.animSeed
    property alias animFps: prefs.animFps
    property alias animOnBattery: prefs.animOnBattery
    property alias animPauseCovered: prefs.animPauseCovered
    property alias animMigrated: prefs.animMigrated
    property alias animLastStyle: prefs.animLastStyle
    property alias topoScale: prefs.topoScale
    property alias topoDetail: prefs.topoDetail
    property alias topoFlow: prefs.topoFlow
    property alias topoLevels: prefs.topoLevels
    property alias topoWidth: prefs.topoWidth
    property alias topoMajor: prefs.topoMajor
    property alias topoLine: prefs.topoLine
    property alias topoLineCustom: prefs.topoLineCustom
    property alias topoStrength: prefs.topoStrength
    property alias topoShade: prefs.topoShade
    property alias topoGround: prefs.topoGround
    property alias topoLow: prefs.topoLow
    property alias topoHigh: prefs.topoHigh
    property alias topoDrift: prefs.topoDrift
    property alias topoSpeed: prefs.topoSpeed
    property alias liveWallpaper: prefs.liveWallpaper
    property alias wallpaperLast: prefs.wallpaperLast
    property alias liveLast: prefs.liveLast
    property alias liveFolders: prefs.liveFolders
    property alias liveFiles: prefs.liveFiles
    property alias liveSound: prefs.liveSound
    property alias liveVolume: prefs.liveVolume
    property alias livePauseCovered: prefs.livePauseCovered
    property alias livePauseOnBattery: prefs.livePauseOnBattery
    property alias liveScaling: prefs.liveScaling
    property alias liveLayout: prefs.liveLayout
    property alias liveScreens: prefs.liveScreens
    property alias liveRotate: prefs.liveRotate
    property alias liveDelay: prefs.liveDelay
    property alias liveOrder: prefs.liveOrder
    property alias barHeight: prefs.barHeight
    property alias workspaceScale: prefs.workspaceScale
    property alias animSpeed: prefs.animSpeed
    property alias screenCorners: prefs.screenCorners
    property alias screenCornerRadius: prefs.screenCornerRadius
    property alias screenCornerTL: prefs.screenCornerTL
    property alias screenCornerTR: prefs.screenCornerTR
    property alias screenCornerBL: prefs.screenCornerBL
    property alias screenCornerBR: prefs.screenCornerBR
    property alias screenCornerScreens: prefs.screenCornerScreens
    property alias screenScales: prefs.screenScales
    property alias clock24: prefs.clock24
    property alias showTray: prefs.showTray
    property alias trayOpen: prefs.trayOpen
    property alias showTasks: prefs.showTasks
    property alias dockPositionName: prefs.dockPosition
    property alias dockTileSize: prefs.dockSize
    property alias dockIconPct: prefs.dockIcon
    property alias dockLabels: prefs.dockLabels
    property alias dockPreviews: prefs.dockPreviews
    property alias dockScope: prefs.dockScope
    property alias altTabEnabled: prefs.altTabEnabled
    property alias altTabMod: prefs.altTabMod
    property alias altTabScope: prefs.altTabScope
    property alias altTabStyle: prefs.altTabStyle
    property alias altTabGroup: prefs.altTabGroup
    property alias altTabSpecial: prefs.altTabSpecial
    property alias altTabHold: prefs.altTabHold
    property alias altTabDelay: prefs.altTabDelay
    property alias altTabSize: prefs.altTabSize
    property alias altTabWorkspaceTags: prefs.altTabWorkspaceTags
    property alias dockAutoHide: prefs.dockHide
    property alias dockOverFullscreen: prefs.dockOverFullscreen
    property alias barAutoHide: prefs.barHide
    property alias barRevealDelay: prefs.barRevealDelay
    property alias volumeStep: prefs.volumeStep
    property alias volumeBoost: prefs.volumeBoost
    property alias volumeFeedback: prefs.volumeFeedback
    property alias saverMode: prefs.saverMode
    property alias saverBelow: prefs.saverBelow
    property alias saverBlur: prefs.saverBlur
    property alias saverShadows: prefs.saverShadows
    property alias saverOpacity: prefs.saverOpacity
    property alias saverAnimations: prefs.saverAnimations
    property alias saverStill: prefs.saverStill
    property alias saverProfile: prefs.saverProfile
    property alias volumeMax: prefs.volumeMax
    property alias soundHidden: prefs.soundHidden
    property alias soundNames: prefs.soundNames
    property alias soundAutoSwitch: prefs.soundAutoSwitch
    property alias soundMeters: prefs.soundMeters
    property alias clipboardHistory: prefs.clipboardHistory
    property alias usbAutomount: prefs.usbAutomount
    property alias usbNotify: prefs.usbNotify
    property alias notifHistory: prefs.notifHistory
    property alias notifHistoryDays: prefs.notifHistoryDays
    property alias focusSchedules: prefs.focusSchedules
    property alias focusUrgent: prefs.focusUrgent
    property alias notifRules: prefs.notifRules
    property alias notifApps: prefs.notifApps
    property alias updatesAuto: prefs.updatesAuto
    property alias updatesEvery: prefs.updatesEvery
    property alias updatesNotify: prefs.updatesNotify
    property alias updatesInBar: prefs.updatesInBar
    property alias mailInBar: prefs.mailInBar
    property alias captureDelay: prefs.captureDelay
    property alias capturePointer: prefs.capturePointer
    property alias captureEdit: prefs.captureEdit
    property alias captureAudio: prefs.captureAudio
    property alias captureRecordMode: prefs.captureRecordMode
    property alias captureOcrLang: prefs.captureOcrLang
    property alias idleLock: prefs.idleLock
    property alias idleOff: prefs.idleOff
    property alias idleSuspend: prefs.idleSuspend
    property alias idleHoldMedia: prefs.idleHoldMedia
    property alias idleHoldFullscreen: prefs.idleHoldFullscreen
    property alias idleMigrated: prefs.idleMigrated
    property alias nightMode: prefs.nightMode
    property alias nightTemp: prefs.nightTemp
    property alias nightFrom: prefs.nightFrom
    property alias nightTo: prefs.nightTo
    property alias nightLat: prefs.nightLat
    property alias nightLon: prefs.nightLon
    property alias rogKbdAccent: prefs.rogKbdAccent
    property alias clipboardMax: prefs.clipboardMax
    property alias soundTab: prefs.soundTab
    property alias eqEnabled: prefs.eqEnabled
    property alias eqGains: prefs.eqGains
    property alias eqPreamp: prefs.eqPreamp
    property alias eqPreset: prefs.eqPreset
    property alias eqTarget: prefs.eqTarget
    property alias peqBands: prefs.peqBands
    property alias peqPresets: prefs.peqPresets
    property alias eqRange: prefs.eqRange
    property alias eqScope: prefs.eqScope
    property alias eqApps: prefs.eqApps
    property alias nsEnabled: prefs.nsEnabled
    property alias nsThreshold: prefs.nsThreshold
    property alias nsTarget: prefs.nsTarget
    property alias dockPinned: prefs.dockPinned

    // ── input devices ─────────────────────────────────────────────────────
    property alias repeatRate: prefs.repeatRate
    property alias repeatDelay: prefs.repeatDelay
    property alias numlock: prefs.numlock
    property alias followMouse: prefs.followMouse
    property alias sensitivity: prefs.sensitivity
    property alias accelProfile: prefs.accelProfile
    property alias leftHanded: prefs.leftHanded
    property alias mouseNaturalScroll: prefs.mouseNaturalScroll
    property alias mouseScrollFactor: prefs.mouseScrollFactor
    property alias hideCursorOnKey: prefs.hideCursorOnKey
    property alias cursorTheme: prefs.cursorTheme
    property alias cursorSystemTheme: prefs.cursorSystemTheme
    property alias cursorFill: prefs.cursorFill
    property alias cursorOutline: prefs.cursorOutline
    property alias cursorSize: prefs.cursorSize
    property alias cursorTimeout: prefs.cursorTimeout
    property alias tapToClick: prefs.tapToClick
    property alias tapAndDrag: prefs.tapAndDrag
    property alias dragLock: prefs.dragLock
    property alias padNaturalScroll: prefs.padNaturalScroll
    property alias padScrollFactor: prefs.padScrollFactor
    property alias padSensitivity: prefs.padSensitivity
    property alias padAccelProfile: prefs.padAccelProfile
    readonly property real padSensitivityNow: padSensitivity < -1 ? sensitivity : padSensitivity
    readonly property string padAccelNow: padAccelProfile || accelProfile
    property alias disableWhileTyping: prefs.disableWhileTyping
    property alias clickfinger: prefs.clickfinger
    property alias tapButtonMap: prefs.tapButtonMap
    property alias middleEmulation: prefs.middleEmulation
    property alias displays: prefs.displays
    property alias keybinds: prefs.keybinds
    property alias modKey: prefs.modKey

    // ── typography ────────────────────────────────────────────────────────
    property alias fontScale: prefs.fontScale
    property alias barFontSize: prefs.barFontSize
    property alias barTitleSize: prefs.barTitleSize
    property alias barAppSize: prefs.barAppSize
    property alias barMenuSize: prefs.barMenuSize
    property alias barClockSize: prefs.barClockSize
    property alias barBadgeSize: prefs.barBadgeSize
    property alias dockLabelSize: prefs.dockLabelSize
    property alias barIconPct: prefs.barIcon
    property alias dockGapPx: prefs.dockGap
    property alias iconSmoothing: prefs.iconSmoothing
    property alias launcherMorph: prefs.launcherMorph
    property alias launcherFiles: prefs.launcherFiles
    property alias launcherTitleSize: prefs.launcherTitleSize
    property alias launcherMetaSize: prefs.launcherMetaSize

    property alias textNative: prefs.textNative
    property alias themeQtApps: prefs.themeQtApps
    property alias kvantumTheme: prefs.kvantumTheme
    property alias subpixel: prefs.subpixel
    property alias fontHinting: prefs.fontHinting

    property alias launcherSize: prefs.launcherSize
    property alias launcherWide: prefs.launcherWide
    property alias launcherTall: prefs.launcherTall
    property alias launcherIconScale: prefs.launcherIconScale

    // The shape everything is scaled from, at 100%.
    // Narrower and taller than the mockup's proportions: at 620x500 with
    // four columns it was a wide shallow box, and a list of search results
    // is a column, not a row. Three across and half as tall again reads as
    // a start menu rather than a strip. Both are still stretchable — Wider
    // and Taller under Shell -> Launcher.
    readonly property var launcherBase: ({ w: 420, h: 720, tile: 60, icon: 22,
                                           cols: 3 })

    // Everything the launcher measures itself by, derived. Nothing else in
    // the shell had to change: these are the same property names it always
    // read, they are just no longer settable one at a time.
    function launcherScaled(px) {
        return Math.round(px * Math.max(40, launcherSize) / 100);
    }
    function launcherStretch(n) { return Math.max(50, Math.min(220, n)) / 100; }

    readonly property int launcherWidth:
        Math.round(launcherScaled(launcherBase.w) * launcherStretch(launcherWide))
    readonly property int launcherHeight:
        Math.round(launcherScaled(launcherBase.h) * launcherStretch(launcherTall))
    // The height setting as a plain multiplier, because the launcher needs
    // it as one: it is spent on rows of apps rather than on empty panel,
    // so the panel grows because there is more in it. A ceiling alone —
    // which is all this used to be — did nothing at all, since the panel
    // was already shorter than it.
    readonly property real launcherHeightStretch: launcherStretch(launcherTall)
    readonly property real launcherWidthStretch: launcherStretch(launcherWide)

    readonly property int launcherTileSize: launcherScaled(launcherBase.tile)
    readonly property int launcherIconSize:
        Math.round(launcherScaled(launcherBase.icon)
                   * launcherStretch(launcherIconScale))

    // Extra width becomes extra columns rather than extra padding: a wider
    // start menu should hold more apps per row, not the same four with more
    // air between them.
    readonly property int launcherColumns:
        Math.max(3, Math.min(10,
            Math.round(launcherBase.cols * launcherStretch(launcherWide))))

    property alias settingsTiled: prefs.settingsTiled
    property alias menuTranslucency: prefs.menuTranslucency
    property alias menuBlur: prefs.menuBlur

    property alias gapsIn: prefs.gapsIn
    property alias gapsOut: prefs.gapsOut
    property alias borderSize: prefs.borderSize
    property alias borderFollowsAccent: prefs.borderFollowsAccent
    property alias activeBorderPct: prefs.activeBorderPct
    property alias inactiveBorderPct: prefs.inactiveBorderPct
    property alias hyprRounding: prefs.hyprRounding
    property alias hyprBlur: prefs.hyprBlur
    property alias hyprBlurSize: prefs.hyprBlurSize
    property alias hyprBlurPasses: prefs.hyprBlurPasses
    property alias shellBlurMode: prefs.shellBlurMode
    property alias hyprShadow: prefs.hyprShadow
    property alias hyprAnimSpeed: prefs.hyprAnimSpeed
    property alias hyprAnimEnabled: prefs.hyprAnimEnabled
    property alias hyprLayout: prefs.hyprLayout
    property alias hyprInactiveOpacity: prefs.hyprInactiveOpacity
    property alias hyprFocusFollowsMouse: prefs.hyprFocusFollowsMouse
    property alias dnd: prefs.dnd
    property alias badges: prefs.badges
    property alias grouping: prefs.grouping
    property alias popupTimeout: prefs.popupTimeout
    property alias gameMode: prefs.gameMode

    // ── theme resolution ──────────────────────────────────────────────────
    // "auto" follows the clock: dark from 19:00 to 07:00. The mockup calls
    // this "follow sunset"; without a location service this is the honest
    // approximation, and it re-evaluates every minute.
    SystemClock {
        id: themeClock
        precision: SystemClock.Minutes
        enabled: root.theme === "auto"
    }
    readonly property bool autoDark: themeClock.hours >= 19 || themeClock.hours < 7
    readonly property bool dark: theme === "auto" ? autoDark : theme === "dark"

    function setTheme(name) { theme = name; }
    function cycleTheme() { theme = theme === "light" ? "dark" : (theme === "dark" ? "auto" : "light"); }
    function toggleTheme() { theme = dark ? "light" : "dark"; }

    // ── accent ────────────────────────────────────────────────────────────
    readonly property var accentPresets: [
        { light: "#ec3013", dark: "#ff563c" },
        { light: "#ae1800", dark: "#e8452b" },
        { light: "#2d2b2b", dark: "#d7d3d3" },
        { light: "#7c1405", dark: "#c94b39" }
    ]

    readonly property color accent: {
        if (wallAccentOn) return dark ? wallAccentDark : wallAccentLight;
        if (accentIndex === -1) return customAccent;
        const preset = accentPresets[Math.max(0, Math.min(accentPresets.length - 1, accentIndex))];
        return dark ? preset.dark : preset.light;
    }

    // Ink laid *on* the accent, so a light custom accent flips to dark text
    // instead of going unreadable.
    //
    // Named inkOnAccent, not onAccent, and that is not a style choice. A
    // property whose name is `on` followed by a capital and whose
    // initialiser is a brace block is parsed as a signal handler: the block
    // becomes handler code that never runs, and the property keeps its
    // type's default — black, for a colour. It fails silently, with no
    // warning at load and no error at run time, and it had been doing so
    // here for as long as this property has existed: every glyph and label
    // drawn on the accent was black rather than this. The same name with a
    // one-line expression binding works, which is why it is easy to miss.
    // `qmlparse.py` now refuses the shape outright.
    readonly property color inkOnAccent: {
        const c = accent;
        const lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b;
        return lum > 0.62 ? "#201e1d" : "#fff8f6";
    }

    // ── neutrals ──────────────────────────────────────────────────────────
    readonly property color ground: dark ? "#201e1d" : "#f3f2f2"
    readonly property color surface: dark ? "#2d2b2b" : "#eae9e9"
    readonly property color ink: dark ? "#f8f4f4" : "#201e1d"
    readonly property color ink2: dark ? "#bab6b6" : "#605d5d"
    readonly property color ink3: dark ? "#8a8686" : "#6b6868"

    readonly property color edge: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.16) : Qt.rgba(0.125, 0.118, 0.114, 0.14)
    readonly property color rule: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.10) : Qt.rgba(0.125, 0.118, 0.114, 0.09)
    readonly property color div: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.22) : Qt.rgba(0.125, 0.118, 0.114, 0.18)

    // Panel and sheet alpha, driven by the Translucency slider. 50% lands on
    // the mockup's own values (0.78 light / 0.72 dark); 0% makes the chrome
    // fully opaque and 100% is as see-through as stays legible.
    //
    // What shows through is the compositor's blur of whatever is behind the
    // surface — hyprland.lua sets a layer_rule per namespace to enable that.
    // With blur off in Hyprland these still read correctly, just flatter.
    readonly property real translucencyFactor: Math.max(0, Math.min(100, translucency)) / 100
    readonly property real panelAlpha: 1.0 - translucencyFactor * (dark ? 0.56 : 0.44)
    readonly property real sheetAlpha: 1.0 - translucencyFactor * (dark ? 0.24 : 0.20)

    readonly property color panel: dark ? Qt.rgba(0.114, 0.106, 0.102, panelAlpha)
                                        : Qt.rgba(0.973, 0.969, 0.969, panelAlpha)
    readonly property color sheet: dark ? Qt.rgba(0.137, 0.129, 0.125, sheetAlpha)
                                        : Qt.rgba(0.980, 0.976, 0.976, sheetAlpha)

    // Fully opaque. A dropdown or popup drawn *inside* a translucent window
    // has nothing blurred behind it — it just shows that window's own
    // content through itself, which is illegible. Menus use this.
    readonly property color solid: dark ? "#1f1d1c" : "#fbfafa"

    // What a dropdown or the colour picker is filled with. Mostly opaque by
    // default: these float over the window's own rows, not over the desktop,
    // so anything showing through is text rather than wallpaper. The control
    // is in Appearance for anyone who wants more of it.
    readonly property real menuAlpha:
        1.0 - Math.max(0, Math.min(60, menuTranslucency)) / 100
    readonly property color menuSurface:
        Qt.rgba(solid.r, solid.g, solid.b, menuAlpha)

    readonly property color hover: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.09) : Qt.rgba(0.125, 0.118, 0.114, 0.07)
    readonly property color sel: dark ? Qt.rgba(0.973, 0.957, 0.957, 0.14) : Qt.rgba(0.125, 0.118, 0.114, 0.10)
    readonly property color gloss: dark ? Qt.rgba(1, 1, 1, 0.10) : Qt.rgba(1, 1, 1, 0.6)
    readonly property color seam: Qt.rgba(accent.r, accent.g, accent.b, dark ? 0.24 : 0.18)
    readonly property color scrim: dark ? Qt.rgba(0.078, 0.075, 0.071, 0.5) : Qt.rgba(0.125, 0.118, 0.114, 0.24)

    // ── wallpaper tint ramps ──────────────────────────────────────────────
    // The mockup's TINTS table. Wallpaper.qml paints these as one linear
    // base plus two radial washes.
    readonly property var tintSpec: {
        const table = {
            light: {
                Warm:    { a: "#f6f4f3", b: "#e7e3e1", g1: "#ffd9d0", g2: "#dcd8d6" },
                Neutral: { a: "#f5f4f4", b: "#e4e2e2", g1: "#e9e7e6", g2: "" },
                Cool:    { a: "#f2f4f5", b: "#e2e5e7", g1: "#d7dee2", g2: "#dcdcde" }
            },
            dark: {
                Warm:    { a: "#24211f", b: "#161514", g1: "#4a2119", g2: "#2a2827" },
                Neutral: { a: "#221f1e", b: "#151413", g1: "#33302f", g2: "" },
                Cool:    { a: "#1d2022", b: "#131516", g1: "#1e2b33", g2: "#24282a" }
            }
        };
        const set = table[dark ? "dark" : "light"];
        return set[tint] || set.Warm;
    }

    // ── radii — one family scaled by `roundingPct` (0 = square) ───────────
    readonly property real rf: roundingPct / 100
    readonly property real rSm: Math.round(9 * rf)
    readonly property real r: Math.round(14 * rf)
    readonly property real rWin: r
    readonly property real rPanel: r
    readonly property real rTile: r
    readonly property real rCard: r
    readonly property real rPill: r
    readonly property real rDock: r
    readonly property real rCap: r

    // ── typography ────────────────────────────────────────────────────────
    // Inter throughout, as in the mockup; the fallback chain keeps the shell
    // legible if it isn't installed.
    // One multiplier over every text size in the shell, so the whole thing
    // scales without each module carrying its own setting.
    readonly property real fontFactor: Math.max(75, Math.min(150, fontScale)) / 100
    function fs(px) { return Math.round(px * fontFactor); }

    // The bar's own sizes, derived from one setting so they keep the
    // design's relative proportions instead of each needing its own slider.
    // barFontSize is the body size; the focused app's name is four steps
    // larger and the notification badge one smaller, which is the 16/12/11
    // the mockup specifies at the default of 12.
    function barFs(delta) { return fs(Math.max(6, barFontSize + (delta || 0))); }

    // Hyprland wants colours as rgba(rrggbbaa), which is not a form Qt hands
    // out, so it is built by hand.
    // A colour made darker or lighter without changing its hue: below 100%
    // each channel is scaled down towards black, so the accent becomes a
    // deeper shade of itself rather than a greyer one; above 100% it is
    // mixed towards white. Alpha is left alone.
    function shade(c, pct) {
        const k = Math.max(0, pct) / 100;
        if (k <= 1) return Qt.rgba(c.r * k, c.g * k, c.b * k, c.a);
        const t = Math.min(1, k - 1);
        return Qt.rgba(c.r + (1 - c.r) * t, c.g + (1 - c.g) * t, c.b + (1 - c.b) * t, c.a);
    }

    // The window borders Hyprland is given (Services.Devices): the focused
    // one from the accent, the others from the divider ink, each at its own
    // brightness.
    readonly property color activeBorderColor: shade(accent, activeBorderPct)
    readonly property color inactiveBorderColor: shade(div, inactiveBorderPct)

    function hyprColor(c, alphaByte) {
        const h = x => {
            const v = Math.round(Math.max(0, Math.min(1, x)) * 255).toString(16);
            return v.length < 2 ? "0" + v : v;
        };
        return "rgba(" + h(c.r) + h(c.g) + h(c.b) + (alphaByte || "ff") + ")";
    }

    readonly property string fontFamily: "Inter"
    readonly property string monoFamily: "JetBrains Mono"

    // ── dock geometry ─────────────────────────────────────────────────────
    readonly property bool dockLeft: dockPositionName === "Left"
    // Never zero, whatever the percentage says: a glyph asked to draw at no
    // size draws nothing at all, and a dock tile with a fill and no icon in
    // it reads as a missing icon rather than as a setting turned down.
    readonly property real dockIconSize:
        Math.max(8, Math.round(dockTileSize * dockIconPct / 100))
    // The utility tiles — overview, settings, show desktop — used to draw at
    // 82% of the app tiles, which is a distinction nobody asked for and read
    // as the corner icons being smaller than the rest. They use dockIconSize
    // now, like everything else in the dock.

    // ── bar glyphs ────────────────────────────────────────────────────────
    // The design's own 16 and 14, scaled by one preference so the bar's
    // icons and the tray's stay in proportion with each other.
    readonly property real barIconSize: Math.max(8, Math.round(16 * barIconPct / 100))
    readonly property real barTrayIconSize: Math.max(8, Math.round(14 * barIconPct / 100))

    readonly property real dockPadH: 7
    readonly property real dockPadV: 5
    readonly property real dockTileSpacing: 3
    // The gap around the dock — between it and the screen edge, and between
    // it and the windows above it. One number for both: the two being
    // different is what made the dock look mounted on the bottom edge
    // rather than floating over it.
    readonly property real dockEdgeGap: Math.max(0, Math.min(40, dockGapPx))
    readonly property real dockTooltipRoom: 46
    readonly property real dockPanelBreadth: dockTileSize + dockPadV * 2

    // ── shared panel geometry ─────────────────────────────────────────────
    // Dropdowns hang this far below the bar and this far in from the right
    // edge, matching the mockup's top:50px / right:12px.
    readonly property real panelGap: 10
    readonly property real panelEdgeGap: 12
    readonly property real panelTop: barHeight + panelGap

    // ── animation ─────────────────────────────────────────────────────────
    // Every duration in the shell goes through this, so one slider governs
    // the lot and 0% is genuinely instant rather than merely brisk. Qt
    // treats a zero-length NumberAnimation as "jump there", which is what
    // is wanted.
    // Set by Battery saver (services/PowerSaver.qml) while it is asking
    // the shell to keep still: transitions become instant and the
    // decorative motion stops. Not a saved setting — it follows the power.
    property bool saverCalm: false

    function anim(ms) {
        if (animSpeed <= 0 || saverCalm) return 0;
        return Math.max(1, Math.round(ms * 100 / Math.max(10, animSpeed)));
    }
    // A few places want to know without asking for a number.
    readonly property bool animated: animSpeed > 0 && !saverCalm

    // ── per-output scale ──────────────────────────────────────────────────
    // A laptop panel run at a compositor scale that makes applications
    // legible makes the shell large to match, because a layer-shell surface
    // is specified in logical pixels and the compositor multiplies them.
    // This is the shell's own correction, per output, so a 150% laptop can
    // carry a 100% bar while the desktop monitor beside it is unchanged.
    readonly property var screenScaleMap: {
        const out = ({});
        for (const line of String(screenScales || "").split("\n")) {
            const m = /^\s*([^=]+?)\s*=\s*(\d+)\s*$/.exec(line);
            if (m) out[m[1]] = Math.max(40, Math.min(200, parseInt(m[2], 10)));
        }
        return out;
    }
    function screenScale(name) {
        const v = screenScaleMap[name || ""];
        return (v === undefined ? 100 : v) / 100;
    }
}
