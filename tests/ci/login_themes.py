#!/usr/bin/env python3
"""The login and boot themes stay themes (ADR-0042, ADR-0040 step 10): nothing in them can do more than draw.

  python3 -I tests/ci/login_themes.py             check packaging/sddm/theme, packaging/plymouth and their package
  python3 -I tests/ci/login_themes.py --selftest  the checks on planted mutants of the real files

The SDDM theme (packaging/sddm/theme, run by sddm-greeter as the `sddm` user):
  - exactly Main.qml, Strings.js, metadata.desktop and theme.conf (all of them installed); metadata names a Qt 6 theme;
  - imports QtQuick, Grassfield.Ui and its own Strings.js only; Strings.js imports nothing;
  - no process, file, network, URL, dynamic code or log call (Process, FileView, XMLHttpRequest, Qt.openUrlExternally, Loader,
    Qt.createComponent/createQmlObject/include, LocalStorage, Qt.labs, console.*, print(), an http(s) or absolute URL);
  - of SDDM's object it calls login, reboot and powerOff and reads canReboot and canPowerOff, nothing else;
  - one text input, a TextInput in Password echo mode, and only its length is read anywhere but in the one function that
    calls sddm.login: there the text is copied to a local once, the field is emptied before sddm.login, and that local is
    sddm.login's password, its only other use; the failure handler empties the field too.
The Plymouth theme (packaging/plymouth):
  - grassfield.plymouth names Plymouth's own two-step module (no script module, no ScriptFile), its images under
    /usr/share/plymouth/themes/grassfield, and the default artwork's ground (tokens.json session.ground) as both background
    colours;
  - build.sh renders every image two-step loads (lock.png, entry.png, bullet.png; watermark.png and the throbber), and the
    mark only from branding/icons/symbolic/grassfield-logo-full.svg with its black fill drawn white (the drawing unchanged);
  - with rsvg-convert installed, build.sh is run into a temporary folder and every image is a PNG (else that part is skipped).
The package (packaging/arch/PKGBUILD, grassfield-login-themes): installs the theme files and the rendered folder, and nothing
that activates them (no /etc file, no hook, no install scriptlet, no plymouth-set-default-theme, mkinitcpio or systemctl).
"""
import configparser
import json
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
THEME = ROOT / "packaging" / "sddm" / "theme"
PLYMOUTH = ROOT / "packaging" / "plymouth"
PKGBUILD = ROOT / "packaging" / "arch" / "PKGBUILD"
TOKENS = ROOT / "ui" / "tokens" / "tokens.json"

THEME_FILES = {"Main.qml", "Strings.js", "metadata.desktop", "theme.conf"}
IMPORTS = {"QtQuick", "Grassfield.Ui", '"Strings.js"'}
SDDM_MEMBERS = {"login", "reboot", "powerOff", "canReboot", "canPowerOff"}
FORBIDDEN = [
    (r"\bProcess\b", "a process"),
    (r"\bFileView\b", "a file"),
    (r"\bXMLHttpRequest\b", "a network or file request"),
    (r"\bQt\s*\.\s*openUrlExternally\b", "an external URL"),
    (r"\bLoader\b", "a Loader"),
    (r"\bQt\s*\.\s*(?:createComponent|createQmlObject|include)\b", "dynamic code"),
    (r"\bLocalStorage\b", "local storage"),
    (r"\bQt\s*\.\s*labs\b", "a Qt.labs module"),
    (r"\bconsole\s*\.", "a log call"),
    (r"(?<![\w.])print\s*\(", "a log call"),
    (r"\bQuickshell\b", "Quickshell"),
    (r"[\"'`](?:https?|ftp)://", "a network URL"),
]
TWO_STEP_IMAGES = ("lock.png", "entry.png", "bullet.png", "watermark.png")
ACTIVATES = ("/etc", "install=", "hook", "plymouth-set-default-theme", "mkinitcpio", "systemctl", "pam.d")


