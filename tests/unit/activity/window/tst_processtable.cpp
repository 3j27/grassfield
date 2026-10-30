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

namespace {

TableRow child(int pid, int ppid, const char *name, double cpu, uint64_t start = 10)
{
    TableRow r = proc(pid, name, cpu, true, start);
    r.process.ppid = ppid;
    return r;
}

QList<int> depths(const ProcessTable &t)
{
    QList<int> list;
    for (int i = 0; i < t.count(); ++i)
        list << t.data(t.index(i), ProcessTable::DepthRole).toInt();
    return list;
}

TableRow gpuClient(int pid, const char *name, double cpu, std::vector<std::string> pdevs)
{
    TableRow r = proc(pid, name, cpu);
    r.process.gpuDevices = std::move(pdevs);
    r.process.hasGpu = true;
    return r;
}

} // namespace

// AM13: a tree by parent pid, each level sorted; the Kernel row and a row whose parent is not listed are roots; a parent
// younger than its child (its pid was reused) is not its parent.
TEST(ProcessTable, HierarchicallyIsATreeSortedByLevel)
{
    Fixture f;
    f.table.setView(View::Tree);
    f.table.setRows({child(1, 0, "systemd", 0.1, 1), child(50, 1, "sshd", 0.5), child(60, 50, "bash", 3, 20),
                     child(70, 1, "Hyprland", 9), child(80, 70, "foot", 2, 30), child(90, 999, "orphan", 1),
                     child(100, 60, "reused", 7, 5), kernelRow(4)});
    EXPECT_EQ(names(f.table), (QStringList{"reused", "Kernel", "orphan", "systemd", "Hyprland", "foot", "sshd", "bash"}));
    EXPECT_EQ(depths(f.table), (QList<int>{0, 0, 0, 0, 1, 2, 1, 2}));
    EXPECT_TRUE(f.table.data(f.table.index(3), ProcessTable::ExpandableRole).toBool());  // systemd
    EXPECT_FALSE(f.table.data(f.table.index(5), ProcessTable::ExpandableRole).toBool()); // foot
    EXPECT_FALSE(f.table.data(f.table.index(3), ProcessTable::GroupRole).toBool());
    EXPECT_EQ(f.table.shownRows().size(), 8u);
}

// AM13: a collapsed row hides its children, and stays collapsed across samples while its process lives; the selection of a
// hidden row goes (AM11).
TEST(ProcessTable, CollapsedStaysCollapsedAcrossSamples)
{
    Fixture f;
    f.table.setView(View::Tree);
    const std::vector<TableRow> sample{child(1, 0, "systemd", 0.1, 1), child(70, 1, "Hyprland", 9), child(80, 70, "foot", 2, 30)};
    f.table.setRows(sample);
    f.table.click(2, Qt::NoModifier); // foot
    EXPECT_EQ(f.table.selectedCount(), 1);
    f.table.setExpanded(1, false); // Hyprland
    EXPECT_EQ(names(f.table), (QStringList{"systemd", "Hyprland"}));
    EXPECT_FALSE(f.table.data(f.table.index(1), ProcessTable::ExpandedRole).toBool());
    EXPECT_EQ(f.table.selectedCount(), 0);
    f.table.setRows(sample); // the next sample
    EXPECT_EQ(names(f.table), (QStringList{"systemd", "Hyprland"}));
    f.table.toggleExpanded(1);
    EXPECT_EQ(names(f.table), (QStringList{"systemd", "Hyprland", "foot"}));
    f.table.setExpanded(2, false); // foot has no children: nothing to collapse
    EXPECT_EQ(f.table.count(), 3);
    // Hyprland's process ends and another takes its pid: the new one is not collapsed.
    f.table.setExpanded(1, false);
    f.table.setRows({child(1, 0, "systemd", 0.1, 1)});
    f.table.setRows({child(1, 0, "systemd", 0.1, 1), child(70, 1, "Hyprland", 9, 40), child(80, 70, "foot", 2, 50)});
    EXPECT_EQ(names(f.table), (QStringList{"systemd", "Hyprland", "foot"}));
    // A collapsed row missing from a sample is forgotten then, not kept for ever (review of 91dcb63): the same process
    // back in a later sample is open.
    f.table.setExpanded(1, false);
    f.table.setRows({child(1, 0, "systemd", 0.1, 1)});
    f.table.setRows({child(1, 0, "systemd", 0.1, 1), child(70, 1, "Hyprland", 9, 40), child(80, 70, "foot", 2, 50)});
    EXPECT_EQ(names(f.table), (QStringList{"systemd", "Hyprland", "foot"}));
}

