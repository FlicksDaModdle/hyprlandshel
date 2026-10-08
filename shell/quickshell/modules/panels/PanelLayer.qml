import QtQuick
import Quickshell
import Quickshell.Wayland
import "../../config" as Config
import "../../services" as Services
import "../common"

// One overlay surface per monitor hosting every bar dropdown: control
// center, notifications, calendar, power menu and the desktop context menu.
//
// They live here rather than in the bar for two reasons. The bar is only
// `barHeight` tall, so anything hanging off it would be clipped by its own
// surface; and a single overlay gives one click-away target that dismisses
// whatever is open, which is what the mockup's full-screen catcher does.
//
// The surface is only mapped while something is open, so it never
// intercepts clicks meant for the desktop.
Variants {
    model: Quickshell.screens

    PanelWindow {
        id: layer
        required property var modelData

        // Variants applies modelData after this binding is first evaluated,
        // so it sees undefined once on the way up. null is the same thing to
        // setScreen (use the default) and doesn't warn; the binding
        // re-evaluates to the real screen the moment modelData lands.
        screen: modelData ?? null
        // ...and nothing is drawn until it is a real one. `?? null` means
        // "the default screen" to setScreen, so during an output change —
        // plugging a monitor in, or changing a scale, which makes Hyprland
        // re-enumerate — a surface whose modelData has momentarily gone
        // would land on the default output instead. Two bars on one monitor
        // is what that looks like from the outside.
        readonly property bool hasScreen: !!modelData
        // Covers the whole output, exclusive zones and all.
        //
        // An always-on dock reserves its strip, and a layer surface that
        // respects that reservation gets shrunk by it — so the wallpaper
        // stopped at the dock and what showed behind and beside it was the
        // compositor's own background, not the desktop. The same shrinking
        // moved the launcher's bottom edge up off the screen edge, which is
        // the one place it must stay anchored, and took its click-away
        // target with it: the desktop beside the dock stopped dismissing
        // it. Reserving space is for *windows*, not for the shell's own
        // full-screen surfaces.
        exclusionMode: ExclusionMode.Ignore
        // Stays mapped a moment after the last panel closes, so it can be
        // seen drawing back in. Hiding it at once froze that animation
        // where it stood — Qt stops a window's animations with it — and the
        // next panel opened at full size, with nothing left to animate.
        // Meanwhile it takes no input (the mask below), so a click lands on
        // whatever is under it.
        readonly property bool open: hasScreen && Config.UiState.anyPanelOpen && isPrimary
        property bool lingering: false
        onOpenChanged: {
            if (open) { linger.stop(); lingering = false; }
            else if (visible) { lingering = true; linger.restart(); }
        }
        Timer { id: linger; interval: Math.max(1, Config.Appearance.anim(320)); onTriggered: layer.lingering = false }
        visible: open || lingering
        mask: Region {
            width: layer.open ? layer.width : 0
            height: layer.open ? layer.height : 0
        }
        color: "transparent"
        exclusiveZone: 0

        anchors.top: true
        anchors.bottom: true
        anchors.left: true
        anchors.right: true

        WlrLayershell.namespace: "quickshell:panel"
        WlrLayershell.layer: WlrLayer.Overlay
        // None by default: these panels are pointer-driven, and a layer
        // surface holding the keyboard would take it from the window behind.
        // OnDemand only while a panel has something to type into.
        WlrLayershell.keyboardFocus: Config.UiState.panelWantsKeyboard
                                     ? WlrKeyboardFocus.OnDemand
                                     : WlrKeyboardFocus.None

        // Panels follow the pointer's monitor: opening the control center
        // from the bar on the right-hand screen should not light it up on
        // the left one. Quickshell has no pointer-position API, so the
        // compositor's focused monitor is the stand-in — it's the monitor
        // whose bar you just clicked.
        //
        // This used to scan `monitors` for a focused flag and treat "none
        // found" as "yes, this screen", which is true on every screen at
        // once — so every dropdown opened on all of them.
        readonly property bool isPrimary: Services.Compositor.isFocusedScreen(modelData)

        // Click-away. Right-clicking bare backdrop reopens the desktop menu
        // at the new spot rather than just dismissing.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton) Config.UiState.openDesktopMenu(mouse.x, mouse.y);
                else Config.UiState.closeAll();
            }
        }

        // Every dropdown right-aligns to the same gutter and hangs the same
        // distance below the bar, as in the mockup.
        readonly property real panelRight: layer.width - Config.Appearance.panelEdgeGap
        readonly property real panelTop: Config.Appearance.panelTop

        Entrance {
            shown: Config.UiState.controlCenterOpen
            x: layer.panelRight - width
            y: layer.panelTop
            ControlCenter {
                id: cc
            }
        }

        Entrance {
            shown: Config.UiState.notificationsOpen
            x: layer.panelRight - width
            y: layer.panelTop
            NotificationCenter {}
        }

        Entrance {
            shown: Config.UiState.calendarOpen
            x: layer.panelRight - width
            y: layer.panelTop
            CalendarPanel {}
        }

        // Centred under the bar, where its pill is, rather than at the
        // right gutter the other dropdowns share.
        Entrance {
            shown: Config.UiState.mediaOpen
            x: Math.round((layer.width - width) / 2)
            y: layer.panelTop
            MediaPanel {}
        }

        // Centred on the screen, like a dialog: it is reached from the
        // keyboard, not from anything on the bar.
        Entrance {
            shown: Config.UiState.clipboardOpen
            x: Math.round((layer.width - width) / 2)
            y: Math.round(layer.height * 0.22)
            ClipboardPanel {
                visible: Config.UiState.clipboardOpen
            }
        }

        Entrance {
            shown: Config.UiState.drivesOpen
            x: layer.panelRight - width
            y: layer.panelTop
            DrivesPanel {}
        }

        Entrance {
            shown: Config.UiState.timersOpen
            x: layer.panelRight - width
            y: layer.panelTop
            TimersPanel {}
        }

        Entrance {
            shown: Config.UiState.privacyOpen
            x: layer.panelRight - width
            y: layer.panelTop
            PrivacyPanel {}
        }

        Entrance {
            shown: Config.UiState.updatesOpen
            x: layer.panelRight - width
            y: layer.panelTop
            UpdatesPanel {}
        }

        // The capture toolbar sits low and in the middle, out of the way
        // of what is being captured.
        Entrance {
            shown: Config.UiState.captureOpen
            fromY: 12
            x: Math.round((layer.width - width) / 2)
            y: layer.height - height - 110
            CapturePanel {}
        }

        Entrance {
            shown: Config.UiState.powerOpen
            x: layer.panelRight - width
            y: layer.panelTop
            PowerMenu {}
        }

        // A tray icon's menu, under the icon, drawn as the shell's own.
        TrayMenu {
            anchors.fill: parent
            visible: Config.UiState.trayMenuOpen
            screenWidth: layer.width
            screenHeight: layer.height
            anchorX: Config.UiState.trayMenuX
            topY: layer.panelTop
        }

        // The bar's window menu hangs under its button rather than at the
        // right gutter, so it reads as belonging to it.
        WindowMenuPanel {
            visible: Config.UiState.windowMenuOpen
            screenWidth: layer.width
            screenHeight: layer.height
            x: Math.max(8, Math.min(Config.UiState.windowMenuX, layer.width - width - 8))
            y: layer.panelTop
        }

        // The context menu opens at the pointer, nudged back on screen if
        // it would run off the right or bottom edge.
        DesktopMenu {
            id: ctx
            visible: Config.UiState.desktopMenuOpen
            x: Math.max(8, Math.min(Config.UiState.desktopMenuX, layer.width - width - 8))
            y: Math.max(Config.Appearance.barHeight + 4,
                        Math.min(Config.UiState.desktopMenuY, layer.height - height - 8))
        }

        // Right-clicking a dock or launcher tile. Opened at the pointer like
        // the desktop menu, but it prefers to sit *above* the click, since
        // the dock it is usually launched from is at the bottom of the
        // screen and a menu hanging down from there would be off it.
        // Centred rather than at the pointer: it is a sheet of eighty-odd
        // glyphs, not a short list of verbs, and hanging that off a dock
        // tile would put most of it off the bottom of the screen.
        Entrance {
            shown: Config.UiState.iconPickerOpen
            x: Math.round((layer.width - width) / 2)
            y: Math.round((layer.height - height) / 2)
            IconPicker {
                id: iconPick
                visible: Config.UiState.iconPickerOpen
            }
        }

        AppMenu {
            id: appCtx
            visible: Config.UiState.appMenuOpen
            x: Math.max(8, Math.min(Config.UiState.appMenuX - width / 2,
                                    layer.width - width - 8))
            y: Config.UiState.appMenuY - height - 10 >= Config.Appearance.barHeight + 4
               ? Config.UiState.appMenuY - height - 10
               : Math.min(Config.UiState.appMenuY + 10, layer.height - height - 8)
        }
    }
}
