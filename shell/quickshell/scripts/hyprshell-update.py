#!/usr/bin/env python3
"""Hyprshell's updates (Settings → Updates): which parts of it have changes
on GitHub, and putting them in when you ask.

    hyprshell-update.py check        JSON: the repository, and for each part
                                     that is installed, the commits upstream
                                     that touch it and aren't installed yet
    hyprshell-update.py run ID ...   in a terminal: pull, then that part's
                                     installer (or several, or "all")

Nothing is updated without being asked. A check fetches from GitHub and
reads; only `run` changes anything, and it runs in a terminal you can watch,
since installers ask for your password (sudo) for packages and system files.

What is installed is remembered per part, as the commit it was installed
from ($XDG_STATE_HOME/hyprshell/installed/<part>). A part installed before
this knew about it is taken to be at the checkout as it was first looked at,
so pulling for one part doesn't hide what's new for the others.
"""

import glob
import json
import os
import shutil
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
STATE = os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.join(HOME, ".local/state"), "hyprshell")
STAMPS = os.path.join(STATE, "installed")
CONFIG = os.environ.get("XDG_CONFIG_HOME") or os.path.join(HOME, ".config")


def found(name):
    """A program by name: on PATH, or where the installers put them."""
    if shutil.which(name):
        return True
    return any(os.path.exists(os.path.join(d, name))
               for d in (os.path.join(HOME, ".local/bin"), "/usr/local/bin", "/usr/bin"))


APPS = ["rog", "notes", "snapshots", "disks", "keys", "docs", "music", "video", "recorder",
        "chats", "weather", "calendar", "fonts", "text", "camera", "software"]

# id, name, what it is, the paths whose commits are its own, its installer,
# whether the installer itself must be root, and whether it's installed.
PARTS = [
    dict(id="shell", name="Shell", note="Bar, dock, launcher, panels, Settings, lock screen",
         paths=["shell", ":(exclude)shell/face", ":(exclude)shell/limine"],
         install=["./shell/install.sh"], root=False,
         present=lambda: os.path.isdir(os.path.join(CONFIG, "quickshell/hyprshell"))),
    dict(id="greeter", name="Login screen", note="The greeter, run by greetd",
         paths=["greeter", "shell/quickshell/modules/common", "shell/quickshell/config"],
         install=["./greeter/install.sh"], root=True,
         present=lambda: os.path.isdir("/usr/share/hyprshell-greeter")),
    dict(id="face", name="Face unlock", note="The IR camera service and its PAM module",
         paths=["shell/face"], install=["./shell/face/install.sh"], root=False,
         present=lambda: os.path.exists("/usr/lib/security/pam_hyprshell_face.so")
                         or os.path.exists("/etc/systemd/system/hyprshell-faced.service")),
    dict(id="limine", name="Boot menu theme", note="Limine in your wallpaper and colours",
         paths=["shell/limine"], install=["./shell/limine/install.sh"], root=False,
         present=lambda: os.path.exists("/usr/local/libexec/hyprshell-limine-theme")),
    dict(id="apps", name="Apps", note="Notes, Weather, Calendar, Fonts, Text Editor, Camera, Software…",
         paths=["apps"], install=["./apps/install.sh"], root=False,
         present=lambda: any(found("hyprshell-" + a) for a in APPS)),
    dict(id="files", name="Files", note="The file manager and file dialogs",
         paths=["files"], install=["./files/install.sh"], root=False,
         present=lambda: found("hyprshell-files")),
    dict(id="tasks", name="Task Manager", note="Processes, performance, startup apps",
         paths=["tasks", "files/qml"], install=["./tasks/install.sh"], root=False,
         present=lambda: found("hyprshell-tasks")),
    dict(id="term", name="Terminal", note="Hyprshell Terminal",
         paths=["term", "files/qml"], install=["./term/install.sh"], root=False,
         present=lambda: found("hyprshell-term")),
    dict(id="mail", name="Mail", note="Hyprshell Mail and its daemon",
         paths=["mail", "files/qml"], install=["./mail/install.sh"], root=False,
         present=lambda: found("hyprshell-mail")),
    dict(id="images", name="Images", note="The image viewer",
         paths=["images"], install=["./images/install.sh"], root=False,
         present=lambda: found("hyprshell-images")),
    dict(id="browser", name="Browser", note="Hyprshell Browser",
         paths=["browser"], install=["./browser/install.sh"], root=False,
         present=lambda: os.path.isdir(os.path.join(HOME, ".local/lib/hyprshell-browser"))),
    dict(id="chats-web", name="Chats Web", note="WhatsApp Web in a window of its own",
         paths=["chats-web"], install=["./chats-web/install.sh"], root=False,
         present=lambda: found("hyprshell-chats-web")),
    dict(id="spotify", name="Spotify theme", note="Spicetify setup and the Spotify launcher",
         paths=["spotify"], install=["./spotify/install.sh"], root=False,
         present=lambda: os.path.isdir(os.path.join(CONFIG, "spicetify/Themes/Hyprshell"))),
]


def git(repo, *args, timeout=60):
    r = subprocess.run(["git", "-C", repo, *args], capture_output=True, text=True, timeout=timeout)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def is_repo(path):
    return (path and os.path.isfile(os.path.join(path, "shell/quickshell/shell.qml"))
            and git(path, "rev-parse", "--git-dir")[0] == 0)


