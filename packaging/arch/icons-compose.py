#!/usr/bin/env python3
"""Compose the Grassfield icon theme `grassfield-icons` from two pinned third-party themes and our own glyphs.

Used by BOTH the package build (packaging/arch/PKGBUILD) and the dev provisioning (scripts/dev/icons.sh).

  icons-compose.py --mactahoe DIR --pebble DIR --branding DIR --list FILE --out DIR

  --mactahoe  checkout of the MacTahoe icon theme (vinceliuice/MacTahoe-icon-theme, pinned, GPL-3.0)
  --pebble    checkout of the Pebble icon theme (a-shewale/Pebble-Icon-Theme, pinned); only its Pebble/ variant is used
  --branding  branding/icons/theme (Grassfield's own icons: scalable/apps first, scalable/devices last; index.theme)
  --list      packaging/arch/icons-apple-logos.txt
  --out       the theme directory to create (replaced when it exists)

Layers (first layer that provides an icon NAME wins; a name is a file name without extension):
  0. ours:      branding scalable/apps
  1. MacTahoe:  base variant, default colour (see below), with three overrides
       a. every name of a listed file is dropped from the layer (all sizes, all directories) together with every
          link that resolves to one of them (to a fixpoint). A dropped name falls through to the next layers.
       b. folders: every non-symbolic name in Pebble's places directories is served by Pebble at all its sizes and
          removed from MacTahoe at every size; MacTahoe links to a removed folder drawing are redirected to Pebble's.
       c. store: every name whose link chain resolves to Pebble's scalable/apps/softwarecenter.svg, and every name
          whose chain resolves to MacTahoe's App Store drawing (src/apps/scalable/softwarecenter.svg, or a file the
          list marks with kind `appstore`) is served by Pebble's bag; MacTahoe's entries for them are removed.
     Aliases: an alias (link) whose chain target NAME was removed from its own layer because another layer provides
       that name is re-pointed to the providing layer's drawing of that name (same context and size directory when the
       provider has one, else its scalable drawing, else its largest size), by a relative link inside the theme. Only
       an alias whose target was dropped as a listed logo (kind other than appstore) is dropped with it.
  2. Pebble:    the Pebble/ variant, minus listed files, for names not provided above
  3. ours:      branding scalable/devices (the six device glyphs), for names not provided above
The theme keeps `Inherits=breeze,Adwaita,hicolor` (from the branding index.theme).

MacTahoe base variant: its install.sh (read in full, pin 839848b) copies src/{actions,animations,apps,categories,
devices,emotes,emblems,mimes,places,preferences} and src/status/{16,22,24,32,symbolic}, deletes
places/scalable/user-trash{,-full}-dark.svg, merges links/ over the same tree, adds @2x symlinks and runs
gtk-update-icon-cache; the default colour and the base variant apply no transformation. That is reproduced here
(no upstream code runs); the @2x symlinks and the cache are not reproduced (the package hook builds the cache).

List format (one entry per line, `#` comments): `<layer>:<path in the upstream checkout> [kind]`
  mactahoe:src/<category>/<size>/<file>      pebble:Pebble/<dir>/<dir>/<file>
  kind: apple-logo (default) | finder-face | doubt | appstore. apple-logo, finder-face and doubt drop the file's name
  from that layer (a doubtful drawing is dropped so that the next layer serves the name); appstore marks a MacTahoe file whose names are served by Pebble's bag instead. A listed file that does not
  exist in its checkout fails the composer (pin drift), and so does any listed name left in its layer's output.

Output layout (no ambiguity: Pebble's directories would collide with ours, and the two upstream layouts differ):
  scalable/apps, scalable/devices   ours (the layout the package always had)
  base/<context>/<size>             MacTahoe, directories and sections as upstream
  extra/<size>/<context>            Pebble, directories and sections as upstream
Each directory gets the upstream section (Size, Scale, Context, Type, MinSize, MaxSize, Threshold) under its
prefixed name. Links are relative and stay inside the theme; no icon-theme.cache is written.
"""
import os
import posixpath
import re
import shutil
import sys

