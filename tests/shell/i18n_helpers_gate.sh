#!/usr/bin/env bash
# Selftest of part (e) of the i18n gate (scripts/dev/check-i18n.py --helpers-only DIR): the session helpers' strings. Each fixture
# helper is a tiny script in its own directory; the gate must pass the good ones, name the problem in each bad one, and must
# never run what it checks (a marker file that every fixture would create on import or execution must not appear).
set -euo pipefail
root=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
tmp=$(mktemp -d "${GRASSFIELD_TEST_TMP:-${TMPDIR:-/tmp}}/i18n-helpers.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
fail=0
check() { if "$@"; then echo "PASS: $desc"; else echo "FAIL: $desc"; fail=1; fi; }
gate() { python3 -I "$root/scripts/dev/check-i18n.py" --helpers-only "$1" 2>&1 || true; }
# fixture NAME FILENAME SHEBANG: body on stdin
fixture() { mkdir -p "$tmp/$1"; { echo "$3"; cat; } >"$tmp/$1/$2"; }

PYHEAD='import os
CATALOG = {"fr": {"Reopen": "Rouvrir", "Disk %s is full": "Le disque %s est plein"}}
def tr(text): return CATALOG["fr"].get(text, text)'

fixture good-py helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
open("$tmp/marker-py", "w").close()
def go(name):
    return ["notify-send", "-a", "Grassfield", "-u", "critical", "-i", "dialog-information", "-c", "device.error", "-t", "0",
            "-A", "reopen=" + tr("Reopen"), "--", tr("Disk %s is full") % name, tr("Reopen")]
EOF
fixture good-sh helper '#!/bin/sh' <<EOF
touch "$tmp/marker-sh"
lang=\${LANG%%[_.@]*}
tr() { case "\$lang:\$1" in fr:"Run") printf '%s' "Exécuter" ;; *) printf '%s' "\$1" ;; esac; }
notify-send -a Grassfield -i dialog-information -A "default=\$(tr "Run")" -- "\$(tr "Run")" "\$body"
EOF
desc="a correct Python and a correct sh helper pass (icon names and other option values are not text)"
check bash -c '[[ -z $1 ]]' _ "$(gate "$tmp/good-py")$(gate "$tmp/good-sh")"
desc="the gate never runs what it reads: no marker file from the Python or the sh fixture"
check bash -c '[[ ! -e $1/marker-py && ! -e $1/marker-sh ]]' _ "$tmp"

fixture var helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go():
    title = "Disk is full right now"
    return ["notify-send", "--", title, tr("Reopen")]
EOF
desc="English text held in a variable (title = ...) is reported"
check grep -q 'title holds the bare English text' <<<"$(gate "$tmp/var")"

fixture literal helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go(): return ["notify-send", "-a", "Grassfield", "--", "Hello there", tr("Reopen")]
EOF
desc="a bare English literal after -- is reported"
check grep -q "'Hello there' is a bare English literal" <<<"$(gate "$tmp/literal")"

fixture action helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go(): return ["notify-send", "-A", "default=Run it now", "--", tr("Reopen")]
EOF
desc="a Python action label (-A default=Run it now) is reported"
check grep -q "action label 'default=Run it now'" <<<"$(gate "$tmp/action")"

fixture action2 helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go(label): return ["notify-send", "-A", label, "--", tr("Reopen")]
EOF
desc="an action built from something that is not id= plus tr() is reported"
check grep -q 'action label is built from text' <<<"$(gate "$tmp/action2")"

fixture missing helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go(): return ["notify-send", "--", tr("Not in the catalog")]
EOF
desc="a tr() string without French text is reported"
check grep -q "has no French text" <<<"$(gate "$tmp/missing")"

fixture constant helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
UNKNOWN_BODY = "Something went wrong with the thing"
ACTIONS = {"a": ("Do it anyway please", "x")}
def go(): return ["notify-send", "--", tr("Reopen")]
EOF
out=$(gate "$tmp/constant")
desc="module-level English text (a constant, a tuple in a dict) that is not in the catalog is reported"
check bash -c 'grep -q "Something went wrong" <<<"$1" && grep -q "Do it anyway please" <<<"$1"' _ "$out"

