// The Store's operations (apps/store/src/operations.h; ADR-0037 b, f; spec SR17-SR20; acceptance A6, A7) with fake programs:
// a fake pkexec standing for the helper (it writes the helper's files and pacman's log lines, then exits with the code its
// mode file says), a fake pacman answering -Q from a list, a fake Omarchy command writing or removing a web app's launcher,
// and a fake Omarchy terminal whose script stands for grassfield-store-run (b.2: its started and exit files, each way it
// can end). One operation at a time; success = exit code 0 AND the state; the locks; the time limits; store.json's record
// and the recovery at start.
#include "operations.h"
#include "statefile.h"
#include "storetest.h"

#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QTemporaryDir>
#include <QTimer>

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

// pkexec's stand-in: `<helper> <verb> <op> <names>`; its mode file says what happens.
const QByteArray kPkexec = R"SH(root=$(dirname "$0")
shift; verb=$1; op=$2; shift 2
mode=$(cat "$root/mode" 2>/dev/null)
[ "$mode" = cancel ] && exit 126
[ "$mode" = wait ] && exec sleep 30
start=$(awk '{sub(/.*\) /, ""); print $20}' /proc/$$/stat)
echo "$$ $start" >"$root/run/$op.started"
echo "grassfield-store-helper: $verb $* (operation $op)" >"$root/run/$op.log"
if [ "$mode" = refuse ]; then
  echo 4 >"$root/run/.$op.exit" && mv "$root/run/.$op.exit" "$root/run/$op.exit"
  exit 4
fi
# pacman -Sw failing as the owner's rc1-7 did (a file the mirror no longer has), or on a mirror that does not answer.
if [ "$mode" = gone ] || [ "$mode" = unreachable ]; then
  why="The requested URL returned error: 404"
  [ "$mode" = unreachable ] && why="Could not resolve host: mirror.example"
  echo "error: failed retrieving file '$1-1-1-x86_64.pkg.tar.zst' from mirror.example : $why" >>"$root/run/$op.log"
  echo "error: failed to commit transaction (failed to retrieve some files)" >>"$root/run/$op.log"
  echo "grassfield-store-helper: pacman could not download the packages" >>"$root/run/$op.log"
  echo 1 >"$root/run/.$op.exit" && mv "$root/run/.$op.exit" "$root/run/$op.exit"
  exit 1
fi
n=0
for p in "$@"; do
  n=$((n + 1))
  [ "$mode" = partial ] && [ $n -gt 1 ] && break
  if [ "$verb" = install ]; then
    echo "[2026-10-27T10:00:00+0000] [ALPM] installed $p (1-1)" >>"$root/pacman.log"; echo "$p 1-1" >>"$root/installed"
  else
    echo "[2026-10-27T10:00:00+0000] [ALPM] removed $p (1-1)" >>"$root/pacman.log"; grep -v "^$p " "$root/installed" >"$root/i2"; mv "$root/i2" "$root/installed"
  fi
done
[ "$mode" = slow ] && sleep 1
code=0
[ "$mode" = partial ] && { echo "error: failed to commit transaction (conflicting files)" >>"$root/run/$op.log"; code=1; }
echo $code >"$root/run/.$op.exit" && mv "$root/run/.$op.exit" "$root/run/$op.exit"
exit $code)SH";

const QByteArray kPacman = R"SH(root=$(dirname "$0")
[ "$1" = -Q ] || exit 1
shift; [ "$1" = -- ] && shift
rc=0
for p in "$@"; do grep "^$p " "$root/installed" || rc=1; done
exit $rc)SH";

// Omarchy's web app commands' stand-in: `<command> <args>`.
const QByteArray kInstaller = R"SH(root=$(dirname "$0")
cmd=$1; shift
case $cmd in
  omarchy-webapp-install)
    [ "$1" = Gone ] && { echo "error: failed retrieving file 'gone-1-1-any.pkg.tar.zst' from mirror.example : The requested URL returned error: 404"; exit 1; }
    printf '[Desktop Entry]\nName=%s\nExec=omarchy-launch-webapp %s\nIcon=%s\n' "$1" "$2" "$3" >"$root/apps/$1.desktop" ;;
  omarchy-webapp-remove) [ "$OMARCHY_REMOVE_NOTIFY" = false ] || exit 3; rm -f "$root/apps/$1.desktop" ;;
  omarchy-launch-floating-terminal-with-presentation)
    [ $# = 1 ] || exit 2
    echo "$1" >>"$root/commands"
    # What the Store left for the script: its pins and their modes.
    set -- $1
    cp "$root/runstore/$2.pins" "$root/pins-seen"
    stat -c %a "$root/runstore" "$root/runstore/$2.pins" >"$root/modes"
    "$root/fakerun" "$@" </dev/null >/dev/null 2>&1 & ;;
  *) exit 2 ;;
esac)SH";

