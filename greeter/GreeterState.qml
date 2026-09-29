import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Greetd

// Everything the greeter knows and does, apart from drawing it: who can log
// in, into what, the choice remembered from last time, and the conversation
// with greetd that turns a password into a session.
//
// greetd does the part that matters. The greeter runs as greetd's own
// unprivileged user and never sees more than what is typed into it: the
// password goes straight to greetd, which checks it with PAM and starts
// the chosen session as you.
//
// Run anywhere greetd is not (`qs -p greeter/shell.qml` from a normal
// session) it is a preview: everything works but the login itself.
Scope {
    id: g

    // ── what the greeter reads, overridable for testing ───────────────────
    readonly property string passwdFile:
        Quickshell.env("HYPRSHELL_GREETER_PASSWD") || "/etc/passwd"
    readonly property string sessionDirs:
        Quickshell.env("HYPRSHELL_GREETER_SESSIONS")
        || "/usr/share/wayland-sessions:/usr/local/share/wayland-sessions"
    readonly property string iconDir:
        Quickshell.env("HYPRSHELL_GREETER_ICONS") || "/var/lib/AccountsService/icons"
    // Written by the greeter, so it has to be somewhere greetd's user owns;
    // install.sh makes it.
    readonly property string stateFile:
        Quickshell.env("HYPRSHELL_GREETER_STATE") || "/var/cache/hyprshell-greeter/state.json"

    readonly property bool preview: !Greetd.available

    property string hostname: ""
    FileView {
        path: "/etc/hostname"
        printErrors: false
        onLoaded: g.hostname = text().trim()
    }

    // ── users ─────────────────────────────────────────────────────────────
    // People, not system accounts: a uid from 1000, and a shell you can log
    // in with. The same rule every display manager uses.
    property var users: []
    property int userIndex: 0
    readonly property var user: users.length > 0 ? users[Math.max(0, Math.min(userIndex, users.length - 1))] : null

    FileView {
        path: g.passwdFile
        printErrors: false
        onLoaded: g.users = g.parseUsers(text())
    }

    function parseUsers(text) {
        const out = [];
        for (const line of String(text).split("\n")) {
            const f = line.split(":");
            if (f.length < 7) continue;
            const uid = parseInt(f[2], 10);
            if (!(uid >= 1000 && uid < 60000)) continue;
            if (/(nologin|false)$/.test(f[6])) continue;
            const full = (f[4] || "").split(",")[0].trim();
            out.push({ name: f[0], display: full || f[0], uid: uid,
                       icon: g.iconDir + "/" + f[0] });
        }
        out.sort((a, b) => a.uid - b.uid);
        return out;
    }

    // ── sessions ──────────────────────────────────────────────────────────
    // Every Wayland session installed, read from its .desktop file.
    property var sessions: []
    property int sessionIndex: 0
    readonly property var session: sessions.length > 0 ? sessions[Math.max(0, Math.min(sessionIndex, sessions.length - 1))] : null

    Process {
        running: true
        // One line per session: id, Name, Exec, DesktopNames, hidden —
        // tab-separated. Only from the [Desktop Entry] section, and only the
        // plain Name=: the localised Name[xx]= lines and any [Desktop
        // Action] after it are not the session.
        command: ["sh", "-c",
            'IFS=:; for d in $1; do for f in "$d"/*.desktop; do [ -f "$f" ] || continue; '
            + 'id=${f##*/}; awk -v id="${id%.desktop}" \''
            + '/^\\[/ { main = ($0 == "[Desktop Entry]") } '
            + 'main && /^Name=/ && n == "" { n = substr($0, 6) } '
            + 'main && /^Exec=/ && e == "" { e = substr($0, 6) } '
            + 'main && /^DesktopNames=/ && dn == "" { dn = substr($0, 14) } '
            + 'main && /^(Hidden|NoDisplay)=true/ { h = 1 } '
            + 'END { printf "%s\\t%s\\t%s\\t%s\\t%s\\n", id, n, e, dn, h }\' "$f"; '
            + 'done; done', "sh", g.sessionDirs]
        stdout: StdioCollector {
            onStreamFinished: {
                const seen = ({});
                const out = [];
                for (const line of text.split("\n")) {
                    const f = line.split("\t");
                    if (f.length < 5 || !f[2] || f[4] === "1" || seen[f[0]]) continue;
                    seen[f[0]] = true;
                    out.push({ id: f[0], name: f[1] || f[0],
                               command: g.splitExec(f[2]), desktopNames: f[3] });
                }
                out.sort((a, b) => a.name.localeCompare(b.name));
                g.sessions = out;
                g.restore();
            }
        }
    }

    // An Exec= line into argv: double quotes group, field codes (%f, %U …)
    // go — a session is not handed files.
    function splitExec(line) {
        const out = [];
        let cur = "", quoted = false, any = false;
        for (let i = 0; i < line.length; i++) {
            const c = line[i];
            if (quoted) {
                if (c === "\\" && i + 1 < line.length) { cur += line[++i]; continue; }
                if (c === '"') { quoted = false; continue; }
                cur += c;
            } else if (c === '"') { quoted = true; any = true;
            } else if (c === " " || c === "\t") {
                if (cur !== "" || any) out.push(cur);
                cur = ""; any = false;
            } else cur += c;
        }
        if (cur !== "" || any) out.push(cur);
        return out.filter(a => !/^%[a-zA-Z]$/.test(a));
    }

    // What the session is told it is — the same variables a display manager
    // sets, which portals and some applications read.
    function sessionEnv(s) {
        const names = (s.desktopNames || s.id).replace(/;+$/, "").replace(/;/g, ":");
        return ["XDG_SESSION_TYPE=wayland",
                "XDG_SESSION_DESKTOP=" + s.id,
                "XDG_CURRENT_DESKTOP=" + names];
    }

    // ── last time's choice ────────────────────────────────────────────────
    property var remembered: null

    FileView {
        id: stateStore
        path: g.stateFile
        printErrors: false
        onLoaded: {
            try { g.remembered = JSON.parse(text()); } catch (e) { g.remembered = null; }
            g.restore();
        }
    }

    // The user and session from last time if they still exist; otherwise
    // the first person, and Hyprland if it is installed.
    function restore() {
        const r = g.remembered || ({});
        const ui = g.users.findIndex(u => u.name === r.user);
        if (ui >= 0) g.userIndex = ui;
        let si = g.sessions.findIndex(s => s.id === r.session);
        if (si < 0) si = g.sessions.findIndex(s => s.id === "hyprland");
        if (si < 0) si = g.sessions.findIndex(s => /hyprland/i.test(s.id));
        if (si >= 0) g.sessionIndex = si;
    }
    onUsersChanged: restore()

    function remember() {
        if (!g.user || !g.session) return;
        stateStore.setText(JSON.stringify({ user: g.user.name, session: g.session.id }) + "\n");
    }

    // ── logging in ────────────────────────────────────────────────────────
    property string entered: ""
    property string status: ""
    property bool failed: false
    property bool busy: false
    // A second question from PAM — a one-time code, a new password — asked
    // in the same field, under its own words.
    property string prompt: ""
    property bool promptEcho: false
    property bool passwordSent: false
    signal rejected()

    function pickUser(i) {
        if (i === g.userIndex) return;
        g.reset();
        g.userIndex = i;
    }

    function reset() {
        if (!g.preview && Greetd.state !== GreetdState.Inactive) Greetd.cancelSession();
        g.entered = ""; g.status = ""; g.failed = false; g.busy = false;
        g.prompt = ""; g.passwordSent = false;
    }

    function submit() {
        if (g.busy || !g.user || !g.session) return;
        if (g.prompt !== "") {
            // Answering the second question.
            const answer = g.entered;
            g.entered = ""; g.prompt = ""; g.busy = true;
            Greetd.respond(answer);
            return;
        }
        if (g.entered.length === 0) return;
        if (g.preview) {
            g.failed = true;
            g.status = "Preview — greetd isn't running, so nothing can log in";
            g.rejected();
            return;
        }
        g.failed = false;
        g.status = "";
        g.busy = true;
        g.passwordSent = false;
        Greetd.createSession(g.user.name);
    }

    Connections {
        target: Greetd

        function onAuthMessage(message, error, responseRequired, echoResponse) {
            if (responseRequired) {
                // The first hidden question is the password already typed.
                if (!g.passwordSent && !echoResponse) {
                    g.passwordSent = true;
                    Greetd.respond(g.entered);
                    return;
                }
                g.prompt = message.trim() || "Answer";
                g.promptEcho = echoResponse;
                g.entered = "";
                g.busy = false;
                return;
            }
            // Information, or a problem PAM can carry on from.
            g.status = message.trim();
            g.failed = error;
        }

        function onAuthFailure(message) {
            g.busy = false;
            g.failed = true;
            g.entered = "";
            g.prompt = "";
            g.status = "Wrong password";
            g.rejected();
        }

        function onError(message) {
            g.busy = false;
            g.failed = true;
            g.prompt = "";
            g.status = message || "Login failed";
            g.rejected();
        }

        function onReadyToLaunch() {
            g.remember();
            g.status = "Starting " + g.session.name + "…";
            g.failed = false;
            Greetd.launch(g.session.command, g.sessionEnv(g.session));
        }
    }

    // ── power ─────────────────────────────────────────────────────────────
    function power(action) {
        if (g.preview) { g.status = "Preview — " + action + " is not run"; return; }
        Quickshell.execDetached(["systemctl", action]);
    }
}
