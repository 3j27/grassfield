#!/usr/bin/env python3
"""Line-coverage summary from gcc's gcov (gate Q3). gcovr and lcov are not installed: this reads `gcov --json-format`.

  coverage_report.py --label NAME --obj-dir DIR --source-dir DIR [--exclude REGEX]... [--min PCT] [--per-file]

DIR (--obj-dir) holds the .gcno/.gcda pairs written by an instrumented build run (g++ --coverage); every .gcda found below
it is read. Only source files below --source-dir are counted (tests, system headers, Qt, gtest are not), reported relative
to it. A source compiled into several objects counts each line once, with the highest execution count. A line is
"covered" when some object executed it. Prints one line:

  coverage NAME: 83.4 % of 1234 lines (1029 covered) in 16 files

Exit: 0 report printed (and, with --min, reached); 1 below --min; 2 no coverage data or usage error.
Standard library only; run isolated (python3 -I).
"""
import argparse
import json
import os
import re
import subprocess
import sys


def gcov_documents(obj_dir):
    """Yield the JSON documents of `gcov --json-format --stdout` for every .gcda below obj_dir."""
    for dirpath, _dirs, files in os.walk(obj_dir):
        for name in sorted(files):
            if not name.endswith(".gcda"):
                continue
            proc = subprocess.run(["gcov", "--json-format", "--stdout", name], cwd=dirpath,
                                  capture_output=True, text=True, check=False)
            for line in proc.stdout.splitlines():
                line = line.strip()
                if line.startswith("{"):
                    try:
                        yield json.loads(line)
                    except ValueError:
                        continue


def collect(obj_dir, source_dir, excludes):
    """Return {relative file: {line number: max execution count}} for the files below source_dir."""
    source_dir = os.path.realpath(source_dir)
    skip = [re.compile(x) for x in excludes]
    result = {}
    for doc in gcov_documents(obj_dir):
        cwd = doc.get("current_working_directory", obj_dir)
        for f in doc.get("files", []):
            path = f.get("file", "")
            if not os.path.isabs(path):
                path = os.path.join(cwd, path)
            path = os.path.realpath(path)
            if not path.startswith(source_dir + os.sep):
                continue
            rel = os.path.relpath(path, source_dir)
            if any(r.search(rel) for r in skip):
                continue
            lines = result.setdefault(rel, {})
            for ln in f.get("lines", []):
                n = ln["line_number"]
                lines[n] = max(lines.get(n, 0), ln.get("count", 0))
    return result


def summarise(data):
    """-> (covered, total, {file: (covered, total)})"""
    per = {}
    for rel, lines in data.items():
        if not lines:
            continue  # a header without executable lines
        per[rel] = (sum(1 for c in lines.values() if c > 0), len(lines))
    covered = sum(c for c, _ in per.values())
    total = sum(t for _, t in per.values())
    return covered, total, per


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--label", required=True)
    ap.add_argument("--obj-dir", required=True)
    ap.add_argument("--source-dir", required=True)
    ap.add_argument("--exclude", action="append", default=[])
    ap.add_argument("--min", type=float)
    ap.add_argument("--per-file", action="store_true")
    args = ap.parse_args(argv)
    data = collect(args.obj_dir, args.source_dir, args.exclude)
    covered, total, per = summarise(data)
    if total == 0:
        print(f"coverage {args.label}: no coverage data below {args.obj_dir} for {args.source_dir}", file=sys.stderr)
        return 2
    if args.per_file:
        for rel in sorted(per):
            c, t = per[rel]
            print(f"  {rel}: {100.0 * c / t:5.1f} % ({c}/{t})")
    pct = 100.0 * covered / total
    print(f"coverage {args.label}: {pct:.1f} % of {total} lines ({covered} covered) in {len(per)} files")
    if args.min is not None and pct < args.min:
        print(f"coverage {args.label}: below the minimum of {args.min:.1f} %", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