fixture nocat helper '#!/usr/bin/python3 -I' <<EOF
def go(): return ["notify-send", "--", "x"]
EOF
desc="a helper that notifies without CATALOG['fr'] is reported"
check grep -q "no CATALOG" <<<"$(gate "$tmp/nocat")"

fixture shact helper '#!/bin/bash' <<'EOF'
lang=fr
tr() { case "$lang:$1" in fr:"Run") printf '%s' "Exécuter" ;; *) printf '%s' "$1" ;; esac; }
notify-send -a Grassfield -A default=Run -- "$(tr "Run")" "x"
EOF
desc="a shell action label (-A default=Run) is reported"
check grep -q "action label" <<<"$(gate "$tmp/shact")"

fixture shvar helper '#!/bin/bash' <<'EOF'
lang=fr
tr() { case "$lang:$1" in fr:"Run") printf '%s' "Exécuter" ;; *) printf '%s' "$1" ;; esac; }
body="Click to run it now"
notify-send -- "$(tr "Run")" "$body"
EOF
desc="English text held in a shell variable (body=...) is reported"
check grep -q "body holds the bare English text" <<<"$(gate "$tmp/shvar")"

fixture shlit helper '#!/bin/bash' <<'EOF'
lang=fr
tr() { case "$lang:$1" in fr:"Run") printf '%s' "Exécuter" ;; *) printf '%s' "$1" ;; esac; }
notify-send -a Grassfield \
  -- "Pending Omarchy migrations" "$(tr "Run")"
EOF
desc="a bare English literal in a shell notify-send (also after a line continuation) is reported"
check grep -q "'Pending Omarchy migrations' is a bare English literal" <<<"$(gate "$tmp/shlit")"

fixture shmiss helper '#!/bin/bash' <<'EOF'
lang=fr
tr() { case "$lang:$1" in fr:"Run") printf '%s' "Exécuter" ;; *) printf '%s' "$1" ;; esac; }
notify-send -- "$(tr "Run")" "$(tr "Stop")"
EOF
desc="a shell tr string without an fr: case is reported"
check grep -q 'tr .Stop. has no fr: case' <<<"$(gate "$tmp/shmiss")"
desc="none of the bad fixtures ran either"
check bash -c '[[ ! -e $1/marker-py && ! -e $1/marker-sh ]]' _ "$tmp"

# --- the shapes the first gate missed: conditionals, % and .format() and f-strings, variables that flow into notify-send ---
must_fail() { # NAME FILENAME SHEBANG PATTERN DESCRIPTION  (body on stdin)
  fixture "$1" "$2" "$3"
  desc="$5"
  check grep -q -- "$4" <<<"$(gate "$tmp/$1")"
}
must_fail cond helper '#!/usr/bin/python3 -I' 'title holds the bare English text' "a conditional of two English texts held in title is reported (both branches)" <<EOF
$PYHEAD
def go(critical):
    title = "Low battery" if not critical else "Very low battery"
    return ["notify-send", "--", title, tr("Reopen")]
EOF
must_fail cond-argv helper '#!/usr/bin/python3 -I' 'English text built in the code' "a conditional with English text directly in the argument list is reported" <<EOF
$PYHEAD
def go(x):
    return ["notify-send", "--", "Hello there" if x else tr("Reopen"), tr("Reopen")]
EOF
must_fail percent helper '#!/usr/bin/python3 -I' 'body holds the bare English text' "a % format of English text held in body is reported (the left side)" <<EOF
$PYHEAD
def go(label):
    body = "Can't %s now" % label.lower()
    return ["notify-send", "--", tr("Reopen"), body]
EOF
must_fail fstring helper '#!/usr/bin/python3 -I' 'English text built in the code' "an f-string (variable not in the watched names) flowing into notify-send is reported" <<EOF
$PYHEAD
def go(name):
    shown = f"Disk {name} is full"
    return ["notify-send", "--", tr("Reopen"), shown]
EOF
must_fail format helper '#!/usr/bin/python3 -I' 'English text built in the code' ".format() on English text in the argument list is reported" <<EOF
$PYHEAD
def go(name):
    return ["notify-send", "--", tr("Reopen"), "Disk {} is full".format(name)]
