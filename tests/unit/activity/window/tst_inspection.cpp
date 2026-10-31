// Inspect's backend (docs/specs/activity.md AM57 to AM59; ADR-0038 AD13, AD45): one inspection per process (a second request
// gives the open one), its header and tabs as the window shows them, another owner's "—" and refusals, Quit through AM50's
// rules, the window closed when the process ends, the reads on the worker's thread and only while the window is on
// screen; the app's Info button, View > Inspect Process and a row's double-click.
#include "../fixture.h"
#include "activityapp.h"
#include "format.h"
#include "inspection.h"

#include <QAbstractItemModelTester>
#include <QDir>
#include <QFile>
#include <QSignalSpy>
#include <QTemporaryDir>
#include <QThread>

#include <gtest/gtest.h>

using namespace activity;
using activity_test::Fixture;

namespace {

constexpr unsigned kMe = 1000;

QString valueOf(const QVariantList &rows, const QString &label)
{
    for (const QVariant &r : rows) {
        const QVariantMap m = r.toMap();
        if (m.value(QStringLiteral("label")).toString() == label)
            return m.value(QStringLiteral("value")).toString();
    }
    return QStringLiteral("<no row %1>").arg(label);
}

QStringList fileTexts(const QVariantList &files)
{
    QStringList out;
    for (const QVariant &f : files) {
        const QVariantMap m = f.toMap();
        out << QStringLiteral("%1 %2").arg(m.value(QStringLiteral("fd")).toInt()).arg(m.value(QStringLiteral("text")).toString());
    }
    return out;
}

struct Registry {
    Fixture fx;
    Inspectors inspectors{fx.proc(), kMe, 100};
    Registry()
    {
        fx.write("proc/stat", "cpu  1 2 3\nbtime 1761800000\n");
        fx.write("proc/1/stat", Fixture::statLine(1, "systemd", 'S', 0, 0, 1, 1, 1, 10));
        inspectors.setNames(
            [](int pid, quint64 start) { return pid == 1 && (start == 10 || start == 0) ? QStringLiteral("System Manager") : QString(); },
            [](uint32_t uid) { return uid == kMe ? QStringLiteral("alice") : QStringLiteral("bob"); });
    }
};

} // namespace

