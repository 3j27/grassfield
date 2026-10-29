// The table's columns (spec AM10, AM15, AM20 to AM43; ADR-0038 "What each tab reads"): each tab's columns in their
// default order, which of them show by default, the tab's default sort, and the reads a column needs beyond its tab's.
#pragma once

#include "sampler.h"

#include <QString>

#include <optional>
#include <vector>

namespace activity {

enum class Column {
    Name,
    CpuPercent,
    CpuTime,
    Threads,
    WakeUps,
    GpuPercent,
    GpuTime,
    OpenFiles,
    Kind,
    Command,
    Memory,
    RealMemory,
    PrivateMemory,
    SharedMemory,
    CompressedMemory,
    PeakMemory,
    PageIns,
    EnergyImpact,
    AverageEnergyImpact,
    PreventingSleep,
    BytesWritten,
    BytesRead,
    ReadRate,
    WriteRate,
    SentBytes,
    ReceivedBytes,
    SentPackets,
    ReceivedPackets,
    Pid,
    User,
};

struct TabColumns {
    std::vector<Column> all;      // every column of the tab, the name first, in the default order
    std::vector<Column> defaults; // the ones shown by default (macOS's; the others are View > Columns' optional ones)
    Column sort;                  // AM10: the default sort, descending
};

const TabColumns &tabColumns(Tab tab);
// A column's stable key, as activity.json keeps it ("cpuPercent", "pid").
QString columnKey(Column column);
std::optional<Column> columnFromKey(const QString &key);
// The header, translated. `swappedMemory`: a disk swap is in use, so Compressed Memory is titled Swapped Memory (AM34).
QString columnTitle(Column column, bool swappedMemory = false);
// Numbers are right-aligned and sort descending first; text (the name, the user, Kind, Command) left and ascending.
bool columnIsNumeric(Column column);
// What the sampler reads for the tab with these columns shown: the tab's reads, plus Wake Ups' thread turns and Command's
// command lines when they are shown (AD10: only what is shown is read).
unsigned readsForColumns(Tab tab, const std::vector<Column> &shown);

QString tabKey(Tab tab);
std::optional<Tab> tabFromKey(const QString &key);

} // namespace activity
