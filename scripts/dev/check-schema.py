#!/usr/bin/env python3
"""Validate JSON documents against config/schema/grassfield.schema.json (stdlib only).

Supports the JSON Schema subset used by Grassfield: type, enum, required, properties,
additionalProperties (bool), items, minimum, maximum, minLength, pattern (re.search, ECMA-262 patterns written
without lookbehind or unicode classes behave the same in Python).
Usage: check-schema.py [FILE...]   (default: config/defaults/grassfield.json)
Without arguments it also checks that config/defaults/grassfield.json is the current output of
scripts/dev/gen-settings.py (every leaf has a default; ADR-0020) and runs that generator's --selftest.
"""
import importlib.util
import json
import pathlib
import re
import sys

sys.dont_write_bytecode = True
ROOT = pathlib.Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "config/schema/grassfield.schema.json"

TYPES = {
    "object": dict, "array": list, "string": str, "boolean": bool,
    "integer": int, "number": (int, float),
}


def check(value, schema, path, errors):
    expected = schema.get("type")
    if expected:
        ok = isinstance(value, TYPES[expected])
        if expected in ("integer", "number") and isinstance(value, bool):
            ok = False
        if not ok:
            errors.append(f"{path}: expected {expected}, got {type(value).__name__}")
            return
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} not in {schema['enum']}")
    if "minimum" in schema and value < schema["minimum"]:
        errors.append(f"{path}: {value} < minimum {schema['minimum']}")
    if "maximum" in schema and value > schema["maximum"]:
        errors.append(f"{path}: {value} > maximum {schema['maximum']}")
    if "minLength" in schema and len(value) < schema["minLength"]:
        errors.append(f"{path}: shorter than {schema['minLength']}")
    # JSON Schema patterns are ECMA-262 and unanchored: `$` matches only at the very end (Python's also before a
    # trailing newline, which would accept "accent\\n"), so `$` is translated to `\\Z`.
    if "pattern" in schema and isinstance(value, str) and not re.search(re.sub(r"(?<!\\)\$", r"\\Z", schema["pattern"]), value):
        errors.append(f"{path}: {value!r} does not match {schema['pattern']}")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required key {key!r}")
        for key, sub in value.items():
            if key in props:
                check(sub, props[key], f"{path}.{key}", errors)
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}: unknown key {key!r}")
    if isinstance(value, list) and "items" in schema:
        for i, item in enumerate(value):
            check(item, schema["items"], f"{path}[{i}]", errors)


def main(argv):
    schema = json.loads(SCHEMA.read_text())
    files = argv or [str(ROOT / "config/defaults/grassfield.json")]
    failed = False
    if not argv:
        spec = importlib.util.spec_from_file_location("gen_settings", ROOT / "scripts/dev/gen-settings.py")
        gen = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(gen)
        errors = gen.stale(schema, gen.DEFAULTS)
        for e in errors:
            print(f"gen-settings: {e}", file=sys.stderr)
        failed |= bool(errors) or bool(gen.selftest())
    for name in files:
        errors = []
        check(json.loads(pathlib.Path(name).read_text()), schema, "$", errors)
        for e in errors:
            print(f"{name}: {e}", file=sys.stderr)
        failed |= bool(errors)
        print(f"{name}: {'INVALID' if errors else 'ok'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