TEST(Inspection, AnOwnProcessHeaderAndTabs)
{
    Registry r;
    r.fx.inspectable(300, 5000, kMe, 100);
    QSignalSpy opened(&r.inspectors, &Inspectors::opened);
    Inspection *i = r.inspectors.open(300, 5000, QStringLiteral("Worker"));
    ASSERT_NE(i, nullptr);
    EXPECT_EQ(opened.count(), 1);
    EXPECT_EQ(i->title(), QStringLiteral("Worker (300)"));
    EXPECT_EQ(i->key(), QStringLiteral("300:5000"));
    EXPECT_FALSE(i->ready()); // nothing read before the window is on screen
    EXPECT_EQ(i->cpuText(), dash());

    i->setShown(true); // no worker: the read is done at once
    ASSERT_TRUE(i->ready());
    EXPECT_EQ(i->parentText(), QStringLiteral("System Manager (1)"));
    EXPECT_TRUE(i->canInspectParent());
    EXPECT_EQ(i->groupText(), QStringLiteral("Worker (300)"));
    EXPECT_EQ(i->userText(), QStringLiteral("alice (1000)"));
    EXPECT_EQ(i->cpuText(), dash()); // one read: no share yet
    EXPECT_EQ(i->hangsText(), dash()); // no projection before step 3
    const QLocale l;
    EXPECT_EQ(valueOf(i->memoryRows(), QStringLiteral("Real Memory Size:")), formatBytes(8000.0 * 1024, l));
    EXPECT_EQ(valueOf(i->memoryRows(), QStringLiteral("Private Memory Size:")), formatBytes(3000.0 * 1024, l));
    EXPECT_EQ(valueOf(i->memoryRows(), QStringLiteral("Proportional Memory Size:")), formatBytes(2500.0 * 1024, l));
    EXPECT_EQ(valueOf(i->memoryRows(), QStringLiteral("Compressed Memory:")), formatBytes(512.0 * 1024, l));
    r.inspectors.setSwappedMemory(true); // AM34: the table's title for VmSwap
    EXPECT_EQ(valueOf(i->memoryRows(), QStringLiteral("Swapped Memory:")), formatBytes(512.0 * 1024, l));

    // A tab chosen is read at once.
    i->setTab(QStringLiteral("statistics"));
    EXPECT_EQ(valueOf(i->statisticsRows(), QStringLiteral("Threads:")), QStringLiteral("2"));
    EXPECT_EQ(valueOf(i->statisticsRows(), QStringLiteral("Voluntary Context Switches:")), QStringLiteral("42"));
    EXPECT_EQ(valueOf(i->statisticsRows(), QStringLiteral("Read Calls:")), QStringLiteral("31"));
    EXPECT_EQ(valueOf(i->statisticsRows(), QStringLiteral("Nice:")), QStringLiteral("-5"));
    EXPECT_EQ(valueOf(i->statisticsRows(), QStringLiteral("Scheduler Policy:")), QStringLiteral("Normal"));
    EXPECT_EQ(valueOf(i->statisticsRows(), QStringLiteral("Unit:")), QStringLiteral("app-Hyprland-foot@1a2b3c4d.service"));
    EXPECT_EQ(valueOf(i->statisticsRows(), QStringLiteral("Command:")), QStringLiteral("/usr/bin/worker --quiet"));
    EXPECT_EQ(valueOf(i->statisticsRows(), QStringLiteral("Executable:")), QStringLiteral("/usr/bin/worker"));
    EXPECT_EQ(valueOf(i->statisticsRows(), QStringLiteral("Working Folder:")), QStringLiteral("/home/alice/projects"));
    // The Memory tab's last values stay meanwhile (no "—" between a tab and its read).
    EXPECT_EQ(valueOf(i->memoryRows(), QStringLiteral("Proportional Memory Size:")), formatBytes(2500.0 * 1024, l));

    i->setTab(QStringLiteral("files"));
    EXPECT_EQ(fileTexts(i->files()), (QStringList{QStringLiteral("0 /home/alice/notes.txt"), QStringLiteral("1 Pipe"),
                                                  QStringLiteral("3 TCP 127.0.0.1:8080 (listening)"),
                                                  QStringLiteral("4 TCP [::1]:54321 to [::ffff:10.0.0.10]:443"),
                                                  QStringLiteral("5 Local socket /run/user/1000/bus"),
                                                  QStringLiteral("10 anon_inode:[eventfd]"), QStringLiteral("11 socket:[7999]")}));
    EXPECT_EQ(i->filesNote(), QString());

    // AM59: Quit acts on this process with AM50's rules.
    auto *actions = qobject_cast<ProcessActions *>(i->actions());
    EXPECT_TRUE(actions->canQuit());
    EXPECT_EQ(actions->refusal(), QString());

    // A second request gives the same inspection (its window comes forward).
    EXPECT_EQ(r.inspectors.open(300, 5000), i);
    EXPECT_EQ(opened.count(), 2);
    EXPECT_EQ(opened.last().at(0).value<QObject *>(), i);
    EXPECT_EQ(r.inspectors.count(), 1);
}

