'use strict';
// Runs beside WhatsApp Web, in its own isolated world. It reads nothing of
// the page but its stylesheets: which ones there are, in order, so the main
// process can recolour them (theme.js) — and it says so again whenever that
// list changes, since WhatsApp loads more as you open things.
//
// And one small thing in the page's world: a clicked notification brings
// the window up, as it would in a browser.

const { ipcRenderer, contextBridge, webFrame } = require('electron');

function collect() {
    const out = [];
    for (const el of document.querySelectorAll('link[rel~="stylesheet"][href], style')) {
        if (el.tagName === 'LINK') { out.push({ href: el.href }); continue; }
        let text = '';
        try {
            // Rules added with insertRule are in the sheet, not the text.
            text = el.sheet ? Array.from(el.sheet.cssRules, r => r.cssText).join('\n') : el.textContent;
        } catch { text = el.textContent || ''; }
        if (text) out.push({ text });
    }
    try {
        for (const s of document.adoptedStyleSheets || []) {
            out.push({ text: Array.from(s.cssRules, r => r.cssText).join('\n') });
        }
    } catch { /* not visible from this world */ }
    return out;
}

let last = '';
function scan() {
    if (location.protocol !== 'https:' && location.protocol !== 'http:') return;
    const list = collect();
    const sig = list.map(s => s.href || `${s.text.length}:${s.text.slice(0, 80)}`).join('|');
    if (sig === last) return;
    last = sig;
    ipcRenderer.send('chats:sheets', list);
}

let soon = null;
function later() { clearTimeout(soon); soon = setTimeout(scan, 150); }

window.addEventListener('DOMContentLoaded', () => {
    scan();
    new MutationObserver(later).observe(document.documentElement, { childList: true, subtree: true });
    // insertRule changes no DOM; a cheap look every two seconds catches it.
    setInterval(scan, 2000);
});

contextBridge.exposeInMainWorld('__hyprshellChats', { show: () => ipcRenderer.send('chats:show') });
webFrame.executeJavaScript(`(() => {
    const N = window.Notification;
    if (!N || !window.__hyprshellChats) return;
    const show = window.__hyprshellChats.show;
    class Notification extends N {
        constructor(title, options) {
            super(title, options);
            this.addEventListener('click', () => show());
        }
    }
    window.Notification = Notification;
})();`).catch(() => {});
