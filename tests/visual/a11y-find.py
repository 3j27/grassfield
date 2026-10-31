#!/usr/bin/env python3
"""Finds a control of a nested-session app by its accessible role and name (AT-SPI), so a visual script acts on the control
it means instead of a screen point that moves when the layout changes (tests/visual/wallpaper-online-ui.sh: the fixed point
of the Online tile landed on "Add Video..." once the Videos grid came in above it).

The app must expose its accessibility tree: start it with QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1 on the nested session's PRIVATE
bus (vs_spawn); this script reads that bus from DBUS_SESSION_BUS_ADDRESS and refuses any other (the owner's session bus
would show the owner's applications). libatspi reads AT_SPI_BUS_ADDRESS first, and falls back on DISPLAY's X root property:
the script asks the private bus for its accessibility bus (org.a11y.Bus GetAddress, tests/visual/a11y-lib.sh's own, under
/tmp/gf-a11y-*), refuses an AT_SPI_BUS_ADDRESS that names another, sets it to that answer and drops DISPLAY.

  a11y-find.py --pid PID --role ROLE-REGEX --name REGEX [--state STATE]... [--press] [--wait SECONDS]

Looks in the application of process PID for a showing accessible whose AT-SPI role name matches ROLE-REGEX in full
("radio button"; a push button is "button" in at-spi2-core 2.60, "push button" before) and whose name matches REGEX (Python
re.search), and that has every --state (AT-SPI state names: selected, sensitive, focused...). Prints one JSON line: {name, role, x, y, width,
height} (x and y relative to the window). --press runs its first action ("Press": QML Accessible.onPressAction, the
control's own activation). Exit 0 when found (and pressed), 1 when nothing matched within --wait seconds, 2 on a usage
or bus error.
"""
import argparse
import json
import os
import re
import sys
import time
import warnings


def bus_problem(bus, runtime):
    """Why `bus` (a DBUS_SESSION_BUS_ADDRESS) is refused, or "": only the nested session's private bus."""
    if not bus.startswith("unix:path=/tmp/dbus-") or bus.startswith("unix:path=%s/bus" % runtime):
        return "refusing bus %r: only the nested session's private bus (unix:path=/tmp/dbus-*)" % bus
    return ""


def accessibility_problem(answer, given):
    """Why the accessibility bus is refused, or "": `answer` is the private bus's GetAddress, `given` AT_SPI_BUS_ADDRESS."""
    if not answer.startswith("unix:path=/tmp/gf-a11y-"):
        return "refusing accessibility bus %r: not a11y-lib.sh's own (/tmp/gf-a11y-*)" % answer
    if given and given != answer:
        return "refusing AT_SPI_BUS_ADDRESS %r: the private bus's accessibility bus is %r" % (given, answer)
    return ""


def private_bus_or_exit():
    problem = bus_problem(os.environ.get("DBUS_SESSION_BUS_ADDRESS", ""), os.environ.get("XDG_RUNTIME_DIR", "/run/user/%d" % os.getuid()))
    if problem:
        print("a11y-find: " + problem, file=sys.stderr)
        sys.exit(2)


def accessibility_bus_or_exit():
    """AT_SPI_BUS_ADDRESS: the private bus's own accessibility bus, and nothing else (review of fac5bff3)."""
    from gi.repository import Gio, GLib
    try:
        conn = Gio.DBusConnection.new_for_address_sync(
            os.environ["DBUS_SESSION_BUS_ADDRESS"],
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        reply = conn.call_sync("org.a11y.Bus", "/org/a11y/bus", "org.a11y.Bus", "GetAddress", None,
                               GLib.VariantType("(s)"), Gio.DBusCallFlags.NO_AUTO_START, 3000, None)
        address = reply.unpack()[0]
    except Exception as e:
        print("a11y-find: the private bus has no accessibility bus (start it with a11y-lib.sh's a11y_start): %s" % e, file=sys.stderr)
        sys.exit(2)
    problem = accessibility_problem(address, os.environ.get("AT_SPI_BUS_ADDRESS", ""))
    if problem:
        print("a11y-find: " + problem, file=sys.stderr)
        sys.exit(2)
    os.environ["AT_SPI_BUS_ADDRESS"] = address
    os.environ.pop("DISPLAY", None)


def walk(node, depth=0):
    if node is None or depth > 64:
        return
    yield node
    try:
        count = node.get_child_count()
    except Exception:
        return
    for i in range(count):
        try:
            child = node.get_child_at_index(i)
        except Exception:
            continue
        yield from walk(child, depth + 1)


def find(Atspi, pid, role, pattern, states):
    desktop = Atspi.get_desktop(0)
    for i in range(desktop.get_child_count()):
        app = desktop.get_child_at_index(i)
        try:
            if app is None or app.get_process_id() != pid:
                continue
        except Exception:
            continue
        for node in walk(app):
            try:
                if not role.fullmatch(node.get_role_name() or "") or not pattern.search(node.get_name() or ""):
                    continue
                state_set = node.get_state_set()
                if not all(state_set.contains(s) for s in [Atspi.StateType.SHOWING] + states):
                    continue
            except Exception:
                continue
            return node
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pid", type=int, required=True)
    parser.add_argument("--role", required=True)
    parser.add_argument("--name", required=True)
    parser.add_argument("--state", action="append", default=[])
    parser.add_argument("--press", action="store_true")
    parser.add_argument("--wait", type=float, default=10)
    args = parser.parse_args()
    private_bus_or_exit()
    import gi
    gi.require_version("Atspi", "2.0")
    accessibility_bus_or_exit()
    from gi.repository import Atspi
    pattern = re.compile(args.name)
    role = re.compile(args.role)
    try:
        states = [getattr(Atspi.StateType, name.upper()) for name in args.state]
    except AttributeError as e:
        print("a11y-find: unknown state: %s" % e, file=sys.stderr)
        return 2
    deadline = time.monotonic() + args.wait
    node = None
    while True:
        node = find(Atspi, args.pid, role, pattern, states)
        if node is not None or time.monotonic() >= deadline:
            break
        time.sleep(0.25)
    if node is None:
        print("a11y-find: no showing %r named /%s/ with states %s in process %d" % (args.role, args.name, args.state, args.pid), file=sys.stderr)
        return 1
    box = {"x": -1, "y": -1, "width": 0, "height": 0}
    try:
        r = node.get_extents(Atspi.CoordType.WINDOW)
        box = {"x": r.x, "y": r.y, "width": r.width, "height": r.height}
    except Exception:
        pass
    actions = []
    try:
        # get_action_name is deprecated in at-spi2-core 2.60 but still the action's untranslated name ("Press").
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", DeprecationWarning)
            actions = [node.get_action_name(i) for i in range(node.get_n_actions())]
    except Exception:
        pass
    print(json.dumps(dict(name=node.get_name(), role=node.get_role_name(), actions=actions, **box), ensure_ascii=False))
    if args.press:
        # The "Press" action (QML Accessible.onPressAction); a radio button lists "Toggle" first, which runs nothing there.
        names = [a.lower() for a in actions]
        index = names.index("press") if "press" in names else 0
        try:
            if not actions or not node.do_action(index):
                print("a11y-find: the control has no action to run (%s)" % actions, file=sys.stderr)
                return 1
        except Exception as e:
            print("a11y-find: the action failed: %s" % e, file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