TEST(Inspection, AnotherOwnersProcess)
{
    Registry r;
    r.fx.inspectable(400, 6000, 2000, 100);
    Inspection *i = r.inspectors.open(400, 6000, QStringLiteral("daemon"));
    ASSERT_NE(i, nullptr);
    i->setShown(true);
    EXPECT_EQ(i->userText(), QStringLiteral("bob (2000)"));
    EXPECT_NE(valueOf(i->memoryRows(), QStringLiteral("Real Memory Size:")), dash());
    EXPECT_EQ(valueOf(i->memoryRows(), QStringLiteral("Proportional Memory Size:")), dash());
    i->setTab(QStringLiteral("statistics"));
    EXPECT_EQ(valueOf(i->statisticsRows(), QStringLiteral("Threads:")), QStringLiteral("2"));
    EXPECT_EQ(valueOf(i->statisticsRows(), QStringLiteral("Voluntary Context Switches:")), QStringLiteral("42"));
    for (const char *label : {"Read Calls:", "Write Calls:", "Unit:", "Command:", "Executable:", "Working Folder:"})
        EXPECT_EQ(valueOf(i->statisticsRows(), QString::fromLatin1(label)), dash()) << label;
    i->setTab(QStringLiteral("files"));
    EXPECT_TRUE(i->files().isEmpty());
    EXPECT_EQ(i->filesNote(), QStringLiteral("The open files of another user's process can't be read."));
    auto *actions = qobject_cast<ProcessActions *>(i->actions());
    EXPECT_FALSE(actions->canQuit()); // AM57: Quit disabled, with AM50's reason
    EXPECT_EQ(actions->refusal(), QStringLiteral("You can only quit your own processes."));
}

TEST(Inspection, TheParentOpensItsOwnAndAnEndedProcessClosesItsWindow)
{
    Registry r;
    r.fx.inspectable(300, 5000, kMe, 100);
    EXPECT_EQ(r.inspectors.open(300, 4000), nullptr); // AM51: not this process
    Inspection *i = r.inspectors.open(300, 5000, QStringLiteral("Worker"));
    ASSERT_NE(i, nullptr);
    i->setShown(true);
    QSignalSpy opened(&r.inspectors, &Inspectors::opened);
    i->inspectParent();
    ASSERT_EQ(opened.count(), 1);
    auto *parent = qobject_cast<Inspection *>(opened.at(0).at(0).value<QObject *>());
    ASSERT_NE(parent, nullptr);
    EXPECT_EQ(parent->title(), QStringLiteral("System Manager (1)"));
    EXPECT_EQ(r.inspectors.count(), 2);

    // AD45: the process ended; its window closes.
    QSignalSpy ended(i, &Inspection::ended);
    r.fx.remove("proc/300");
    i->setTab(QStringLiteral("statistics"));
    EXPECT_EQ(ended.count(), 1);
    r.inspectors.close(i);
    EXPECT_EQ(r.inspectors.count(), 1);
}

TEST(Inspection, ReadsOnTheWorkersThreadOnlyWhileShown)
{
    Registry r;
    r.fx.inspectable(300, 5000, kMe, 100);
    QThread thread;
    auto *worker = new QObject;
    worker->moveToThread(&thread);
    QObject::connect(&thread, &QThread::finished, worker, &QObject::deleteLater);
    thread.start();
    r.inspectors.setWorker(worker);
    r.inspectors.setInterval(1);

    Inspection *i = r.inspectors.open(300, 5000, QStringLiteral("Worker"));
    ASSERT_NE(i, nullptr);
    QSignalSpy changed(i, &Inspection::changed);
    i->setShown(true);
    EXPECT_FALSE(i->ready()); // read on the worker's thread, delivered later
    ASSERT_TRUE(changed.wait(3000));
    EXPECT_TRUE(i->ready());
    // A second later, then each interval: the % CPU comes with the second read.
    ASSERT_TRUE(changed.wait(3000));
    EXPECT_NE(i->cpuText(), dash());

    i->setShown(false);
    changed.wait(300); // a read asked for while it was shown may still come back
    changed.clear();
    EXPECT_FALSE(changed.wait(2500)); // AM8: nothing read off screen

    // Closed while its read runs: the read goes nowhere.
    i->setShown(true);
    r.inspectors.close(i);
    QCoreApplication::processEvents();
    QThread::msleep(100);
    QCoreApplication::processEvents();
    EXPECT_EQ(r.inspectors.count(), 0);
    thread.quit();
    thread.wait();
}