// grassfield-store-run's stand-in, `<run> <op> <deadline> setup|aur <recipe> [<arg>...]`: its tmode file says how it goes,
// its tpackages file which packages the recipe installs or removes (the AUR's at a version of its build's own, 9-1).
const QByteArray kFakeRun = R"SH(root=$(dirname "$0"); run=$root/runstore
op=$2; recipe=$5
mode=$(cat "$root/tmode" 2>/dev/null)
fin() { echo "$1" >"$run/.$op.exit" && mv "$run/.$op.exit" "$run/$op.exit"; exit "$1"; }
case $mode in never) exit 0 ;; late) fin 6 ;; busy) fin 3 ;; esac
start=$(awk '{sub(/.*\) /, ""); print $20}' /proc/$$/stat)
echo "$$ $start" >"$run/.$op.started" && mv "$run/.$op.started" "$run/$op.started"
case $mode in slow) sleep 1 ;; changed) fin 5 ;; stopped) fin 130 ;; fail) fin 1 ;; refused) fin 7 ;; esac
n=0
for p in $(cat "$root/tpackages"); do
  n=$((n + 1))
  [ "$mode" = closed ] && [ $n -gt 1 ] && exit 0
  case $recipe in
    omarchy-install-*) echo "[2026-10-28T10:00:00+0000] [ALPM] installed $p (1-1)" >>"$root/pacman.log"; echo "$p 1-1" >>"$root/installed" ;;
    omarchy-pkg-aur-add) echo "[2026-10-28T10:00:00+0000] [ALPM] installed $p (9-1)" >>"$root/pacman.log"; echo "$p 9-1" >>"$root/installed" ;;
    *) echo "[2026-10-28T10:00:00+0000] [ALPM] removed $p (1-1)" >>"$root/pacman.log"; grep -v "^$p " "$root/installed" >"$root/i2"; mv "$root/i2" "$root/installed" ;;
  esac
done
[ "$mode" = closed ] && exit 0
fin 0)SH";

struct Fixture {
    QTemporaryDir dir;
    OperationsConfig config;
    Fixture()
    {
        storetest::ensureApp();
        const QString root = dir.path();
        QDir().mkpath(root + QStringLiteral("/run"));
        QDir().mkpath(root + QStringLiteral("/apps"));
        storetest::writeFile(root + QStringLiteral("/installed"), "bash 5.3-1\n");
        storetest::writeFile(root + QStringLiteral("/pacman.log"), "[2026-10-27T09:00:00+0000] [ALPM] installed old (1-1)\n");
        config.pkexec = storetest::script(root + QStringLiteral("/pkexec"), kPkexec);
        config.helper = QStringLiteral("/usr/lib/grassfield/grassfield-store-helper");
        config.statusDir = root + QStringLiteral("/run");
        config.updateLock = root + QStringLiteral("/omarchy-update.lock");
        config.dbLock = root + QStringLiteral("/db.lck");
        config.pacmanLog = root + QStringLiteral("/pacman.log");
        config.pacman = storetest::script(root + QStringLiteral("/pacman"), kPacman);
        config.stateFile = root + QStringLiteral("/state/store.json");
        config.applications = root + QStringLiteral("/apps");
        const QString installer = storetest::script(root + QStringLiteral("/installer"), kInstaller);
        storetest::script(root + QStringLiteral("/fakerun"), kFakeRun);
        config.run = QStringLiteral("/usr/lib/grassfield/grassfield-store-run");
        config.runDir = root + QStringLiteral("/runstore");
        config.terminalStartMs = 1000;
        config.terminalGraceMs = 500;
        config.omarchy = [installer](const QString &command, const QStringList &args) { return QStringList{installer, command} + args; };
        config.pollMs = 20;
    }
    void mode(const QByteArray &m) { storetest::writeFile(dir.filePath(QStringLiteral("mode")), m); }
    void terminalMode(const QByteArray &m) { storetest::writeFile(dir.filePath(QStringLiteral("tmode")), m); }
    QByteArray read(const QString &name) const
    {
        QFile file(dir.filePath(name));
        return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
    }
    QJsonObject record() const { return readStoreState(config.stateFile).value(QStringLiteral("operation")).toObject(); }
};

OperationRecord helperRecord(const QString &app, const QString &kind, const QStringList &plan)
{
    OperationRecord r;
    r.id = newOperationId();
    r.kind = kind;
    r.path = QStringLiteral("helper");
    r.app = app;
    r.name = app;
    r.packages = plan; // the fake pkexec installs what it is given (pacman would add the dependencies itself)
    for (const QString &n : plan) {
        PlannedPackage p;
        p.name = n;
        p.version = QStringLiteral("1-1");
        r.plan.append(p);
    }
    return r;
}

// A setup's operation (b.2): its recipe with its arguments, its packages (the plan), the catalog's pins.
OperationRecord terminalRecord(const QString &app, const QString &kind, const QStringList &plan)
{
    OperationRecord r = helperRecord(app, kind, plan);
    r.path = QStringLiteral("terminal");
    r.recipe = (kind == QLatin1String("install") ? QStringLiteral("omarchy-install-") : QStringLiteral("omarchy-remove-")) + app;
    r.args = {QStringLiteral("one"), QStringLiteral("v2.0")};
    r.pins = {{QStringLiteral("bin/") + r.recipe, QString(64, QLatin1Char('a'))}, {QStringLiteral("install/x.sh"), QString(64, QLatin1Char('b'))}};
    return r;
}

