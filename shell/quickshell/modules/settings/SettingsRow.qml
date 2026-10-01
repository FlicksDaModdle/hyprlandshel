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
//   gallery pictures to pick from, full width under the labels
//   color   a swatch that opens the colour picker
//   buttons several accent buttons, from spec.buttons [{ label, set }]
//   panel   a whole pane of its own, full width: spec.panel is "wifi" or
//           "bluetooth" (WifiPanel.qml, BluetoothPanel.qml)
Item {
    id: root

    required property var spec
    property bool showRule: true

    // Where popups (dropdowns, the colour picker) are drawn. They reparent
    // into it so the pane's clipping and the rows painted after them stop
    // applying. Null is fine — they fall back to being drawn in place.
    property Item overlay: null

    readonly property bool isHeader: root.spec.type === "header"
    // The control goes under the labels, across the whole row.
    readonly property bool isWide: root.spec.type === "gallery" || root.spec.type === "panel"
    readonly property bool hasLabels: !!(root.spec.n || root.spec.s)

    implicitWidth: parent ? parent.width : 560
    implicitHeight: root.isHeader
        ? labels.implicitHeight + 34
        : root.isWide
        ? (root.hasLabels ? labels.implicitHeight + 10 : 0) + control.implicitHeight + 26
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
        visible: !root.isWide || root.hasLabels
        anchors.left: parent.left
        anchors.right: root.isHeader || root.isWide ? parent.right : control.left
        anchors.rightMargin: root.isHeader || root.isWide ? 0 : 24
        anchors.top: root.isWide ? parent.top : undefined
        anchors.topMargin: 13
        anchors.verticalCenter: root.isWide ? undefined : parent.verticalCenter
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
        anchors.verticalCenter: root.isWide ? undefined : parent.verticalCenter
        anchors.bottom: root.isWide ? parent.bottom : undefined
        anchors.bottomMargin: 13
        implicitWidth: root.isHeader ? 0 : loader.implicitWidth
        implicitHeight: root.isHeader ? 0 : loader.implicitHeight
        width: root.isWide ? root.width : implicitWidth
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
                case "monitors": return monitorsComponent;
                case "gallery": return galleryComponent;
                case "panel":  return root.spec.panel === "bluetooth" ? bluetoothComponent : wifiComponent;
                case "color":  return colorComponent;
                case "buttons": return buttonsComponent;
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
                color: capture.listening ? Config.Appearance.inkOnAccent : Config.Appearance.ink
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
                value: (root.spec.value - root.spec.min) / Math.max(1e-9, root.spec.max - root.spec.min)

                // Whole numbers unless the spec gives a finer `step`, as a
                // live wallpaper's options do (0 to 1 by 0.01, say).
                readonly property real step: root.spec.step > 0 ? root.spec.step : 1
                readonly property int places: step >= 1 ? 0 : Math.min(4, Math.ceil(-Math.log(step) / Math.LN10 - 1e-9))
                function snap(x) {
                    const n = Math.round((x - root.spec.min) / step) * step + root.spec.min;
                    return Number(Math.max(root.spec.min, Math.min(root.spec.max, n)).toFixed(places));
                }
                function toSteps(v) {
                    return snap(root.spec.min + v * (root.spec.max - root.spec.min));
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
                        text: (slider.dragging ? slider.toSteps(slider.shownValue)
                                               : Number(root.spec.value)).toFixed(slider.places)
                        color: Config.Appearance.ink
                        font.family: Config.Appearance.fontFamily
                        font.pixelSize: Config.Appearance.fs(12)
                        font.weight: Font.DemiBold
                        selectByMouse: true
                        selectionColor: Config.Appearance.accent
                        selectedTextColor: Config.Appearance.inkOnAccent
                        inputMethodHints: slider.places > 0 ? Qt.ImhFormattedNumbersOnly : Qt.ImhDigitsOnly

                        function commit() {
                            const v = parseFloat(text);
                            if (isNaN(v)) { text = Number(root.spec.value).toFixed(slider.places); return; }
                            root.spec.set(slider.snap(v));
                        }

                        onEditingFinished: commit()
                        Keys.onReturnPressed: { commit(); focus = false; }
                        Keys.onEscapePressed: { text = Number(root.spec.value).toFixed(slider.places); focus = false; }
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

            // What the value looks like, for a slider whose spec has a
            // `preview` (value → colour): drawn as an outline, since the
            // ones that use it set a window border. Follows the drag, like
            // the number, so the shade can be found before letting go.
            Rectangle {
                visible: typeof root.spec.preview === "function"
                anchors.verticalCenter: parent.verticalCenter
                width: 26
                height: 26
                radius: Config.Appearance.rSm
                color: "transparent"
                border.width: 3
                border.color: visible
                    ? root.spec.preview(slider.dragging ? slider.toSteps(slider.shownValue)
                                                        : root.spec.value)
                    : "transparent"
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
            // Wide enough for the longest option it holds, and 168 at the
            // narrowest so the short menus look as they always did.
            //
            // Every menu in these panes used to carry a resolution or a
            // percentage, and 168 was plenty; the colour presets are
            // sentences. Neither label elided, so one that didn't fit
            // painted straight over the chevron and out of the box rather
            // than being cut off tidily.
            //
            // Measured with the same text component that draws them — the
            // font size is a setting, so a number worked out once would be
            // wrong for anyone who moved it. A Column skips children that
            // are not visible, but an invisible Column still lays its own
            // out, so this costs nothing and is never painted.
            Column {
                id: sizer
                visible: false
                Repeater {
                    model: root.spec.options
                    StyledText {
                        required property var modelData
                        text: String(modelData)
                        font.pixelSize: Config.Appearance.fs(12)
                        font.weight: Font.DemiBold
                    }
                }
            }

            // 10 + 10 either side, 17 for the chevron, and enough of a gap
            // that the longest label is not touching it. Capped, because a
            // pathological option should cost the description beside it a
            // line of wrapping, not the whole row.
            implicitWidth: Math.max(168, Math.min(320, sizer.implicitWidth + 46))
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
                    // Elides rather than overflowing, for whatever is
                    // longer than the cap above.
                    anchors.right: chevron.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    text: root.spec.value
                    font.pixelSize: Config.Appearance.fs(12)
                    font.weight: Font.DemiBold
                }

                MonoIcon {
                    id: chevron
                    anchors.right: parent.right
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevronDown"
                    size: 17
                    inkColor: Config.Appearance.ink3
                    monochrome: true
                    rotation: menuRoot.open ? 180 : 0
                    Behavior on rotation { NumberAnimation { duration: Config.Appearance.anim(160) } }
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
                                // The tick is always there to anchor
                                // against, whether or not it is drawn: an
                                // invisible item still has a geometry.
                                anchors.right: tick.left
                                anchors.rightMargin: 4
                                anchors.verticalCenter: parent.verticalCenter
                                elide: Text.ElideRight
                                text: option.modelData
                                font.pixelSize: Config.Appearance.fs(12)
                            }

                            MonoIcon {
                                id: tick
                                anchors.right: parent.right
                                anchors.rightMargin: 9
                                anchors.verticalCenter: parent.verticalCenter
                                visible: option.modelData === root.spec.value
                                name: "check"
                                size: 16
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
                        size: 18
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
                    size: 18
                    inkColor: Config.Appearance.inkOnAccent
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
                    // What it is set to now, where that is not a secret.
                    text: root.spec.secret ? "" : (root.spec.value || "")
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
                    color: Config.Appearance.inkOnAccent
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
                color: Config.Appearance.inkOnAccent
            }

            HoverHandler { id: actionHover; cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: root.spec.set() }
        }
    }

    // The display arrangement. Wider and taller than any other control
    // because it is a picture of your desk rather than a value.
    Component {
        id: monitorsComponent
        MonitorMap {
            implicitWidth: 360
            implicitHeight: 190
            monitors: root.spec.monitors || []
            selected: root.spec.value || ""
            onPicked: name => { if (root.spec.pick) root.spec.pick(name); }
            onMoved: (name, x, y) => { if (root.spec.set) root.spec.set(name, x, y); }
        }
    }

    // A colour to set: the swatch, and the shell's own picker under it.
    Component {
        id: colorComponent
        Rectangle {
            id: colorSwatch
            implicitWidth: 44
            implicitHeight: 28
            radius: Config.Appearance.rSm
            color: root.spec.value || "black"
            border.width: 1
            border.color: Config.Appearance.div

            HoverHandler { cursorShape: Qt.PointingHandCursor }
            TapHandler { onTapped: colorPicker.open = !colorPicker.open }

            // Placed as the accent's picker is (see swatchComponent).
            ColorPicker {
                id: colorPicker
                parent: root.overlay || colorSwatch
                z: 200
                readonly property point anchorPoint: {
                    if (!root.overlay)
                        return Qt.point(colorSwatch.width / 2, colorSwatch.height);
                    void root.overlay.scrollY;
                    void root.overlay.pane;
                    void root.overlay.width;
                    void root.overlay.height;
                    void root.y;
                    void root.width;
                    return colorSwatch.mapToItem(root.overlay, colorSwatch.width / 2, colorSwatch.height);
                }
                x: root.overlay
                   ? Math.max(8, Math.min(anchorPoint.x - width / 2, root.overlay.width - width - 8))
                   : -width / 2
                readonly property bool flipUp: {
                    if (!root.overlay) return false;
                    const avail = root.overlay.height;
                    if (avail <= 0 || height <= 0) return false;
                    const below = avail - (anchorPoint.y + 8);
                    if (below >= height) return false;
                    return (anchorPoint.y - colorSwatch.height - 8) > below;
                }
                y: flipUp ? anchorPoint.y - colorSwatch.height - height - 8 : anchorPoint.y + 8
                backdrop: root.overlay ? root.overlay.backdrop : null
                value: root.spec.value || "black"
                onPicked: c => root.spec.set(c)
            }
        }
    }

    // A few actions on one thing, side by side.
    Component {
        id: buttonsComponent
        Row {
            spacing: 8
            Repeater {
                model: root.spec.buttons || []
                Rectangle {
                    id: btn
                    required property var modelData
                    readonly property bool quiet: !!modelData.quiet
                    anchors.verticalCenter: parent.verticalCenter
                    implicitWidth: btnLabel.implicitWidth + 24
                    implicitHeight: 32
                    radius: Config.Appearance.rSm
                    color: quiet ? (btnHover.hovered ? Config.Appearance.sel : Config.Appearance.hover)
                                 : Config.Appearance.accent
                    border.width: quiet ? 1 : 0
                    border.color: Config.Appearance.rule
                    opacity: modelData.enabled === false ? 0.45 : (btnHover.hovered && !quiet ? 0.9 : 1)

                    StyledText {
                        id: btnLabel
                        anchors.centerIn: parent
                        text: btn.modelData.label
                        font.pixelSize: Config.Appearance.fs(12)
                        font.weight: Font.DemiBold
                        color: btn.quiet ? Config.Appearance.ink : Config.Appearance.inkOnAccent
                    }

                    HoverHandler {
                        id: btnHover
                        cursorShape: btn.modelData.enabled === false ? Qt.ArrowCursor : Qt.PointingHandCursor
                    }
                    TapHandler {
                        enabled: btn.modelData.enabled !== false
                        onTapped: btn.modelData.set()
                    }
                }
            }
        }
    }

    Component {
        id: wifiComponent
        WifiPanel { width: control.width }
    }
    Component {
        id: bluetoothComponent
        BluetoothPanel { width: control.width }
    }

    Component {
        id: galleryComponent
        WallpaperGallery {
            width: control.width
            items: root.spec.items || []
            value: root.spec.value || ""
            multi: !!root.spec.multi
            selection: root.spec.selection || []
            state: root.spec.state || null
            onPicked: dir => { if (root.spec.pick) root.spec.pick(dir); }
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
