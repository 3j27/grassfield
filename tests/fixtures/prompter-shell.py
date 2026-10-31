#!/usr/bin/env python3
"""A fake shell for grassfield-prompter's socket (tests/security/prompter_bridge.sh; ADR-0035 D-9, prompter/1).

Connects to --socket, writes every line the bridge sends to --log (one per line, flushed) and runs the commands it reads
from --commands (a FIFO the test writes to, one command per line):
  hello [kind...]                 {"v":"prompter/1","type":"hello","shell":"test","kinds":[...]} (default: password confirm)
  answer <id> ok <password>       a password answer ("last" as the id: the newest prompt seen)
  answer <id> ok-choice <password>  the same with "choice": true
  answer <id> cancel              a cancel answer
  confirm <id> ok|cancel          a confirmation answer
  raw <text>                      <text> and a newline, as is
  long <n>                        n bytes of "a" and a newline (an over-long line)
  close                           disconnects and exits
When the bridge closes the connection the log gets "#closed" and the fake exits. Python standard library only; run it
with python3 -I. Test data only: no real secret ever passes here.
"""
import argparse
import json
import os
import selectors
import socket
import sys


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--log", required=True)
    ap.add_argument("--commands", required=True)
    args = ap.parse_args()

    log = open(args.log, "a", buffering=1, encoding="utf-8")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(args.socket)
    except OSError as e:
        log.write("#connect-failed %s\n" % e)
        return 1
    log.write("#connected\n")
    # Read-write: the FIFO always has a writer (this process), so it never reads as closed between the test's writes.
    commands = os.open(args.commands, os.O_RDWR | os.O_NONBLOCK)
    sel = selectors.DefaultSelector()
    sel.register(sock, selectors.EVENT_READ, "sock")
    sel.register(commands, selectors.EVENT_READ, "cmd")
    inbuf = b""
    cmdbuf = b""
    last_id = None

    def send(obj):
        sock.sendall((json.dumps(obj) + "\n").encode())

    while True:
        for key, _ in sel.select(timeout=30):
            if key.data == "sock":
                try:
                    data = sock.recv(65536)
                except OSError:
                    data = b""
                if not data:
                    log.write("#closed\n")
                    return 0
                inbuf += data
                while b"\n" in inbuf:
                    line, inbuf = inbuf.split(b"\n", 1)
                    text = line.decode("utf-8", "replace")
                    log.write(text + "\n")
                    try:
                        msg = json.loads(text)
                        if msg.get("type") == "prompt":
                            last_id = msg.get("id")
                    except ValueError:
                        pass
            else:
                try:
                    data = os.read(commands, 65536)
                except BlockingIOError:
                    continue
                cmdbuf += data
                while b"\n" in cmdbuf:
                    line, cmdbuf = cmdbuf.split(b"\n", 1)
                    words = line.decode().split(" ")
                    op, rest = words[0], words[1:]
                    target = (lambda i: last_id if i == "last" else i)
                    try:
                        if op == "hello":
                            send({"v": "prompter/1", "type": "hello", "shell": "test", "kinds": rest or ["password", "confirm"]})
                        elif op == "answer" and rest[1] in ("ok", "ok-choice"):
                            msg = {"type": "answer", "id": target(rest[0]), "result": "ok", "password": " ".join(rest[2:])}
                            if rest[1] == "ok-choice":
                                msg["choice"] = True
                            send(msg)
                        elif op == "answer":
                            send({"type": "answer", "id": target(rest[0]), "result": "cancel"})
                        elif op == "confirm":
                            send({"type": "answer", "id": target(rest[0]), "result": rest[1]})
                        elif op == "raw":
                            sock.sendall((" ".join(rest) + "\n").encode())
                        elif op == "long":
                            sock.sendall(b"a" * int(rest[0]) + b"\n")
                        elif op == "close":
                            log.write("#bye\n")
                            sock.close()
                            return 0
                        log.write("#sent %s\n" % op)
                    except OSError as e:
                        log.write("#send-failed %s\n" % e)


if __name__ == "__main__":
    sys.exit(main())