// The apps whose operation ended, in order (Operations::finished).
struct Ended {
    QStringList apps;
    explicit Ended(Operations &ops)
    {
        QObject::connect(&ops, &Operations::finished, &ops, [this](const QString &app) { apps.append(app); });
    }
    int count() const { return int(apps.size()); }
};

// Runs the event loop until `done` or 10 s.
template<typename F>
bool waitFor(F done, int ms = 10000)
{
    QEventLoop loop;
    QTimer timeout;
    timeout.setSingleShot(true);
    timeout.start(ms);
    while (!done() && timeout.isActive()) {
        QTimer::singleShot(10, &loop, &QEventLoop::quit);
        loop.exec();
    }
    return done();
}

} // namespace

TEST(Operations, RecordsAndIds)
{
    const QString id = newOperationId();
    EXPECT_TRUE(isOperationId(id));
    EXPECT_NE(id, newOperationId());
    EXPECT_FALSE(isOperationId(id.toUpper()));
    const OperationRecord r = helperRecord(QStringLiteral("xterm"), QStringLiteral("install"), {QStringLiteral("xterm"), QStringLiteral("libxaw")});
    const auto back = OperationRecord::fromJson(r.toJson());
    ASSERT_TRUE(back);
    EXPECT_EQ(back->id, r.id);
    EXPECT_EQ(back->plan.size(), 2);
    QJsonObject bad = r.toJson();
    bad.insert(QStringLiteral("packages"), QJsonArray{QStringLiteral("-rf")});
    EXPECT_FALSE(OperationRecord::fromJson(bad));
    bad = r.toJson();
    bad.insert(QStringLiteral("kind"), QStringLiteral("upgrade"));
    EXPECT_FALSE(OperationRecord::fromJson(bad));
    EXPECT_EQ(judge(0, 2, 2), Outcome::Done);
    EXPECT_EQ(judge(0, 1, 2), Outcome::Interrupted) << "an exit 0 with a part installed is not installed (S6)";
    EXPECT_EQ(judge(std::nullopt, 2, 2), Outcome::Interrupted) << "the state alone is not enough either";
    EXPECT_EQ(judge(1, 0, 2), Outcome::NotFinished);
    EXPECT_EQ(countLogged("[x] [ALPM] installed xterm (411-1)\n[x] [ALPM] installed other (1)\n[x] [ALPM] removed libxaw (1)\n",
                          QStringLiteral("installed"), {QStringLiteral("xterm"), QStringLiteral("libxaw")}), 1);
}

TEST(Operations, InstallThroughTheHelper)
{
    Fixture f;
    f.mode("ok");
    Operations ops(f.config);
    Ended finished(ops);
    ops.enqueue(helperRecord(QStringLiteral("xterm"), QStringLiteral("install"), {QStringLiteral("xterm"), QStringLiteral("libxaw")}));
    EXPECT_TRUE(ops.running());
    EXPECT_EQ(f.record().value(QStringLiteral("app")).toString(), QStringLiteral("xterm")) << "written before it starts";
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty()) << "done: nothing to say";
    EXPECT_TRUE(f.record().isEmpty()) << "the record goes once it ended";
    EXPECT_FALSE(ops.running());
}

