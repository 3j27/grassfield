// The Store's operations (apps/store/src/operations.h; ADR-0037 b, f; spec SR17-SR20; acceptance A6, A7) with fake programs:
// a fake pkexec standing for the helper (it writes the helper's files and pacman's log lines, then exits with the code its
// mode file says), a fake pacman answering -Q from a list, a fake Omarchy command writing or removing a web app's launcher.
// One operation at a time; success = exit code 0 AND the state; the locks; the authorization's time limit; store.json's
// record and the recovery at start.
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
  omarchy-webapp-install) printf '[Desktop Entry]\nName=%s\nExec=omarchy-launch-webapp %s\nIcon=%s\n' "$1" "$2" "$3" >"$root/apps/$1.desktop" ;;
  omarchy-webapp-remove) [ "$OMARCHY_REMOVE_NOTIFY" = false ] || exit 3; rm -f "$root/apps/$1.desktop" ;;
  *) exit 2 ;;
esac)SH";

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
        config.omarchy = [installer](const QString &command, const QStringList &args) { return QStringList{installer, command} + args; };
        config.pollMs = 20;
    }
    void mode(const QByteArray &m) { storetest::writeFile(dir.filePath(QStringLiteral("mode")), m); }
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
