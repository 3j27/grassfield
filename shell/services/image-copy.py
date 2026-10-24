#!/usr/bin/env python3
# image-copy.py: the only producer of the images the shell shows from files it does not own (integrator decision after
# the review of 423766f: the shell only ever decodes images it produced itself). Used by ThemeIcons (theme names found
# only in the user's icon folders, Icon= paths, tray icons, desktop thumbnails, stack previews, media art, the lock
# screen's account picture) and by Notifications (image and app icon files). Run as `python3 -I`, never by the GUI thread.
#
# A source file is read once, into memory: its real path (a flatpak user export is a symlink) must lie under one of the
# allowed roots below, lstat must say a regular file, then it is opened with O_NOFOLLOW|O_NONBLOCK, fstat must say a
# regular, non-empty file within the size cap and /proc/self/fd must still name a path under an allowed root. The bytes
# are then re-encoded to a PNG of at most BOX x BOX pixels by rsvg-convert (librsvg), fed on STDIN so the document has no
# base URL: librsvg then resolves no reference to another file at all (absolute, file:, relative, XInclude, CSS @import,
# external entities and DTDs; tests/security/theme_icon_files.sh checks each against a FIFO):
#   - PNG, JPEG, GIF and WebP (by their magic bytes; the header must give a size within MAX_SIDE and MAX_PIXELS) are
#     wrapped in an SVG of our own as a data: URI and rendered (librsvg decodes them in memory, out of the shell);
#   - anything else is handed to rsvg-convert as an SVG document (plain, gzip-compressed, any XML encoding); what it
#     cannot parse is refused.
# rsvg-convert runs with an address-space limit, a CPU-time limit and a wall-clock timeout; its output must be a PNG
# within OUT_CAP. The shell then loads only that PNG, which it made, by its .png name.
#
# Media art an app names by an https URL (Spotify, browsers) is fetched by curl into memory, then re-encoded the same
# way (macOS itself fetches nothing: apps hand over image bytes; review of dce68c2, minor 1, integrator decision):
#   - the URL: https only, a host name (never an IP literal in any notation, never localhost or *.localhost), no user,
#     password or whitespace;
#   - the name is resolved here first; every address must be public (no private, loopback, link-local, shared, reserved
#     or multicast range, also inside IPv4-mapped, 6to4 and Teredo addresses), and curl connects to exactly those
#     addresses (`--resolve`: no second lookup, so no DNS rebinding) and to no proxy;
#   - redirects are followed here, at most FETCH_REDIRECTS, each target checked like the first URL;
#   - at most FETCH_BYTES, FETCH_SECONDS in all, no cookies, no credentials (no HOME, no .curlrc or .netrc: `-q` first),
#     no URL globbing, a fixed user agent with nothing personal; only the CA variables of the session reach curl.
#
#   image-copy.py batch <out dir> <icon cap> <picture cap> <budget> [<kind> <n> <value>]...
#       ThemeIcons. Kinds: "name" (a plain theme name: looked up in the user-changeable icon folders), "icon" and
#       "picture" (an absolute path), "tray" ("<plain name>|<IconThemePath>": the app's folder, then like "name"),
#       "url" (an https URL: media art, fetched as above),
#       "drop" (delete copy <value> now), "lru" (copy <value> may be deleted to make room, least recently used first).
#       One line per item: "ok<TAB><kind>:<value><TAB><out dir>/<n>.png" or "no<TAB><kind>:<value>"; "gone<TAB><file>"
#       for each copy deleted to make room. The copies stay within <budget> bytes in all. Past SOFT_SECONDS the items not
#       started yet are answered "later<TAB><kind>:<value>" (asked again by the next run): a batch of big photos or slow
#       documents ends well within the caller's timeout instead of being killed with all its items refused. A theme name
#       re-encodes at most NAME_ATTEMPTS readable candidates.
#   image-copy.py file <source> <cap> <destination>
#       Notifications: one file, written to <destination> (created, 0600); exit status 0 when written.
import base64, ipaddress, os, re, resource, socket, stat, subprocess, sys, threading, time

