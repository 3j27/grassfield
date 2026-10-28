// The table (spec AM10 to AM19): views, search, sort, the selection across samples by row identity, Copy, and a model that
// never resets (the list keeps its scroll position).
#include "processtable.h"

#include <QAbstractItemModelTester>
#include <QSignalSpy>

#include <gtest/gtest.h>

using namespace activity;

namespace {

TableRow proc(int pid, const char *name, double cpu, bool own = true, uint64_t start = 1)
{
    TableRow r;
    r.process.pid = pid;
    r.process.start = start;
    r.process.own = own;
    r.process.uid = own ? 1000 : 1001;
    r.process.cpuPercent = cpu;
    r.process.threads = 1;
    r.name = QString::fromLatin1(name);
    r.user = own ? QStringLiteral("alice") : QStringLiteral("bob");
    return r;
}

TableRow kernelRow(double cpu)
{
    TableRow r;
    r.kernel = true;
    r.process.systemAccount = true;
    r.process.cpuPercent = cpu;
    r.process.threads = 120;
    r.user = QStringLiteral("root");
    return r;
}

QStringList names(const ProcessTable &t)
{
    QStringList list;
    for (int i = 0; i < t.count(); ++i)
        list << t.data(t.index(i), ProcessTable::NameRole).toString();
    return list;
}

struct Fixture {
    ProcessTable table;
    QAbstractItemModelTester tester{&table, QAbstractItemModelTester::FailureReportingMode::Fatal};
    Fixture()
    {
        table.setLocale(QLocale(QLocale::English, QLocale::UnitedStates));
        table.setColumns({Column::Name, Column::CpuPercent, Column::Pid, Column::User});
        table.setSort(Column::CpuPercent, true);
    }
};

} // namespace

TEST(ProcessTable, SortedByTheColumnTiesByPid)
{
    Fixture f;
    f.table.setRows({proc(30, "c", 5), proc(10, "a", 50), proc(20, "b", 5), kernelRow(2), proc(40, "d", -1)});
    // The first sample of a process has no rate ("—"): it sorts below every value (AM20).
    EXPECT_EQ(names(f.table), (QStringList{"a", "b", "c", "Kernel", "d"}));
    f.table.setSort(Column::CpuPercent, false);
    EXPECT_EQ(names(f.table), (QStringList{"d", "Kernel", "b", "c", "a"}));
    f.table.setSort(Column::Name, false);
    EXPECT_EQ(names(f.table), (QStringList{"a", "b", "c", "d", "Kernel"}));
    EXPECT_EQ(f.table.data(f.table.index(0), ProcessTable::CellsRole).toStringList(), (QStringList{"a", "50.0", "10", "alice"}));
    const QStringList kernel = f.table.data(f.table.index(4), ProcessTable::CellsRole).toStringList();
    EXPECT_EQ(kernel, (QStringList{"Kernel", "2.0", "—", "root"})); // AM20a: no pid
}

TEST(ProcessTable, ViewsAndSearch)
{
    Fixture f;
    TableRow daemon = proc(5, "systemd-journald", 0, false);
    daemon.process.systemAccount = true;
    daemon.user = QStringLiteral("root");
    TableRow gpu = proc(7, "game", 30);
    gpu.process.gpuDevices = {"0000:00:02.0"};
    TableRow firefox = proc(1234, "firefox", 10);
    firefox.appName = QStringLiteral("Firefox Web Browser");
    firefox.process.command = "/usr/lib/firefox/firefox --private-window";
    TableRow theirs = proc(900, "sshd", 1, false);
    theirs.process.command = "secret-should-never-match"; // AD25: another owner's command never matches (it is never read)
    f.table.setRows({kernelRow(1), daemon, gpu, firefox, theirs});

    f.table.setView(View::Mine);
    EXPECT_EQ(names(f.table), (QStringList{"game", "firefox"}));
    f.table.setView(View::System);
    EXPECT_EQ(names(f.table), (QStringList{"Kernel", "systemd-journald"}));
    f.table.setView(View::OtherUsers);
    EXPECT_EQ(names(f.table), (QStringList{"sshd"}));
    f.table.setView(View::Active);
    EXPECT_EQ(names(f.table), (QStringList{"game", "firefox", "Kernel", "sshd"}));
    f.table.setView(View::Inactive);
    EXPECT_EQ(names(f.table), (QStringList{"systemd-journald"}));
    f.table.setView(View::Gpu);
    EXPECT_EQ(names(f.table), (QStringList{"game"}));
    f.table.setView(View::All);

    // AM14: the name, the app's name, the user, an own command, or a pid's first digits; case-insensitive.
    f.table.setSearch(QStringLiteral("FIRE"));
    EXPECT_EQ(names(f.table), (QStringList{"firefox"}));
    f.table.setSearch(QStringLiteral("web browser"));
    EXPECT_EQ(names(f.table), (QStringList{"firefox"}));
    f.table.setSearch(QStringLiteral("private-window"));
    EXPECT_EQ(names(f.table), (QStringList{"firefox"}));
    f.table.setSearch(QStringLiteral("secret"));
    EXPECT_TRUE(names(f.table).isEmpty());
    f.table.setSearch(QStringLiteral("bob"));
    EXPECT_EQ(names(f.table), (QStringList{"sshd"}));
    f.table.setSearch(QStringLiteral("12"));
    EXPECT_EQ(names(f.table), (QStringList{"firefox"}));
    f.table.setSearch(QStringLiteral("23")); // a pid that starts with the digits, not one that holds them
    EXPECT_TRUE(names(f.table).isEmpty());
    f.table.setSearch(QString());
    EXPECT_EQ(f.table.count(), 5);
}

