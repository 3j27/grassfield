#!/usr/bin/env python3
"""Render Grassfield's public installation script from its template (ADR-0043 b).

  render.py --conf packaging/pacman/repository.conf --template grassfield-install.sh.in --out DIR

Reads repository.conf with the parser generate.py uses at build (one source of truth for the host and the fingerprint),
substitutes the two values into the template and writes DIR/grassfield-install.sh (mode 0755) and
DIR/grassfield-install.sh.sha256 (sha256sum format, the checksum the install page publishes).

Refuses (exit 1, nothing written) while the build is not publishable: a host ending in .invalid or an empty fingerprint
(the owner's O8 and O11), a non-https base, or a template that keeps an unreplaced @...@ marker. Python standard library.
"""
import argparse
import hashlib
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "pacman"))
import generate  # noqa: E402  (packaging/pacman/generate.py: the repository.conf parser)

NAME = "grassfield-install.sh"


def render(conf_text, template):
    base, _mirrors, _previous, fpr = generate.parse(conf_text)
    host = re.sub(r"^https://", "", base).split("/")[0].split(":")[0]
    if not base.startswith("https://"):
        raise generate.Invalid("the public script needs an https:// base")
    if host.endswith(".invalid") or host == "invalid":
        raise generate.Invalid(f"GRASSFIELD_REPO_BASE is the placeholder {base} (owner decision O8): not publishable")
    if not fpr:
        raise generate.Invalid("GRASSFIELD_SIGNING_FINGERPRINT is empty (owner decision O11): not publishable")
    text = template.replace("@GRASSFIELD_REPO_BASE@", base).replace("@GRASSFIELD_SIGNING_FINGERPRINT@", fpr)
    if re.search(r"@GRASSFIELD_[A-Z_]+@", text):
        raise generate.Invalid("the template keeps an unreplaced marker")
    return text


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--conf", required=True)
    ap.add_argument("--template", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    try:
        with open(args.conf, encoding="utf-8") as f:
            conf = f.read()
        with open(args.template, encoding="utf-8") as f:
            template = f.read()
        text = render(conf, template)
    except (OSError, UnicodeDecodeError, generate.Invalid) as e:
        print(f"render.py: {e}", file=sys.stderr)
        return 1
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, NAME)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(path, 0o755)
    digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
    with open(path + ".sha256", "w", encoding="utf-8") as f:
        f.write(f"{digest}  {NAME}\n")
    print(f"{path} sha256 {digest}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