// Mutant N8 of step 2d: a read asked for while one runs (a tab chosen) is not made once the window has gone off screen.
TEST(Inspection, AReadAskedForMeanwhileIsDroppedOffScreen)
{
    Registry r;
    r.fx.inspectable(300, 5000, kMe, 100);
    QThread thread;
    auto *worker = new QObject;
    worker->moveToThread(&thread);
    QObject::connect(&thread, &QThread::finished, worker, &QObject::deleteLater);
    thread.start();
    r.inspectors.setWorker(worker);
    Inspection *i = r.inspectors.open(300, 5000, QStringLiteral("Worker"));
    ASSERT_NE(i, nullptr);
    // The worker's thread is busy for a while: the window's first read waits behind it.
    QMetaObject::invokeMethod(worker, [] { QThread::msleep(300); }, Qt::QueuedConnection);
    QSignalSpy changed(i, &Inspection::changed);
    i->setShown(true);                         // a read asked for
    i->setTab(QStringLiteral("statistics"));   // one more while it runs
    i->setShown(false);                        // off screen before either is made
    changed.clear();                           // setTab's own signal
    ASSERT_TRUE(changed.wait(3000));           // the first read comes back
    EXPECT_FALSE(changed.wait(1500));          // and nothing more is read
    EXPECT_EQ(changed.count(), 1);
    r.inspectors.close(i);
    thread.quit();
    thread.wait();
}

TEST(Inspection, TheAppOpensTheSelectedRowOrADoubleClickedOne)
{
    Fixture f;
    f.process(100, "mine", kMe, 100, 1, std::string("mine\0", 5), "/");
    f.process(101, "other", kMe, 50, 1, std::string("other\0", 6), "/");
    f.process(2, "kthreadd", 0, 5, 1, "", "/", kPfKthread); // the Kernel row
    QTemporaryDir config, state;
    qputenv("GRASSFIELD_CONFIG_HOME", config.path().toUtf8());
    Options o;
    o.procRoot = f.proc();
    o.sysRoot = f.sys();
    o.uid = kMe;
    o.clockTicks = 100;
    o.maxKeptFiles = 4096;
    ActivityApp app(o, state.path() + QStringLiteral("/activity.json"));
    QSignalSpy sampled(&app, &ActivityApp::sampled);
    app.setWindowShown(true);
    ASSERT_TRUE(sampled.wait(5000));
    ProcessTable &table = app.processTable();
    QSignalSpy requested(&app, &ActivityApp::inspectRequested);

    EXPECT_FALSE(app.canInspect()); // nothing selected
    int mine = -1, kernel = -1;
    for (int row = 0; row < table.count(); ++row) {
        const TableRow *t = table.rowAt(row);
        if (t && t->kernel)
            kernel = row;
        else if (t && t->process.pid == 100)
            mine = row;
    }
    ASSERT_GE(mine, 0);
    ASSERT_GE(kernel, 0);
    table.click(mine, 0);
    EXPECT_TRUE(app.canInspect());
    app.inspectSelection();
    ASSERT_EQ(requested.count(), 1);
    auto *i = qobject_cast<Inspection *>(requested.at(0).at(0).value<QObject *>());
    ASSERT_NE(i, nullptr);
    EXPECT_EQ(i->pid(), 100);
    app.inspectRow(mine); // a double-click on the same row: the same window
    ASSERT_EQ(requested.count(), 2);
    EXPECT_EQ(requested.at(1).at(0).value<QObject *>(), i);

    table.click(kernel, 0); // AM3: not the Kernel row
    EXPECT_FALSE(app.canInspect());
    app.inspectSelection();
    app.inspectRow(kernel);
    EXPECT_EQ(requested.count(), 2);
    table.selectAll(); // one row only
    EXPECT_FALSE(app.canInspect());

    app.closeInspection(i);
    EXPECT_EQ(app.inspectors().count(), 0);
}