TEST(Operations, OutcomesFromCodeAndState)
{
    Fixture f;
    Operations ops(f.config);
    Ended finished(ops);
    f.mode("cancel");
    ops.enqueue(helperRecord(QStringLiteral("a"), QStringLiteral("install"), {QStringLiteral("a")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("a")).outcome, QStringLiteral("cancelled"));

    f.mode("partial");
    ops.enqueue(helperRecord(QStringLiteral("b"), QStringLiteral("install"), {QStringLiteral("b"), QStringLiteral("b-dep")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    const Operations::Result r = ops.results().value(QStringLiteral("b"));
    EXPECT_EQ(r.outcome, QStringLiteral("interrupted"));
    EXPECT_EQ(r.present, 1);
    EXPECT_EQ(r.total, 2);
    EXPECT_TRUE(r.details.contains(QStringLiteral("conflicting files"))) << qPrintable(r.details);

    f.mode("refuse");
    ops.enqueue(helperRecord(QStringLiteral("c"), QStringLiteral("install"), {QStringLiteral("c")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 3; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("c")).outcome, QStringLiteral("unfinished"));
    ops.dismiss(QStringLiteral("c"));
    EXPECT_FALSE(ops.results().contains(QStringLiteral("c")));

    // Removed: each planned package gone.
    f.mode("ok");
    ops.enqueue(helperRecord(QStringLiteral("b"), QStringLiteral("remove"), {QStringLiteral("b")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 4; }));
    EXPECT_FALSE(ops.results().contains(QStringLiteral("b")));

    // A planned file the mirror no longer has (the integrator's note on PR #36): the system is older than the mirror,
    // "outdated" (Software Update); pacman's lines stay in the details, not in the line. A mirror that does not answer
    // is a failure like any other.
    f.mode("gone");
    ops.enqueue(helperRecord(QStringLiteral("d"), QStringLiteral("install"), {QStringLiteral("d")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 5; }));
    const Operations::Result gone = ops.results().value(QStringLiteral("d"));
    EXPECT_EQ(gone.outcome, QStringLiteral("outdated"));
    EXPECT_TRUE(gone.details.contains(QStringLiteral("returned error: 404"))) << qPrintable(gone.details);
    f.mode("unreachable");
    ops.enqueue(helperRecord(QStringLiteral("e"), QStringLiteral("install"), {QStringLiteral("e")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 6; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("e")).outcome, QStringLiteral("failed"));
}

TEST(Operations, OneAtATimeAndTheLocks)
{
    Fixture f;
    f.mode("slow");
    Operations ops(f.config);
    Ended finished(ops);
    ops.enqueue(helperRecord(QStringLiteral("one"), QStringLiteral("install"), {QStringLiteral("one")}));
    ops.enqueue(helperRecord(QStringLiteral("two"), QStringLiteral("install"), {QStringLiteral("two")}));
    ops.enqueue(helperRecord(QStringLiteral("three"), QStringLiteral("install"), {QStringLiteral("three")}));
    ASSERT_EQ(ops.items().size(), 3);
    EXPECT_EQ(ops.items().at(0).record.app, QStringLiteral("one"));
    EXPECT_EQ(ops.items().at(1).state, Operations::State::Waiting);
    // Omarchy's update lock is the Store's while the helper runs: another process cannot take it.
    EXPECT_TRUE(lockHeld(f.config.updateLock));
    EXPECT_TRUE(ops.removeWaiting(ops.items().at(2).record.id));
    EXPECT_FALSE(ops.removeWaiting(ops.items().at(0).record.id)) << "the running one stays";
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    EXPECT_EQ(finished.apps.at(0), QStringLiteral("one"));
    EXPECT_EQ(finished.apps.at(1), QStringLiteral("two"));
    EXPECT_FALSE(lockHeld(f.config.updateLock)) << "let go once it ended";

    // pacman's lock there: the next one waits (blocked) and starts when it goes.
    f.mode("ok");
    storetest::writeFile(f.config.dbLock, "");
    ops.enqueue(helperRecord(QStringLiteral("four"), QStringLiteral("install"), {QStringLiteral("four")}));
    EXPECT_FALSE(ops.running());
    ASSERT_EQ(ops.items().size(), 1);
    EXPECT_TRUE(ops.items().at(0).blocked);
    QFile::remove(f.config.dbLock);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 3; }));
    EXPECT_TRUE(ops.results().isEmpty());

    // Omarchy's update running (its lock held by another process): the same.
    QProcess holder;
    holder.start(QStringLiteral("flock"), {QStringLiteral("-o"), f.config.updateLock, QStringLiteral("sleep"), QStringLiteral("30")});
    ASSERT_TRUE(holder.waitForStarted());
    ASSERT_TRUE(waitFor([&] { return lockHeld(f.config.updateLock); }));
    ops.enqueue(helperRecord(QStringLiteral("five"), QStringLiteral("install"), {QStringLiteral("five")}));
    EXPECT_FALSE(ops.running());
    holder.kill();
    holder.waitForFinished();
    ASSERT_TRUE(waitFor([&] { return finished.count() == 4; }));
}

TEST(Operations, AuthorizationTimesOut)
{
    Fixture f;
    f.mode("wait"); // the password never comes
    f.config.authorizationMs = 300;
    Operations ops(f.config);
    Ended finished(ops);
    ops.enqueue(helperRecord(QStringLiteral("slow"), QStringLiteral("install"), {QStringLiteral("slow")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("slow")).outcome, QStringLiteral("timedOut"));
}

TEST(Operations, WebApps)
{
    Fixture f;
    Operations ops(f.config);
    Ended finished(ops);
    OperationRecord r;
    r.id = newOperationId();
    r.kind = QStringLiteral("install");
    r.path = QStringLiteral("webapp");
    r.app = QStringLiteral("chat");
    r.name = QStringLiteral("Chat");
    r.webName = QStringLiteral("Chat Room");
    r.webUrl = QStringLiteral("https://chat.example.org/");
    r.webIcon = f.dir.filePath(QStringLiteral("chat.png"));
    ops.enqueue(r);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(QFile::exists(f.dir.filePath(QStringLiteral("apps/Chat Room.desktop"))));
    EXPECT_TRUE(ops.results().isEmpty());
    r.id = newOperationId();
    r.kind = QStringLiteral("remove");
    ops.enqueue(r);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    EXPECT_FALSE(QFile::exists(f.dir.filePath(QStringLiteral("apps/Chat Room.desktop"))));
    EXPECT_TRUE(ops.results().isEmpty()) << "OMARCHY_REMOVE_NOTIFY=false reached the command";
    // A web app's command that fails with words like pacman's download error is a failure, never "update the system first":
    // only the helper's pacman downloads from the mirror (the integrator's review of ff2fd83: that condition's mutant).
    r.id = newOperationId();
    r.kind = QStringLiteral("install");
    r.webName = QStringLiteral("Gone");
    ops.enqueue(r);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 3; }));
    EXPECT_EQ(ops.results().value(QStringLiteral("chat")).outcome, QStringLiteral("failed"));
    EXPECT_TRUE(ops.results().value(QStringLiteral("chat")).details.contains(QStringLiteral("returned error: 404")));
}

TEST(Operations, RecoveryAtStart)
{
    Fixture f;
    // Done while the Store was away: its exit file 0 and every package there -> nothing said, the record gone.
    OperationRecord done = helperRecord(QStringLiteral("xterm"), QStringLiteral("install"), {QStringLiteral("xterm")});
    storetest::writeFile(f.dir.filePath(QStringLiteral("installed")), "xterm 1-1\n");
    storetest::writeFile(f.dir.filePath(QStringLiteral("run/") + done.id + QStringLiteral(".exit")), "0\n");
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), done.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_TRUE(ops.results().isEmpty());
        EXPECT_TRUE(f.record().isEmpty());
    }
    // Interrupted: no exit file, no helper running, one of two packages there.
    OperationRecord cut = helperRecord(QStringLiteral("gimp"), QStringLiteral("install"), {QStringLiteral("gimp"), QStringLiteral("babl")});
    storetest::writeFile(f.dir.filePath(QStringLiteral("installed")), "babl 1-1\n");
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), cut.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        const Operations::Result r = ops.results().value(QStringLiteral("gimp"));
        EXPECT_EQ(r.outcome, QStringLiteral("interrupted"));
        EXPECT_EQ(r.present, 1);
        EXPECT_EQ(r.total, 2);
    }
    // Not finished: nothing there.
    OperationRecord none = helperRecord(QStringLiteral("blender"), QStringLiteral("install"), {QStringLiteral("blender")});
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), none.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_EQ(ops.results().value(QStringLiteral("blender")).outcome, QStringLiteral("notFinished"));
    }
    // Still running (its started file names a live process with its start time): followed until its exit file comes.
    OperationRecord live = helperRecord(QStringLiteral("vlc"), QStringLiteral("install"), {QStringLiteral("vlc")});
    QProcess sleeper;
    sleeper.start(QStringLiteral("sleep"), {QStringLiteral("30")});
    ASSERT_TRUE(sleeper.waitForStarted());
    QFile stat(QStringLiteral("/proc/%1/stat").arg(sleeper.processId()));
    ASSERT_TRUE(stat.open(QIODevice::ReadOnly));
    const QByteArray line = stat.readAll();
    const QByteArray start = line.mid(line.lastIndexOf(") ") + 2).split(' ').at(19);
    storetest::writeFile(f.dir.filePath(QStringLiteral("run/") + live.id + QStringLiteral(".started")), QByteArray::number(sleeper.processId()) + ' ' + start + '\n');
    EXPECT_TRUE(helperRunning(f.config.statusDir, live.id));
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), live.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        EXPECT_TRUE(ops.running());
        waitFor([] { return false; }, 200); // a while: it is still running
        EXPECT_EQ(finished.count(), 0);
        storetest::writeFile(f.dir.filePath(QStringLiteral("installed")), "vlc 1-1\n");
        storetest::writeFile(f.dir.filePath(QStringLiteral("run/") + live.id + QStringLiteral(".exit")), "0\n");
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_TRUE(ops.results().isEmpty());
    }
    sleeper.kill();
    sleeper.waitForFinished();
    EXPECT_FALSE(helperRunning(f.config.statusDir, live.id));
}

