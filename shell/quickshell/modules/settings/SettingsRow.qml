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

    // Where popups (dropdowns, the colour picker) are drawn. They reparent
    // into it so the pane's clipping and the rows painted after them stop
    // applying. Null is fine — they fall back to being drawn in place.
    property Item overlay: null

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
                case "text":   return textComponent;
                case "keybind": return keybindComponent;
                default:       return infoComponent;
                }
            }
        }
    }

    // ── controls ──────────────────────────────────────────────────────────

    // Records the next chord you press. There is no portable way to ask a
    // compositor for a key name, so this builds Hyprland's own spelling from
    // the Qt event: modifiers in its order, then the key.
    Component {
        id: keybindComponent

        Rectangle {
            id: capture
            property bool listening: false

            width: 196
            height: 30
            radius: Config.Appearance.rSm
            color: listening ? Config.Appearance.accent
                             : (capHover.hovered ? Config.Appearance.sel
                                                 : Config.Appearance.hover)
            border.width: 1
            border.color: listening ? Config.Appearance.accent : Config.Appearance.rule

            StyledText {
                anchors.centerIn: parent
                width: parent.width - 16
                horizontalAlignment: Text.AlignHCenter
                elide: Text.ElideRight
                text: capture.listening ? "Press a shortcut…" : (root.spec.value || "unset")
                font.pixelSize: Config.Appearance.fs(12)
                font.weight: Font.DemiBold
                font.family: capture.listening ? Config.Appearance.fontFamily
                                               : Config.Appearance.monoFamily
                color: capture.listening ? Config.Appearance.onAccent : Config.Appearance.ink
            }

            HoverHandler { id: capHover; cursorShape: Qt.PointingHandCursor }
            TapHandler {
                onTapped: { capture.listening = !capture.listening; if (capture.listening) capture.forceActiveFocus(); }
            }

            focus: capture.listening
            Keys.onPressed: event => {
                if (!capture.listening) return;
                event.accepted = true;

                if (event.key === Qt.Key_Escape) { capture.listening = false; return; }
                // Backspace clears back to the default rather than binding it.
                if (event.key === Qt.Key_Backspace) {
                    capture.listening = false;
                    root.spec.set("");
                    return;
                }
                const bareMod =
                    event.key === Qt.Key_Super_L || event.key === Qt.Key_Super_R
                    || event.key === Qt.Key_Shift || event.key === Qt.Key_Control
                    || event.key === Qt.Key_Alt || event.key === Qt.Key_Meta
                    || event.key === Qt.Key_Hyper_L || event.key === Qt.Key_Hyper_R;

                // A modifier on its own is not a shortcut, so normally the
                // capture waits for the real key. The probe row is the
                // exception: reporting *which* modifier a key produces is
                // the entire point of it.
                if (bareMod) {
                    if (!root.spec.probe) return;
                    capture.listening = false;
                    root.spec.set(root.modNameFor(event.key));
                    return;
                }

                const parts = [];
                if (event.modifiers & Qt.MetaModifier) parts.push("SUPER");
                if (event.modifiers & Qt.ControlModifier) parts.push("CTRL");
                if (event.modifiers & Qt.AltModifier) parts.push("ALT");
                if (event.modifiers & Qt.ShiftModifier) parts.push("SHIFT");
                parts.push(root.hyprKeyName(event));
                capture.listening = false;
                root.spec.set(parts.join(" + "));
            }
        }
    }

    // Which modifier a bare key press is, in Hyprland's spelling. Qt maps
    // X11/Wayland Mod4 to MetaModifier and reports the key as Super_L, so a
    // standard Windows key lands here as SUPER.
    function modNameFor(key) {
        switch (key) {
        case Qt.Key_Super_L:
        case Qt.Key_Super_R:
        case Qt.Key_Meta:    return "SUPER";
        case Qt.Key_Control: return "CTRL";
        case Qt.Key_Alt:     return "ALT";
        case Qt.Key_Shift:   return "SHIFT";
        case Qt.Key_Hyper_L:
        case Qt.Key_Hyper_R: return "HYPER";
        }
        return "unknown";
    }

    // Qt key → the name Hyprland expects. Letters and digits are themselves;
    // the rest are xkb keysym names, which is what Hyprland parses.
    function hyprKeyName(event) {
        const k = event.key;
        if (k >= Qt.Key_A && k <= Qt.Key_Z) return String.fromCharCode(k);
        if (k >= Qt.Key_0 && k <= Qt.Key_9) return String.fromCharCode(k);
        if (k >= Qt.Key_F1 && k <= Qt.Key_F12) return "F" + (k - Qt.Key_F1 + 1);
        switch (k) {
        case Qt.Key_Space:     return "SPACE";
        case Qt.Key_Return:
        case Qt.Key_Enter:     return "Return";
        case Qt.Key_Tab:       return "Tab";
        case Qt.Key_Comma:     return "comma";
        case Qt.Key_Period:    return "period";
        case Qt.Key_Slash:     return "slash";
        case Qt.Key_Semicolon: return "semicolon";
        case Qt.Key_Apostrophe:return "apostrophe";
        case Qt.Key_BracketLeft:  return "bracketleft";
        case Qt.Key_BracketRight: return "bracketright";
        case Qt.Key_Minus:     return "minus";
        case Qt.Key_Equal:     return "equal";
        case Qt.Key_Backslash: return "backslash";
        case Qt.Key_Grave:     return "grave";
        case Qt.Key_Left:      return "left";
        case Qt.Key_Right:     return "right";
        case Qt.Key_Up:        return "up";
        case Qt.Key_Down:      return "down";
        case Qt.Key_Home:      return "Home";
        case Qt.Key_End:       return "End";
        case Qt.Key_PageUp:    return "Prior";
        case Qt.Key_PageDown:  return "Next";
        case Qt.Key_Delete:    return "Delete";
        case Qt.Key_Print:     return "Print";
        }
        // Fall back to the text the key produced, which covers most of the
        // rest of a standard layout.
        return event.text ? event.text.toUpperCase() : "";
    }

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

                // Committed on release only, and this is not about cost.
                //
                // The pane's Repeater is driven by `settings.rows`, which is
                // a binding that returns a *new array* whenever any value it
                // reads changes. So writing a value mid-drag rebuilds the
                // model, the Repeater destroys and recreates every delegate,
                // and the slider under the pointer is destroyed along with
                // the mouse grab it was holding. That is the whole reason
                // these felt stuck: the drag was being cut, repeatedly.
                //
                // Throttling only changed how often it happened. The fill
                // already tracks the pointer through dragValue without any
                // help from the model, so nothing is lost by waiting.
                onReleased: v => root.spec.set(toSteps(v))
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

            // A pane switch rebuilds the rows underneath an open menu, so
            // close it rather than leave one pointing at a row that is gone.
            Connections {
                target: root.overlay
                enabled: root.overlay !== null
                function onPaneChanged() { menuRoot.open = false; }
            }
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
                    size: 15
                    inkColor: Config.Appearance.ink3
                    monochrome: true
                    rotation: menuRoot.open ? 180 : 0
                    Behavior on rotation { NumberAnimation { duration: 160 } }
                }

                HoverHandler { id: menuHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: menuRoot.open = !menuRoot.open }
            }

            // Drawn in the window's popup layer rather than here, so the
            // scrolling pane can't clip it and the rows below can't paint
            // over it. Its position is mapped from this button each frame,
            // so it follows the row when the pane scrolls.
            Rectangle {
                id: menuPopup
                parent: root.overlay || menuRoot
                visible: menuRoot.open
                z: 100

                // mapToItem is a plain function call, so this binding has
                // to be told what to watch: reading the overlay's scroll
                // offset and this row's own geometry is what makes it
                // re-run when the row moves. Without that it evaluated once
                // — before layout, when everything was still at 0 — and the
                // popup stayed there.
                readonly property point anchorPoint: {
                    if (!root.overlay) return Qt.point(0, menuRoot.height);
                    void root.overlay.scrollY;
                    void root.overlay.pane;
                    void root.overlay.width;
                    void root.overlay.height;
                    void root.y;
                    void root.width;
                    return menuRoot.mapToItem(root.overlay, 0, menuRoot.height);
                }

                x: anchorPoint.x
                // Opens downward unless there genuinely isn't room. The
                // previous test flipped whenever the overlay's height read
                // as 0 — which it does before layout — so menus near the top
                // of the pane opened upwards for no reason.
                readonly property bool flipUp: {
                    if (!root.overlay) return false;
                    const avail = root.overlay.height;
                    if (avail <= 0 || height <= 0) return false;
                    const below = avail - (anchorPoint.y + 4);
                    if (below >= height) return false;
                    // Only flip if there is actually more space above.
                    return (anchorPoint.y - menuRoot.height - 4) > below;
                }
                y: flipUp ? anchorPoint.y - menuRoot.height - height - 4
                          : anchorPoint.y + 4
                width: menuRoot.width
                height: optionColumn.implicitHeight + 8
                radius: Config.Appearance.rSm
                // Mostly opaque by default, adjustable in Appearance. This
                // floats over the window's own rows rather than the desktop,
                // so what shows through is text — readable at a little
                // translucency, not at a lot.
                color: Config.Appearance.menuSurface
                border.width: 1
                border.color: Config.Appearance.edge

                // Frosted glass behind the menu. Via a Loader with a URL, not
                // a direct import: BlurBackdrop pulls in QtQuick.Effects, and
                // if that module is missing this degrades to an unfrosted
                // menu instead of the whole shell failing to load.
                Loader {
                    id: menuBlur
                    anchors.fill: parent
                    z: -1
                    active: Config.Appearance.menuBlur
                            && root.overlay !== null
                            && menuRoot.open
                    source: "../common/BlurBackdrop.qml"
                    onLoaded: {
                        item.sourceItem = Qt.binding(
                            () => root.overlay ? root.overlay.backdrop : null);
                        // The sample is taken in the backdrop's own
                        // coordinates. Both it and this popup's overlay are
                        // anchored children of the window frame, so the
                        // offset between them is the backdrop's own x and y —
                        // no mapToItem, and therefore nothing to go stale.
                        item.sampleRect = Qt.binding(() => {
                            const b = root.overlay ? root.overlay.backdrop : null;
                            if (!b) return Qt.rect(0, 0, 0, 0);
                            return Qt.rect(menuPopup.x - b.x, menuPopup.y - b.y,
                                           menuPopup.width, menuPopup.height);
                        });
                        item.radius = Qt.binding(() => Config.Appearance.rSm);
                    }
                }


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
                                size: 14
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
                        size: 16
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
                    size: 16
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

                // Same treatment as the dropdown: drawn in the window's
                // popup layer, because the accent row sits near the top of a
                // scrolling pane that clips, and the picker is tall enough
                // that its hex field was being cut off entirely.
                ColorPicker {
                    id: picker
                    parent: root.overlay || customSwatch
                    z: 200

                    // Same as the dropdown: mapToItem can't be tracked, so
                    // the dependencies are read explicitly.
                    readonly property point anchorPoint: {
                        if (!root.overlay)
                            return Qt.point(customSwatch.width / 2, customSwatch.height);
                        void root.overlay.scrollY;
                        void root.overlay.pane;
                        void root.overlay.width;
                        void root.overlay.height;
                        void root.y;
                        void root.width;
                        return customSwatch.mapToItem(root.overlay,
                                                      customSwatch.width / 2,
                                                      customSwatch.height);
                    }

                    // Kept inside the window on both axes, and flipped above
                    // the swatch when there isn't room beneath it.
                    x: root.overlay
                       ? Math.max(8, Math.min(anchorPoint.x - width / 2,
                                              root.overlay.width - width - 8))
                       : -width / 2
                    readonly property bool flipUp: {
                        if (!root.overlay) return false;
                        const avail = root.overlay.height;
                        if (avail <= 0 || height <= 0) return false;
                        const below = avail - (anchorPoint.y + 8);
                        if (below >= height) return false;
                        return (anchorPoint.y - customSwatch.height - 8) > below;
                    }
                    y: flipUp ? anchorPoint.y - customSwatch.height - height - 8
                              : anchorPoint.y + 8

                    backdrop: root.overlay ? root.overlay.backdrop : null
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
        id: textComponent

        // A typed value — a Wi-Fi password, for now. Committed on Enter or
        // on the button, not on every keystroke: half a password is not a
        // password, and joining a network is not something to attempt
        // sixteen times on the way to typing one.
        Row {
            spacing: 8

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: 190
                implicitHeight: 32
                radius: Config.Appearance.rSm
                color: Config.Appearance.ground
                border.width: field.activeFocus ? 2 : 1
                border.color: field.activeFocus ? Config.Appearance.accent
                                                : Config.Appearance.rule

                TextInput {
                    id: field
                    anchors.fill: parent
                    anchors.leftMargin: 10
                    anchors.rightMargin: 10
                    verticalAlignment: Text.AlignVCenter
                    clip: true
                    color: Config.Appearance.ink
                    font.family: Config.Appearance.fontFamily
                    font.pixelSize: Config.Appearance.fs(12)
                    echoMode: root.spec.secret ? TextInput.Password : TextInput.Normal
                    selectByMouse: true
                    onAccepted: root.spec.set(text)

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: field.text === "" && !field.activeFocus
                        text: root.spec.placeholder || ""
                        font.pixelSize: Config.Appearance.fs(12)
                        color: Config.Appearance.ink3
                    }
                }
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: goLabel.implicitWidth + 24
                implicitHeight: 32
                radius: Config.Appearance.rSm
                color: Config.Appearance.accent
                opacity: goHover.hovered ? 0.9 : 1

                StyledText {
                    id: goLabel
                    anchors.centerIn: parent
                    text: root.spec.label || "Go"
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.DemiBold
                    color: Config.Appearance.onAccent
                }

                HoverHandler { id: goHover; cursorShape: Qt.PointingHandCursor }
                TapHandler { onTapped: root.spec.set(field.text) }
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