EXTS = (".svg", ".png")
FORBIDDEN = re.compile(r"mac|osx|apple|tahoe", re.I)
MT_DIRS = ["actions", "animations", "apps", "categories", "devices", "emotes", "emblems", "mimes", "places",
           "preferences", "status/16", "status/22", "status/24", "status/32", "status/symbolic"]
MT_LINK_DIRS = ["actions", "apps", "categories", "devices", "emotes", "emblems", "mimes", "places", "status",
                "preferences"]
MT_REMOVED = ["places/scalable/user-trash-dark.svg", "places/scalable/user-trash-full-dark.svg"]
MT_STORE_ANCHOR = "apps/scalable/softwarecenter.svg"
PB_STORE_ANCHOR = "scalable/apps/softwarecenter.svg"
PB_PLACES = ("16x16/places", "scalable/places")
KINDS = ("apple-logo", "finder-face", "doubt", "appstore")


def die(msg):
    sys.exit("icons-compose: " + msg)


def name_of(rel):
    base = posixpath.basename(rel)
    for e in EXTS:
        if base.endswith(e):
            return base[: -len(e)]
    return None


def accepted(rel):
    base = posixpath.basename(rel)
    return not base.startswith(".") and name_of(rel) not in (None, "")


class Layer:
    """rel path -> ('f', abs file) or ('l', link target text)."""

    def __init__(self, label):
        self.label = label
        self.e = {}

    def add_tree(self, base, sub, strip_prefix=""):
        top = os.path.join(base, sub)
        if not os.path.isdir(top):
            die("%s: missing directory %s" % (self.label, top))
        for d, ds, fs in os.walk(top):
            ds.sort()
            for f in sorted(fs):
                p = os.path.join(d, f)
                rel = os.path.relpath(p, base)
                if not accepted(rel):
                    continue
                if os.path.islink(p):
                    self.e[rel] = ("l", os.readlink(p))
                elif os.path.isfile(p):
                    self.e[rel] = ("f", p)

    def resolve(self, rel):
        for _ in range(40):
            ent = self.e.get(rel)
            if ent is None:
                return None
            if ent[0] == "f":
                return rel
            t = ent[1]
            if t.startswith("/"):
                return None
            rel = posixpath.normpath(posixpath.join(posixpath.dirname(rel), t))
            if rel.startswith(".."):
                return None
        return None

    def names(self):
        return {name_of(r) for r in self.e}

    def drop_names(self, names):
        for r in [r for r in self.e if name_of(r) in names]:
            del self.e[r]

    def snapshot(self):
        c = Layer(self.label)
        c.e = dict(self.e)
        return c

    def prune_dangling(self, orig):
        """Remove the links that no longer resolve. Returns [(rel, name of the target in `orig` or None)]: the target
        name tells the caller which drawing the alias was meant for."""
        pruned = []
        while True:
            bad = [r for r, ent in self.e.items() if ent[0] == "l" and self.resolve(r) is None]
            if not bad:
                return pruned
            for r in bad:
                del self.e[r]
                t = orig.resolve(r)
                pruned.append((r, name_of(t) if t else None))


def parse_list(path):
    entries = []
    with open(path, encoding="utf-8") as fh:
        for ln, line in enumerate(fh, 1):
            line = line.split("#", 1)[0].strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) > 2 or ":" not in parts[0]:
                die("%s:%d: bad entry %r" % (path, ln, line))
            layer, rel = parts[0].split(":", 1)
            kind = parts[1] if len(parts) == 2 else "apple-logo"
            if layer not in ("mactahoe", "pebble") or kind not in KINDS:
                die("%s:%d: bad layer or kind in %r" % (path, ln, line))
            if kind == "appstore" and layer != "mactahoe":
                die("%s:%d: kind appstore is for mactahoe files" % (path, ln))
            entries.append((layer, rel, kind))
    return entries