BOX = 256
MAX_SIDE = 16384
MAX_PIXELS = 50_000_000
OUT_CAP = 4 * 1024 * 1024
RSVG_SECONDS = 8
RSVG_MEMORY = 1 << 30
SOFT_SECONDS = 20
NAME_ATTEMPTS = 3
FETCH_BYTES = 5 * 1024 * 1024
FETCH_SECONDS = 5
FETCH_REDIRECTS = 3
FETCH_AGENT = "Grassfield-NowPlaying/1.0"
# https://host[:port][/path]: host of letters, digits, "." and "-" (no user or password, no IP v6 literal), the path of
# printable ASCII without spaces or backslashes. ArtUrl.remoteUrl (shell/widgets/ArtUrl.js) applies the same rules.
FETCH_URL = re.compile(r"https://([A-Za-z0-9.-]{1,253})(?::([0-9]{1,5}))?(/[!-\[\]-~]*)?")
FETCH_ENV = ("CURL_CA_BUNDLE", "SSL_CERT_FILE", "SSL_CERT_DIR")
RESOLVE_SECONDS = 3
# The only directories Qt searches for icons (ui/i18n/iconsearchpaths.h): filled by system packages. Every other icon
# directory (the user's, /usr/local/share, flatpak and snap system exports written by app installs) is looked up here.
PACKAGED = ("/usr/share/icons", "/usr/share/pixmaps")
PLAIN_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}")
SIZES = ["scalable", "512x512", "256x256", "192x192", "128x128", "96x96", "72x72", "64x64", "48x48", "36x36", "32x32",
         "24x24", "22x22", "16x16"]
KINDS = ["apps", "status", "mimetypes", "places", "devices"]

home = os.environ.get("HOME", "")
data_home = os.environ.get("XDG_DATA_HOME") or os.path.join(home, ".local/share")
data_dirs = [d for d in (os.environ.get("XDG_DATA_DIRS") or "/usr/local/share:/usr/share").split(":") if d.startswith("/")]


def real_roots(paths):
    out = []
    for p in paths:
        if p and p.startswith("/"):
            r = os.path.realpath(p)
            if r != "/" and r not in out:
                out.append(r)
    return out


# Where a source file may really lie (after symlinks): the user's home and data folders, the system's, flatpak's, the
# account pictures, and the places applications put images for notifications and media art. Never /proc, /sys or /dev.
ROOTS = real_roots([home, data_home] + data_dirs + ["/usr", "/opt", "/var/lib/flatpak", "/var/lib/snapd/desktop", "/var/lib/AccountsService/icons",
                   "/tmp", "/var/tmp", os.environ.get("XDG_RUNTIME_DIR", ""), "/media", "/mnt", "/run/media", "/srv"])


def under_roots(path):
    return any(path == r or path.startswith(r + "/") for r in ROOTS)


def mapped_root():
    try:
        if open("/proc/self/uid_map").read().split()[:2] == ["0", "0"]:
            return -1
        return int(open("/proc/sys/kernel/overflowuid").read())
    except (OSError, ValueError):
        return -1


ROOT = mapped_root()


# The rule of ui/i18n/iconsearchpaths.h: Qt searches a directory only when it and every ancestor belong to root and the
# user can neither own nor write them; every other existing icon directory is the user's, looked up here.
def user_changeable(path):
    p = os.path.realpath(path)
    if not os.path.isdir(p):
        return False
    while True:
        try:
            st = os.stat(p)
        except OSError:
            return True
        if st.st_uid not in (0, ROOT) or st.st_uid == os.geteuid() or os.access(p, os.W_OK):
            return True
        if p == "/":
            return False
        p = os.path.dirname(p)


def read_source(src, cap):
    """The bytes of regular file `src` (at most `cap`), or None. Never blocks on a FIFO or a device."""
    if not src.startswith("/") or len(src) > 4096 or re.search(r"[\x00-\x1f\x7f]", src):
        return None
    real = os.path.realpath(src)
    if not under_roots(real):
        return None
    try:
        if not stat.S_ISREG(os.lstat(real).st_mode):
            return None
        fd = os.open(real, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_NOCTTY | os.O_CLOEXEC)
    except (OSError, ValueError):
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_size == 0 or st.st_size > cap:
            return None
        if not under_roots(os.readlink("/proc/self/fd/%d" % fd)):
            return None
        chunks, left = [], cap + 1
        while left > 0:
            b = os.read(fd, min(left, 1 << 20))
            if not b:
                break
            chunks.append(b)
            left -= len(b)
        data = b"".join(chunks)
        return data if 0 < len(data) <= cap else None
    except OSError:
        return None
    finally:
        os.close(fd)