TEST(ProcessTable, TheSelectionFollowsItsProcesses)
{
    Fixture f;
    f.table.setRows({proc(10, "a", 30), proc(20, "b", 20), proc(30, "c", 10)});
    f.table.click(1, Qt::NoModifier); // b
    f.table.click(2, Qt::ControlModifier); // and c
    EXPECT_EQ(f.table.selectedCount(), 2);

    // A new sample re-sorts the rows: the selection stays on b and c wherever they go (AM11).
    f.table.setRows({proc(10, "a", 1), proc(20, "b", 40), proc(30, "c", 10), proc(40, "d", 20)});
    EXPECT_EQ(names(f.table), (QStringList{"b", "d", "c", "a"}));
    EXPECT_TRUE(f.table.data(f.table.index(0), ProcessTable::SelectedRole).toBool());
    EXPECT_FALSE(f.table.data(f.table.index(1), ProcessTable::SelectedRole).toBool());
    EXPECT_TRUE(f.table.data(f.table.index(2), ProcessTable::SelectedRole).toBool());

    // c ends; its pid comes back as another process (another start time): a new row, not selected.
    f.table.setRows({proc(10, "a", 1), proc(20, "b", 40), proc(30, "c2", 50, true, 999)});
    EXPECT_EQ(f.table.selectedCount(), 1);
    EXPECT_EQ(names(f.table), (QStringList{"c2", "b", "a"}));
    EXPECT_FALSE(f.table.data(f.table.index(0), ProcessTable::SelectedRole).toBool());

    // A row the search hides leaves the selection: no action applies to a row out of sight.
    f.table.setSearch(QStringLiteral("c2"));
    EXPECT_EQ(f.table.selectedCount(), 0);
}

TEST(ProcessTable, ShiftAndKeyboardExtend)
{
    Fixture f;
    f.table.setRows({proc(10, "a", 50), proc(20, "b", 40), proc(30, "c", 30), proc(40, "d", 20)});
    f.table.click(0, Qt::NoModifier);
    f.table.click(2, Qt::ShiftModifier);
    EXPECT_EQ(f.table.selectedCount(), 3);
    f.table.moveCurrent(1, true); // Shift+Down: from the anchor to d
    EXPECT_EQ(f.table.selectedCount(), 4);
    EXPECT_EQ(f.table.currentRow(), 3);
    f.table.moveCurrent(-10, false); // Home
    EXPECT_EQ(f.table.selectedCount(), 1);
    EXPECT_EQ(f.table.currentRow(), 0);
    f.table.selectAll();
    EXPECT_EQ(f.table.selectedCount(), 4);
    f.table.clearSelection();
    EXPECT_EQ(f.table.selectedCount(), 0);
}

TEST(ProcessTable, SelectedProcessesViewKeepsItsRows)
{
    Fixture f;
    f.table.setRows({proc(10, "a", 50), proc(20, "b", 40), proc(30, "c", 30)});
    f.table.click(0, Qt::NoModifier);
    f.table.click(2, Qt::ControlModifier);
    f.table.setView(View::Selected);
    EXPECT_EQ(names(f.table), (QStringList{"a", "c"}));
    f.table.setRows({proc(10, "a", 50), proc(20, "b", 40), proc(30, "c", 30), proc(40, "d", 60)});
    EXPECT_EQ(names(f.table), (QStringList{"a", "c"})); // kept until another view (AM12)
}

TEST(ProcessTable, CopyAsShown)
{
    Fixture f;
    f.table.setRows({proc(10, "a", 50), proc(20, "b", 40.04)});
    f.table.selectAll();
    EXPECT_EQ(f.table.copyText(), "Process Name\t% CPU\tPID\tUser\na\t50.0\t10\talice\nb\t40.0\t20\talice\n");
}

TEST(ProcessTable, AnotherOwnersRowAndTheKernelsDashes)
{
    Fixture f;
    f.table.setColumns({Column::Name, Column::GpuPercent, Column::SentBytes, Column::Command, Column::Kind, Column::BytesRead});
    TableRow mine = proc(10, "mine", 1);
    mine.process.command = "mine --flag";
    f.table.setRows({mine, proc(20, "theirs", 1, false), kernelRow(1)});
    f.table.setSort(Column::Name, false);
    // Own: no GPU client is 0.0; no socket is 0 bytes; no io read yet is "—" (AM16, AM41, AM43, AM46).
    EXPECT_EQ(f.table.data(f.table.index(1), ProcessTable::CellsRole).toStringList(),
              (QStringList{"mine", "0.0", "0 bytes", "mine --flag", "Background", "—"}));
    EXPECT_EQ(f.table.data(f.table.index(2), ProcessTable::CellsRole).toStringList(), (QStringList{"theirs", "—", "—", "—", "—", "—"}));
    EXPECT_EQ(f.table.data(f.table.index(0), ProcessTable::CellsRole).toStringList(), (QStringList{"Kernel", "—", "—", "—", "—", "—"}));
}

TEST(ProcessTable, NeverResetsAndKeepsPersistentIndexes)
{
    Fixture f;
    QSignalSpy resets(&f.table, &QAbstractItemModel::modelReset);
    f.table.setRows({proc(10, "a", 50), proc(20, "b", 40), proc(30, "c", 30)});
    const QPersistentModelIndex b(f.table.index(1));
    f.table.setRows({proc(10, "a", 10), proc(20, "b", 60), proc(30, "c", 30), proc(50, "e", 5)});
    ASSERT_TRUE(b.isValid());
    EXPECT_EQ(b.row(), 0); // b moved to the top, its index with it
    f.table.setRows({proc(20, "b", 60)});
    EXPECT_EQ(b.row(), 0);
    EXPECT_EQ(resets.count(), 0);
}
