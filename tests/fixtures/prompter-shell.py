#!/usr/bin/env python3
"""A fake shell for grassfield-prompter's socket (tests/security/prompter_bridge.sh; ADR-0035 D-9, prompter/1).

Connects to --socket, writes every line the bridge sends to --log (one per line, flushed) and runs the commands it reads
from --commands (a FIFO the test writes to, one command per line):
  hello [kind...]                 {"v":"prompter/1","type":"hello","shell":"test","kinds":[...]} (default: password confirm)
  answer <id> ok <password>       a password answer ("last" as the id: the newest prompt seen)
  answer <id> ok-choice <password>  the same with "choice": true
  answer <id> ok-identity <identity> <password>  an nm answer with a name ("identity") and a password (step 9c)
  answer <id> kio <name|-> <yes|no|-> <password>  a kio answer (step 9e): "identity" unless "-", "choice" (Remember this
                                  password) unless "-", and the password
  answer <id> cancel              a cancel answer
  confirm <id> ok|cancel          a confirmation answer
  raw <text>                      <text> and a newline, as is
  long <n>                        n bytes of "a" and a newline (an over-long line)
  close                           disconnects and exits
  halfclose                       shuts its reading side down and keeps the socket open: the bridge's next write fails
                                  (EPIPE) while it never reads an end
With --auto-answer PASSWORD (a stand-in for the stock prompter in tests/security/askpass.sh) it says hello at once and
answers every password prompt "ok" with PASSWORD, every confirmation "ok"; --commands is then optional.
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
    ap.add_argument("--commands")
    ap.add_argument("--auto-answer")
    args = ap.parse_args()
    if args.commands is None and args.auto_answer is None:
        ap.error("--commands or --auto-answer")

    log = open(args.log, "a", buffering=1, encoding="utf-8")
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.connect(args.socket)
    except OSError as e:
        log.write("#connect-failed %s\n" % e)
        return 1
    log.write("#connected\n")
    # Read-write: the FIFO always has a writer (this process), so it never reads as closed between the test's writes.
    sel = selectors.DefaultSelector()
    sel.register(sock, selectors.EVENT_READ, "sock")
    commands = None
    if args.commands is not None:
        commands = os.open(args.commands, os.O_RDWR | os.O_NONBLOCK)
        sel.register(commands, selectors.EVENT_READ, "cmd")
    inbuf = b""
    cmdbuf = b""
    last_id = None

    def send(obj):
        sock.sendall((json.dumps(obj) + "\n").encode())

    if args.auto_answer is not None:
        send({"v": "prompter/1", "type": "hello", "shell": "auto", "kinds": ["password", "confirm"]})

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
                            if args.auto_answer is not None:
                                answer = {"type": "answer", "id": last_id, "result": "ok"}
                                if msg.get("kind") == "password":
                                    answer["password"] = args.auto_answer
                                send(answer)
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
                        elif op == "answer" and rest[1] == "kio":
                            msg = {"type": "answer", "id": target(rest[0]), "result": "ok", "password": " ".join(rest[4:])}
                            if rest[2] != "-":
                                msg["identity"] = rest[2]
                            if rest[3] != "-":
                                msg["choice"] = rest[3] == "yes"
                            send(msg)
                        elif op == "answer" and rest[1] == "ok-identity":
                            send({"type": "answer", "id": target(rest[0]), "result": "ok", "identity": rest[2], "password": " ".join(rest[3:])})
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
                        elif op == "halfclose":
                            sock.shutdown(socket.SHUT_RD)
                            sel.unregister(sock)
                            log.write("#halfclosed\n")
                            continue
                        log.write("#sent %s\n" % op)
                    except OSError as e:
                        log.write("#send-failed %s\n" % e)


if __name__ == "__main__":
    sys.exit(main())
