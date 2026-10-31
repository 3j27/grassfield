#!/usr/bin/env python3
"""The guards of tests/visual/a11y-find.py (review of fac5bff3, MINOR): it reads only the nested session's private bus and
only that bus's own accessibility bus, whatever AT_SPI_BUS_ADDRESS or DISPLAY the caller inherited (libatspi reads
AT_SPI_BUS_ADDRESS first, then DISPLAY's X root property). Pure checks, plus the script run with refused environments: it
exits 2 before it touches any bus. Run: python3 -I tests/visual/test_a11y_find.py
"""
import importlib.util
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(HERE, "a11y-find.py")
spec = importlib.util.spec_from_file_location("a11y_find", SCRIPT)
a11y_find = importlib.util.module_from_spec(spec)
spec.loader.exec_module(a11y_find)

PRIVATE = "unix:path=/tmp/dbus-AbCdEf,guid=0123"
OWN_A11Y = "unix:path=/tmp/gf-a11y-Xy12Zz/at-spi/bus_0,guid=4567"


class Guards(unittest.TestCase):
    def test_only_the_private_bus(self):
        self.assertEqual(a11y_find.bus_problem(PRIVATE, "/run/user/1000"), "")
        for bus in ("", "unix:path=/run/user/1000/bus", "unix:path=/run/user/1000/bus,guid=1", "autolaunch:",
                    "unix:abstract=/tmp/dbus-x", "tcp:host=localhost,port=1"):
            self.assertIn("refusing bus", a11y_find.bus_problem(bus, "/run/user/1000"), bus)

    def test_only_its_own_accessibility_bus(self):
        self.assertEqual(a11y_find.accessibility_problem(OWN_A11Y, ""), "")
        self.assertEqual(a11y_find.accessibility_problem(OWN_A11Y, OWN_A11Y), "")
        # The owner's accessibility bus, given by the environment or answered by the bus: refused.
        owner = "unix:path=/run/user/1000/at-spi/bus_0"
        self.assertIn("refusing AT_SPI_BUS_ADDRESS", a11y_find.accessibility_problem(OWN_A11Y, owner))
        self.assertIn("refusing accessibility bus", a11y_find.accessibility_problem(owner, ""))
        self.assertIn("refusing accessibility bus", a11y_find.accessibility_problem("", ""))

    def test_the_script_refuses_before_any_bus(self):
        env = {"PATH": os.environ.get("PATH", "/usr/bin"), "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
               "AT_SPI_BUS_ADDRESS": "unix:path=/run/user/1000/at-spi/bus_0", "DISPLAY": ":0", "XDG_RUNTIME_DIR": "/run/user/1000"}
        out = subprocess.run([sys.executable, "-I", SCRIPT, "--pid", "1", "--role", "x", "--name", "x", "--wait", "0"],
                             env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 2, out.stderr)
        self.assertIn("refusing bus", out.stderr)
        # A private bus with no accessibility bus of a11y-lib.sh's: refused too (nothing listens at that path).
        env["DBUS_SESSION_BUS_ADDRESS"] = "unix:path=/tmp/dbus-gf-a11y-test-absent"
        out = subprocess.run([sys.executable, "-I", SCRIPT, "--pid", "1", "--role", "x", "--name", "x", "--wait", "0"],
                             env=env, capture_output=True, text=True, timeout=30)
        self.assertEqual(out.returncode, 2, out.stderr)
        self.assertIn("no accessibility bus", out.stderr)


if __name__ == "__main__":
    unittest.main()
