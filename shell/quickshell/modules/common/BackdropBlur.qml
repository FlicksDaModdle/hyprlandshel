import QtQuick
import QtQuick.Effects
import Quickshell.Widgets

// Frosted glass over the shell's own content: what `source` draws under
// this rectangle, blurred, with rounded corners.
//
// For a menu drawn inside the same surface as what it covers — the
// launcher's session and right-click menus. The compositor's blur only
// reaches what is behind a surface, so over the launcher's own rows a
// translucent menu showed them sharp through it, and the menus were made
// solid instead. This blurs them in the shell, so the menu can be the same
// translucent glass as every other panel.
//
// Lay the menu's own (translucent) panel over it. `source` must not
// contain this item.
ClippingRectangle {
    id: root

    property Item source: null
    property real amount: 1

    color: "transparent"
    // The software renderer has no shaders; the menu's own colour is then
    // all there is, as before.
    visible: GraphicsInfo.api !== GraphicsInfo.Software && !!source

    ShaderEffectSource {
        id: grab
        visible: false
        live: true
        sourceItem: root.source
        // What is under this rectangle, in the source's coordinates; the
        // positions are read so it follows either of them moving.
        sourceRect: {
            if (!root.source) return Qt.rect(0, 0, 0, 0);
            void (root.x + root.y + root.width + root.height
                  + root.source.x + root.source.y + root.source.width + root.source.height);
            const p = root.mapToItem(root.source, 0, 0);
            return Qt.rect(p.x, p.y, root.width, root.height);
        }
    }

    MultiEffect {
        anchors.fill: parent
        source: grab
        autoPaddingEnabled: false
        blurEnabled: true
        blur: root.amount
        blurMax: 40
        saturation: 0.15
    }
}