def be16(b, i):
    return int.from_bytes(b[i:i + 2], "big")


def le16(b, i):
    return int.from_bytes(b[i:i + 2], "little")


def raster(data):
    """(mime type, width, height) of a PNG, JPEG, GIF or WebP image, else None."""
    if data.startswith(b"\x89PNG\r\n\x1a\n") and data[12:16] == b"IHDR" and len(data) >= 24:
        return "image/png", int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")
    if data[:6] in (b"GIF87a", b"GIF89a") and len(data) >= 10:
        return "image/gif", le16(data, 6), le16(data, 8)
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP" and len(data) >= 30:
        chunk = data[12:16]
        if chunk == b"VP8 " and data[23:26] == b"\x9d\x01\x2a":
            return "image/webp", le16(data, 26) & 0x3FFF, le16(data, 28) & 0x3FFF
        if chunk == b"VP8L" and data[20] == 0x2F:
            bits = int.from_bytes(data[21:25], "little")
            return "image/webp", (bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1
        if chunk == b"VP8X":
            return "image/webp", int.from_bytes(data[24:27], "little") + 1, int.from_bytes(data[27:30], "little") + 1
        return None
    if data[:3] == b"\xff\xd8\xff":
        i = 2
        while i + 9 < len(data):
            if data[i] != 0xFF:
                return None
            marker = data[i + 1]
            if marker == 0xFF:
                i += 1
                continue
            if marker in (0x01, 0xD8) or 0xD0 <= marker <= 0xD7:
                i += 2
                continue
            if 0xC0 <= marker <= 0xCF and marker not in (0xC4, 0xC8, 0xCC):
                return "image/jpeg", be16(data, i + 7), be16(data, i + 5)
            i += 2 + be16(data, i + 2)
        return None
    return None


def limits():
    resource.setrlimit(resource.RLIMIT_AS, (RSVG_MEMORY, RSVG_MEMORY))
    resource.setrlimit(resource.RLIMIT_CPU, (RSVG_SECONDS, RSVG_SECONDS + 1))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def rsvg(document, args):
    try:
        p = subprocess.run(["rsvg-convert"] + args, input=document, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                           timeout=RSVG_SECONDS, preexec_fn=limits, close_fds=True)
    except (OSError, subprocess.SubprocessError):
        return None
    out = p.stdout
    if p.returncode != 0 or not out.startswith(b"\x89PNG\r\n\x1a\n") or len(out) > OUT_CAP:
        return None
    return out


def fetch_limits():
    resource.setrlimit(resource.RLIMIT_CPU, (FETCH_SECONDS + 2, FETCH_SECONDS + 3))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def url_target(url):
    """(host, port) of an https URL the helper may fetch, or None (ArtUrl.remoteUrl's rules)."""
    m = FETCH_URL.fullmatch(url) if len(url) <= 2048 else None
    if m is None:
        return None
    host = m.group(1).lower().rstrip(".")
    labels = host.split(".")
    # An IP literal in any notation (decimal, octal, hex, dotted or not: a host whose last label is a number is one),
    # localhost and *.localhost are refused outright.
    if not host or re.fullmatch(r"[0-9]+|0x[0-9a-f]*", labels[-1]) or host == "localhost" or host.endswith(".localhost"):
        return None
    port = int(m.group(2)) if m.group(2) else 443
    return (host, port) if 0 < port < 65536 else None


def public_address(ip):
    """True for an address that is public: not private, loopback, link-local, shared, reserved, unspecified or multicast,
    also once an IPv4 address embedded in an IPv4-mapped, 6to4 or Teredo address is taken out."""
    try:
        a = ipaddress.ip_address(ip.split("%")[0])
    except ValueError:
        return False
    if a.version == 6:
        inner = [x for x in (a.ipv4_mapped, a.sixtofour) if x is not None] + (list(a.teredo) if a.teredo else [])
        if any(not public_address(str(x)) for x in inner):
            return False
    return a.is_global and not a.is_multicast


def address_allowed(host, ip):
    return public_address(ip)


def resolve_host(host, port):
    """The addresses `host` resolves to (within RESOLVE_SECONDS), or []."""
    found = []

    def lookup():
        try:
            found.extend(sorted({i[4][0] for i in socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)}))
        except (OSError, UnicodeError):
            pass

    t = threading.Thread(target=lookup, daemon=True)
    t.start()
    t.join(RESOLVE_SECONDS)
    return [] if t.is_alive() else list(found)


