import QtQuick
import QtWebEngine
import Hyprshell
import Hyprshell.Backend

// A message's HTML, in full, in a sandbox: its own off-the-record profile,
// no JavaScript, nothing fetched from anywhere unless pictures from the web
// were allowed (MailApp's gate), links opened in the browser and never
// here. As tall as what it shows, so the conversation scrolls as one.
Item {
    id: web
    property var body
    property bool allowRemote: false
    // The page's height. WebEngine reports at least the view's own height,
    // so this only ever grows to fit — exactly, or it would chase itself.
    implicitHeight: Math.max(48, Math.ceil(view.contentsSize.height))
    height: implicitHeight
    clip: true

    readonly property string page: {
        if (!web.body) return "";
        const dark = Mail.darkMessages && Appearance.dark;
        const head = '<meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="script-src \'none\'; object-src \'none\'; frame-src \'none\'">'
            + '<style>html{overflow-y:hidden}html,body{margin:0;padding:10px 12px;font-family:Inter,system-ui,sans-serif;font-size:14px;line-height:1.45;word-wrap:break-word}'
            + 'img{max-width:100%;height:auto}blockquote{margin-left:.8ex;padding-left:1ex;border-left:2px solid #ccc}'
            + (dark ? 'html{filter:invert(.9) hue-rotate(180deg)}img,video,picture{filter:invert(1) hue-rotate(180deg)}' : '')
            + '</style>';
        return head + web.body.html;
    }

    Rectangle {
        anchors.fill: parent
        radius: Appearance.rSm
        color: Mail.darkMessages && Appearance.dark ? "#1b1b1b" : "white"
    }
    WebEngineProfile {
        id: profile
        offTheRecord: true
        httpCacheType: WebEngineProfile.MemoryHttpCache
        persistentCookiesPolicy: WebEngineProfile.NoPersistentCookies
        Component.onCompleted: MailApp.secure(profile)
    }
    WebEngineView {
        id: view
        anchors.fill: parent
        profile: profile
        backgroundColor: "transparent"
        settings.javascriptEnabled: false
        settings.javascriptCanOpenWindows: false
        settings.javascriptCanAccessClipboard: false
        settings.localContentCanAccessRemoteUrls: false
        settings.localContentCanAccessFileUrls: false
        settings.localStorageEnabled: false
        settings.pluginsEnabled: false
        settings.errorPageEnabled: false
        settings.navigateOnDropEnabled: false
        settings.autoLoadImages: true
        settings.focusOnNavigationEnabled: false

        onNavigationRequested: req => {
            const url = req.url.toString();
            if (req.navigationType === WebEngineNavigationRequest.LinkClickedNavigation) {
                if (/^(https?|mailto):/i.test(url)) Qt.openUrlExternally(req.url);
                req.reject();
                return;
            }
            // Only the message itself is shown here.
            if (url.startsWith("data:") || url === "about:blank") req.accept();
            else req.reject();
        }
        onNewWindowRequested: req => { if (/^(https?|mailto):/i.test(req.requestedUrl.toString())) Qt.openUrlExternally(req.requestedUrl); }
        onContextMenuRequested: req => {
            req.accepted = true;
            const link = req.linkUrl.toString();
            const items = [{ n: "Copy", icon: "file", active: req.selectedText !== "", run: () => view.triggerWebAction(WebEngineView.Copy) },
                           { n: "Select all", icon: "check", run: () => view.triggerWebAction(WebEngineView.SelectAll) }];
            if (link) {
                items.push({ n: "Open link", icon: "globe", rule: true, run: () => Qt.openUrlExternally(req.linkUrl) });
                items.push({ n: "Copy link address", icon: "globe", run: () => view.triggerWebAction(WebEngineView.CopyLinkToClipboard) });
            }
            const p = view.mapToItem(null, req.position.x, req.position.y);
            const frame = Mail.frameRef;
            if (frame) frame.menu.openAt(p.x, p.y, items);
        }
    }
    function reload() {
        MailApp.setAllowRemote(profile, web.allowRemote);
        view.loadHtml(web.page);
    }
    onPageChanged: reload()
    onAllowRemoteChanged: reload()
    Component.onCompleted: reload()
}
