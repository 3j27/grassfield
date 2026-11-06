#!/usr/bin/env python3
"""Build-time files of Grassfield's [grassfield] pacman repository (ADR-0033 b.3, c.1, g).

  generate.py --conf repository.conf --key grassfield-signing-key.asc --out DIR

Reads packaging/pacman/repository.conf (KEY=value lines, never sourced) and the pinned public key next to it, checks
them, and writes into DIR the root-owned files the package installs under /usr/share/grassfield/pacman/:

  repository.conf           the same four values, checked and normalised (read by grassfield-channel.sh,
                            grassfield-channel-set and grassfield-update-check)
  grassfield-stable.conf    the content of /etc/pacman.d/grassfield.conf for each channel: SigLevel = Required, then
  grassfield-beta.conf      one Server line per base, the primary first (the only source the root helper writes from)
  grassfield-stable-cohort.conf  the staged rollout's cohort form (ADR-0050 2): one Server line per base on the path
  grassfield-beta-cohort.conf    <base>/<channel>/cohort/@COHORT@/$arch, then the plain lines as a fallback; the root
                                 scriptlet replaces @COHORT@ with the machine's two digits and nothing else
  grassfield-signing-key.asc  the pinned public key, copied once its fingerprint is checked (empty when none is pinned)

Fails (exit 1, nothing written) on an unknown, missing or repeated key, a base that is not https:// (or file:// for
the container tests' own builds), a fingerprint that is not 40 hex digits, a key file whose only primary key is not the
pinned fingerprint, a key file holding a secret key, or a key file without a fingerprint. An empty fingerprint and an
empty key file together are a valid build that refuses to set Grassfield updates up (owner decision O11).
Python standard library and gpg only.
"""
import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile

KEYS = ("GRASSFIELD_REPO_BASE", "GRASSFIELD_REPO_MIRRORS", "GRASSFIELD_REPO_BASE_PREVIOUS", "GRASSFIELD_SIGNING_FINGERPRINT")
CHANNELS = ("stable", "beta")
SEGMENT = r"/[A-Za-z0-9._~+-]+"
BASE = re.compile(r"^(?:https://[A-Za-z0-9.-]+(?::[0-9]{1,5})?(?:%s)*|file://(?:%s)+)$" % (SEGMENT, SEGMENT))
FINGERPRINT = re.compile(r"^[0-9A-F]{40}$")


class Invalid(Exception):
    pass


def check_base(value, what):
    if not BASE.match(value) or any(part in (".", "..") for part in value.split("/")):
        raise Invalid(f"{what}: '{value}' is not an https:// (or file:///) base without a trailing slash")
    return value


def parse(text):
    values = {}
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        key, sep, value = line.partition("=")
        if not sep or key not in KEYS:
            raise Invalid(f"line {n}: expected one of {', '.join(KEYS)} followed by '='")
        if key in values:
            raise Invalid(f"line {n}: {key} is set twice")
        if value != value.strip() or any(c in value for c in "\"'`$\\"):
            raise Invalid(f"line {n}: {key}: no quotes, expansions or surrounding blanks")
        values[key] = value
    missing = [k for k in KEYS if k not in values]
    if missing:
        raise Invalid(f"missing: {', '.join(missing)}")
    base = check_base(values["GRASSFIELD_REPO_BASE"], "GRASSFIELD_REPO_BASE")
    mirrors = [check_base(v, "GRASSFIELD_REPO_MIRRORS") for v in values["GRASSFIELD_REPO_MIRRORS"].split()]
    previous = [check_base(v, "GRASSFIELD_REPO_BASE_PREVIOUS") for v in values["GRASSFIELD_REPO_BASE_PREVIOUS"].split()]
    if len(set([base] + mirrors)) != 1 + len(mirrors):
        raise Invalid("GRASSFIELD_REPO_MIRRORS repeats a base")
    if base in previous or set(mirrors) & set(previous):
        raise Invalid("GRASSFIELD_REPO_BASE_PREVIOUS names a current base")
    fpr = values["GRASSFIELD_SIGNING_FINGERPRINT"]
    if fpr and not FINGERPRINT.match(fpr):
        raise Invalid("GRASSFIELD_SIGNING_FINGERPRINT: 40 upper-case hex digits, or empty")
    return base, mirrors, previous, fpr