def curl_once(url, host, port, addresses, seconds):
    """(status, body, redirect URL) of one request to `url` at exactly `addresses`, or None."""
    env = {"PATH": "/usr/bin:/bin"}
    env.update({k: os.environ[k] for k in FETCH_ENV if k in os.environ})
    pinned = ",".join("[%s]" % a if ":" in a else a for a in addresses)
    cmd = ["curl", "-q", "--silent", "--fail", "--globoff", "--noproxy", "*", "--proto", "=https", "--max-filesize", str(FETCH_BYTES),
           "--max-time", "%.1f" % seconds, "--connect-timeout", "%.1f" % seconds, "--resolve", "%s:%d:%s" % (host, port, pinned),
           "--user-agent", FETCH_AGENT, "--output", "-", "--write-out", "%{stderr}%{http_code} %{redirect_url}\n", "--", url]
    try:
        p = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
                             close_fds=True, preexec_fn=fetch_limits)
    except OSError:
        return None
    try:
        data = p.stdout.read(FETCH_BYTES + 1)
        if len(data) > FETCH_BYTES:
            p.kill()
            p.wait()
            return None
        info = p.stderr.read(8192).decode("ascii", "replace").strip().split("\n")[-1].split(" ", 1)
        rc = p.wait(timeout=seconds + 3)
    except (OSError, subprocess.SubprocessError):
        p.kill()
        p.wait()
        return None
    finally:
        p.stdout.close()
        p.stderr.close()
    if rc != 0 or not info[0].isdigit():
        return None
    return int(info[0]), data, (info[1] if len(info) > 1 else "")


def fetch(url):
    """The body of https `url` (at most FETCH_BYTES, FETCH_SECONDS in all), or None."""
    deadline = time.monotonic() + FETCH_SECONDS
    for _ in range(FETCH_REDIRECTS + 1):
        target = url_target(url)
        if target is None:
            return None
        host, port = target
        addresses = resolve_host(host, port)
        if not addresses or not all(address_allowed(host, a) for a in addresses):
            return None
        left = deadline - time.monotonic()
        if left < 0.5:
            return None
        answer = curl_once(url, host, port, addresses, left)
        if answer is None:
            return None
        status, data, location = answer
        if status in (301, 302, 303, 307, 308):
            url = location
            continue
        return data if status == 200 and data else None
    return None


def normalize(data):
    """`data` re-encoded as a PNG of at most BOX x BOX pixels (aspect kept), or None."""
    kind = raster(data)
    if kind is not None:
        mime, w, h = kind
        if not (0 < w <= MAX_SIDE and 0 < h <= MAX_SIDE) or w * h > MAX_PIXELS:
            return None
        scale = min(1.0, BOX / w, BOX / h)
        ow, oh = max(1, round(w * scale)), max(1, round(h * scale))
        doc = ('<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="%d" height="%d">'
               '<image width="%d" height="%d" preserveAspectRatio="none" xlink:href="data:%s;base64,' % (ow, oh, ow, oh, mime)
               ).encode() + base64.b64encode(data) + b'"/></svg>'
        # --unlimited: the document is ours (no entity, one element); a big photo's data URI exceeds libxml2's default.
        return rsvg(doc, ["--unlimited"])
    return rsvg(data, ["-w", str(BOX), "-h", str(BOX), "-a"])