def parse_index(path):
    """-> (header keys dict, ordered Directories list, {section: [(key, value)]})."""
    header, dirs, secs, cur = {}, [], {}, None
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            line = line.rstrip("\n")
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            m = re.match(r"\[(.+)\]$", line)
            if m:
                cur = m.group(1)
                if cur != "Icon Theme":
                    secs[cur] = []
                continue
            if "=" not in line:
                continue
            k, v = line.split("=", 1)
            if cur == "Icon Theme":
                header[k] = v
                if k == "Directories":
                    dirs = [d for d in v.split(",") if d]
            elif cur is not None:
                secs[cur].append((k, v))
    return header, dirs, secs


def fixpoint_drop(layer, names):
    """Drop `names` from the layer and, to a fixpoint, every name with an entry resolving to a dropped one."""
    names = set(names)
    while True:
        more = set()
        for r in layer.e:
            t = layer.resolve(r)
            if t is not None and name_of(t) in names and name_of(r) not in names:
                more.add(name_of(r))
        if not more:
            break
        names |= more
    layer.drop_names(names)
    return names


def compose(a):
    entries = parse_list(a.list)
    mt_root, pb_root = a.mactahoe, os.path.join(a.pebble, "Pebble")
    for layer, rel, kind in entries:
        base = mt_root if layer == "mactahoe" else a.pebble
        if not os.path.lexists(os.path.join(base, rel)):
            die("listed file does not exist in the %s checkout (pin drift?): %s" % (layer, rel))

    # ---- load the layers
    mt = Layer("mactahoe")
    for d in MT_DIRS:
        mt.add_tree(os.path.join(mt_root, "src"), d)
    # entries are keyed relative to src/ ; the links/ tree merges over the same keys (cp -r)
    for d in MT_LINK_DIRS:
        lb = os.path.join(mt_root, "links")
        if os.path.isdir(os.path.join(lb, d)):
            tmp = Layer("links")
            tmp.add_tree(lb, d)
            mt.e.update(tmp.e)
    for r in MT_REMOVED:
        mt.e.pop(r, None)
    pb = Layer("pebble")
    for d in sorted(os.listdir(pb_root)):
        if os.path.isdir(os.path.join(pb_root, d)):
            pb.add_tree(pb_root, d)
    own_apps, own_dev = Layer("ours-apps"), Layer("ours-devices")
    for d in sorted(os.listdir(a.branding)):
        p = os.path.join(a.branding, d)
        if d == "index.theme":
            continue
        if d != "scalable" or not os.path.isdir(p):
            die("unexpected entry in the branding theme: %s" % p)
        for s in sorted(os.listdir(p)):
            if s == "apps":
                own_apps.add_tree(a.branding, "scalable/apps")
            elif s == "devices":
                own_dev.add_tree(a.branding, "scalable/devices")
            else:
                die("unexpected branding directory scalable/%s" % s)
    counts = {"mactahoe upstream": len(mt.e), "pebble upstream": len(pb.e)}
    # Directories that the upstream index.theme does not list are invisible to GTK and Qt in the upstream theme too:
    # their files do not take part (they must not claim a name either).
    _, mt_dirs0, mt_secs0 = parse_index(os.path.join(mt_root, "src/index.theme"))
    _, pb_dirs0, pb_secs0 = parse_index(os.path.join(pb_root, "index.theme"))
    for ly, listed, secs in ((mt, mt_dirs0, mt_secs0), (pb, pb_dirs0, pb_secs0)):
        unlisted = [r for r in ly.e if posixpath.dirname(r) not in listed or posixpath.dirname(r) not in secs]
        for r in unlisted:
            del ly.e[r]
        counts[ly.label + " files in unlisted directories (ignored)"] = len(unlisted)

    # ---- a. listed files: drop their names from their layer
    anchors_mt = {MT_STORE_ANCHOR}
    drop = {"mactahoe": set(), "pebble": set()}
    for layer, rel, kind in entries:
        if kind == "appstore":
            anchors_mt.add(re.sub(r"^(src|links)/", "", rel))
            continue
        drop[layer].add(name_of(rel) or die("listed file is not an icon file: " + rel))
    dropped_mt = fixpoint_drop(mt, drop["mactahoe"])
    dropped_pb = fixpoint_drop(pb, drop["pebble"])

    # ---- b/c. folders and store
    if pb.resolve(PB_STORE_ANCHOR) is None:
        die("Pebble store anchor missing: Pebble/" + PB_STORE_ANCHOR)
    pb_bag = {name_of(r) for r in pb.e if pb.resolve(r) == PB_STORE_ANCHOR}
    own_names = own_apps.names()
    mt_anchor_present = [x for x in anchors_mt if x in mt.e]
    if MT_STORE_ANCHOR not in mt.e and name_of(MT_STORE_ANCHOR) not in dropped_mt:
        die("MacTahoe store anchor missing: src/" + MT_STORE_ANCHOR)
    mt_store = {name_of(r) for r in mt.e if mt.resolve(r) in mt_anchor_present}
    folders = {name_of(r) for r in pb.e if r.startswith(PB_PLACES) and not name_of(r).endswith("-symbolic")}
    mt_snap, pb_snap = mt.snapshot(), pb.snapshot()
    mt.drop_names(own_names | folders | pb_bag | mt_store)
    mt_pruned = mt.prune_dangling(mt_snap)
    counts["mactahoe dangling links pruned (re-pointed or dropped)"] = len(mt_pruned)

    # Pebble: names provided by layers 0 and 1 are dropped from it, the store names are (re)built. The pruned
    # MacTahoe aliases are re-pointed later but keep their names (they are MacTahoe's).
    mt_names = mt.names() | {name_of(r) for r, t in mt_pruned if t}
    pb.drop_names(own_names | mt_names)
    bag_dir = posixpath.dirname(PB_STORE_ANCHOR)
    for n in sorted((mt_store - pb_bag) - own_names - dropped_pb):
        pb.drop_names({n})
        pb.e["%s/%s.svg" % (bag_dir, n)] = ("l", posixpath.basename(PB_STORE_ANCHOR))
    pb_pruned = pb.prune_dangling(pb_snap)
    counts["pebble dangling links pruned (re-pointed or dropped)"] = len(pb_pruned)
    pb_names = pb.names() | {name_of(r) for r, t in pb_pruned if t}
    # layer 3: the device glyphs
    own_dev.drop_names(own_names | mt_names | pb_names)

    # ---- the final layers, under their directory prefixes
    out_entries = {}  # output rel -> entry
    layers = [("ours (apps)", own_apps, "", None), ("mactahoe", mt, "base/", None), ("pebble", pb, "extra/", None),
              ("ours (devices)", own_dev, "", None)]
    for label, ly, prefix, _ in layers:
        for r, ent in ly.e.items():
            out_entries[prefix + r] = ent

    # ---- aliases whose target name another layer provides: re-pointed to that layer's drawing
    own_h, _, own_secs = parse_index(os.path.join(a.branding, "index.theme"))
    secs_of = {"": own_secs, "base/": mt_secs0, "extra/": pb_secs0}
    provide = [("", own_apps), ("base/", mt), ("extra/", pb), ("", own_dev)]
    by_name = []
    for prefix, ly in provide:
        idx = {}
        for r in ly.e:
            t = ly.resolve(r)
            if t is not None and t not in idx.setdefault(name_of(r), []):
                idx[name_of(r)].append(t)
        by_name.append(idx)

    def info(prefix, rel):
        d = posixpath.dirname(rel)
        sec = dict(secs_of[prefix].get(d, []))
        return (sec.get("Context", "").lower(), int(sec.get("Size", "0") or 0), sec.get("Type") == "Scalable",
                "symbolic" in d)

    def best(target_name, ctx, size, symb, dest_dir):
        found = None
        for (prefix, ly), idx in zip(provide, by_name):
            if target_name in idx:
                found = (prefix, idx[target_name])
                break
        if found is None:
            return None
        prefix, cands = found
        scored = []
        for f in cands:
            fc, fs, fscal, fsym = info(prefix, f)
            if fsym == symb and fc == ctx and fs == size:
                k = (0, 0)
            elif fsym == symb and fscal and fc == ctx:
                k = (1, 0)
            elif fsym == symb and fscal:
                k = (2, 0)
            elif fsym == symb:
                k = (3, -fs)
            else:
                k = (4, -fs)
            scored.append((k, f))
        scored.sort()
        f = scored[0][1]
        return posixpath.splitext(f)[1], posixpath.relpath(prefix + f, dest_dir)

    repointed = {"mactahoe": 0, "pebble": 0}
    unresolved = {"mactahoe": [], "pebble": []}
    for label, prefix, pruned in (("mactahoe", "base/", mt_pruned), ("pebble", "extra/", pb_pruned)):
        for r, t in sorted(pruned):
            if t is None:
                continue
            ctx, size, _, symb = info(prefix, r)
            dest_dir = prefix + posixpath.dirname(r)
            got = best(t, ctx, size, symb, dest_dir)
            if got is None:
                unresolved[label].append(name_of(r))
                continue
            ext, rel = got
            dest = "%s/%s%s" % (dest_dir, name_of(r), ext)
            if dest not in out_entries:
                out_entries[dest] = ("l", rel)
                repointed[label] += 1

    # ---- listed names must be gone from their layer's output
    for layer, rel, kind in entries:
        if kind == "appstore":
            continue
        ly, prefix = (mt, "base/") if layer == "mactahoe" else (pb, "extra/")
        n = name_of(rel)
        left = [r for r in ly.e if name_of(r) == n]
        if left:
            die("listed name %s remains in the %s layer: %s" % (n, layer, left[:3]))
    for layer, ly in (("mactahoe", mt), ("pebble", pb)):
        for r in ly.e:
            if name_of(r) in (dropped_mt if layer == "mactahoe" else dropped_pb):
                die("dropped name %s remains in the %s layer" % (name_of(r), layer))

    # ---- write
    out = a.out
    if os.path.lexists(out):
        shutil.rmtree(out)
    os.makedirs(out)
    present_dirs = {"scalable/apps"}
    for r in sorted(out_entries):
        kind, val = out_entries[r]
        dst = os.path.join(out, r)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        present_dirs.add(posixpath.dirname(r))
        if kind == "f":
            shutil.copyfile(val, dst)
            os.chmod(dst, 0o644)
        else:
            os.symlink(posixpath.normpath(val), dst)
    os.makedirs(os.path.join(out, "scalable/apps"), exist_ok=True)

    # ---- index.theme
    own_h, _, own_secs = parse_index(os.path.join(a.branding, "index.theme"))
    _, mt_dirs, mt_secs = parse_index(os.path.join(mt_root, "src/index.theme"))
    _, pb_dirs, pb_secs = parse_index(os.path.join(pb_root, "index.theme"))
    dirs, body = [], []
    spec = [("", ["scalable/apps"], own_secs), ("base/", mt_dirs, mt_secs), ("extra/", pb_dirs, pb_secs),
            ("", ["scalable/devices"], own_secs)]
    for prefix, order, secs in spec:
        if prefix:
            ordered = [prefix + d for d in order if prefix + d in present_dirs]
        else:
            ordered = [d for d in order if d in present_dirs]
        for d in ordered:
            if d in dirs:
                continue
            key = d[len(prefix):] if prefix else d
            if key not in secs:
                die("no index.theme section for %s" % d)
            dirs.append(d)
            body.append("[%s]\n%s\n" % (d, "\n".join("%s=%s" % kv for kv in secs[key])))
    for d in sorted(present_dirs):
        if d not in dirs:
            die("directory %s has icons but its layer's index.theme has no section for it" % d)
    for k in ("Name", "Inherits", "Hidden"):
        if k not in own_h:
            die("branding index.theme has no %s" % k)
    text = ("[Icon Theme]\nName=%s\nComment=Grassfield icon theme: Grassfield's own icons, then two composed third-party "
            "layers, then Breeze, Adwaita and hicolor\nInherits=%s\nHidden=%s\nDirectories=%s\n\n"
            % (own_h["Name"], own_h["Inherits"], own_h["Hidden"], ",".join(dirs))) + "\n".join(body)
    if FORBIDDEN.search(text):
        die("forbidden word in index.theme: %s" % FORBIDDEN.search(text).group(0))
    with open(os.path.join(out, "index.theme"), "w", encoding="utf-8") as fh:
        fh.write(text)

    verify(out)

    # ---- report
    print("icons-compose: layer counts (files + links, names)")
    for label, ly, _, _ in layers:
        nf = sum(1 for e in ly.e.values() if e[0] == "f")
        print("  %-16s %6d files %6d links %6d names" % (label, nf, len(ly.e) - nf, len(ly.names())))
    print("  mactahoe: %d names dropped by the list (with their links), %d store names"
          % (len(dropped_mt), len(mt_store)))
    print("  pebble: %d folder names, %d store names (incl. %d added aliases), %d names dropped by the list"
          % (len(folders), len(pb_bag | mt_store), len(mt_store - pb_bag), len(dropped_pb)))
    print("  aliases re-pointed to another layer's drawing: %d mactahoe, %d pebble; unresolved: %d"
          % (repointed["mactahoe"], repointed["pebble"], len(unresolved["mactahoe"]) + len(unresolved["pebble"])))
    for k in ("mactahoe", "pebble"):
        if unresolved[k]:
            print("  unresolved %s aliases: %s" % (k, " ".join(sorted(set(unresolved[k]))[:20])))
    for k, v in sorted(counts.items()):
        print("  %s: %d" % (k, v))
    total = 0
    for d, _, fs in os.walk(out):
        for f in fs:
            p = os.path.join(d, f)
            if not os.path.islink(p):
                total += os.path.getsize(p)
    print("  directories: %d, entries: %d, total size: %.1f MiB" % (len(dirs), len(out_entries), total / 1048576))