// The rows change in place (the window keeps its scroll position at each read, as the table, AM11): a changed row is
// signalled, the count grows or shrinks at the end, never a reset; one role, read by a delegate as `modelData`.
TEST(Inspection, TheRowsChangeInPlace)
{
    InspectRows rows;
    QAbstractItemModelTester tester(&rows, QAbstractItemModelTester::FailureReportingMode::Fatal);
    QSignalSpy reset(&rows, &QAbstractItemModel::modelReset);
    QSignalSpy changed(&rows, &QAbstractItemModel::dataChanged);
    QSignalSpy inserted(&rows, &QAbstractItemModel::rowsInserted);
    QSignalSpy removed(&rows, &QAbstractItemModel::rowsRemoved);
    const auto pair = [](const char *label, const char *value) {
        return QVariant(QVariantMap{{QStringLiteral("label"), QString::fromLatin1(label)}, {QStringLiteral("value"), QString::fromLatin1(value)}});
    };
    rows.setRows({pair("A:", "1"), pair("B:", "2"), pair("C:", "3")});
    EXPECT_EQ(inserted.count(), 1);
    rows.setRows({pair("A:", "1"), pair("B:", "5"), pair("C:", "3")});
    ASSERT_EQ(changed.count(), 1);
    EXPECT_EQ(changed.at(0).at(0).toModelIndex().row(), 1);
    EXPECT_EQ(changed.at(0).at(1).toModelIndex().row(), 1);
    rows.setRows({pair("A:", "1"), pair("B:", "5"), pair("C:", "3")});
    EXPECT_EQ(changed.count(), 1); // nothing changed, nothing signalled
    rows.setRows({pair("A:", "1"), pair("B:", "5"), pair("C:", "3"), pair("D:", "4")});
    EXPECT_EQ(inserted.count(), 2);
    EXPECT_EQ(inserted.last().at(1).toInt(), 3);
    rows.setRows({pair("A:", "9")});
    EXPECT_EQ(removed.count(), 1);
    EXPECT_EQ(removed.last().at(1).toInt(), 1);
    EXPECT_EQ(reset.count(), 0);
    EXPECT_EQ(rows.rowCount(), 1);
    EXPECT_EQ(rows.roleNames().size(), 1); // one role: QML's `modelData`
    EXPECT_EQ(rows.data(rows.index(0), rows.roleNames().constBegin().key()).toMap().value(QStringLiteral("value")).toString(),
              QStringLiteral("9"));
}