EOF
must_fail flow helper '#!/usr/bin/python3 -I' 'English text built in the code' "a variable with an unwatched name that holds English text and reaches notify-send is reported" <<EOF
$PYHEAD
def go():
    shown = "Something happened here"
    return ["notify-send", "--", tr("Reopen"), shown]
EOF
must_fail param helper '#!/usr/bin/python3 -I' 'is given the bare English text' "a local function called with English text for its title or body parameter is reported" <<EOF
$PYHEAD
def show(title, body):
    return ["notify-send", "--", title, body]
show("Hello there world", tr("Reopen"))
EOF
must_fail tr-cond helper '#!/usr/bin/python3 -I' 'has no French text' "tr() of a conditional: each branch needs French text" <<EOF
$PYHEAD
def go(x):
    return ["notify-send", "--", tr("Reopen" if x else "Not translated at all")]
EOF
# The old battery-watch (bc4a3c2) with a catalog that lacks its strings passed with 0 violations: it must fail.
must_fail old-battery helper '#!/usr/bin/python3 -I' 'English text' "the pre-fix battery-watch shape (conditional title, % body) with a catalog that lacks its strings is reported" <<EOF
import subprocess
CATALOG = {"fr": {"Other": "Autre"}}
def tr(text): return CATALOG["fr"].get(text, text)
def notify(level, capacity):
    critical = level <= 5
    title = "Low battery" if not critical else "Very low battery"
    body = "%d%% of the battery is left. Connect the charger%s." % (capacity, " now, the computer will shut down soon" if critical else "")
    subprocess.run(["notify-send", "-a", "Grassfield", "-u", "critical" if critical else "normal", "--", title, body], capture_output=True, timeout=10, check=False)
EOF
# The pre-fix session-end: the labels in a module-level table, "Can't %s now" % label.lower(), the bodies as variables.
fixture old-session-end helper '#!/usr/bin/python3 -I' <<EOF
import subprocess
CATALOG = {"fr": {"Other": "Autre"}}
def tr(text): return CATALOG["fr"].get(text, text)
ACTIONS = {"logout": ("Log Out", "Log Out Anyway"), "restart": ("Restart", "Restart Anyway")}
def ask(title, body, anyway):
    subprocess.Popen(["notify-send", "-a", "Grassfield", "-u", "critical", "-A", "force=" + anyway, "--", title, body])
def notify_blocked(action, names, unknown=False):
    label, anyway = ACTIONS[action]
    title = "Can't %s now" % label.lower()
    if unknown:
        body = "The list of open windows could not be read, so the session was not ended."
    else:
        body = "These applications are still open: %s." % ", ".join(names[:5])
    ask(title, body, anyway)
EOF
out=$(gate "$tmp/old-session-end")
desc="the pre-fix session-end shape is reported: the table's English, the % title and body, the English handed to ask(title, body)"
check bash -c 'grep -q "Log Out Anyway" <<<"$1" && grep -q "title holds the bare English text" <<<"$1" && grep -q "body holds the bare English text" <<<"$1"' _ "$out"
# Shell: a variable of any name that reaches notify-send, a one-line if, a printf format.
must_fail sh-msg helper '#!/bin/bash' "msg holds the bare English text" "a shell variable of any name that reaches notify-send (msg=...) is reported" <<'EOF'
lang=fr
tr() { case "$lang:$1" in
    fr:"Run") printf '%s' "Exécuter" ;;
    *) printf '%s' "$1" ;;
  esac; }
msg="Something went wrong here"
notify-send -- "$(tr "Run")" "$msg"
EOF
must_fail sh-oneline helper '#!/bin/bash' "note holds the bare English text" "a literal assigned inside a one-line if ... then ...; fi is reported" <<'EOF'
lang=fr
tr() { case "$lang:$1" in
    fr:"Run") printf '%s' "Exécuter" ;;
    *) printf '%s' "$1" ;;
  esac; }
if [ "$n" = 1 ]; then note="One thing happened"; else note=$(tr "Run"); fi
notify-send -- "$(tr "Run")" "$note"
EOF
must_fail sh-printf helper '#!/bin/bash' "shown holds the bare English text" "a printf whose format is English text and whose result reaches notify-send is reported" <<'EOF'
lang=fr
tr() { case "$lang:$1" in
    fr:"Run") printf '%s' "Exécuter" ;;
    *) printf '%s' "$1" ;;
  esac; }