def verify(out):
    """Independent walk of the written tree: relative links inside the theme, none dangling, no cache."""
    root = os.path.realpath(out)
    for d, ds, fs in os.walk(out):
        for f in fs + [x for x in ds if os.path.islink(os.path.join(d, x))]:
            p = os.path.join(d, f)
            if f in ("icon-theme.cache",):
                die("cache file in the output: " + p)
            if os.path.islink(p):
                t = os.readlink(p)
                if t.startswith("/"):
                    die("absolute link " + p)
                real = os.path.realpath(p)
                if not (real == root or real.startswith(root + os.sep)):
                    die("link escapes the theme: " + p)
                if not os.path.isfile(real):
                    die("dangling link: %s -> %s" % (p, t))


def main(argv):
    opts = {}
    it = iter(argv)
    for k in it:
        if k in ("--mactahoe", "--pebble", "--branding", "--list", "--out"):
            opts[k[2:]] = os.path.abspath(next(it, None) or die("missing value for " + k))
        else:
            die("usage: icons-compose.py --mactahoe DIR --pebble DIR --branding DIR --list FILE --out DIR")
    for k in ("mactahoe", "pebble", "branding", "list", "out"):
        if k not in opts:
            die("missing --" + k)

    class A:
        pass

    a = A()
    a.__dict__.update(opts)
    compose(a)


if __name__ == "__main__":
    main(sys.argv[1:])