// AM60, AM17, AM27, AM12, AM57 (step 3): the shell's projection, read from the display's runtime folder. A process that owns
// a window takes its app's desktop entry name and icon, one the shell marks shows " (Not Responding)" and counts a hang
// each time the mark comes back; Windowed Processes lists the windowed ones; without a projection Recent hangs is "—".
TEST(Inspection, TheShellsProjectionNamesMarksAndCountsHangs)
{
    Fixture f;
    f.process(100, "editor", kMe, 100, 1, std::string("editor\0", 7), "/");
    f.process(101, "helper", kMe, 50, 1, std::string("helper\0", 7), "/");
    f.write("proc/700/stat", Fixture::statLine(700, "quickshell", 'S', 1, 0, 1, 1, 4, 9000)); // the shell, the writer
    QTemporaryDir config, state, runtime, data;
    qputenv("GRASSFIELD_CONFIG_HOME", config.path().toUtf8());
    const QByteArray runtimeBefore = qgetenv("XDG_RUNTIME_DIR"), displayBefore = qgetenv("WAYLAND_DISPLAY"),
                     dataBefore = qgetenv("XDG_DATA_DIRS"), homeBefore = qgetenv("XDG_DATA_HOME");
    qputenv("XDG_RUNTIME_DIR", runtime.path().toUtf8());
    qputenv("WAYLAND_DISPLAY", "wayland-test");
    qputenv("XDG_DATA_HOME", (data.path() + QStringLiteral("/none")).toUtf8());
    qputenv("XDG_DATA_DIRS", data.path().toUtf8());
    QDir().mkpath(data.path() + QStringLiteral("/applications"));
    QFile entry(data.path() + QStringLiteral("/applications/org.example.Editor.desktop"));
    ASSERT_TRUE(entry.open(QIODevice::WriteOnly));
    entry.write("[Desktop Entry]\nType=Application\nName=Example Editor\nIcon=accessories-text-editor\nExec=editor\n");
    entry.close();
    const QString folder = runtimeFolder();
    ASSERT_TRUE(QDir().mkpath(folder));
    const auto write = [&](const char *hung) {
        QFile out(folder + QStringLiteral("/windows.json"));
        ASSERT_TRUE(out.open(QIODevice::WriteOnly | QIODevice::Truncate));
        out.write(QByteArray(R"({"v":1,"writer":{"pid":700,"start":9000},"windows":[{"pid":100,"app":"org.example.Editor","idleInhibit":true}],"notResponding":[)")
                  + hung + "]}");
    };
    write("100");
    Options o;
    o.procRoot = f.proc();
    o.sysRoot = f.sys();
    o.uid = kMe;
    o.clockTicks = 100;
    o.maxKeptFiles = 4096;
    {
        ActivityApp app(o, state.path() + QStringLiteral("/activity.json"));
        QSignalSpy sampled(&app, &ActivityApp::sampled);
        app.setWindowShown(true);
        ASSERT_TRUE(sampled.wait(5000));
        const TableRow *editor = app.processTable().processRow(100, 0);
        ASSERT_NE(editor, nullptr);
        EXPECT_TRUE(editor->windowed);
        EXPECT_TRUE(editor->notResponding);
        EXPECT_TRUE(editor->preventingSleep); // its window inhibits idle (AM38)
        EXPECT_EQ(editor->name, QStringLiteral("Example Editor"));
        EXPECT_EQ(editor->icon, QStringLiteral("accessories-text-editor"));
        EXPECT_EQ(app.processTable().cellText(*editor, Column::Name), QStringLiteral("Example Editor (Not Responding)"));
        const TableRow *helper = app.processTable().processRow(101, 0);
        ASSERT_NE(helper, nullptr);
        EXPECT_FALSE(helper->windowed);
        app.setView(QStringLiteral("windowed"));
        ASSERT_EQ(app.processTable().count(), 1);
        EXPECT_EQ(app.processTable().rowAt(0)->process.pid, 100);

        // AM57: the mark goes and comes back: two hangs.
        Inspection *i = app.inspectors().open(100, editor->process.start, editor->name);
        ASSERT_NE(i, nullptr);
        EXPECT_EQ(i->hangsText(), QStringLiteral("1"));
        write("");
        app.inspectors().namesChanged();
        ASSERT_TRUE(sampled.wait(7000)); // the next sample reads the projection again
        write("100");
        ASSERT_TRUE(sampled.wait(7000));
        EXPECT_EQ(i->hangsText(), QStringLiteral("2"));

        // The shell's file goes (its last window closed): no projection, nothing marked, "—".
        QFile::remove(folder + QStringLiteral("/windows.json"));
        ASSERT_TRUE(sampled.wait(7000));
        EXPECT_FALSE(app.processTable().processRow(100, 0)->notResponding);
        EXPECT_EQ(i->hangsText(), dash());
    }
    const auto restore = [](const char *name, const QByteArray &value) { value.isNull() ? qunsetenv(name) : qputenv(name, value); };
    restore("XDG_RUNTIME_DIR", runtimeBefore);
    restore("WAYLAND_DISPLAY", displayBefore);
    restore("XDG_DATA_DIRS", dataBefore);
    restore("XDG_DATA_HOME", homeBefore);
}