def key_fingerprints(path):
    """(primary fingerprints, has a secret key) of the OpenPGP data in `path`, read without importing it."""
    home = tempfile.mkdtemp(prefix="grassfield-key-")
    try:
        out = subprocess.run(
            ["gpg", "--homedir", home, "--batch", "--no-tty", "--with-colons", "--import-options", "show-only",
             "--import", path], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
    finally:
        subprocess.run(["gpgconf", "--homedir", home, "--kill", "all"], capture_output=True)
        shutil.rmtree(home, ignore_errors=True)
    if out.returncode != 0:
        raise Invalid(f"{path}: gpg cannot read it: {out.stderr.strip()[:200]}")
    primaries, secret, expect = [], False, False
    for line in out.stdout.splitlines():
        fields = line.split(":")
        if fields[0] in ("pub", "sec"):
            secret = secret or fields[0] == "sec"
            expect = True
        elif fields[0] == "fpr" and expect:
            primaries.append(fields[9])
            expect = False
        elif fields[0] in ("sub", "ssb"):
            expect = False
    return primaries, secret


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--conf", required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    try:
        with open(args.conf, encoding="utf-8") as f:
            base, mirrors, previous, fpr = parse(f.read())
        key_size = os.path.getsize(args.key)
        if fpr and key_size == 0:
            raise Invalid(f"{args.key} is empty but GRASSFIELD_SIGNING_FINGERPRINT is set")
        if not fpr and key_size != 0:
            raise Invalid(f"{args.key} holds a key but GRASSFIELD_SIGNING_FINGERPRINT is empty")
        if fpr:
            primaries, secret = key_fingerprints(args.key)
            if secret:
                raise Invalid(f"{args.key} holds a secret key: only the public key ships")
            if primaries != [fpr]:
                raise Invalid(f"{args.key} must hold exactly the key {fpr}, found: {' '.join(primaries) or 'none'}")
    except (OSError, UnicodeDecodeError, subprocess.TimeoutExpired, Invalid) as e:
        print(f"generate.py: {e}", file=sys.stderr)
        return 1
    os.makedirs(args.out, exist_ok=True)
    files = {
        "repository.conf": "# Generated from packaging/pacman/repository.conf by generate.py (ADR-0033 g).\n"
        f"GRASSFIELD_REPO_BASE={base}\nGRASSFIELD_REPO_MIRRORS={' '.join(mirrors)}\n"
        f"GRASSFIELD_REPO_BASE_PREVIOUS={' '.join(previous)}\nGRASSFIELD_SIGNING_FINGERPRINT={fpr}\n",
    }
    for channel in CHANNELS:
        files[f"grassfield-{channel}.conf"] = (
            f"# Grassfield's package repository, channel {channel} (ADR-0033). Written by grassfield-channel-set from\n"
            f"# /usr/share/grassfield/pacman/grassfield-{channel}.conf; Software Update's \"Repair...\" writes it again.\n"
            "SigLevel = Required\n" + "".join(f"Server = {b}/{channel}/$arch\n" for b in [base] + mirrors))
        files[f"grassfield-{channel}-cohort.conf"] = (
            f"# Grassfield's package repository, channel {channel}, staged rollout (ADR-0033, ADR-0050). Written by\n"
            f"# grassfield-channel-scriptlet from /usr/share/grassfield/pacman/grassfield-{channel}-cohort.conf: this computer's\n"
            "# cohort first, then the channel's own path when a cohort path does not answer.\n"
            "SigLevel = Required\n" + "".join(f"Server = {b}/{channel}/cohort/@COHORT@/$arch\n" for b in [base] + mirrors)
            + "".join(f"Server = {b}/{channel}/$arch\n" for b in [base] + mirrors))
    for name, text in files.items():
        with open(os.path.join(args.out, name), "w", encoding="utf-8") as f:
            f.write(text)
    shutil.copyfile(args.key, os.path.join(args.out, "grassfield-signing-key.asc"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