// AM14: in the tree, a row that matches keeps every row above it; the others go.
TEST(ProcessTable, HierarchicallySearchKeepsTheRowsAbove)
{
    Fixture f;
    f.table.setView(View::Tree);
    f.table.setRows({child(1, 0, "systemd", 0.1, 1), child(50, 1, "sshd", 0.5), child(60, 50, "bash", 3, 20),
                     child(70, 1, "Hyprland", 9), child(80, 70, "foot", 2, 30)});
    f.table.setSearch(QStringLiteral("foo"));
    EXPECT_EQ(names(f.table), (QStringList{"systemd", "Hyprland", "foot"}));
    EXPECT_EQ(depths(f.table), (QList<int>{0, 1, 2}));
}

// Two rows that name each other as parent (read in a race) are still listed, once each.
TEST(ProcessTable, HierarchicallyListsEveryRowOnce)
{
    Fixture f;
    f.table.setView(View::Tree);
    f.table.setRows({child(10, 20, "a", 1, 5), child(20, 10, "b", 2, 5), child(30, 0, "c", 3, 1)});
    QStringList shown = names(f.table);
    shown.sort();
    EXPECT_EQ(shown, (QStringList{"a", "b", "c"}));
}

// AM49: a header per GPU with its client processes, sorted; a process of two GPUs is under both, selected and copied once;
// a header is never selected and the keyboard passes over it; a GPU without a matching process goes (AM14).
TEST(ProcessTable, ByGpuGroupsTheClientsUnderTheirGpu)
{
    Fixture f;
    f.table.setView(View::ByGpu);
    f.table.setGpuNames({{QStringLiteral("0000:00:02.0"), QStringLiteral("Intel UHD Graphics")}});
    f.table.setRows({gpuClient(10, "game", 40, {"0000:00:02.0"}), gpuClient(20, "Hyprland", 5, {"0000:00:02.0", "0000:03:00.0"}),
                     proc(30, "no-gpu", 90), gpuClient(40, "encoder", 10, {"0000:03:00.0"}), kernelRow(1)});
    EXPECT_EQ(names(f.table), (QStringList{"Intel UHD Graphics", "game", "Hyprland", "0000:03:00.0", "encoder", "Hyprland"}));
    EXPECT_EQ(depths(f.table), (QList<int>{0, 1, 1, 0, 1, 1}));
    EXPECT_TRUE(f.table.data(f.table.index(0), ProcessTable::GroupRole).toBool());
    EXPECT_EQ(f.table.data(f.table.index(0), ProcessTable::CellsRole).toStringList(), (QStringList{"Intel UHD Graphics", "", "", ""}));
    EXPECT_EQ(f.table.data(f.table.index(0), ProcessTable::PidRole).toInt(), -1);

    f.table.click(0, Qt::NoModifier); // a header
    EXPECT_EQ(f.table.selectedCount(), 0);
    f.table.click(2, Qt::NoModifier); // Hyprland under the first GPU
    EXPECT_TRUE(f.table.data(f.table.index(5), ProcessTable::SelectedRole).toBool()); // and under the second
    f.table.moveCurrent(1, false);                                                     // passes over the second header
    EXPECT_EQ(f.table.currentRow(), 4);
    f.table.moveCurrent(-1, false);
    EXPECT_EQ(f.table.currentRow(), 2);
    f.table.selectAll();
    EXPECT_EQ(f.table.selectedCount(), 3);
    EXPECT_EQ(f.table.copyText().count(QLatin1Char('\n')), 4); // the headers' line and three processes
    // The actions' processes once each, in the table's order (step 2c, AM50).
    QStringList acted;
    for (const TableRow &r : f.table.selectedRows())
        acted << r.name;
    EXPECT_EQ(acted, (QStringList{"game", "Hyprland", "encoder"}));

    f.table.setExpanded(0, false); // the first GPU collapsed, kept across samples
    f.table.setRows({gpuClient(10, "game", 40, {"0000:00:02.0"}), gpuClient(40, "encoder", 10, {"0000:03:00.0"})});
    EXPECT_EQ(names(f.table), (QStringList{"Intel UHD Graphics", "0000:03:00.0", "encoder"}));
    f.table.setSearch(QStringLiteral("enc"));
    EXPECT_EQ(names(f.table), (QStringList{"0000:03:00.0", "encoder"}));
}

TEST(ProcessTable, TheGpuViewsReadTheGpus)
{
    EXPECT_EQ(readsForView(View::ByGpu), static_cast<unsigned>(ReadDescriptors | ReadGpu));
    EXPECT_EQ(readsForView(View::Gpu), static_cast<unsigned>(ReadDescriptors | ReadGpu));
    EXPECT_EQ(readsForView(View::Tree), 0u);
    EXPECT_EQ(viewTitle(View::Tree), QStringLiteral("All Processes, Hierarchically"));
    EXPECT_EQ(viewTitle(View::ByGpu), QStringLiteral("Processes, by GPU"));
    EXPECT_EQ(views().at(1), View::Tree);
    EXPECT_EQ(views().back(), View::ByGpu);
}