def write_new(dst, data):
    fd = os.open(dst, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        view = memoryview(data)
        while view:
            view = view[os.write(fd, view):]
    finally:
        os.close(fd)


def candidates(name, themepath):
    if themepath:
        for ext in ("png", "svg"):
            yield os.path.join(themepath, name + "." + ext)
        yield from theme_files([themepath], name)
    yield from theme_files(BASES, name)
    for d in PIXMAPS:
        for ext in ("png", "svg"):
            yield os.path.join(d, name + "." + ext)


def theme_files(bases, name):
    for base in bases:
        try:
            themes = sorted(e.name for e in os.scandir(base) if e.is_dir())[:64]
        except OSError:
            continue
        themes = ["hicolor"] + [t for t in themes if t != "hicolor"]
        for theme in themes:
            for size in SIZES:
                for kind in KINDS:
                    for ext in ("png", "svg"):
                        yield os.path.join(base, theme, size, kind, name + "." + ext)


def used(out):
    total = 0
    for e in os.scandir(out):
        try:
            total += e.stat(follow_symlinks=False).st_size
        except OSError:
            pass
    return total


def batch(argv):
    out, iconcap, piccap, budget = argv[0], int(argv[1]), int(argv[2]), int(argv[3])
    args = argv[4:]
    if not os.path.isdir(out) or os.path.islink(out):
        return 1
    start = time.monotonic()
    started = 0
    copy_name = re.compile(r"[0-9]+\.png")
    lru = []
    items = []
    for i in range(0, len(args) - 2, 3):
        kind, n, value = args[i], args[i + 1], args[i + 2]
        if kind == "drop":
            if copy_name.fullmatch(value):
                try:
                    os.unlink(os.path.join(out, value))
                except OSError:
                    pass
        elif kind == "lru":
            if copy_name.fullmatch(value):
                lru.append(value)
        else:
            items.append((kind, n, value))
    for kind, n, value in items:
        # A value with a control character is never echoed (a newline would forge an answer line): no answer, and the
        # caller refuses every key it gets no answer for.
        if not re.fullmatch(r"[0-9]{1,12}", n) or re.search(r"[\x00-\x1f\x7f]", value):
            continue
        key = kind + ":" + value
        # At least one item per run, so a run always makes progress.
        if started and time.monotonic() - start > SOFT_SECONDS:
            print("later\t%s" % key, flush=True)
            continue
        started += 1
        path = None
        try:
            png = None
            if kind in ("name", "tray"):
                name, _, themepath = value.partition("|") if kind == "tray" else (value, "", "")
                if PLAIN_NAME.fullmatch(name) and ".." not in name and (themepath == "" or themepath.startswith("/")):
                    themepath = os.path.realpath(themepath) if themepath else ""
                    if themepath and not under_roots(themepath):
                        themepath = ""
                    attempts = 0
                    for c in candidates(name, themepath):
                        data = read_source(c, iconcap)
                        if not data:
                            continue
                        attempts += 1
                        png = normalize(data)
                        if png or attempts >= NAME_ATTEMPTS:
                            break
            elif kind in ("icon", "picture"):
                data = read_source(value, iconcap if kind == "icon" else piccap)
                png = normalize(data) if data else None
            elif kind == "url":
                data = fetch(value)
                png = normalize(data) if data else None
            if png:
                while used(out) + len(png) > budget and lru:
                    victim = lru.pop(0)
                    try:
                        os.unlink(os.path.join(out, victim))
                    except OSError:
                        pass
                    print("gone\t%s" % victim, flush=True)
                if used(out) + len(png) <= budget:
                    dst = os.path.join(out, "%s.png" % n)
                    write_new(dst, png)
                    path = dst
        except Exception:
            path = None
        print(("ok\t%s\t%s" % (key, path)) if path else ("no\t%s" % key), flush=True)
    return 0


def one_file(argv):
    src, cap, dst = argv[0], int(argv[1]), argv[2]
    data = read_source(src, cap)
    png = normalize(data) if data else None
    if not png:
        return 1
    try:
        write_new(dst, png)
    except OSError:
        return 1
    return 0


def qt_searches(path):
    """The rule of iconsearchpaths.h: Qt searches only the packaged directories, and only when the user cannot change them."""
    return os.path.realpath(path) in PACKAGED and not user_changeable(path)


# Every existing icon directory Qt does not search: the user's, user-changeable data dirs, and root-owned ones that are
# not packaged (/usr/local/share, flatpak and snap system exports).
BASES = [b for b in [os.path.join(home, ".icons"), os.path.join(data_home, "icons")] + [os.path.join(d, "icons") for d in data_dirs]
         if os.path.isdir(b) and not qt_searches(b)]
PIXMAPS = [p for p in [os.path.join(data_home, "pixmaps")] + [os.path.join(d, "pixmaps") for d in data_dirs]
           if os.path.isdir(p) and not qt_searches(p)]


def main(argv):
    mode = argv[1] if len(argv) > 1 else ""
    try:
        if mode == "batch" and len(argv) >= 6:
            return batch(argv[2:])
        if mode == "file" and len(argv) == 5:
            return one_file(argv[2:])
    except (ValueError, OSError):
        return 1
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
