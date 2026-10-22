#!/usr/bin/env python3
"""Unlock the running gnome-keyring-daemon's login keyring.

The password comes on standard input, never on the command line. It is
handed to the daemon over its control socket ($GNOME_KEYRING_CONTROL/
control, as PAM passes it on, else $XDG_RUNTIME_DIR/keyring/control), the
same way pam_gnome_keyring does it at a password login:

    a nul byte (the daemon checks who we are with SO_PEERCRED), then
    uint32 length, uint32 op (1: unlock), uint32 password length, password
    and back: uint32 length (8), uint32 result

all big-endian. Exit status: 0 unlocked, 3 the password was refused,
4 failed, 5 no daemon is running yet.

Used by scripts/face-keyring.sh, for unlocking the keyring after a login
with your face (Settings -> Login screen -> Keyring).
"""
import os
import socket
import stat
import struct
import sys

OP_UNLOCK = 1
RESULTS = {0: 0, 1: 3, 2: 4, 3: 5}


def main():
    password = sys.stdin.buffer.read()
    if password.endswith(b"\n"):
        password = password[:-1]
    if not password:
        print("keyring-unlock: no password on stdin", file=sys.stderr)
        return 4

    runtime = os.environ.get("XDG_RUNTIME_DIR") or "/run/user/%d" % os.getuid()
    places = [os.path.join(runtime, "keyring", "control")]
    if os.environ.get("GNOME_KEYRING_CONTROL"):
        places.insert(0, os.path.join(os.environ["GNOME_KEYRING_CONTROL"], "control"))
    path, st = None, None
    for p in places:
        try:
            path, st = p, os.lstat(p)
            break
        except FileNotFoundError:
            continue
    if st is None:
        return 5
    # Ours, and a socket: nothing else gets the password.
    if st.st_uid != os.getuid() or not stat.S_ISSOCK(st.st_mode):
        print("keyring-unlock: %s isn't the keyring's own socket" % path, file=sys.stderr)
        return 4

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(path)
    except ConnectionRefusedError:
        return 5
    with sock:
        # The daemon on the other end runs as us.
        creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        _, uid, _ = struct.unpack("3i", creds)
        if uid != os.getuid():
            print("keyring-unlock: the keyring daemon isn't running as you", file=sys.stderr)
            return 4
        sock.sendall(b"\0")
        packet = struct.pack(">II", 8 + 4 + len(password), OP_UNLOCK)
        packet += struct.pack(">I", len(password)) + password
        sock.sendall(packet)
        reply = b""
        while len(reply) < 8:
            part = sock.recv(8 - len(reply))
            if not part:
                print("keyring-unlock: the daemon hung up", file=sys.stderr)
                return 4
            reply += part
        _, result = struct.unpack(">II", reply)
        return RESULTS.get(result, 4)


if __name__ == "__main__":
    sys.exit(main())