shown=$(printf "Run %s things" "$n")
notify-send -- "$(tr "Run")" "$shown"
EOF
fixture good-sh2 helper '#!/bin/bash' <<'EOF'
lang=fr
tr() { case "$lang:$1" in
    fr:"Run %s") printf '%s' "Exécuter %s" ;;
    fr:"Run") printf '%s' "Exécuter" ;;
    *) printf '%s' "$1" ;;
  esac; }
if [ "$n" = 1 ]; then note=$(tr "Run"); else note=$(printf "$(tr "Run %s")" "$n"); fi
notify-send -- "$(tr "Run")" "$note"
EOF
desc="a shell helper whose variables hold translated text (also through printf of a tr) passes"
check bash -c '[[ -z $1 ]]' _ "$(gate "$tmp/good-sh2")"
fixture good-py2 helper '#!/usr/bin/python3 -I' <<EOF
$PYHEAD
def go(critical, name):
    title = tr("Reopen" if critical else "Disk %s is full") % name
    shown = tr("Reopen") if critical else tr("Disk %s is full") % name
    return ["notify-send", "-i", "dialog-information", "--", title, shown, f"{name}"]
EOF
desc="a Python helper whose conditionals, % formats and f-strings only carry translated or dynamic text passes"
check bash -c '[[ -z $1 ]]' _ "$(gate "$tmp/good-py2")"

desc="the packaged helpers pass the gate (it is part of just check)"
check bash -c '[[ -z $(python3 -I "$1/scripts/dev/check-i18n.py" --helpers-only "$1/packaging/bin" 2>&1) ]]' _ "$root"

