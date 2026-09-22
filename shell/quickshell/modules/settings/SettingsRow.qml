import QtQuick
import Quickshell
import "../../config" as Config
import "../common"
import "../icons"

// One row in a Settings pane: name and description on the left, a control on
// the right chosen by `spec.type`.
//
//   seg     segmented control      slider  fill slider + numeric field
//   toggle  pill switch            menu    dropdown
//   swatch  accent picker          info    read-only value
//   meter   labelled bar           action  accent button
//   header  a group caption, no control — used to break a pane into
//           sections, one per display or per device
Item {
    id: root

    required property var spec
    property bool showRule: true

    readonly property bool isHeader: root.spec.type === "header"

    implicitWidth: parent ? parent.width : 560
    implicitHeight: root.isHeader
        ? labels.implicitHeight + 34
        : Math.max(labels.implicitHeight, control.implicitHeight) + 26

    Rectangle {
        // A header draws its own separator above itself and owns the space,
        // so the row rule would double it.
        visible: root.showRule && !root.isHeader
        anchors.top: parent.top
        width: parent.width
        height: 1
        color: Config.Appearance.rule
    }

    Column {
        id: labels
        anchors.left: parent.left
        anchors.right: root.isHeader ? parent.right : control.left
        anchors.rightMargin: root.isHeader ? 0 : 24
        anchors.verticalCenter: parent.verticalCenter
        anchors.verticalCenterOffset: root.isHeader ? 6 : 0
        spacing: 3

        StyledText {
            width: parent.width
            elide: Text.ElideRight
            text: root.spec.n || ""
            font.pixelSize: root.isHeader ? 12 : 13
            font.weight: root.isHeader ? Font.DemiBold : Font.Medium
            font.capitalization: root.isHeader ? Font.AllUppercase : Font.MixedCase
            font.letterSpacing: root.isHeader ? 0.6 : 0
            color: root.isHeader ? Config.Appearance.ink3 : Config.Appearance.ink
        }
        StyledText {
            width: parent.width
            wrapMode: Text.WordWrap
            text: root.spec.s || ""
            font.pixelSize: Config.Appearance.fs(12)
            font.weight: Font.Normal
            color: Config.Appearance.ink3
        }
    }

    Item {
        id: control
        visible: !root.isHeader
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: root.isHeader ? 0 : loader.implicitWidth
        implicitHeight: root.isHeader ? 0 : loader.implicitHeight
        width: implicitWidth
        height: implicitHeight

        Loader {
            id: loader
            active: !root.isHeader
            sourceComponent: {
                switch (root.spec.type) {
                case "seg":    return segComponent;
                case "slider": return sliderComponent;
                case "toggle": return toggleComponent;
                case "menu":   return menuComponent;
                case "swatch": return swatchComponent;
                case "meter":  return meterComponent;
                case "action": return actionComponent;
                default:       return infoComponent;
                }
            }
        }
    }

    // ── controls ──────────────────────────────────────────────────────────

    Component {
        id: segComponent
        Segmented {
            options: root.spec.options
            value: root.spec.value
            onSelected: v => root.spec.set(v)
        }
    }

    Component {
        id: toggleComponent
        Toggle {
            checked: root.spec.value
            onToggled: on => root.spec.set(on)
        }
    }

    Component {
        id: sliderComponent
        Row {
            spacing: 12

            FillSlider {
                id: slider
                anchors.verticalCenter: parent.verticalCenter
                width: 216
                trough: 20
                showRule: true
                value: (root.spec.value - root.spec.min) / Math.max(1, root.spec.max - root.spec.min)

                function toSteps(v) {
                    return Math.round(root.spec.min + v * (root.spec.max - root.spec.min));
                }

                // Committing on every pixel of travel is what made these
                // feel stuck: each one wrote theme.json, or — for a device
                // setting — spawned an hyprctl. Dragging fired hundreds.
                // The fill follows the pointer live off dragValue; the value
                // itself is written at most every 80ms, and always once more
                // on release so the last position is never lost.
                property int pendingValue: 0
                onMoved: v => { pendingValue = toSteps(v); throttle.start(); }
                onReleased: v => {
                    throttle.stop();
                    root.spec.set(toSteps(v));
                }

                Timer {
                    id: throttle
                    interval: 80
                    repeat: false
                    onTriggered: root.spec.set(slider.pendingValue)
                }
            }

            // Numeric readout, typed into directly.
            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 74
                height: 26
                radius: Config.Appearance.rSm
                color: Config.Appearance.hover
                border.width: 1
                border.color: field.activeFocus ? Config.Appearance.accent : Config.Appearance.rule

                Row {
                    anchors.centerIn: parent
                    spacing: 3

                    TextInput {
                        id: field
                        anchors.verticalCenter: parent.verticalCenter
                        width: 34
                        horizontalAlignment: Text.AlignRight
                        // Follows the drag rather than the committed value,
                        // which is throttled — otherwise the number visibly
                        // stutters behind the fill.
                        text: slider.dragging
                              ? slider.toSteps(slider.shownValue) : root.spec.value
                        color: Config.Appearance.ink
                        font.family: Config.Appearance.fontFamily
                        font.pixelSize: Config.Appearance.fs(12)
                        font.weight: Font.DemiBold
                        selectByMouse: true
                        selectionColor: Config.Appearance.accent
                        selectedTextColor: Config.Appearance.onAccent
                        inputMethodHints: Qt.ImhDigitsOnly
                        validator: IntValidator { bottom: root.spec.min; top: root.spec.max }

                        function commit() {
                            const v = parseInt(text);
                            if (isNaN(v)) { text = root.spec.value; return; }
                            root.spec.set(Math.max(root.spec.min, Math.min(root.spec.max, v)));
                        }

                        onEditingFinished: commit()
                        Keys.onReturnPressed: { commit(); focus = false; }
                        Keys.onEscapePressed: { text = root.spec.value; focus = false; }
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.spec.unit || ""
                        font.pixelSize: Config.Appearance.fs(11)
                        font.weight: Font.Normal
                        color: Config.Appearance.ink3
                    }
                }
            }
        }
    }

    Component {
        id: menuComponent

        Item {
            id: menuRoot
            property bool open: false
            implicitWidth: 168
            implicitHeight: 32

            Rectangle {
                anchors.fill: parent
                radius: Config.Appearance.rSm
                color: menuHover.hovered ? Config.Appearance.sel : Config.Appearance.hover
                border.width: 1
                border.color: Config.Appearance.rule

                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.spec.value
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.DemiBold
                }

                MonoIcon {
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevronDown"
                    size: 13
                    inkColor: Config.Appearance.ink3
                    monochrome: true
                    rotation: menuRoot.open ? 180 : 0
                    Behavior on rotation { NumberAnimation { duration: 160 } }
                }

                HoverHandler { id: menuHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: menuRoot.open = !menuRoot.open }
            }

            // Drawn inside the Settings window, above the rows below it.
            Rectangle {
                visible: menuRoot.open
                z: 100
                anchors.top: parent.bottom
                anchors.topMargin: 4
                anchors.right: parent.right
                width: parent.width
                height: optionColumn.implicitHeight + 8
                radius: Config.Appearance.rSm
                // Opaque, not `sheet`. This popup is drawn inside the
                // Settings window, so a translucent fill has nothing blurred
                // behind it — it shows the rows underneath straight through
                // itself, and the options become unreadable.
                color: Config.Appearance.solid
                border.width: 1
                border.color: Config.Appearance.edge

                Column {
                    id: optionColumn
                    anchors.fill: parent
                    anchors.margins: 4
                    spacing: 1

                    Repeater {
                        model: root.spec.options

                        Rectangle {
                            id: option
                            required property var modelData
                            width: optionColumn.width
                            height: 29
                            radius: Config.Appearance.rSm
                            color: optionHover.hovered ? Config.Appearance.hover : "transparent"

                            StyledText {
                                anchors.left: parent.left
                                anchors.leftMargin: 9
                                anchors.verticalCenter: parent.verticalCenter
                                text: option.modelData
                                font.pixelSize: Config.Appearance.fs(12)
                            }

                            MonoIcon {
                                anchors.right: parent.right
                                anchors.rightMargin: 9
                                anchors.verticalCenter: parent.verticalCenter
                                visible: option.modelData === root.spec.value
                                name: "check"
                                size: 12
                                inkColor: Config.Appearance.accent
                                monochrome: true
                            }

                            HoverHandler { id: optionHover; cursorShape: Qt.PointingHandCursor }
                            TapHandler {
                                onTapped: {
                                    menuRoot.open = false;
                                    root.spec.set(option.modelData);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: swatchComponent

        Row {
            spacing: 8

            Repeater {
                model: Config.Appearance.accentPresets

                Rectangle {
                    id: swatch
                    required property var modelData
                    required property int index

                    width: 28
                    height: 28
                    radius: Config.Appearance.rSm
                    color: Config.Appearance.dark ? modelData.dark : modelData.light
                    border.width: 1
                    border.color: Config.Appearance.rule

                    // Selection ring, drawn outside the swatch.
                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.width + 6
                        height: parent.height + 6
                        radius: parent.radius + 3
                        color: "transparent"
                        border.width: Config.Appearance.accentIndex === swatch.index ? 2 : 0
                        border.color: Config.Appearance.ink
                    }

                    MonoIcon {
                        anchors.centerIn: parent
                        visible: Config.Appearance.accentIndex === swatch.index
                        name: "check"
                        size: 14
                        inkColor: Config.Appearance.dark ? "#201e1d" : "#fff2ef"
                        monochrome: true
                    }

                    HoverHandler { cursorShape: Qt.PointingHandCursor }
                    TapHandler { onTapped: Config.Appearance.accentIndex = swatch.index }
                }
            }

            // Custom accent. Opens a picker rather than cycling a fixed
            // set of hues, which is what it used to do — that was a
            // workaround for a layer-shell process not being able to host a
            // system colour dialog, and the answer is to draw one in the
            // shell's own vocabulary instead of borrowing the desktop's.
            Rectangle {
                id: customSwatch
                width: 28
                height: 28
                radius: Config.Appearance.rSm
                color: Config.Appearance.customAccent
                border.width: 1
                border.color: Config.Appearance.rule

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width + 6
                    height: parent.height + 6
                    radius: parent.radius + 3
                    color: "transparent"
                    border.width: Config.Appearance.accentIndex === -1 ? 2 : 0
                    border.color: Config.Appearance.ink
                }

                MonoIcon {
                    anchors.centerIn: parent
                    name: Config.Appearance.accentIndex === -1 ? "check" : "plus"
                    size: 14
                    inkColor: Config.Appearance.onAccent
                    monochrome: true
                }

                HoverHandler { cursorShape: Qt.PointingHandCursor }
                TapHandler {
                    onTapped: {
                        Config.Appearance.accentIndex = -1;
                        picker.open = !picker.open;
                    }
                }

                ColorPicker {
                    id: picker
                    z: 200
                    anchors.top: parent.bottom
                    anchors.topMargin: 8
                    anchors.horizontalCenter: parent.horizontalCenter
                    value: Config.Appearance.customAccent
                    onPicked: c => {
                        Config.Appearance.customAccent = c;
                        Config.Appearance.accentIndex = -1;
                    }
                }
            }
        }
    }

    Component {
        id: meterComponent

        Row {
            spacing: 12

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 160
                height: 8
                radius: 4
                color: Config.Appearance.sel
                clip: true

                Rectangle {
                    width: parent.width * Math.max(0, Math.min(1, root.spec.value))
                    height: parent.height
                    radius: 4
                    color: root.spec.color || Config.Appearance.accent
                }
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                width: 44
                horizontalAlignment: Text.AlignRight
                text: root.spec.label
                font.pixelSize: Config.Appearance.fs(13)
                font.weight: Font.DemiBold
                color: Config.Appearance.ink2
            }
        }
    }

    Component {
        id: actionComponent

        Rectangle {
            implicitWidth: actionLabel.implicitWidth + 28
            implicitHeight: 32
            radius: Config.Appearance.rSm
            color: Config.Appearance.accent
            opacity: actionHover.hovered ? 0.9 : 1

            StyledText {
                id: actionLabel
                anchors.centerIn: parent
                text: root.spec.label
                font.pixelSize: Config.Appearance.fs(12)
                font.weight: Font.DemiBold
                color: Config.Appearance.onAccent
            }

            HoverHandler { id: actionHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.spec.set() }
        }
    }

    Component {
        id: infoComponent

        StyledText {
            text: root.spec.value !== undefined ? root.spec.value : ""
            font.pixelSize: Config.Appearance.fs(13)
            font.weight: Font.DemiBold
            color: Config.Appearance.ink2
        }
    }
}