TEST(Operations, TerminalRecordsAndCommand)
{
    const OperationRecord r = terminalRecord(QStringLiteral("game"), QStringLiteral("install"), {QStringLiteral("game")});
    const auto back = OperationRecord::fromJson(r.toJson());
    ASSERT_TRUE(back);
    EXPECT_EQ(back->recipe, QStringLiteral("omarchy-install-game"));
    EXPECT_EQ(back->args, (QStringList{QStringLiteral("one"), QStringLiteral("v2.0")}));
    EXPECT_TRUE(back->pins.isEmpty()) << "the pins are not kept in store.json";
    QJsonObject bad = r.toJson();
    bad.insert(QStringLiteral("recipe"), QStringLiteral("omarchy-remove-game"));
    EXPECT_FALSE(OperationRecord::fromJson(bad)) << "an install runs an install recipe";
    bad = r.toJson();
    bad.insert(QStringLiteral("args"), QJsonArray{QStringLiteral("one;id")});
    EXPECT_FALSE(OperationRecord::fromJson(bad));
    bad = r.toJson();
    bad.insert(QStringLiteral("args"), QJsonArray{QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c"), QStringLiteral("d"), QStringLiteral("e")});
    EXPECT_FALSE(OperationRecord::fromJson(bad));

    const QString run = QStringLiteral("/usr/lib/grassfield/grassfield-store-run");
    const QString id = QString(32, QLatin1Char('c'));
    EXPECT_EQ(terminalCommand(run, id, 1793155826, QStringLiteral("omarchy-install-browser"), {QStringLiteral("firefox")}),
              run + QStringLiteral(" ") + id + QStringLiteral(" 1793155826 setup omarchy-install-browser firefox"));
    // Each token as e.5 allows it, or no command at all (the launcher hands it to bash -c).
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-install-browser"), {QStringLiteral("firefox;id")}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-install-browser"), {QStringLiteral("$(id)")}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-install-browser"), {QStringLiteral("-x")}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-install-browser x"), {}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-launch-browser"), {}), QString());
    EXPECT_EQ(terminalCommand(run, QStringLiteral("cccc"), 1, QStringLiteral("omarchy-install-browser"), {}), QString());
    EXPECT_EQ(terminalCommand(run, id, 0, QStringLiteral("omarchy-install-browser"), {}), QString());
    EXPECT_EQ(terminalCommand(QStringLiteral("/tmp/a b"), id, 1, QStringLiteral("omarchy-install-browser"), {}), QString());
}