# Part (f): the Settings C++. 61 variants of visible English text in the table below plus one literal on the line after its call: each
# must fail on its own line; the good file
# (translated text, tokens, log lines, comparisons, D-Bus names, i18n-ignore) must pass.
cppgate() { python3 -I "$root/scripts/dev/check-i18n.py" --cpp-only "$1" 2>&1 || true; }
cppcase() { # NAME LINE-OF-CODE...: the file holds those lines (line 1 is the first); the gate must report exactly line 1
  mkdir -p "$tmp/cpp-$1"
  shift_name=$1
  shift
  printf '%s\n' "$@" >"$tmp/cpp-$shift_name/f.cpp"
}
declare -A variants=(
  [stringliteral]='QString a() { return QStringLiteral("that network is gone"); }'
  [qstring]='QString a() { return QString("that network is gone"); }'
  [implicit]='const char *a() { return "that network is gone"; }'
  [u_s]='QString a() { return u"that network is gone"_s; }'
  [view]='QStringView a() { return QLatin1StringView("that network is gone"); }'
  [word]='QString a() { return QStringLiteral("failed"); }'
  [ternary]='QString a(bool b) { return b ? QStringLiteral("failed") : QString(); }'
  [assign]='void a(QString &error) { error = QStringLiteral("failed"); }'
  [latin1]='QString a() { QString reason; reason = QLatin1String("it broke"); return reason; }'
  [logline]='QString a() { qWarning() << "fine"; return QStringLiteral("it broke"); }'
  [callarg]='void a(const QString &tag) { emit failed(tag, QStringLiteral("failed")); }'
  [callarg2]='void a(Label *l) { l->setText(QStringLiteral("Failed")); }'
  [member]='void A::a() { m_reason = QStringLiteral("failed"); }'
  [localvar]='void a() { const QString shown = QStringLiteral("failed"); use(shown); }'
  [fromlatin1]='QString a() { return QString::fromLatin1("failed"); }'
  [fromutf8var]='void a() { QString shown = QString::fromUtf8("failed"); use(shown); }'
  [nestedsink]='void a() { reportError(QString(QStringLiteral("failed"))); }'
  [braceinit]='void a() { QString reason{QStringLiteral("failed")}; use(reason); }'
  [pluseq]='void a(QString &out) { out += QStringLiteral("failed"); }'
  [argcall]='QString a() { return base().arg(QStringLiteral("failed")); }'
  [insertvalue]='void a(QJsonObject &o) { o.insert(QStringLiteral("reason"), QStringLiteral("failed")); }'
  [returnbrace]='Result a() { return {false, {}, QStringLiteral("failed")}; }'
  [donecall]='void a(Done done) { done(QStringLiteral("failed"), QString()); }'
  [settlecall]='void a() { settle(QStringLiteral("failed"), {}); }'
  [finishedcall]='void a() { emit finished(tag, false, QStringLiteral("failed")); }'
  [bracespace]='void a() { QString reason {QStringLiteral("failed")}; use(reason); }'
  [assignbrace]='void a() { QString shown = {QStringLiteral("failed")}; use(shown); }'
  [declparen]='void a() { const QString shown(QStringLiteral("failed")); use(shown); }'
  [declbrace]='void a() { QString shown{QStringLiteral("failed")}; use(shown); }'
  [insertmessage]='void a(QJsonObject &o) { o.insert(QStringLiteral("message"), QStringLiteral("failed")); }'
  [memberappend]='void A::a() { m_errors.append(QStringLiteral("failed")); }'
  [pushback]='void a() { reasons.push_back(QStringLiteral("failed")); }'
  [constkey]='void a(QJsonObject &o) { o.insert(kReasonKey, QStringLiteral("failed")); }'
  [msgkey]='void a(QJsonObject &o) { o.insert(QStringLiteral("msg"), QStringLiteral("failed")); }'
  [detailkey]='void a(QJsonObject &o) { o.insert(QStringLiteral("detail"), QStringLiteral("failed")); }'
  [jsonpair]='QJsonObject a() { return QJsonObject{{"reason", "failed"}}; }'
  [shiftlist]='void a() { reasons << QStringLiteral("failed"); }'
  [jsonvalue]='void a(QJsonObject &o) { o.insert(QStringLiteral("reason"), QJsonValue("failed")); }'
  [ondone]='void a() { onDone(QStringLiteral("failed"), {}); }'
  [emplaceback]='void a() { reasons.emplace_back(QStringLiteral("failed")); }'
  [emplaceBack]='void a() { m_errors.emplaceBack(QStringLiteral("failed")); }'
  [shiftprefix]='void A::a() { m_reasons << QStringLiteral("failed"); }'
  [shiftdptr]='void A::a() { d->errors << QStringLiteral("failed"); }'
  [shiftthis]='void A::a() { this->lines << QStringLiteral("failed"); }'
  [keycamel]='QJsonObject a() { return QJsonObject{{"errorMessage", "Hello"}}; }'
  [keystatustext]='QJsonObject a() { return QJsonObject{{"statusText", "Hello"}}; }'
  [insertcamel]='void a(QJsonObject &o) { o.insert(QStringLiteral("statusText"), QStringLiteral("Hello")); }'
  [insertsnake]='void a(QJsonObject &o) { o.insert(QStringLiteral("last_error"), QStringLiteral("Hello")); }'
  [shiftlast]='void A::a() { m_lastError << "Hello"; }'
  [shiftlines]='void a() { errorLines << "Hello"; }'
  [shiftmessages]='void a() { statusMessages << "Hello"; }'
  [shiftsnake]='void a() { last_errors << "Hello"; }'
  [shiftindex]='void a() { list[0].reasons << "Hello"; }'
  [shiftderef]='void a() { (*reasons) << "Text"; }'
  [shiftcast]='void a() { static_cast<QStringList &>(reasons) << "Text"; }'
  [shiftassign]='void a() { reasons = QStringList() << "Failed"; }'
  [shiftassignm]='void A::a() { m_errors = QStringList() << QStringLiteral("Failed"); }'
  [shiftpluseq]='void a() { reasons += QStringList() << "Failed"; }'
  [shiftconstdecl]='void a() { const QStringList reasons = QStringList() << "Failed"; }'
  [shiftautodecl]='void a() { auto reasons = QStringList() << "Failed"; }'
  [shiftchain]='void a(Result &r) { r.errors << QStringLiteral("failed") << QStringLiteral("it broke"); }'
)
for name in "${!variants[@]}"; do
  cppcase "$name" "${variants[$name]}"
  desc="part (f): $name is reported"
  check grep -q "f.cpp:1: English text" <<<"$(cppgate "$tmp/cpp-$name")"
