#!/usr/bin/env python3
"""A fake grassfield-prompter for tests/security/secret_bridge.sh (ADR-0035 D-9, step 9b): a Unix socket server that speaks
prompter/1 to the shell's real PrompterClient (or SecretAgent) running in an offscreen Quickshell, plays one scenario and
prints PASS/FAIL lines. Test values only; never the user's socket (the paths come from the test's scratch directory).

  fake_bridge.py <scenario> <socket> [<other socket>]

Scenarios:
  client         the client's protocol: its hello (version, kinds), one answer per request and only its own ids, a
                 withdrawal, a cancel for an unknown id ignored, a late answer to a withdrawn request never sent, a
                 confirmation without a password, the check box's state; NetworkManager's kind (step 9c): an answer carries
                 the password only (enterprise included: NetworkManager keeps nothing else), a cancel nothing, an nm prompt
                 with a name for a WPA2 network closes the connection; a malformed line, an over-long line, a prompt
                 before hello, another protocol version and a duplicate id each close the connection; the next attempt
                 waits 1 s, then 2 s, then 4 s (no hello in between), and 1 s again after a hello
  bound          SecretAgent: nine requests; the ninth is refused at once ("refused", never a user's "cancel"), the others
                 are not answered
  session-socket SecretAgent in a real session: it connects to <socket> (the session's), never to <other socket> (a dev
                 socket it was given)
  nothing        no connection at all within 4 s on <socket>
"""
import json
import os
import socket
import sys
import time

FAILED = []


def check(desc, ok, detail=""):
    print(("PASS: " if ok else "FAIL: ") + desc + ("" if ok or not detail else " (" + detail + ")"), flush=True)
    if not ok:
        FAILED.append(desc)


def listen(path):
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    old = os.umask(0o077)
    s.bind(path)
    os.umask(old)
    s.listen(4)
    return s


class Conn:
    def __init__(self, sock):
        self.sock = sock
        self.buf = b""
        self.at = time.monotonic()

    def send(self, obj):
        data = obj if isinstance(obj, bytes) else (json.dumps(obj, separators=(",", ":")) + "\n").encode()
        self.sock.sendall(data)

    def line(self, timeout=5.0):
        """The next line from the shell, None at end of stream, "" on timeout."""
        end = time.monotonic() + timeout
        while b"\n" not in self.buf:
            left = end - time.monotonic()
            if left <= 0:
                return ""
            self.sock.settimeout(left)
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                return ""
            except OSError:
                return None
            if not chunk:
                return None
            self.buf += chunk
        raw, self.buf = self.buf.split(b"\n", 1)
        return raw.decode("utf-8", "replace")

    def json(self, timeout=5.0):
        raw = self.line(timeout)
        if not raw:
            return raw
        try:
            return json.loads(raw)
        except ValueError:
            return {"unparsed": raw}

    def quiet(self, seconds):
        """No line for `seconds`: [] or the lines that came."""
        got = []
        while True:
            raw = self.line(seconds)
            if raw == "":
                return got
            if raw is None:
                got.append("<closed>")
                return got
            got.append(raw)

    def closed(self, timeout=5.0):
        """The shell closes the connection within `timeout` (lines before that are returned, not judged)."""
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            raw = self.line(end - time.monotonic())
            if raw is None:
                return True
        return False

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def accept(server, timeout=10.0):
    server.settimeout(timeout)
    try:
        c, _ = server.accept()
    except socket.timeout:
        return None
    return Conn(c)


def hello(c):
    c.send({"v": "prompter/1", "type": "hello", "bridge": "fake", "kinds": ["password", "confirm"], "max": 8})


def prompt(n, title, kind="password", choice=None, role="keyring"):
    req = {"role": role, "name": "", "desktopId": "", "icon": "", "path": "/usr/bin/gnome-keyring-daemon", "identified": role != "unidentified",
           "onBehalf": role in ("keyring", "gnupg", "ssh")}
    return {"type": "prompt", "id": "p%d" % n, "kind": kind, "requester": req,
            "texts": {"title": title, "message": "", "description": "", "warning": "", "continue": "", "cancel": ""},
            "choice": choice, "passwordNew": False, "strength": False}