// The AUR (step 3b2): its two commands through the same terminal path, kind "aur", one package's name; an AUR package is
// there at whatever version its build made; the script's 7 (its plan refused) is a refusal.
TEST(Operations, AurThroughTheTerminal)
{
    OperationRecord r = terminalRecord(QStringLiteral("aur:example-app-bin"), QStringLiteral("install"), {});
    r.recipe = kAurAdd;
    r.args = {QStringLiteral("example-app-bin")};
    r.packages = {QStringLiteral("example-app-bin")};
    r.plan.clear();
    for (const QString &name : {QStringLiteral("example-app-bin"), QStringLiteral("example-lib")}) {
        PlannedPackage p;
        p.name = name;
        p.repo = QStringLiteral("aur"); // no version: whichever the build makes
        r.plan.append(p);
    }
    r.pins = {{QStringLiteral("bin/omarchy-pkg-aur-add"), QString(64, QLatin1Char('a'))}};
    const auto back = OperationRecord::fromJson(r.toJson());
    ASSERT_TRUE(back);
    EXPECT_EQ(back->recipe, kAurAdd);
    EXPECT_EQ(back->plan.at(1).version, QString());
    for (const auto &[key, value] : {std::pair{QStringLiteral("recipe"), QJsonValue(kAurDrop)},
                                     std::pair{QStringLiteral("recipe"), QJsonValue(QStringLiteral("omarchy-pkg-add"))},
                                     std::pair{QStringLiteral("args"), QJsonValue(QJsonArray{QStringLiteral("-rf")})},
                                     std::pair{QStringLiteral("args"), QJsonValue(QJsonArray{})},
                                     std::pair{QStringLiteral("args"), QJsonValue(QJsonArray{QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("c"),
                                                                                             QStringLiteral("d"), QStringLiteral("e")})}}) {
        QJsonObject bad = r.toJson();
        bad.insert(key, value);
        EXPECT_FALSE(OperationRecord::fromJson(bad)) << key.toStdString(); // an install runs the AUR's add, with 1 to 4 names
    }

    const QString run = QStringLiteral("/usr/lib/grassfield/grassfield-store-run");
    const QString id = QString(32, QLatin1Char('c'));
    EXPECT_EQ(terminalKind(kAurAdd, {QStringLiteral("example-app-bin")}), QStringLiteral("aur"));
    EXPECT_EQ(terminalKind(QStringLiteral("omarchy-install-browser"), {QStringLiteral("firefox")}), QStringLiteral("setup"));
    EXPECT_EQ(terminalCommand(run, id, 1793155826, kAurAdd, {QStringLiteral("example-app-bin")}),
              run + QStringLiteral(" ") + id + QStringLiteral(" 1793155826 aur omarchy-pkg-aur-add example-app-bin"));
    EXPECT_EQ(terminalCommand(run, id, 1, kAurDrop, {QStringLiteral("lib32-gcc@x+")}).section(QLatin1Char(' '), 3),
              QStringLiteral("aur omarchy-pkg-drop lib32-gcc@x+"));
    for (const QString &bad : {QStringLiteral("-rf"), QStringLiteral("a;id"), QStringLiteral("$(id)"), QStringLiteral("A"), QString()})
        EXPECT_EQ(terminalCommand(run, id, 1, kAurAdd, {bad}), QString()) << bad.toStdString();
    EXPECT_EQ(terminalCommand(run, id, 1, kAurAdd, {}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-pkg-add"), {QStringLiteral("gimp")}), QString());
    EXPECT_EQ(terminalCommand(run, id, 1, QStringLiteral("omarchy-install-browser"), {QStringLiteral("a@b")}), QString())
        << "a setup's arguments keep their own pattern";

    Fixture f;
    f.terminalMode("ok");
    storetest::writeFile(f.dir.filePath(QStringLiteral("tpackages")), "example-app-bin example-lib\n");
    Operations ops(f.config);
    Ended finished(ops);
    ops.enqueue(r);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty()) << "done: exit 0, both there (at 9-1, the build's version)";
    EXPECT_TRUE(f.read(QStringLiteral("commands")).contains(" aur omarchy-pkg-aur-add example-app-bin\n"));

    OperationRecord drop = r;
    drop.id = newOperationId();
    drop.kind = QStringLiteral("remove");
    drop.recipe = kAurDrop;
    f.terminalMode("refused");
    ops.enqueue(drop);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    EXPECT_EQ(ops.results().value(r.app).outcome, QStringLiteral("refused")) << "exit 7: the script refused the plan";
    f.terminalMode("ok");
    drop.id = newOperationId();
    ops.enqueue(drop);
    ASSERT_TRUE(waitFor([&] { return finished.count() == 3; }));
    EXPECT_TRUE(ops.results().isEmpty()) << "removed: exit 0 and both gone";
    EXPECT_EQ(f.read(QStringLiteral("installed")), "bash 5.3-1\n");
}

TEST(Operations, TerminalInstallAndRemove)
{
    Fixture f;
    f.terminalMode("slow");
    storetest::writeFile(f.dir.filePath(QStringLiteral("tpackages")), "game game-data\n");
    Operations ops(f.config);
    Ended finished(ops);
    const OperationRecord r = terminalRecord(QStringLiteral("game"), QStringLiteral("install"), {QStringLiteral("game"), QStringLiteral("game-data")});
    const qint64 asked = QDateTime::currentSecsSinceEpoch();
    ops.enqueue(r);
    EXPECT_EQ(ops.items().at(0).state, Operations::State::Opening);
    EXPECT_EQ(ops.list().at(0).toMap().value(QStringLiteral("path")).toString(), QStringLiteral("terminal"));
    ASSERT_TRUE(waitFor([&] { return ops.running() && ops.items().at(0).state == Operations::State::Running; }));
    // The script takes Omarchy's lock itself (b.2): the Store does not hold it.
    EXPECT_FALSE(lockHeld(f.config.updateLock));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty()) << "done: exit 0 and both packages there";

    // The launcher got one argument: grassfield-store-run's command, its deadline the Store's 60 s (1 s here).
    const QList<QByteArray> words = f.read(QStringLiteral("commands")).trimmed().split(' ');
    ASSERT_EQ(words.size(), 7);
    EXPECT_EQ(words.at(0), "/usr/lib/grassfield/grassfield-store-run");
    EXPECT_EQ(words.at(1), r.id.toLatin1());
    EXPECT_GE(words.at(2).toLongLong(), asked + 1);
    EXPECT_LE(words.at(2).toLongLong(), asked + 2);
    EXPECT_EQ(words.mid(3), (QList<QByteArray>{"setup", "omarchy-install-game", "one", "v2.0"}));
    EXPECT_EQ(f.read(QStringLiteral("pins-seen")), QByteArray(64, 'a') + "  bin/omarchy-install-game\n" + QByteArray(64, 'b') + "  install/x.sh\n");
    EXPECT_EQ(f.read(QStringLiteral("modes")), "700\n600\n");
    EXPECT_TRUE(QDir(f.config.runDir).entryList(QDir::Files | QDir::Hidden).isEmpty()) << "its files go once it ended";

    f.terminalMode("ok");
    ops.enqueue(terminalRecord(QStringLiteral("game"), QStringLiteral("remove"), {QStringLiteral("game"), QStringLiteral("game-data")}));
    ASSERT_TRUE(waitFor([&] { return finished.count() == 2; }));
    EXPECT_TRUE(ops.results().isEmpty()) << "removed: exit 0 and both packages gone";
    EXPECT_EQ(f.read(QStringLiteral("installed")), "bash 5.3-1\n");
}

