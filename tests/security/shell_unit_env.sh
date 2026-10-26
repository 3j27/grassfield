#!/usr/bin/env bash
# Review of 360d6fa (the GF-115 class) and its re-review: leaked developer search paths and accidental overrides must not
# replace or disable the packaged shell's QML. A `qs/security/lock` directory on QML_IMPORT_PATH replaced the whole lock
# screen; a stray QS_MANIFEST made `qs -n -p` exit 108 (no lock, no polkit agent). Static (data layer):
# packaging/systemd/grassfield-shell.service clears, with UnsetEnvironment= (systemd applies it last, over Environment=,
# EnvironmentFile=, PassEnvironment= and the manager's environment), the QML and Qt plugin search paths, the GTK module
# variables, the Vulkan loader override and EVERY variable `qs --help` maps to an option ("Env:" entries, read from the
# installed Quickshell, so a new option cannot be missed silently; the packaged command line needs none of them); no
# packaged drop-in resets that list; ExecStart names the system tree; scripts/dev/shell-run.sh --unit-env applies the
# same list from the unit file. Not a defence against code already running as the user (docs/specs/security.md).
#   tests/security/shell_unit_env.sh             check the files, then run the selftest
#   tests/security/shell_unit_env.sh --selftest  only the selftest: each mutation of the unit must fail
# The runtime counterpart (a hostile qs/security/lock ignored with the unit's environment) is
# tests/security/unit_env_paths.sh. Plain shell test: PASS/FAIL lines, non-zero on failure.
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
cd "$root"
exec python3 -I - "$@" <<'PY'
import glob
import re
import subprocess
import sys

UNIT = "packaging/systemd/grassfield-shell.service"
# The search paths Qt 6 reads for QML modules, QML plugins, compiled QML and native plugins; the GTK module variables (the
# gtk3 platform theme Omarchy's environment selects runs gtk_init, which loads them); the Vulkan loader override; and
# Quickshell's option variables (also derived from `qs --help` below).
REQUIRED = ["QML_IMPORT_PATH", "QML2_IMPORT_PATH", "QML_PLUGIN_PATH", "QML_DISK_CACHE_PATH", "QT_PLUGIN_PATH",
            "QT_QPA_PLATFORM_PLUGIN_PATH", "QS_CONFIG_PATH", "QS_CONFIG_NAME", "QS_MANIFEST", "GTK_MODULES", "GTK3_MODULES",
            "GTK_PATH", "GIO_EXTRA_MODULES", "QT_VULKAN_LIB", "QSG_RHI_BACKEND"]


def qs_option_variables():
    """The variables `qs --help` maps to options (its "Env:" entries), or None when Quickshell is not installed."""
    try:
        out = subprocess.run(["qs", "--help"], capture_output=True, text=True, timeout=20, env={"PATH": "/usr/bin:/bin", "QT_QPA_PLATFORM": "offscreen"})
    except (OSError, subprocess.SubprocessError):
        return None
    names = re.findall(r"\(Env:([A-Z0-9_]+)\)", out.stdout + out.stderr)
    return sorted(set(names)) if names else None


def unset_list(text):
    """The variables UnsetEnvironment= leaves cleared, in order of the [Service] section (an empty assignment resets it)."""
    out = []
    section = None
    for raw in text.splitlines():
        line = raw.strip()
        if line.startswith("[") and line.endswith("]"):
            section = line
            continue
        if section != "[Service]" or line.startswith(("#", ";")):
            continue
        m = re.match(r"UnsetEnvironment\s*=\s*(.*)$", line)
        if m:
            value = m.group(1).strip()
            if value == "":
                out = []
            else:
                out += value.split()
    return out


