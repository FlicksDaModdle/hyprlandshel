#!/usr/bin/env python3
# A stand-in greetd for the tests (tools/test): its IPC on the socket given,
# every request logged (answers shown only by their length).
#   tester:   "Welcome", then the password (testpw), then a one-time code (123456)
#   facetest: found by face after a moment, with nothing typed
import socket, struct, json, os, sys
path = sys.argv[1]
log = open(sys.argv[2], "a")
try: os.unlink(path)
except FileNotFoundError: pass
srv = socket.socket(socket.AF_UNIX); srv.bind(path); srv.listen(1)
def recv(c):
    h = c.recv(4, socket.MSG_WAITALL)
    if len(h) < 4: return None
    n = struct.unpack("=I", h)[0]
    return json.loads(c.recv(n, socket.MSG_WAITALL))
def send(c, o):
    b = json.dumps(o).encode(); c.sendall(struct.pack("=I", len(b)) + b)
while True:
    c, _ = srv.accept()
    st = {}
    while True:
        m = recv(c)
        if m is None: break
        t = m["type"]
        shown = dict(m)
        if "response" in shown and shown["response"]: shown["response"] = "<%d chars>" % len(shown["response"])
        log.write(json.dumps(shown) + "\n"); log.flush()
        if t == "create_session" and m["username"] == "facetest":
            st = {"user": m["username"], "step": "face"}
            send(c, {"type": "auth_message", "auth_message_type": "info", "auth_message": "\u200bCome a little closer"})
        elif t == "post_auth_message_response" and st.get("step") == "face":
            import time; time.sleep(2.5)
            st["step"] = "ok"; send(c, {"type": "success"})
        elif t == "create_session":
            st = {"user": m["username"], "step": "pw"}
            send(c, {"type": "auth_message", "auth_message_type": "info", "auth_message": "Welcome"})
        elif t == "post_auth_message_response":
            r = m.get("response")
            if r is None and st.get("step") == "pw":
                send(c, {"type": "auth_message", "auth_message_type": "secret", "auth_message": "Password: "})
            elif st.get("step") == "pw":
                if r == "testpw":
                    st["step"] = "otp"
                    send(c, {"type": "auth_message", "auth_message_type": "visible", "auth_message": "Verification code:"})
                else:
                    send(c, {"type": "error", "error_type": "auth_error", "description": "pam_authenticate: AUTH_ERR"})
            elif st.get("step") == "otp":
                if r == "123456":
                    st["step"] = "ok"; send(c, {"type": "success"})
                else:
                    send(c, {"type": "error", "error_type": "auth_error", "description": "bad code"})
        elif t == "start_session":
            send(c, {"type": "success"})
        elif t == "cancel_session":
            st = {}; send(c, {"type": "success"})
