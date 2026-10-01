import QtQuick
import Hyprshell

// A panel within a view: a soft fill, a hairline, rounded like the shell.
Rectangle {
    radius: Appearance.r
    color: Appearance.hover
    border.width: 1
    border.color: Appearance.rule
}
