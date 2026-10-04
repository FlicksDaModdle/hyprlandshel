pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Services.Mpris
import "../config" as Config

// Whatever is playing, flattened into something a panel can draw.
//
// Nothing outside this file touches an MprisPlayer. Every property below
// answers even when there is no player at all, so a surface binding to
// them never has to ask whether there is one — it asks `available` once,
// for whether to show itself, and reads plain strings and numbers after
// that. It also means there is exactly one place to change when the
// service's own API turns out to differ from what was expected, which on
// past form it will.
Singleton {
    id: root

    readonly property var players: {
        // Quickshell hands these over as an ObjectModel; `values` is the
        // list. Guarded because a version that exposes a plain list
        // instead would otherwise read as "nothing is playing" for ever,
        // which is indistinguishable from a quiet desktop.
        //
        // The array case is tested for first and not by asking for
        // `.values`: every JavaScript array has a `values` of its own —
        // the iterator — so "does it have values" answers yes for a plain
        // list and hands back a function to filter.
        const m = Mpris.players;
        if (!m) return [];
        const all = Array.isArray(m) ? m
                  : (m.values !== undefined ? m.values : []);
        if (!all || typeof all.filter !== "function") return [];

        // playerctld, if it is running, registers a player of its own that
        // mirrors whichever real one is active. Left in, the desktop looks
        // as though it has two of everything and the pill can settle on
        // the mirror, whose identity is "playerctld" rather than the name
        // of the thing actually playing. It is still better than nothing,
        // so it is dropped only when there is a real player behind it.
        const real = all.filter(p => p && root.nameOf(p) !== root.mirrorName);
        return real.length > 0 ? real : all;
    }

    readonly property string mirrorName: "org.mpris.MediaPlayer2.playerctld"

    // ── which player ──────────────────────────────────────────────────
    //
    // A desktop usually has several: a music player, a browser tab that
    // once played a video, and whatever else has registered. Switching
    // between them on every metadata change is worse than picking one
    // and staying with it, so the choice is sticky — it moves only when
    // the chosen one goes away, or when another one starts playing while
    // this one is not.
    property string chosen: ""

    readonly property var player: {
        const list = root.players;
        if (list.length === 0) return null;

        const byName = n => {
            for (const p of list) if (p && root.nameOf(p) === n) return p;
            return null;
        };

        const held = root.chosen !== "" ? byName(root.chosen) : null;
        if (held && root.isPlaying(held)) return held;

        // Anything actually playing wins over a held pick that is not.
        for (const p of list) if (p && root.isPlaying(p)) return p;
        if (held) return held;
        return list[0];
    }

    function nameOf(p) {
        if (!p) return "";
        return p.dbusName !== undefined ? String(p.dbusName)
             : (p.identity !== undefined ? String(p.identity) : "");
    }

    function isPlaying(p) {
        if (!p) return false;
        // MprisPlaybackState.Playing, compared by value rather than by
        // name: the enum is not worth importing into every call site.
        return p.playbackState === MprisPlaybackState.Playing;
    }

    // The pick follows whatever is being drawn, so choosing a player in
    // the panel sticks. The position comes with it: a new player's
    // position is not the old one's, and the poll below may be a good
    // half-second away.
    onPlayerChanged: {
        if (root.player) root.chosen = root.nameOf(root.player);
        root.refreshPosition();
    }

    // ── what it is ────────────────────────────────────────────────────
    readonly property bool available: root.player !== null
    readonly property bool playing: root.isPlaying(root.player)

    readonly property string title: {
        const t = root.player ? root.player.trackTitle : "";
        return (t && String(t).trim() !== "") ? String(t) : "Nothing playing";
    }
    readonly property string artist: {
        const a = root.player ? root.player.trackArtist : "";
        return a ? String(a) : "";
    }
    readonly property string album: {
        const a = root.player ? root.player.trackAlbum : "";
        return a ? String(a) : "";
    }
    readonly property string artUrl: {
        const u = root.player ? root.player.trackArtUrl : "";
        return u ? String(u) : "";
    }
    readonly property string identity: {
        const i = root.player ? root.player.identity : "";
        return i ? String(i) : "mpris";
    }

    // ── what it can do ────────────────────────────────────────────────
    //
    // Every one of these is read as "did the player say no", not "did it
    // say yes": a player that does not implement the flag at all leaves
    // it undefined, and a control greyed out because of a missing
    // property is a control that looks broken.
    function says(prop, fallback) {
        if (!root.player) return false;
        const v = root.player[prop];
        return v === undefined ? fallback : !!v;
    }
    //
    // Each one is exactly what Quickshell's own setter demands before it
    // will do anything, read out of MprisPlayer: every one of those
    // refuses with a qWarning when its condition does not hold, so a
    // button that looks live and only prints to the log is the failure
    // being avoided here. Volume, shuffle and loop each want their
    // "supported" flag *and* canControl; a seek wants canSeek and a
    // player that reports a position at all.
    readonly property bool canNext:    root.says("canGoNext", true)
    readonly property bool canPrev:    root.says("canGoPrevious", true)
    readonly property bool canToggle:  root.says("canTogglePlaying", true)
    readonly property bool canSeek:    root.says("canSeek", true)
                                       && root.says("positionSupported", true)
    readonly property bool canShuffle: root.says("shuffleSupported", false)
                                       && root.says("canControl", true)
    readonly property bool canLoop:    root.says("loopSupported", false)
                                       && root.says("canControl", true)
    readonly property bool canVolume:  root.says("volumeSupported", true)
                                       && root.says("canControl", true)

    // ── where it is ───────────────────────────────────────────────────
    // A track's length, or 0 for "there isn't one" — a stream, or a
    // player that has not said. Players report a length of a handful of
    // milliseconds between tracks, which would make the progress bar
    // jump to the end for a frame, so anything under a second is treated
    // as nothing rather than as a very short song.
    readonly property real length: {
        if (!root.says("lengthSupported", true)) return 0;
        const l = root.player ? root.player.length : 0;
        return (l > 1 && isFinite(l)) ? l : 0;
    }
    property real position: 0
    readonly property real progress:
        root.length > 0 ? Math.max(0, Math.min(1, root.position / root.length)) : 0

    // Position is not pushed: a player reports it when asked, and a
    // progress bar that only moves when the track changes is not a
    // progress bar. Polled a little faster than once a second so the
    // seconds tick over without visibly lagging, and only while
    // something is actually playing and someone is looking.
    //
    // `watchers` is how many surfaces are on screen and want a live
    // number even while the track is paused — the panel, while it is
    // open. Counted rather than set, because there is one panel per
    // monitor and a `watched = visible` from the hidden ones would keep
    // turning off what the visible one turned on.
    property int watchers: 0
    function watch() { root.watchers++; }
    function unwatch() { root.watchers = Math.max(0, root.watchers - 1); }

    // Twice a second while the panel with its seek bar is open; otherwise
    // only the bar's thin progress line wants it, and that moves about a
    // pixel every couple of seconds.
    Timer {
        running: root.available && (root.playing || root.watchers > 0)
        interval: root.watchers > 0 ? 500 : 2000
        repeat: true
        triggeredOnStart: true
        onTriggered: root.refreshPosition()
    }
    function refreshPosition() {
        if (!root.player) { root.position = 0; return; }
        const p = root.player.position;
        root.position = (p >= 0 && isFinite(p)) ? p : 0;
    }

    readonly property real volume: {
        const v = root.player ? root.player.volume : 0;
        return (v >= 0 && isFinite(v)) ? Math.min(1, v) : 0;
    }
    readonly property bool shuffle: root.says("shuffle", false)
    readonly property string loop: {
        if (!root.player) return "none";
        const l = root.player.loopState;
        if (l === MprisLoopState.Track) return "track";
        if (l === MprisLoopState.Playlist) return "playlist";
        return "none";
    }

    // ── doing things ──────────────────────────────────────────────────
    //
    // Each one checks the method is there before calling it. A player
    // that does not implement `next` should do nothing, not take the
    // shell's binding down with a TypeError in a signal handler — which
    // is printed and swallowed, leaving a button that half-works.
    function call(name) {
        if (!root.player) return;
        const f = root.player[name];
        if (typeof f === "function") root.player[name]();
    }

    function toggle() {
        if (!root.player || !root.canToggle) return;
        if (typeof root.player.togglePlaying === "function") root.player.togglePlaying();
        else root.call(root.playing ? "pause" : "play");
    }
    function next() { if (root.canNext) root.call("next"); }
    function previous() { if (root.canPrev) root.call("previous"); }

    function seekTo(fraction) {
        if (!root.player || !root.canSeek || root.length <= 0) return;
        const want = Math.max(0, Math.min(1, fraction)) * root.length;
        root.player.position = want;
        root.position = want;
    }

    function setVolume(v) {
        if (!root.player || !root.canVolume) return;
        root.player.volume = Math.max(0, Math.min(1, v));
    }

    function toggleShuffle() {
        if (!root.player || !root.canShuffle) return;
        root.player.shuffle = !root.player.shuffle;
    }

    // None → whole playlist → this track → none, which is the order
    // every other player cycles in.
    function cycleLoop() {
        if (!root.player || !root.canLoop) return;
        const l = root.loop;
        root.player.loopState = l === "none" ? MprisLoopState.Playlist
                              : l === "playlist" ? MprisLoopState.Track
                              : MprisLoopState.None;
    }

    // ── m:ss ──────────────────────────────────────────────────────────
    //
    // Seconds, as a clock. An hour-long track gets an hour field; a
    // three-minute one does not, because "0:03:21" reads as a duration
    // and "3:21" reads as a song.
    function clock(seconds) {
        if (!(seconds >= 0) || !isFinite(seconds)) return "0:00";
        const whole = Math.floor(seconds);
        const s = whole % 60;
        const m = Math.floor(whole / 60) % 60;
        const h = Math.floor(whole / 3600);
        const two = n => (n < 10 ? "0" : "") + n;
        return h > 0 ? h + ":" + two(m) + ":" + two(s) : m + ":" + two(s);
    }
}