TEST(Operations, TerminalOutcomes)
{
    Fixture f;
    storetest::writeFile(f.dir.filePath(QStringLiteral("tpackages")), "game game-data\n");
    Operations ops(f.config);
    Ended finished(ops);
    const auto outcome = [&](const QByteArray &mode, const QString &app) {
        f.terminalMode(mode);
        const int before = finished.count();
        ops.enqueue(terminalRecord(app, QStringLiteral("install"), {QStringLiteral("game"), QStringLiteral("game-data")}));
        if (!waitFor([&] { return finished.count() == before + 1; }))
            return QStringLiteral("(did not end)");
        return ops.results().value(app).outcome;
    };
    EXPECT_EQ(outcome("never", QStringLiteral("a")), QStringLiteral("terminalDidNotOpen")) << "no started file within 60 s (1 s here)";
    EXPECT_EQ(outcome("late", QStringLiteral("b")), QStringLiteral("terminalDidNotOpen")) << "exit 6: past its deadline";
    EXPECT_EQ(outcome("busy", QStringLiteral("c")), QStringLiteral("busy"));
    EXPECT_EQ(outcome("changed", QStringLiteral("d")), QStringLiteral("omarchyChanged")) << "exit 5: a pinned file differs";
    EXPECT_EQ(outcome("stopped", QStringLiteral("e")), QStringLiteral("cancelled")) << "Ctrl+C before anything was installed";
    EXPECT_EQ(outcome("fail", QStringLiteral("f")), QStringLiteral("failed"));
    EXPECT_EQ(outcome("closed", QStringLiteral("g")), QStringLiteral("interrupted")) << "the terminal closed: no exit file";
    EXPECT_EQ(ops.results().value(QStringLiteral("g")).present, 1);
    EXPECT_EQ(ops.results().value(QStringLiteral("g")).total, 2);

    // No folder for its files (no XDG_RUNTIME_DIR): it fails before anything starts, no command is run.
    f.config.runDir.clear();
    QFile::remove(f.dir.filePath(QStringLiteral("commands")));
    Operations without(f.config);
    Ended ended(without);
    without.enqueue(terminalRecord(QStringLiteral("h"), QStringLiteral("install"), {QStringLiteral("h")}));
    ASSERT_TRUE(waitFor([&] { return ended.count() == 1; }));
    EXPECT_EQ(without.results().value(QStringLiteral("h")).outcome, QStringLiteral("failed"));
    EXPECT_FALSE(QFile::exists(f.dir.filePath(QStringLiteral("commands"))));
}

