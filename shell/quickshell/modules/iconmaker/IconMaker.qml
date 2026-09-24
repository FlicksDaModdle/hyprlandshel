import QtQuick
import Quickshell
import "../../config" as Config
import "../common"
import "../icons"
import "../icons/IconPaths.js" as IconPaths

// Draw an icon in the shell's own style, and keep it.
//
// Shapes rather than curves, on purpose. The style here is not a matter
// of taste that a freer tool would let you express: it is monoline, two
// units wide, round caps, built on a 24 grid out of lines, boxes,
// circles and arcs. Thirty of the built-in glyphs are literally made of
// those primitives and the rest are the same shapes written out by hand.
// A tool with bezier handles would mostly be an efficient way to draw
// something that does not belong next to the others.
//
// So: place a primitive, drag it about, say whether it is ink or accent,
// and watch the real MonoIcon draw the result at the sizes it will
// actually be seen at.
Item {
    id: root

    // `doc`, not `model`. Every Repeater delegate in this file has a
    // `model` of its own in scope, so an id by that name is reachable
    // from the outer scopes and shadowed inside exactly the delegates
    // that need it most — the tool rail and the action buttons.
    IconModel { id: doc }

    property string iconName: ""
    // What was loaded, so Save knows whether it is replacing something.
    property string loadedAs: ""
    property string tool: "select"
    property string nextColour: "ink"
    property int nextWeight: 2
    property real snap: 0.5

    readonly property bool dirty: doc.shapes.length > 0

    readonly property string trimmedName: root.iconName.trim()
    // Names have to survive being a JSON key and a QML property lookup,
    // and must not shadow a built-in glyph — MonoIcon resolves the pack
    // first, so a user icon called "folder" would be unreachable from
    // the moment it was saved.
    readonly property bool nameTaken: IconPaths.has(root.trimmedName)
    readonly property bool nameOk: /^[A-Za-z][A-Za-z0-9_-]{0,31}$/.test(root.trimmedName)
                                   && !root.nameTaken
    readonly property string nameProblem:
        root.trimmedName === "" ? "Give it a name"
        : root.nameTaken ? "The built-in pack already has one called that"
        : !root.nameOk ? "Letters, digits, - and _, starting with a letter"
        : ""

    function reset() {
        doc.replace([], false);
        doc.selected = -1;
        root.iconName = "";
        root.loadedAs = "";
    }

    function load(name) {
        const g = Config.UserIcons.spec(name);
        if (!g) return;
        // Only an icon saved with its shapes can be opened again. One
        // that was hand-written straight into icons.json has paths and
        // nothing else, and there is no way back from a merged path to
        // the shapes that made it — so say so rather than opening an
        // empty canvas that would overwrite it on the next save.
        if (!g.shapes || g.shapes.length === 0) {
            root.notice = "“" + name + "” was written by hand, not drawn here — "
                          + "there are no shapes to open.";
            return;
        }
        doc.replace(JSON.parse(JSON.stringify(g.shapes)), false);
        doc.selected = -1;
        root.iconName = name;
        root.loadedAs = name;
        root.notice = "";
    }

    function save() {
        if (!root.nameOk || !doc.draws()) return;
        Config.UserIcons.put(root.trimmedName, doc.glyph());
        root.loadedAs = root.trimmedName;
        root.notice = "Saved as “" + root.trimmedName + "”";
    }

    property string notice: ""

    // ── window ────────────────────────────────────────────────────────
    FloatingWindow {
        id: win
        title: "Icon Maker"
        color: Config.Appearance.sheet
        implicitWidth: 1000
        implicitHeight: 700

        // Closing the window has to clear the flag that opens it.
        //
        // Without that, the maker opened exactly once per shell: the
        // window's own close button hides the window but does not touch
        // iconMakerOpen, which stays true. Opening it again writes true
        // over true — no change, so nothing re-evaluates, so nothing
        // happens, for the rest of the session. The flag said the window
        // was up and the window was not.
        //
        // The Binding element is the belt to that pair of braces: it
        // re-applies its value whenever it changes, so it also survives
        // the property being written from somewhere else.
        Binding {
            target: win
            property: "visible"
            value: Config.UiState.iconMakerOpen && !Config.UiState.locked
            restoreMode: Binding.RestoreNone
        }

        onVisibleChanged: if (!visible) Config.UiState.iconMakerOpen = false

        Item {
            anchors.fill: parent
            anchors.margins: 16

            // ── tools ─────────────────────────────────────────────────
            Column {
                id: rail
                anchors.left: parent.left
                anchors.top: parent.top
                width: 44
                spacing: 6

                Repeater {
                    model: [
                        { t: "select",  i: "cursor",  n: "Select and move" },
                        { t: "line",    i: "minus",   n: "Line" },
                        { t: "rect",    i: "square",  n: "Rectangle" },
                        { t: "circle",  i: "circle",  n: "Circle" },
                        { t: "ellipse", i: "ellipse", n: "Ellipse" },
                        { t: "arc",     i: "arc",     n: "Arc" },
                        { t: "poly",    i: "poly",    n: "Polyline — click each corner, right-click to finish" },
                        { t: "pen",     i: "pen",     n: "Pen — click for a corner, drag for a curve; click the first point to close" },
                        { t: "dot",     i: "dot",     n: "Dot" }
                    ]

                    Rectangle {
                        id: toolBtn
                        required property var modelData
                        readonly property bool on: root.tool === modelData.t
                        width: 44
                        height: 38
                        radius: Config.Appearance.rSm
                        color: toolBtn.on ? Config.Appearance.accent
                             : (toolHover.hovered ? Config.Appearance.hover : "transparent")

                        MonoIcon {
                            anchors.centerIn: parent
                            name: toolBtn.modelData.i
                            size: 18
                            inkColor: toolBtn.on ? Config.Appearance.inkOnAccent
                                                 : Config.Appearance.ink2
                            monochrome: true
                        }

                        HoverHandler { id: toolHover; cursorShape: Qt.PointingHandCursor }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.tool = toolBtn.modelData.t
                        }
                    }
                }
            }

            // ── canvas ────────────────────────────────────────────────
            IconCanvas {
                id: canvas
                anchors.left: rail.right
                anchors.leftMargin: 14
                anchors.top: parent.top
                width: Math.min(parent.height - bottomBar.height - 12,
                                parent.width - rail.width - side.width - 42)
                height: width
                model: doc
                tool: root.tool
                snap: root.snap
                nextColour: root.nextColour
                nextWeight: root.nextWeight
            }

            Row {
                id: bottomBar
                anchors.left: canvas.left
                anchors.top: canvas.bottom
                anchors.topMargin: 12
                spacing: 10

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Snap"
                    font.pixelSize: Config.Appearance.fs(12)
                    color: Config.Appearance.ink3
                }

                Segmented {
                    anchors.verticalCenter: parent.verticalCenter
                    options: [{ label: "¼", value: "0.25" }, { label: "½", value: "0.5" },
                              { label: "1", value: "1" }, { label: "Off", value: "0" }]
                    value: String(root.snap)
                    onSelected: v => root.snap = parseFloat(v)
                }

                Item { width: 12; height: 1 }

                // A fixed list, with availability worked out in the
                // delegate rather than carried as a field in the array.
                //
                // Written the obvious way, every one of these destroys
                // itself as it is clicked: Undo changes canUndo, which
                // re-evaluates the array, which rebuilds the Repeater's
                // delegates — and the rest of the handler then runs in a
                // scope that no longer exists. The terminal's context
                // menu had exactly this, and every entry in it
                // half-worked.
                Repeater {
                    model: [
                        { n: "Undo",      i: "rotateCw", act: "undo" },
                        { n: "Redo",      i: "refresh",  act: "redo" },
                        { n: "Duplicate", i: "plus",     act: "duplicate" },
                        { n: "Delete",    i: "trash",    act: "delete" },
                        { n: "Clear",     i: "x",        act: "clear" }
                    ]

                    Rectangle {
                        id: actBtn
                        required property var modelData
                        readonly property bool ready: root.actionReady(modelData.act)
                        anchors.verticalCenter: parent.verticalCenter
                        width: 36
                        height: 32
                        radius: Config.Appearance.rSm
                        opacity: actBtn.ready ? 1 : 0.35
                        color: actHover.hovered && actBtn.ready
                               ? Config.Appearance.hover : "transparent"
                        border.width: 1
                        border.color: Config.Appearance.rule

                        MonoIcon {
                            anchors.centerIn: parent
                            name: actBtn.modelData.i
                            size: 15
                            inkColor: Config.Appearance.ink2
                            monochrome: true
                        }

                        HoverHandler {
                            id: actHover
                            enabled: actBtn.ready
                            cursorShape: Qt.PointingHandCursor
                        }
                        MouseArea {
                            anchors.fill: parent
                            enabled: actBtn.ready
                            onClicked: {
                                // Focus first: the action may well be the
                                // last thing this delegate ever does.
                                canvas.forceActiveFocus();
                                root.runAction(actBtn.modelData.act);
                            }
                        }
                    }
                }
            }

            // ── the side column ───────────────────────────────────────
            Column {
                id: side
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                width: 268
                spacing: 14

                // Previews, drawn by the very component the dock uses, at
                // the sizes it uses — an icon that reads at 48 and turns
                // to mud at 16 is the failure this is here to catch.
                Rectangle {
                    width: parent.width
                    height: 92
                    radius: Config.Appearance.rSm
                    color: Config.Appearance.ground
                    border.width: 1
                    border.color: Config.Appearance.edge

                    Row {
                        anchors.centerIn: parent
                        spacing: 22

                        Repeater {
                            model: [48, 24, 16]

                            Column {
                                id: preview
                                required property int modelData
                                spacing: 6

                                Item {
                                    width: 48
                                    height: 48
                                    MonoIcon {
                                        anchors.centerIn: parent
                                        // The drawing itself, not a name:
                                        // it may not have one yet.
                                        specOverride: root.liveGlyph
                                        size: preview.modelData
                                        inkColor: Config.Appearance.ink
                                        accentColor: Config.Appearance.accent
                                    }
                                }
                                StyledText {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    text: preview.modelData + "px"
                                    font.pixelSize: Config.Appearance.fs(10)
                                    color: Config.Appearance.ink3
                                }
                            }
                        }
                    }
                }

                // ── the selected shape ────────────────────────────────
                Column {
                    width: parent.width
                    spacing: 8
                    opacity: doc.current ? 1 : 0.4

                    StyledText {
                        text: doc.current ? doc.current.kind : "Nothing selected"
                        font.pixelSize: Config.Appearance.fs(12)
                        font.weight: Font.DemiBold
                        color: Config.Appearance.ink
                    }

                    Segmented {
                        width: parent.width
                        options: [{ label: "Ink", value: "ink" },
                                  { label: "Accent", value: "acc" }]
                        value: doc.current ? (doc.current.c || "ink") : root.nextColour
                        onSelected: v => {
                            root.nextColour = v;
                            if (doc.current) doc.update({ c: v });
                        }
                    }

                    Segmented {
                        width: parent.width
                        options: [{ label: "Regular", value: "2" },
                                  { label: "Heavy", value: "3" }]
                        value: String(doc.current ? (doc.current.sw || 2) : root.nextWeight)
                        onSelected: v => {
                            root.nextWeight = parseInt(v, 10);
                            if (doc.current) doc.update({ sw: parseInt(v, 10) });
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: 10
                        visible: !!doc.current && root.canFill(doc.current.kind)

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Filled"
                            font.pixelSize: Config.Appearance.fs(12)
                            color: Config.Appearance.ink2
                        }
                        Toggle {
                            anchors.verticalCenter: parent.verticalCenter
                            checked: !!(doc.current && doc.current.fill)
                            onToggled: v => doc.update({ fill: v })
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            // Saying it rather than letting it surprise
                            // someone: MonoIcon only ever fills in accent.
                            text: "always accent"
                            font.pixelSize: Config.Appearance.fs(10)
                            color: Config.Appearance.ink3
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: 10
                        visible: !!doc.current && doc.current.kind === "rect"

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Corners"
                            font.pixelSize: Config.Appearance.fs(12)
                            color: Config.Appearance.ink2
                        }
                        FillSlider {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 150
                            // Up to half the short side, which is where a
                            // rounded box becomes a stadium.
                            value: doc.current && doc.current.kind === "rect"
                                   ? (doc.current.r || 0)
                                     / Math.max(0.01, Math.min(doc.current.w,
                                                               doc.current.h) / 2)
                                   : 0
                            onMoved: v => doc.update({
                                r: v * Math.min(doc.current.w, doc.current.h) / 2 }, true)
                            onReleased: v => doc.update({
                                r: v * Math.min(doc.current.w, doc.current.h) / 2 })
                        }
                    }

                    // Turning. The slider is for finding an angle and the
                    // readout is for knowing which one you found — a
                    // knob on the canvas can place it but cannot say
                    // that it is at 45 and not 44.
                    Row {
                        width: parent.width
                        spacing: 10
                        visible: !!doc.current && doc.current.kind !== "circle"
                                 && doc.current.kind !== "dot"

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Turn"
                            font.pixelSize: Config.Appearance.fs(12)
                            color: Config.Appearance.ink2
                        }
                        FillSlider {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 130
                            // -180…180 mapped onto the trough.
                            value: doc.current ? ((doc.current.rot || 0) + 180) / 360 : 0.5
                            onMoved: v => doc.update({ rot: Math.round(v * 360 - 180) }, true)
                            onReleased: v => doc.update({ rot: Math.round(v * 360 - 180) })
                        }
                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: (doc.current ? Math.round(doc.current.rot || 0) : 0) + "°"
                            font.pixelSize: Config.Appearance.fs(11)
                            color: Config.Appearance.ink3
                        }
                    }

                    // What a point-based shape needs and a primitive does
                    // not.
                    Column {
                        width: parent.width
                        spacing: 6
                        visible: !!doc.current
                                 && (doc.current.kind === "path" || doc.current.kind === "poly")

                        Row {
                            width: parent.width
                            spacing: 10
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: "Closed"
                                font.pixelSize: Config.Appearance.fs(12)
                                color: Config.Appearance.ink2
                            }
                            Toggle {
                                anchors.verticalCenter: parent.verticalCenter
                                checked: !!(doc.current && doc.current.closed)
                                onToggled: doc.toggleClosed()
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: doc.current && doc.current.kind === "path"
                                      ? (doc.current.nodes.length + " points") : ""
                                font.pixelSize: Config.Appearance.fs(10)
                                color: Config.Appearance.ink3
                            }
                        }

                        Row {
                            width: parent.width
                            spacing: 6
                            visible: doc.current && doc.current.kind === "path"
                                     && doc.selectedNode >= 0

                            Repeater {
                                model: [
                                    { n: "Corner / smooth", op: "corner" },
                                    { n: "Split", op: "split" },
                                    { n: "Remove", op: "delete" }
                                ]
                                Rectangle {
                                    id: nodeBtn
                                    required property var modelData
                                    width: (side.width - 12) / 3
                                    height: 28
                                    radius: Config.Appearance.rSm
                                    color: nodeHover.hovered ? Config.Appearance.hover
                                                             : "transparent"
                                    border.width: 1
                                    border.color: Config.Appearance.rule
                                    StyledText {
                                        anchors.centerIn: parent
                                        width: parent.width - 8
                                        horizontalAlignment: Text.AlignHCenter
                                        elide: Text.ElideRight
                                        text: nodeBtn.modelData.n
                                        font.pixelSize: Config.Appearance.fs(10.5)
                                        color: Config.Appearance.ink2
                                    }
                                    HoverHandler {
                                        id: nodeHover
                                        cursorShape: Qt.PointingHandCursor
                                    }
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: doc.pathNodeOp(nodeBtn.modelData.op,
                                                                  doc.selectedNode)
                                    }
                                }
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: 6
                        visible: !!doc.current

                        Repeater {
                            model: [{ n: "Bring forward", d: 1 }, { n: "Send back", d: -1 }]
                            Rectangle {
                                required property var modelData
                                width: (side.width - 6) / 2
                                height: 28
                                radius: Config.Appearance.rSm
                                color: orderHover.hovered ? Config.Appearance.hover
                                                          : "transparent"
                                border.width: 1
                                border.color: Config.Appearance.rule
                                StyledText {
                                    anchors.centerIn: parent
                                    text: parent.modelData.n
                                    font.pixelSize: Config.Appearance.fs(11)
                                    color: Config.Appearance.ink2
                                }
                                HoverHandler { id: orderHover; cursorShape: Qt.PointingHandCursor }
                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: doc.reorder(parent.modelData.d)
                                }
                            }
                        }
                    }
                }

                Rectangle { width: parent.width; height: 1; color: Config.Appearance.rule }

                // ── name and save ─────────────────────────────────────
                Column {
                    width: parent.width
                    spacing: 8

                    Rectangle {
                        width: parent.width
                        height: 34
                        radius: Config.Appearance.rPill
                        color: Config.Appearance.sel
                        border.width: 1
                        border.color: nameField.activeFocus ? Config.Appearance.accent
                                    : (root.trimmedName !== "" && !root.nameOk
                                       ? Config.Appearance.accent : Config.Appearance.edge)

                        TextInput {
                            id: nameField
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            verticalAlignment: Text.AlignVCenter
                            clip: true
                            text: root.iconName
                            onTextChanged: root.iconName = text
                            color: Config.Appearance.ink
                            font.family: Config.Appearance.fontFamily
                            font.pixelSize: Config.Appearance.fs(12)
                            selectByMouse: true
                            selectionColor: Config.Appearance.accent
                            selectedTextColor: Config.Appearance.inkOnAccent
                            Keys.onReturnPressed: root.save()

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: nameField.text === ""
                                text: "Icon name"
                                font.pixelSize: Config.Appearance.fs(12)
                                color: Config.Appearance.ink3
                            }
                        }
                    }

                    StyledText {
                        width: parent.width
                        wrapMode: Text.Wrap
                        visible: text !== ""
                        text: root.notice !== "" ? root.notice
                            : (root.trimmedName !== "" ? root.nameProblem : "")
                        font.pixelSize: Config.Appearance.fs(10.5)
                        color: Config.Appearance.ink3
                    }

                    Row {
                        width: parent.width
                        spacing: 6

                        Rectangle {
                            id: saveBtn
                            width: (side.width - 6) * 0.62
                            height: 32
                            radius: Config.Appearance.rSm
                            readonly property bool ready: root.nameOk && doc.draws()
                            opacity: saveBtn.ready ? 1 : 0.4
                            color: saveBtn.ready ? Config.Appearance.accent
                                                 : Config.Appearance.hover
                            StyledText {
                                anchors.centerIn: parent
                                text: root.loadedAs === root.trimmedName
                                      && root.loadedAs !== "" ? "Save changes" : "Save icon"
                                font.pixelSize: Config.Appearance.fs(12)
                                font.weight: Font.DemiBold
                                color: saveBtn.ready ? Config.Appearance.inkOnAccent
                                                     : Config.Appearance.ink3
                            }
                            HoverHandler { cursorShape: Qt.PointingHandCursor }
                            MouseArea {
                                anchors.fill: parent
                                enabled: saveBtn.ready
                                onClicked: root.save()
                            }
                        }

                        Rectangle {
                            width: (side.width - 6) * 0.38
                            height: 32
                            radius: Config.Appearance.rSm
                            color: newHover.hovered ? Config.Appearance.hover : "transparent"
                            border.width: 1
                            border.color: Config.Appearance.rule
                            StyledText {
                                anchors.centerIn: parent
                                text: "New"
                                font.pixelSize: Config.Appearance.fs(12)
                                color: Config.Appearance.ink2
                            }
                            HoverHandler { id: newHover; cursorShape: Qt.PointingHandCursor }
                            MouseArea { anchors.fill: parent; onClicked: root.reset() }
                        }
                    }
                }

                // ── what you have made ────────────────────────────────
                StyledText {
                    text: "Your icons"
                    font.pixelSize: Config.Appearance.fs(11)
                    color: Config.Appearance.ink3
                }

                Flickable {
                    width: parent.width
                    height: Math.max(40, side.height - y - 8)
                    contentHeight: saved.height
                    clip: true
                    interactive: contentHeight > height

                    Grid {
                        id: saved
                        width: parent.width
                        columns: 5

                        Repeater {
                            model: Config.UserIcons.names

                            Rectangle {
                                id: savedTile
                                required property string modelData
                                width: 52
                                height: 52
                                radius: Config.Appearance.rSm
                                color: savedTile.modelData === root.loadedAs
                                       ? Config.Appearance.sel
                                     : (savedHover.hovered ? Config.Appearance.hover
                                                           : "transparent")

                                MonoIcon {
                                    anchors.centerIn: parent
                                    name: savedTile.modelData
                                    size: 24
                                    inkColor: Config.Appearance.ink2
                                    accentColor: Config.Appearance.accent
                                }

                                HoverHandler { id: savedHover; cursorShape: Qt.PointingHandCursor }
                                MouseArea {
                                    anchors.fill: parent
                                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                                    onClicked: mouse => {
                                        if (mouse.button === Qt.RightButton)
                                            Config.UserIcons.remove(savedTile.modelData);
                                        else
                                            root.load(savedTile.modelData);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    function actionReady(act) {
        switch (act) {
        case "undo":      return doc.canUndo;
        case "redo":      return doc.canRedo;
        case "duplicate":
        case "delete":    return !!doc.current;
        case "clear":     return doc.shapes.length > 0;
        }
        return false;
    }

    function runAction(act) {
        switch (act) {
        case "undo":      doc.undo(); break;
        case "redo":      doc.redo(); break;
        case "duplicate": doc.duplicateSelected(); break;
        case "delete":    doc.removeSelected(); break;
        case "clear":     doc.clear(); break;
        }
    }

    // Only these can be filled — a line or an arc has no inside, and an
    // open polyline's is whatever the closing straight line makes it.
    function canFill(kind) {
        if (kind === "path" || kind === "poly")
            return !!(doc.current && doc.current.closed);
        return kind === "rect" || kind === "circle" || kind === "ellipse";
    }

    // What the previews draw. Recomposed whenever the drawing changes,
    // rather than bound to doc.shapes: editing sometimes writes a new
    // array and sometimes edits one in place, so the signal is the
    // reliable half and the array is not.
    property var liveGlyph: ({})
    Connections {
        target: doc
        function onChanged() { root.liveGlyph = doc.glyph(); }
    }
}
