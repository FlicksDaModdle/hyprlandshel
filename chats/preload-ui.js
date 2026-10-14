'use strict';
// For the app's own pages (the title row, the offline page): the palette and
// the state to draw, and the few things they can ask for.

const { ipcRenderer, contextBridge } = require('electron');

const ACTS = new Set(['minimize', 'maximize', 'close', 'reload', 'retry', 'zoom-reset']);

contextBridge.exposeInMainWorld('chats', {
    onPalette: fn => ipcRenderer.on('chats:palette', (_e, p) => fn(p)),
    onState: fn => ipcRenderer.on('chats:state', (_e, s) => fn(s)),
    act: what => { if (ACTS.has(what)) ipcRenderer.send('chats:act', what); },
    ready: () => ipcRenderer.send('chats:ui-ready'),
});