def nm_prompt(n, ssid, security, identity=""):
    return {"type": "prompt", "id": "p%d" % n, "kind": "nm", "network": {"ssid": ssid, "security": security, "identity": identity}}


def shell_hello(c, desc):
    h = c.json()
    check(desc, isinstance(h, dict) and h.get("v") == "prompter/1" and h.get("type") == "hello" and h.get("kinds") == ["password", "confirm", "nm"]
          and isinstance(h.get("shell"), str) and set(h) == {"v", "type", "shell", "kinds"}, repr(h))


def scenario_client(server):
    c = accept(server)
    check("the shell connects", c is not None)
    if c is None:
        return
    shell_hello(c, "the shell's hello is the first line, prompter/1, the kinds it draws (password, confirm, nm)")
    hello(c)
    c.send({"type": "name", "state": "owned"})
    c.send(prompt(1, "answer-ok"))
    a = c.json()
    check("a password request is answered once, with the password", a == {"type": "answer", "id": "p1", "result": "ok", "password": "pw-p1"}, repr(a))
    c.send(prompt(2, "leave"))
    c.send({"type": "cancel", "id": "p2"})
    c.send({"type": "cancel", "id": "p77"})
    c.send(prompt(3, "answer-twice"))
    a = c.json()
    check("answered once although asked twice; a withdrawn request and an unknown id get nothing",
          a == {"type": "answer", "id": "p3", "result": "ok", "password": "pw-p3"}, repr(a))
    c.send(prompt(4, "answer-late"))
    c.send({"type": "cancel", "id": "p4"})
    c.send(prompt(5, "answer-cancel", kind="confirm", choice={"label": "Remember", "chosen": True}))
    a = c.json()
    check("no late answer to a withdrawn request; a cancelled confirmation carries the check box, no password",
          a == {"type": "answer", "id": "p5", "result": "cancel", "choice": True}, repr(a))
    c.send(prompt(6, "answer-ok", kind="confirm"))
    a = c.json()
    check("a confirmation answered ok carries no password", a == {"type": "answer", "id": "p6", "result": "ok"}, repr(a))
    c.send(nm_prompt(20, "answer-ok", "wpa"))
    a = c.json()
    check("an nm request (WPA2) answered ok carries the password only", a == {"type": "answer", "id": "p20", "result": "ok", "password": "pw-p20"}, repr(a))
    c.send(nm_prompt(21, "answer-ok", "enterprise", "alice"))
    a = c.json()
    check("an nm request (enterprise) answered ok carries the password only (the username is shown, never sent)",
          a == {"type": "answer", "id": "p21", "result": "ok", "password": "pw-p21"}, repr(a))
    c.send(nm_prompt(22, "answer-cancel", "wep"))
    a = c.json()
    check("an nm request cancelled carries nothing", a == {"type": "answer", "id": "p22", "result": "cancel"}, repr(a))
    extra = c.quiet(0.6)
    check("nothing else is sent (the late answer to p4 included)", extra == [], repr(extra))
    bad = prompt(7, "answer-ok")
    bad["html"] = "<b>admin</b>"
    c.send(bad)
    check("a prompt with a key prompter/1 does not have closes the connection (never answered)", c.closed())
    c.close()
    closed_at = time.monotonic()

    def reconnect(desc, low, high):
        nonlocal closed_at
        c2 = accept(server, high + 3)
        waited = time.monotonic() - closed_at
        check(desc + " (%.1f s)" % waited, c2 is not None and low <= waited <= high + 1.5)
        return c2

    c = reconnect("the shell connects again after about 1 s", 0.8, 1.5)
    if c is None:
        return
    shell_hello(c, "a hello again on the new connection")
    hello(c)
    c.send(("{\"type\":\"name\",\"state\":\"owned\",\"pad\":\"" + "x" * 20000 + "\"}\n").encode())
    check("an over-long line closes the connection", c.closed())
    c.close()
    closed_at = time.monotonic()
    c = reconnect("then again after about 1 s (its hello reset the wait)", 0.8, 1.5)
    if c is None:
        return
    c.json()
    c.send(prompt(8, "answer-ok"))
    check("a prompt before the bridge's hello closes the connection", c.closed())
    c.close()
    closed_at = time.monotonic()
    c = reconnect("without a hello in between the wait doubles: 2 s", 1.8, 2.5)
    if c is None:
        return
    c.json()
    c.send({"v": "prompter/2", "type": "hello", "bridge": "fake", "kinds": ["password"], "max": 8})
    check("another protocol version closes the connection", c.closed())
    c.close()
    closed_at = time.monotonic()
    c = reconnect("then 4 s", 3.8, 4.5)
    if c is None:
        return
    c.json()
    hello(c)
    c.send(prompt(9, "leave"))
    c.send(prompt(9, "leave"))
    check("the same id twice closes the connection", c.closed())
    c.close()
    closed_at = time.monotonic()
    c = reconnect("then 1 s again (the bridge's hello on that connection reset the wait)", 0.8, 1.5)
    if c is None:
        return
    c.json()
    hello(c)
    c.send(nm_prompt(30, "answer-ok", "wpa", "eve"))
    check("an nm prompt with a name for a WPA2 network closes the connection (never answered)", c.closed())
    c.close()