def find_repo():
    """Where the hyprshell checkout is: as shell/install.sh noted it, else
    the usual places."""
    try:
        with open(os.path.join(STATE, "repo")) as f:
            p = f.read().strip()
            if is_repo(p):
                return p
    except OSError:
        pass
    for p in [os.environ.get("HYPRSHELL_REPO", "")] + [os.path.join(HOME, n) for n in
              ("hyprlandshel", "hyprshell", "src/hyprlandshel", "src/hyprshell",
               "Projects/hyprlandshel", "Projects/hyprshell", "git/hyprlandshel", "git/hyprshell")]:
        if is_repo(p):
            return p
    return None


def upstream(repo):
    """The branch this checkout follows, e.g. origin/main."""
    rc, out, _ = git(repo, "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
    if rc == 0 and out:
        return out
    rc, branch, _ = git(repo, "rev-parse", "--abbrev-ref", "HEAD")
    return "origin/" + branch if rc == 0 else None


def stamp_path(pid):
    return os.path.join(STAMPS, pid)


def read_stamp(repo, pid):
    try:
        with open(stamp_path(pid)) as f:
            c = f.read().strip()
        if c and git(repo, "cat-file", "-e", c + "^{commit}")[0] == 0:
            return c
    except OSError:
        pass
    return None


def write_stamp(pid, commit):
    os.makedirs(STAMPS, exist_ok=True)
    tmp = stamp_path(pid) + ".tmp"
    with open(tmp, "w") as f:
        f.write(commit + "\n")
    os.replace(tmp, stamp_path(pid))


def check():
    out = {"repo": None, "branch": None, "error": "", "checked": int(time.time()), "parts": []}
    repo = find_repo()
    if not repo:
        out["error"] = ("Couldn't find the hyprshell folder. Run ./shell/install.sh from it once, "
                        "and it will be remembered.")
        return out
    out["repo"] = repo
    up = upstream(repo)
    out["branch"] = up
    if not up:
        out["error"] = "The checkout isn't on a branch."
        return out
    remote = up.split("/", 1)[0]
    try:
        rc, _, err = git(repo, "fetch", "--quiet", remote, timeout=45)
        if rc != 0:
            out["error"] = "Couldn't reach GitHub: " + (err.splitlines()[-1] if err else "fetch failed")
    except subprocess.TimeoutExpired:
        out["error"] = "Couldn't reach GitHub: it took too long"
    rc, head, _ = git(repo, "rev-parse", "HEAD")
    rc2, upc, _ = git(repo, "rev-parse", up)
    if rc2 != 0:
        out["error"] = out["error"] or ("No " + up + " to compare with")
        return out
    out["upstreamCommit"] = upc[:9]
    rc, dirty, _ = git(repo, "status", "--porcelain", "--untracked-files=no")
    out["localChanges"] = bool(dirty)
    for p in PARTS:
        try:
            present = bool(p["present"]())
        except Exception:
            present = False
        if not present:
            continue
        base = read_stamp(repo, p["id"])
        if not base:
            # First look: the checkout as it is now stands for what was
            # installed, and is kept, so later pulls don't move it.
            base = head
            write_stamp(p["id"], head)
        spec = ["--"] + p["paths"]
        _, n, _ = git(repo, "rev-list", "--count", base + ".." + up, *spec)
        _, log, _ = git(repo, "log", "--format=%h%x09%s%x09%cr", "-n", "6", base + ".." + up, *spec)
        commits = []
        for line in log.splitlines():
            h, _, rest = line.partition("\t")
            s, _, when = rest.partition("\t")
            commits.append({"hash": h, "subject": s, "when": when})
        out["parts"].append({"id": p["id"], "name": p["name"], "note": p["note"],
                             "behind": int(n or 0), "commits": commits, "root": p["root"],
                             "installed": base[:9]})
    return out


def run(ids):
    repo = find_repo()
    if not repo:
        print("Couldn't find the hyprshell folder.")
        return 1
    up = upstream(repo)
    print("\033[1mUpdating hyprshell\033[0m in " + repo + "\n")
    rc = subprocess.run(["git", "-C", repo, "pull", "--ff-only"]).returncode
    if rc != 0:
        print("\n\033[31mCouldn't pull.\033[0m If you've changed files in " + repo + ", commit or")
        print("stash them (git stash), then try again.")
        return rc
    _, head, _ = git(repo, "rev-parse", "HEAD")
    if ids == ["all"]:
        info = check()
        ids = [p["id"] for p in info["parts"] if p["behind"] > 0]
    failed = []
    for pid in ids:
        p = next((x for x in PARTS if x["id"] == pid), None)
        if not p:
            continue
        print("\n\033[1m── " + p["name"] + " ──\033[0m")
        cmd = (["sudo"] if p["root"] else []) + p["install"]
        r = subprocess.run(cmd, cwd=repo).returncode
        if r == 0:
            write_stamp(pid, head)
        else:
            failed.append(p["name"])
    # Tells the shell to look again (it watches this file).
    os.makedirs(STATE, exist_ok=True)
    with open(os.path.join(STATE, "update-done"), "w") as f:
        f.write(str(int(time.time())) + "\n")
    if failed:
        print("\n\033[31mDidn't finish:\033[0m " + ", ".join(failed))
        return 1
    print("\n\033[32mUp to date.\033[0m")
    return 0


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "check":
        print(json.dumps(check()))
        return 0
    if len(sys.argv) >= 3 and sys.argv[1] == "run":
        code = run(sys.argv[2:])
        try:
            input("\nPress Enter to close. ")
        except EOFError:
            pass
        return code
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main())
