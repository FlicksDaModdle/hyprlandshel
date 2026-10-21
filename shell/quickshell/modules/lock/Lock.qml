import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.UPower
import "../../config" as Config
import "../../services" as Services
import "../common"
import "../icons"
import "../corners"

// Session lock. The mockup's lock screen, made real: this is a Wayland
// session-lock surface, so the compositor guarantees nothing behind it is
// visible and nothing else can take input while it's up — and the password
// field authenticates against PAM, so the only way past it is your actual
// password.
//
// What it draws is LoginView, the same file the greeter draws, so unlocking
// and logging in are one design: the card with your picture and name, the
// field with its cursor and the eye, sleep / restart / shut down. What is
// the lock screen's own is the line in the corner — battery, network,
// notifications — where the greeter names the machine.
//
// The mockup's "Click anywhere to unlock" is the one thing deliberately not
// carried over.
Scope {
    // The password, shared by every monitor's surface (LockAuth.qml). Beside
    // the lock rather than inside it: what is inside a WlSessionLock is made
    // per surface.
    LockAuth { id: lockAuth }

    WlSessionLock {
        id: lock

        locked: Config.UiState.locked
        // Each lock starts with an empty field, and with your face being
        // looked for (when Howdy is set up).
        onLockedChanged: locked ? lockAuth.begin() : lockAuth.stop()

        // Your name as the greeter shows it — the full name from /etc/passwd,
        // the login name when there is none.
        property string displayName: Services.SysInfo.user
        FileView {
            path: "/etc/passwd"
            printErrors: false
            onLoaded: {
                for (const line of text().split("\n")) {
                    const f = line.split(":");
                    if (f[0] !== Services.SysInfo.user) continue;
                    const full = (f[4] || "").split(",")[0].trim();
                    if (full) lock.displayName = full;
                    break;
                }
            }
        }

        // Every monitor gets its own surface.
        surface: WlSessionLockSurface {
            id: surface
            color: Config.Appearance.ground

            readonly property var battery: UPower.displayDevice
            readonly property bool hasBattery: !!battery && battery.isLaptopBattery && battery.isPresent

            // A refused password shakes every screen's card.
            Connections {
                target: lockAuth
                function onRejected() { view.shake(); }
            }

            LoginView {
                id: view
                anchors.fill: parent

                auth: lockAuth
            // Another monitor's surface has the keys: typing works there.
            keyboardElsewhere: lockAuth.keyboardSomewhere && !windowActive
            onWindowActiveChanged: lockAuth.setKeyboard(screenName, windowActive)
            Component.onCompleted: lockAuth.setKeyboard(screenName, windowActive)
            Component.onDestruction: lockAuth.setKeyboard(screenName, false)
                screen: surface.screen
                // The desktop's wallpaper, carried on from where it is now — the
                // same settings are read from the theme; this is the moment.
                wallPhase: Services.WallMotion.phaseFor(surface.screen ? String(surface.screen.name) : "")
                userName: lock.displayName
                subtitle: "Locked"
                // Your ~/.face, then the picture the greeter shows.
                pictures: [Quickshell.env("HOME") + "/.face",
                           "/var/lib/AccountsService/icons/" + Services.SysInfo.user]
                statusText: lockAuth.status || lockAuth.pamMessage || lockAuth.info

                onPower: action => {
                    if (action === "suspend") Services.Session.suspend();
                    else if (action === "reboot") Services.Session.reboot();
                    else if (action === "poweroff") Services.Session.powerOff();
                }

                // The things worth knowing without unlocking.
                corner: Component {
                    Row {
                        spacing: 18

                        Row {
                            spacing: 7
                            visible: surface.hasBattery
                            MonoIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: surface.battery && surface.battery.state === UPowerDeviceState.Charging
                                      ? "batteryCharging" : "battery"
                                size: 15
                                inkColor: view.fg3
                                monochrome: true
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: surface.hasBattery
                                      ? Math.round(surface.battery.percentage * 100) + "%" : ""
                                font.pixelSize: Config.Appearance.fs(12)
                                color: view.fg3
                            }
                        }

                        Row {
                            spacing: 7
                            MonoIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: Services.Network.icon
                                size: 15
                                inkColor: view.fg3
                                monochrome: true
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Services.Network.label
                                font.pixelSize: Config.Appearance.fs(12)
                                color: view.fg3
                            }
                        }

                        Row {
                            spacing: 7
                            visible: Services.Notifications.count > 0
                            MonoIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                name: "bell"
                                size: 15
                                inkColor: view.fg3
                                monochrome: true
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Services.Notifications.count
                                      + (Services.Notifications.count === 1
                                         ? " notification" : " notifications")
                                font.pixelSize: Config.Appearance.fs(12)
                                color: view.fg3
                            }
                        }
                    }
                }
            }

            // The lock is drawn over every layer, the screen corners
            // included, so it rounds its own (Settings → Appearance).
            Repeater {
                model: {
                    const A = Config.Appearance;
                    const name = String(surface.screen ? surface.screen.name : "");
                    if (!A.screenCorners || A.screenCornerRadius <= 0) return [];
                    if (A.screenCornerScreens !== "all" && !/^(eDP|LVDS|DSI)/.test(name)) return [];
                    const out = [];
                    if (A.screenCornerTL) out.push({ turn: 0,   right: false, bottom: false });
                    if (A.screenCornerTR) out.push({ turn: 90,  right: true,  bottom: false });
                    if (A.screenCornerBR) out.push({ turn: 180, right: true,  bottom: true });
                    if (A.screenCornerBL) out.push({ turn: 270, right: false, bottom: true });
                    return out;
                }
                CornerPiece {
                    required property var modelData
                    z: 1000
                    radius: Config.Appearance.screenCornerRadius
                    turn: modelData.turn
                    x: modelData.right ? surface.width - width : 0
                    y: modelData.bottom ? surface.height - height : 0
                    guard: true
                    origin: surface.screen ? Qt.point(surface.screen.x + x, surface.screen.y + y) : Qt.point(0, 0)
                }
            }
        }
    }
}