def check(files, options=()):
    fails = []
    unit = files[UNIT]
    # systemd reads the unit, then its drop-ins in name order; each UnsetEnvironment= adds, an empty one resets.
    dropins = [files[k] for k in sorted(k for k in files if k.startswith(UNIT + ".d/"))]
    cleared = unset_list("\n".join([unit] + dropins))
    missing = [v for v in REQUIRED if v not in cleared]
    if missing:
        fails.append("the unit does not clear " + ", ".join(missing))
    unlisted = [v for v in options if v not in cleared]
    if unlisted:
        fails.append("the unit does not clear the qs option variables " + ", ".join(unlisted) + " (from `qs --help`)")
    # An assignment that a later UnsetEnvironment= undoes is harmless, but one that names these variables is a contradiction.
    for raw in unit.splitlines():
        line = raw.strip()
        if re.match(r"(Environment|PassEnvironment|EnvironmentFile)\s*=", line) and any(re.search(r"\b%s\b" % v, line) for v in list(REQUIRED) + list(options)):
            fails.append("the unit sets or passes a cleared variable: " + line)
    exec_lines = [l.strip() for l in unit.splitlines() if l.strip().startswith("ExecStart=")]
    if exec_lines != ["ExecStart=/usr/bin/qs -n -p /usr/share/grassfield/shell"]:
        fails.append("ExecStart is not exactly the system tree: %s" % exec_lines)
    run = files.get("scripts/dev/shell-run.sh", "")
    if "sed -n 's/^UnsetEnvironment=//p' \"$root/packaging/systemd/grassfield-shell.service\"" not in run or 'env "${unit_unset[@]}"' not in run:
        fails.append("scripts/dev/shell-run.sh --unit-env does not apply the unit's UnsetEnvironment=")
    return fails


def load():
    files = {UNIT: open(UNIT, encoding="utf-8").read(), "scripts/dev/shell-run.sh": open("scripts/dev/shell-run.sh", encoding="utf-8").read()}
    for path in sorted(glob.glob(UNIT + ".d/*")):
        files[path] = open(path, encoding="utf-8").read()
    return files


def selftest(files, options):
    ok = not check(files, options)
    print(("PASS" if ok else "FAIL") + ": shell unit env selftest: the tree itself passes")
    line = [l for l in files[UNIT].splitlines() if l.startswith("UnsetEnvironment=")][0]
    cases = [
        ("one variable left out", lambda t: t.replace(line, line.replace(" QML2_IMPORT_PATH", ""))),
        ("a misspelled variable", lambda t: t.replace(line, line.replace("QT_PLUGIN_PATH", "QT_PLUGINS_PATH"))),
        ("the list reset by a later empty assignment", lambda t: t.replace(line, line + "\nUnsetEnvironment=")),
        ("the list in a comment only", lambda t: t.replace(line, "# " + line)),
        ("the list under [Unit] instead of [Service]", lambda t: t.replace(line + "\n", "").replace("[Unit]\n", "[Unit]\n" + line + "\n")),
        ("a cleared variable set again by Environment=", lambda t: t.replace(line, line + "\nEnvironment=QML_IMPORT_PATH=/tmp/x")),
        ("ExecStart on a user path", lambda t: t.replace("ExecStart=/usr/bin/qs -n -p /usr/share/grassfield/shell", "ExecStart=/usr/bin/qs -n -c grassfield")),
        ("QS_MANIFEST left out", lambda t: t.replace(line, line.replace(" QS_MANIFEST", ""))),
        ("a GTK module variable left out", lambda t: t.replace(line, line.replace(" GTK3_MODULES", ""))),
    ]
    for label, mutate in cases:
        copy = dict(files)
        copy[UNIT] = mutate(files[UNIT])
        caught = bool(check(copy, options))
        ok = ok and caught
        print(("PASS" if caught else "FAIL") + ": shell unit env selftest: %s is caught" % label)
    copy = dict(files)
    copy[UNIT + ".d/90-reset.conf"] = "[Service]\nUnsetEnvironment=\n"
    caught = bool(check(copy, options))
    ok = ok and caught
    print(("PASS" if caught else "FAIL") + ": shell unit env selftest: a packaged drop-in resetting the list is caught")
    # A Quickshell that grows an option variable the unit does not clear.
    caught = bool(check(files, list(options) + ["QS_NEW_OPTION"]))
    ok = ok and caught
    print(("PASS" if caught else "FAIL") + ": shell unit env selftest: a new qs option variable not in the list is caught")
    return ok


files = load()
options = qs_option_variables()
if options is None:
    print("SKIP: shell unit env: qs is not installed here: the option variables of `qs --help` were not read (NOT VERIFIED)")
    options = []
if sys.argv[1:] == ["--selftest"]:
    sys.exit(0 if selftest(files, options) else 1)
fails = check(files, options)
if fails:
    for f in fails:
        print("FAIL: shell unit env " + f)
else:
    print("PASS: shell unit env the unit clears " + " ".join(REQUIRED) + "; every qs option variable (" + " ".join(options)
          + ", from `qs --help`); ExecStart is the system tree; shell-run --unit-env applies the list")
sys.exit(0 if selftest(files, options) and not fails else 1)
PY