def strip_comments(src):
    """The source without // and /* */ comments (string literals kept)."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c in "\"'`":
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == "\\" else 1
            out.append(src[i:j + 1])
            i = j + 1
        elif src.startswith("//", i):
            while i < n and src[i] != "\n":
                i += 1
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(c)
            i += 1
    return "".join(out)


def block_at(code, brace):
    """The text between the "{" at `brace` and its matching "}" (strings skipped)."""
    depth, i, n = 0, brace, len(code)
    while i < n:
        c = code[i]
        if c in "\"'`":
            j = i + 1
            while j < n and code[j] != c:
                j += 2 if code[j] == "\\" else 1
            i = j + 1
            continue
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return code[brace + 1:i]
        i += 1
    return code[brace + 1:]


def call_args(code, start):
    """The top-level arguments of the call whose "(" is at `start`."""
    depth, i, args, cur = 0, start, [], []
    while i < len(code):
        c = code[i]
        if c in "([{":
            depth += 1
            if depth > 1:
                cur.append(c)
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append("".join(cur).strip())
                return [a for a in args if a]
            cur.append(c)
        elif c == "," and depth == 1:
            args.append("".join(cur).strip())
            cur = []
        else:
            cur.append(c)
        i += 1
    return args


def enclosing_function(code, pos):
    """The body of the innermost `function name(...) {` that contains `pos`, or None."""
    best = None
    for m in re.finditer(r"\bfunction\s+\w+\s*\([^)]*\)\s*(?::\s*\w+\s*)?\{", code):
        brace = m.end() - 1
        body = block_at(code, brace)
        if brace < pos <= brace + len(body):
            best = (brace + 1, body)
    return best


def check_sddm(files):
    """Problems of the SDDM theme given as {name: text}."""
    problems = []
    names = set(files)
    if names != THEME_FILES:
        problems.append("theme files are %s, expected %s" % (sorted(names), sorted(THEME_FILES)))
    meta = configparser.ConfigParser(interpolation=None)
    meta.optionxform = str
    try:
        meta.read_string(files.get("metadata.desktop", ""))
        section = meta["SddmGreeterTheme"]
        for key, want in (("Type", "sddm-theme"), ("MainScript", "Main.qml"), ("QtVersion", "6"), ("ConfigFile", "theme.conf")):
            if section.get(key) != want:
                problems.append("metadata.desktop: %s is %r, expected %r" % (key, section.get(key), want))
    except (configparser.Error, KeyError) as e:
        problems.append("metadata.desktop: not a [SddmGreeterTheme] file (%s)" % e)

    qml = strip_comments(files.get("Main.qml", ""))
    js = strip_comments(files.get("Strings.js", ""))
    for m in re.finditer(r"^\s*import\s+(\S+)", qml, re.M):
        if m.group(1) not in IMPORTS:
            problems.append("Main.qml imports %s (only %s)" % (m.group(1), ", ".join(sorted(IMPORTS))))
    if re.search(r"^\s*\.import\b", js, re.M):
        problems.append("Strings.js imports a module")
    for label, code in (("Main.qml", qml), ("Strings.js", js)):
        for pattern, what in FORBIDDEN:
            if re.search(pattern, code):
                problems.append("%s: %s (%s)" % (label, what, pattern))

    used = set(re.findall(r"\bsddm\s*\.\s*(\w+)", qml))
    if used - SDDM_MEMBERS:
        problems.append("Main.qml uses sddm.%s (only %s)" % (", sddm.".join(sorted(used - SDDM_MEMBERS)), ", ".join(sorted(SDDM_MEMBERS))))
    if re.search(r"\bsddm\s*\[", qml):
        problems.append("Main.qml reaches SDDM's object by a computed name")

    # The password field.
    if re.search(r"\b(?:TextField|TextEdit|TextArea)\s*\{", qml):
        problems.append("Main.qml has a text input other than the password's TextInput")
    inputs = list(re.finditer(r"\bTextInput\s*\{", qml))
    if len(inputs) != 1:
        problems.append("Main.qml has %d TextInput, expected one" % len(inputs))
        return problems
    body = block_at(qml, inputs[0].end() - 1)
    fid = re.search(r"^\s*id\s*:\s*(\w+)", body, re.M)
    if not re.search(r"\becho[Mm]ode\s*:\s*TextInput\s*\.\s*Password\b", body):
        problems.append("the TextInput is not in Password echo mode")
    if not fid:
        problems.append("the TextInput has no id")
        return problems
    fid = fid.group(1)
    # Inside the field, its own text is only measured (`text: ...` of a child is an assignment, not a read).
    own = body
    for child in re.finditer(r"\b[A-Z]\w*\s*\{", body):
        own = own.replace(block_at(body, child.end() - 1), "")
    for m in re.finditer(r"(?<![\w.])text\b(?!\s*:)", own):
        if not own.startswith(".length", m.end()):
            problems.append("the TextInput reads its own text beyond its length")
    calls = list(re.finditer(r"\bsddm\s*\.\s*login\s*\(", qml))
    if len(calls) != 1:
        problems.append("sddm.login is called %d times, expected once" % len(calls))
        return problems
    call = calls[0]
    func = enclosing_function(qml, call.start())
    if func is None:
        problems.append("sddm.login is not called from a function")
        return problems
    fstart, fbody = func
    reads = list(re.finditer(r"\b%s\s*\.\s*text\b(?!\s*\.\s*length\b)(?!\s*=[^=])" % re.escape(fid), qml))
    copy = re.search(r"\b(?:const|let|var)\s+(\w+)\s*=\s*%s\s*\.\s*text\s*;" % re.escape(fid), fbody)
    outside = [m for m in reads if not (copy and m.start() == fstart + copy.start() + copy.group(0).index(fid))]
    if outside:
        problems.append("the password (%s.text) is read %d time(s) beyond the one copy for sddm.login" % (fid, len(outside)))
    if not copy:
        problems.append("the function that calls sddm.login does not copy %s.text to a local once" % fid)
        return problems
    secret = copy.group(1)
    clear = re.search(r"\b%s\s*\.\s*(?:text\s*=\s*(?:\"\"|'')|clear\s*\(\s*\))" % re.escape(fid), fbody[copy.end():])
    login_at = call.start() - fstart
    if not clear or copy.end() + clear.start() > login_at:
        problems.append("the field is not emptied between the copy and sddm.login")
    args = call_args(qml, call.end() - 1)
    if len(args) != 3 or args[1] != secret:
        problems.append("sddm.login's password is not the local copy %s (arguments: %s)" % (secret, args))
    uses = re.findall(r"\b%s\b" % re.escape(secret), fbody)
    if len(uses) != 2:
        problems.append("the local %s is used %d times in its function, expected twice (its copy and sddm.login)" % (secret, len(uses)))
    failed = re.search(r"\bfunction\s+onLoginFailed\s*\([^)]*\)\s*(?::\s*\w+\s*)?\{|\bonLoginFailed\s*:\s*\{", qml)
    if not failed or not re.search(r"\b%s\s*\.\s*(?:text\s*=\s*(?:\"\"|'')|clear\s*\(\s*\))" % re.escape(fid), block_at(qml, failed.end() - 1)):
        problems.append("a failed login does not empty the field")
    return problems


def check_plymouth(conf_text, build_text, ground):
    """Problems of the Plymouth theme: its .plymouth file, its build script and the ground colour (#RRGGBB)."""
    problems = []
    conf = configparser.ConfigParser(interpolation=None)
    conf.optionxform = str
    try:
        conf.read_string(conf_text)
    except configparser.Error as e:
        return ["grassfield.plymouth is not a key file (%s)" % e]
    if set(conf.sections()) != {"Plymouth Theme", "two-step"}:
        problems.append("grassfield.plymouth sections are %s, expected [Plymouth Theme] and [two-step]" % conf.sections())
    if conf.get("Plymouth Theme", "ModuleName", fallback="") != "two-step":
        problems.append("grassfield.plymouth does not name the two-step module")
    for section in conf.sections():
        if "ScriptFile" in conf[section]:
            problems.append("grassfield.plymouth names a script")
    step = conf["two-step"] if conf.has_section("two-step") else {}
    if step.get("ImageDir") != "/usr/share/plymouth/themes/grassfield":
        problems.append("ImageDir is %r, expected /usr/share/plymouth/themes/grassfield" % step.get("ImageDir"))
    want = "0x" + ground.lstrip("#").lower()
    for key in ("BackgroundStartColor", "BackgroundEndColor"):
        if str(step.get(key, "")).lower() != want:
            problems.append("%s is %r, expected the ground %s" % (key, step.get(key), want))

    build = strip_sh_comments(build_text)
    for image in TWO_STEP_IMAGES:
        if not re.search(r'"\$out/%s"' % re.escape(image), build):
            problems.append("build.sh does not render %s" % image)
    if not re.search(r"throbber-%04d\.png", build):
        problems.append("build.sh does not render the throbber frames")
    if not re.search(r'"\$here/grassfield\.plymouth"\s+"\$out/grassfield\.plymouth"', build):
        problems.append("build.sh does not copy grassfield.plymouth")
    marks = re.findall(r"grassfield-logo[\w.-]*\.svg", build)
    if marks != ["grassfield-logo-full.svg"]:
        problems.append("build.sh reads the mark from %s, expected grassfield-logo-full.svg once" % marks)
    seds = re.findall(r"\bsed\b[^\n]*", build)
    if seds != ["sed 's/fill=\"#000\"/fill=\"#FFFFFF\"/' \"$root/branding/icons/symbolic/grassfield-logo-full.svg\" > \"$work/mark.svg\""]:
        problems.append("build.sh changes the mark beyond its fill colour: %s" % seds)
    return problems


def strip_sh_comments(src):
    return "\n".join(line for line in src.splitlines() if not line.lstrip().startswith("#"))


def package_body(pkgbuild):
    m = re.search(r"^package_grassfield-login-themes\(\)\s*\{\n(.*?)^\}", pkgbuild, re.M | re.S)
    return m.group(1) if m else None


def check_package(pkgbuild, theme_names):
    """Problems of the grassfield-login-themes package in the PKGBUILD text."""
    problems = []
    names = re.search(r"^pkgname=\(([^)]*)\)", pkgbuild, re.M)
    if not names or "grassfield-login-themes" not in names.group(1).split():
        problems.append("pkgname does not list grassfield-login-themes")
    if not re.search(r'"\$\(_root\)/packaging/plymouth/build\.sh" --out "\$srcdir/plymouth-grassfield"', pkgbuild):
        problems.append("build() does not render the Plymouth theme")
    body = package_body(pkgbuild)
    if body is None:
        return problems + ["no package_grassfield-login-themes()"]
    code = strip_sh_comments(body)
    for word in ACTIVATES:
        if word in code:
            problems.append("package_grassfield-login-themes() has %r (it installs, never activates)" % word)
    if not re.search(r"depends=\([^)]*grassfield-desktop", code):
        problems.append("grassfield-login-themes does not depend on grassfield-desktop (Grassfield.Ui)")
    listed = re.search(r'"\$\(_root\)"/packaging/sddm/theme/\{([^}]*)\}', code)
    if not listed or set(listed.group(1).split(",")) != set(theme_names):
        problems.append("the package installs %s of the theme, which holds %s" % (listed.group(1) if listed else "nothing", sorted(theme_names)))
    if '/usr/share/sddm/themes/grassfield' not in code or '/usr/share/plymouth/themes/grassfield' not in code:
        problems.append("the package does not install into the two theme folders")
    if not re.search(r'"\$srcdir"/plymouth-grassfield/\*\.png', code):
        problems.append("the package does not install the rendered Plymouth images")
    return problems


def render_check():
    """Runs build.sh into a temporary folder when rsvg-convert is installed; problems, or None when skipped."""
    if shutil.which("rsvg-convert") is None:
        return None
    problems = []
    with tempfile.TemporaryDirectory() as out:
        run = subprocess.run([str(PLYMOUTH / "build.sh"), "--out", out], capture_output=True, text=True, timeout=120)
        if run.returncode != 0:
            return ["build.sh failed (%d): %s" % (run.returncode, run.stderr.strip()[-400:])]
        files = {p.name for p in Path(out).iterdir()}
        for image in TWO_STEP_IMAGES + ("throbber-0001.png",):
            if image not in files:
                problems.append("build.sh did not write %s" % image)
        for name in sorted(files):
            if name.endswith(".png") and (Path(out) / name).read_bytes()[:8] != b"\x89PNG\r\n\x1a\n":
                problems.append("%s is not a PNG" % name)
        frames = sorted(int(n[9:13]) for n in files if re.fullmatch(r"throbber-\d{4}\.png", n))
        if frames != list(range(1, len(frames) + 1)):
            problems.append("the throbber frames are not numbered from 0001 without a gap: %s" % frames)
        if "grassfield.plymouth" not in files:
            problems.append("build.sh did not copy grassfield.plymouth")
    return problems


def real():
    theme = {p.name: p.read_text() for p in THEME.iterdir() if p.is_file()}
    ground = json.loads(TOKENS.read_text())["session"]["ground"]["value"]
    return theme, (PLYMOUTH / "grassfield.plymouth").read_text(), (PLYMOUTH / "build.sh").read_text(), ground, PKGBUILD.read_text()


def main():
    theme, conf, build, ground, pkgbuild = real()
    problems = check_sddm(theme) + check_plymouth(conf, build, ground) + check_package(pkgbuild, set(theme))
    rendered = render_check()
    for p in problems + (rendered or []):
        print("FAIL: %s" % p)
    if rendered is None:
        print("skip: rsvg-convert is not installed (the render of build.sh is not run)")
    if problems or rendered:
        return 1
    print("login_themes: the SDDM theme draws and hands the password to sddm.login only; the Plymouth theme is two-step "
          "images on the ground; the package activates nothing")
    return 0


def selftest():
    theme, conf, build, ground, pkgbuild = real()
    failures = []

    def expect(label, problems, bad):
        if bool(problems) != bad:
            failures.append("%s: %s" % (label, problems or "no problem found"))

    expect("real SDDM theme", check_sddm(theme), False)
    expect("real Plymouth theme", check_plymouth(conf, build, ground), False)
    expect("real package", check_package(pkgbuild, set(theme)), False)

    qml = theme["Main.qml"]
    copy_line = "        const secret = field.text;\n"
    clear_line = '        field.text = "";\n        root.message = "";\n        root.busy = true;\n'
    assert copy_line in qml and clear_line in qml, "the selftest's anchors moved: update them"
    mutants = {
        "a process": qml.replace("    // ---- what is drawn ----", "    Process { command: [\"id\"] }\n    // ---- what is drawn ----"),
        "a log of the password": qml.replace(copy_line, copy_line + "        console.log(secret);\n"),
        "a print": qml.replace(copy_line, copy_line + "        print(field.text.length);\n"),
        "a binding to the password": qml.replace("    property string message: \"\"", "    readonly property string typed: field.text\n    property string message: \"\""),
        "the password in the message": qml.replace('root.message = root.t("incorrect");', 'root.message = field.text;'),
        "the field not emptied": qml.replace(clear_line, '        root.message = "";\n        root.busy = true;\n', 1),
        "emptied after login": qml.replace(clear_line, '        root.message = "";\n        root.busy = true;\n', 1).replace(
            "sddm.login(root.userName, secret, root.sessionIndex);", "sddm.login(root.userName, secret, root.sessionIndex);\n        field.text = \"\";"),
        "the field read directly": qml.replace("sddm.login(root.userName, secret, root.sessionIndex);", "sddm.login(root.userName, field.text, root.sessionIndex);"),
        "the secret used twice": qml.replace("root.busy = true;\n        sddm", "root.busy = secret.length > 0;\n        sddm"),
        "failure keeps the text": qml.replace("        function onLoginFailed(): void {\n            field.text = \"\";\n", "        function onLoginFailed(): void {\n"),
        "an echoed field": qml.replace("echoMode: TextInput.Password", "echoMode: TextInput.Normal"),
        "a second input": qml.replace("    // ---- what is drawn ----", "    TextField { }\n    // ---- what is drawn ----"),
        "another sddm call": qml.replace("onClicked: sddm.reboot()", "onClicked: sddm.suspend()"),
        "a network URL": qml.replace('"file://" + root.user.iconPath', '"https://example.org/" + root.user.userName'),
        "a Loader": qml.replace("    // ---- what is drawn ----", "    Loader { source: \"/tmp/x.qml\" }\n    // ---- what is drawn ----"),
        "an import": qml.replace("import QtQuick\n", "import QtQuick\nimport Quickshell.Io\n"),
        "dynamic code": qml.replace(copy_line, copy_line + "        Qt.createQmlObject(\"import QtQuick; Item {}\", root);\n"),
        "the field's own text read": qml.replace("if (text.length > 0)", "if (text !== \"\")"),
    }
    for label, text in mutants.items():
        if text == qml:
            failures.append("mutant %r did not apply" % label)
            continue
        expect("SDDM mutant: " + label, check_sddm(dict(theme, **{"Main.qml": text})), True)
    expect("SDDM mutant: an extra file", check_sddm(dict(theme, **{"run.sh": "id"})), True)
    expect("SDDM mutant: Qt 5 metadata", check_sddm(dict(theme, **{"metadata.desktop": theme["metadata.desktop"].replace("QtVersion=6", "QtVersion=5")})), True)
    expect("SDDM mutant: a log in Strings.js", check_sddm(dict(theme, **{"Strings.js": theme["Strings.js"] + "\nconsole.warn('x');\n"})), True)

    plymouth_mutants = {
        "the script module": (conf.replace("ModuleName=two-step", "ModuleName=script"), build),
        "a script file": (conf.replace("[two-step]\n", "[two-step]\nScriptFile=/tmp/x.script\n"), build),
        "another image folder": (conf.replace("ImageDir=/usr/share/plymouth/themes/grassfield", "ImageDir=/tmp"), build),
        "another ground": (conf.replace("BackgroundStartColor=0x2f6d5f", "BackgroundStartColor=0x000000"), build),
        "no lock image": (conf, build.replace('"$out/lock.png"', '"$out/padlock.png"')),
        "no throbber": (conf, build.replace("throbber-%04d.png", "spinner-%04d.png")),
        "the mark recoloured otherwise": (conf, build.replace('s/fill="#000"/fill="#FFFFFF"/', 's/fill="#000"/fill="#FFFFFF" stroke="#F00"/')),
        "the mark transformed": (conf, build.replace("> \"$work/mark.svg\"", "| sed 's/<path/<path transform=\"rotate(10)\"/' > \"$work/mark.svg\"")),
        "another mark file": (conf, build.replace("grassfield-logo-full.svg\" > \"$work", "grassfield-logo.svg\" > \"$work")),
    }
    for label, (c, b) in plymouth_mutants.items():
        if (c, b) == (conf, build):
            failures.append("mutant %r did not apply" % label)
            continue
        expect("Plymouth mutant: " + label, check_plymouth(c, b, ground), True)

    body = package_body(pkgbuild)
    package_mutants = {
        "an /etc file": pkgbuild.replace(body, body + '  install -Dm644 /dev/null "$pkgdir/etc/sddm.conf.d/zz-grassfield-theme.conf"\n'),
        "an install scriptlet": pkgbuild.replace(body, "  install=grassfield-login-themes.install\n" + body),
        "a hook": pkgbuild.replace(body, body + '  install -Dm644 x "$pkgdir/usr/share/libalpm/hooks/grassfield-plymouth.hook"\n'),
        "a theme file left out": pkgbuild.replace("{Main.qml,Strings.js,metadata.desktop,theme.conf}", "{Main.qml,metadata.desktop,theme.conf}"),
        "not in pkgname": pkgbuild.replace(" grassfield-login-themes)", ")"),
        "no desktop dependency": pkgbuild.replace(body, body.replace('depends=("grassfield-desktop=$pkgver-$pkgrel")', "depends=()")),
    }
    for label, text in package_mutants.items():
        if text == pkgbuild:
            failures.append("mutant %r did not apply" % label)
            continue
        expect("package mutant: " + label, check_package(text, set(theme)), True)

    for f in failures:
        print("FAIL: %s" % f)
    if failures:
        return 1
    print("login_themes selftest: %d mutants caught, the real files pass" % (len(mutants) + 3 + len(plymouth_mutants) + len(package_mutants)))
    return 0


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:] == ["--selftest"] else main())