def scenario_bound(server):
    c = accept(server)
    check("SecretAgent connects (a dev session, its test socket)", c is not None)
    if c is None:
        return
    shell_hello(c, "SecretAgent's hello")
    hello(c)
    c.send({"type": "name", "state": "owned"})
    for n in range(1, 10):
        c.send(prompt(n, "leave"))
    a = c.json()
    check("the ninth request is refused at once (\"refused\", never a user's cancel)", a == {"type": "answer", "id": "p9", "result": "refused"}, repr(a))
    extra = c.quiet(1.0)
    check("the eight others wait for the user (no answer invented)", extra == [], repr(extra))
    c.send({"type": "cancel", "id": "p3"})
    c.send({"type": "cancel", "id": "p1"})
    extra = c.quiet(1.0)
    check("withdrawn requests are not answered", extra == [], repr(extra))
    c.close()


def scenario_session_socket(server, other):
    c = accept(server)
    check("in a real session the agent connects to $XDG_RUNTIME_DIR/grassfield/prompter.sock", c is not None)
    if c is not None:
        shell_hello(c, "...and says hello there")
        hello(c)
        c.send({"type": "name", "state": "owned"})
    other.settimeout(2.0)
    try:
        o, _ = other.accept()
        o.close()
        check("the dev socket it was given is never used in a real session", False)
    except socket.timeout:
        check("the dev socket it was given is never used in a real session", True)
    time.sleep(1.5)
    if c is not None:
        c.close()


def scenario_nothing(server):
    server.settimeout(4.0)
    try:
        c, _ = server.accept()
        c.close()
        check("a dev session without a test socket connects nowhere", False)
    except socket.timeout:
        check("a dev session without a test socket connects nowhere", True)


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: fake_bridge.py <scenario> <socket> [<other socket>]")
    scenario, path = sys.argv[1], sys.argv[2]
    server = listen(path)
    open(path + ".ready", "w").close()
    if scenario == "client":
        scenario_client(server)
    elif scenario == "bound":
        scenario_bound(server)
    elif scenario == "session-socket":
        scenario_session_socket(server, listen(sys.argv[3]))
    elif scenario == "nothing":
        scenario_nothing(server)
    else:
        sys.exit("unknown scenario " + scenario)
    sys.exit(1 if FAILED else 0)


if __name__ == "__main__":
    main()