done
mkdir -p "$tmp/cpp-next"
printf '%s\n' 'QString a(int x)' '{' '    return fail(x,' '        QStringLiteral("that network is gone"));' '}' >"$tmp/cpp-next/f.cpp"
desc="part (f): a literal on the line after its call is reported (line 4)"
check grep -q "f.cpp:4: English text" <<<"$(cppgate "$tmp/cpp-next")"
mkdir -p "$tmp/cpp-good"
cat >"$tmp/cpp-good/f.cpp" <<'CPP'
QString a() { return QCoreApplication::translate("X", "that network is gone"); }
QString b() { return tr("that network is gone"); }
QString c() { return QStringLiteral("two words"); } // i18n-ignore: a test
// i18n-ignore: the next line
QString d() { return QStringLiteral("two words"); }
QString e() { return QStringLiteral("org.example.Name"); }
bool f(const QString &m) { return m == QLatin1String("Get") || m == QStringLiteral("GetAll"); }
void g() { qWarning().noquote() << "dev guard: refused a command" << argv.first(); qInfo() << "dev guard:"; }
void k(const QString &t) { emit failed(t, QCoreApplication::translate("X", "failed")); QString mode = tr("failed"); }
void m(QJsonObject &o, Result &r) { o.insert(QStringLiteral("reason"), x); r.insert(QStringLiteral("radio"), true); }
QJsonObject n() { return QJsonObject{{QStringLiteral("name"), v}, {QStringLiteral("connected"), w}}; }
Result o() { return {false, {}, tr("failed")}; }
void p(QStringList &args, QJsonObject &o) { args.append(QStringLiteral("status")); o.insert(k, QStringLiteral("owe")); abandoned(QStringLiteral("failed")); }
void q(Result &r) { r.insert(QStringLiteral("name"), QStringLiteral("owe")); QString mode = tr("failed"); const auto x = f(QStringLiteral("a")); }
void r(QStringList &args, QStringList &cmd, QStringList &argv, QJsonObject &o) {
    args.append(QStringLiteral("status")); cmd.push_back(QStringLiteral("status")); argv << QStringLiteral("status");
    o.insert(kPath, QStringLiteral("owe")); o.insert(QStringLiteral("radio"), QStringLiteral("owe")); abandoned(QStringLiteral("failed"));
}
QJsonObject s() { return QJsonObject{{"name", "owe"}, {"mode", "infrastructure"}}; }
void l(Bus &bus) { bus.call(a, QStringLiteral("Connect"), QStringLiteral("on")); const bool x = flag == QLatin1String("on"); }
void h(Bus &bus) { bus.call(a, QStringLiteral("GetDevices"), QStringLiteral("on"), QStringLiteral("ready to go")); } // i18n-ignore: x
/* a comment: that network is gone */ // and another one: no word is read here
QString i() { return QStringLiteral("%1.%2").arg(a, b); }
QString j() { return QCoreApplication::translate("X", "timed out") + QString::fromUtf8(R"(raw/path)"); }
QDBusMessage t() { QDBusMessage msg; msg << "clicked"; return msg; }
void u(QTextStream &err) { err << "grassfield-preview: " << "failed"; }
void v() { QJsonObject o{{"set_toplevel_description", "os"}, {"titles", "File:"}}; }
void w(QStringList &args, bool x) { args << reasonFlag << "status"; args << QStringLiteral("status") << "failed"; }
void y(QTextStream &o) { o.insert("titles", "File:"); o.insert(QStringLiteral("set_toplevel_description"), QStringLiteral("os")); }
void x(QTextStream &cerr, QString &outline, QString &context, QString &hinting) { cerr << "failed"; outline << "failed"; context << "failed"; hinting << "failed"; }
CPP
desc="part (f): translated text, tokens, comparisons, log lines, comments and i18n-ignore pass"
check bash -c '[[ -z $1 ]]' _ "$(cppgate "$tmp/cpp-good")"
desc="part (f): apps/settings/src has no bare English literal"
check bash -c '[[ -z $(python3 -I "$1/scripts/dev/check-i18n.py" --cpp-only "$1/apps/settings/src" 2>&1) ]]' _ "$root"

exit $fail
