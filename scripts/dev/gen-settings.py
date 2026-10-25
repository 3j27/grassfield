#!/usr/bin/env python3
"""Generate config/defaults/grassfield.json from the `default` keywords of the schema (stdlib only).

The schema config/schema/grassfield.schema.json is the one source of the settings contract (ADR-0020). Every leaf
(a property that is not an object with `properties`) must carry a `default`; the generated file nests those
defaults in schema order. Keys of array items and of additionalProperties objects are not leaves.

Usage: gen-settings.py            write the generated files
       gen-settings.py --check    exit 1 when a generated file is stale (no write)
       gen-settings.py --selftest a leaf without a default fails, stale output fails
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "config/schema/grassfield.schema.json"
DEFAULTS = ROOT / "config/defaults/grassfield.json"


def is_group(node):
    return node.get("type") == "object" and "properties" in node


def defaults_of(node, path, errors):
    """Nested defaults of an object schema; a leaf without `default` is an error."""
    out = {}
    for key, child in node["properties"].items():
        where = f"{path}.{key}" if path else key
        if is_group(child):
            out[key] = defaults_of(child, where, errors)
        elif "default" in child:
            out[key] = child["default"]
        else:
            errors.append(f"{where}: leaf without a default")
    return out


def render(schema, errors):
    return json.dumps(defaults_of(schema, "", errors), indent=2, ensure_ascii=False) + "\n"


def stale(schema, target):
    errors = []
    text = render(schema, errors)
    if not errors and (not target.exists() or target.read_text() != text):
        errors.append(f"{target.relative_to(ROOT) if target.is_relative_to(ROOT) else target}: stale, run scripts/dev/gen-settings.py")
    return errors


def selftest():
    import copy
    import tempfile
    schema = json.loads(SCHEMA.read_text())
    failures = []
    if stale(schema, DEFAULTS):
        failures.append("the repository's generated file is not current")
    broken = copy.deepcopy(schema)
    del broken["properties"]["material"]["properties"]["transparency"]["default"]
    if not stale(broken, DEFAULTS):
        failures.append("a leaf without a default was accepted")
    with tempfile.TemporaryDirectory() as tmp:
        target = pathlib.Path(tmp) / "grassfield.json"
        target.write_text(render(schema, []))
        if stale(schema, target):
            failures.append("fresh output reported stale")
        target.write_text(target.read_text().replace("0.25", "0.5"))
        if not stale(schema, target):
            failures.append("stale output was accepted")
    for f in failures:
        print(f"gen-settings selftest: {f}", file=sys.stderr)
    print("gen-settings selftest: " + ("FAILED" if failures else "ok"))
    return 1 if failures else 0


def main(argv):
    if argv == ["--selftest"]:
        return selftest()
    if argv not in ([], ["--check"]):
        print(__doc__, file=sys.stderr)
        return 2
    schema = json.loads(SCHEMA.read_text())
    errors = []
    text = render(schema, errors)
    if not errors and argv == ["--check"]:
        errors = stale(schema, DEFAULTS)
    for e in errors:
        print(f"gen-settings: {e}", file=sys.stderr)
    if errors:
        return 1
    if not argv:
        DEFAULTS.write_text(text)
    print(f"gen-settings: {DEFAULTS.relative_to(ROOT)} {'current' if argv else 'written'}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
