#!/usr/bin/env python3
# layout-names.py LANGUAGE NAME...: the keyboard layout names in a language, one line per NAME, in the order given.
#
# Hyprland names a layout by its xkb description in English ("English (US)"); xkeyboard-config ships those descriptions
# translated in its gettext domain ("Anglais (US)"). This reads the catalog with Python's gettext module (it needs no
# generated locale, unlike gettext(1), and no D-Bus), tries xkeyboard-config-2 then xkeyboard-config, and prints the NAME
# itself for a language without a catalog and for a name the catalog does not know. It never fails: a bad language, a
# missing catalog or an odd name give the names unchanged. Used by platform/InputSource.qml (the input source HUD); Settings
# reads the same catalogs the same way (one source of truth for the names). Run as `python3 -I`.
import gettext
import os
import re
import sys

# GRASSFIELD_XKB_LOCALEDIR (a catalog of a test's own) replaces the system's locale directory in a development session only
# (GRASSFIELD_DEV exactly 1 and GRASSFIELD_SESSION not 1, the run-mode rule of shell/lib/RunMode.js, as GRASSFIELD_TRANSLATIONS_DIR).
DEV = os.environ.get("GRASSFIELD_DEV") == "1" and os.environ.get("GRASSFIELD_SESSION") != "1"
LOCALEDIR = (os.environ.get("GRASSFIELD_XKB_LOCALEDIR") if DEV else "") or "/usr/share/locale"
DOMAINS = ("xkeyboard-config-2", "xkeyboard-config")
LANGUAGE = re.compile(r"^[A-Za-z]{2,3}(?:[_-][A-Za-z0-9]{2,8})?(?:[.@][A-Za-z0-9_-]{1,32})*$")


def catalogs(language):
    """The translation objects of a language, best first (fr_FR, then fr); none for English or a malformed value."""
    if not LANGUAGE.match(language or ""):
        return []
    base = re.split(r"[.@]", language)[0].replace("-", "_")
    candidates = [base]
    if "_" in base:
        candidates.append(base.split("_")[0])
    if candidates[-1] == "en":
        return []
    found = []
    for domain in DOMAINS:
        for candidate in candidates:
            try:
                found.append(gettext.translation(domain, LOCALEDIR, languages=[candidate]))
                break
            except Exception:  # no catalog, or one that does not parse (struct.error, EOFError, ...): the next one, else the names as given
                continue
    return found


def translate(name, found):
    for catalog in found:
        try:
            text = catalog.gettext(name)
        except Exception:
            continue
        if text != name:
            return text
    return name


def main(argv):
    found = catalogs(argv[1]) if len(argv) > 1 else []
    for name in argv[2:]:
        name = name.replace("\n", " ").replace("\r", " ")
        try:
            print(translate(name, found))
        except Exception:
            print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