TEST(Operations, TerminalWaitsForTheLocks)
{
    Fixture f;
    f.terminalMode("ok");
    storetest::writeFile(f.dir.filePath(QStringLiteral("tpackages")), "game\n");
    Operations ops(f.config);
    Ended finished(ops);
    // Omarchy's update running: the terminal is not asked for until its lock is free.
    QProcess holder;
    holder.start(QStringLiteral("flock"), {QStringLiteral("-o"), f.config.updateLock, QStringLiteral("sleep"), QStringLiteral("30")});
    ASSERT_TRUE(holder.waitForStarted());
    ASSERT_TRUE(waitFor([&] { return lockHeld(f.config.updateLock); }));
    ops.enqueue(terminalRecord(QStringLiteral("game"), QStringLiteral("install"), {QStringLiteral("game")}));
    EXPECT_FALSE(ops.running());
    EXPECT_TRUE(ops.items().at(0).blocked);
    EXPECT_FALSE(QFile::exists(f.dir.filePath(QStringLiteral("commands"))));
    holder.kill();
    holder.waitForFinished();
    ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
    EXPECT_TRUE(ops.results().isEmpty());
}

TEST(Operations, TerminalRecovery)
{
    Fixture f;
    QDir().mkpath(f.config.runDir);
    // Still running (its started file names a live process): followed again until its exit file comes.
    OperationRecord live = terminalRecord(QStringLiteral("game"), QStringLiteral("install"), {QStringLiteral("game")});
    live.startedAt = QDateTime::currentDateTimeUtc().addSecs(-600);
    QProcess sleeper;
    sleeper.start(QStringLiteral("sleep"), {QStringLiteral("30")});
    ASSERT_TRUE(sleeper.waitForStarted());
    QFile stat(QStringLiteral("/proc/%1/stat").arg(sleeper.processId()));
    ASSERT_TRUE(stat.open(QIODevice::ReadOnly));
    const QByteArray line = stat.readAll();
    const QByteArray start = line.mid(line.lastIndexOf(") ") + 2).split(' ').at(19);
    storetest::writeFile(f.config.runDir + QLatin1Char('/') + live.id + QStringLiteral(".started"), QByteArray::number(sleeper.processId()) + ' ' + start + '\n');
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), live.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(ops.running());
        EXPECT_EQ(ops.items().at(0).state, Operations::State::Running);
        waitFor([] { return false; }, 200);
        EXPECT_EQ(finished.count(), 0);
        storetest::writeFile(f.dir.filePath(QStringLiteral("installed")), "game 1-1\n");
        storetest::writeFile(f.config.runDir + QLatin1Char('/') + live.id + QStringLiteral(".exit"), "0\n");
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_TRUE(ops.results().isEmpty());
    }
    sleeper.kill();
    sleeper.waitForFinished();

    // Asked for long ago, never started: not finished; an old file of another operation is cleared.
    OperationRecord gone = terminalRecord(QStringLiteral("other"), QStringLiteral("install"), {QStringLiteral("other")});
    gone.startedAt = QDateTime::currentDateTimeUtc().addSecs(-600);
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), gone.toJson()); });
    const QString old = f.config.runDir + QLatin1Char('/') + QString(32, QLatin1Char('d')) + QStringLiteral(".exit");
    storetest::writeFile(old, "0\n");
    QFile oldFile(old);
    ASSERT_TRUE(oldFile.open(QIODevice::ReadWrite));
    ASSERT_TRUE(oldFile.setFileTime(QDateTime::currentDateTimeUtc().addDays(-1), QFileDevice::FileModificationTime));
    oldFile.close();
    const QString recent = f.config.runDir + QLatin1Char('/') + QString(32, QLatin1Char('e')) + QStringLiteral(".exit");
    storetest::writeFile(recent, "0\n");
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_EQ(ops.results().value(QStringLiteral("other")).outcome, QStringLiteral("notFinished"));
    }
    EXPECT_FALSE(QFile::exists(old));
    EXPECT_TRUE(QFile::exists(recent)) << "within its 3 h it may still be followed";

    // Asked for moments ago: the terminal may still open, the Store waits for it.
    OperationRecord opening = terminalRecord(QStringLiteral("third"), QStringLiteral("install"), {QStringLiteral("third")});
    opening.startedAt = QDateTime::currentDateTimeUtc();
    updateStoreState(f.config.stateFile, [&](QJsonObject &s) { s.insert(QStringLiteral("operation"), opening.toJson()); });
    {
        Operations ops(f.config);
        Ended finished(ops);
        ops.recover();
        ASSERT_TRUE(ops.running());
        EXPECT_EQ(ops.items().at(0).state, Operations::State::Opening);
        ASSERT_TRUE(waitFor([&] { return finished.count() == 1; }));
        EXPECT_EQ(ops.results().value(QStringLiteral("third")).outcome, QStringLiteral("terminalDidNotOpen"));
    }
}
