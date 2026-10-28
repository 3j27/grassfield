#include "columns.h"

#include <QCoreApplication>

namespace activity {

namespace {

struct ColumnInfo {
    Column column;
    const char *key;
    const char *title;
    bool numeric;
    unsigned reads;
};

// Titles as macOS 27 words them; the Network tab's say "(TCP)" (owner, AQ2). Translated in the "ActivityColumn" context.
const ColumnInfo kColumns[] = {
    {Column::Name, "name", QT_TRANSLATE_NOOP("ActivityColumn", "Process Name"), false, 0},
    {Column::CpuPercent, "cpuPercent", QT_TRANSLATE_NOOP("ActivityColumn", "% CPU"), true, 0},
    {Column::CpuTime, "cpuTime", QT_TRANSLATE_NOOP("ActivityColumn", "CPU Time"), true, 0},
    {Column::Threads, "threads", QT_TRANSLATE_NOOP("ActivityColumn", "Threads"), true, 0},
    {Column::WakeUps, "wakeUps", QT_TRANSLATE_NOOP("ActivityColumn", "Wake Ups"), true, ReadThreads},
    {Column::GpuPercent, "gpuPercent", QT_TRANSLATE_NOOP("ActivityColumn", "% GPU"), true, ReadDescriptors | ReadGpu},
    {Column::GpuTime, "gpuTime", QT_TRANSLATE_NOOP("ActivityColumn", "GPU Time"), true, ReadDescriptors | ReadGpu},
    {Column::OpenFiles, "openFiles", QT_TRANSLATE_NOOP("ActivityColumn", "Open Files"), true, ReadDescriptors},
    {Column::Kind, "kind", QT_TRANSLATE_NOOP("ActivityColumn", "Kind"), false, 0},
    {Column::Command, "command", QT_TRANSLATE_NOOP("ActivityColumn", "Command"), false, ReadCommand},
    {Column::Memory, "memory", QT_TRANSLATE_NOOP("ActivityColumn", "Memory"), true, 0},
    {Column::RealMemory, "realMemory", QT_TRANSLATE_NOOP("ActivityColumn", "Real Memory"), true, 0},
    {Column::PrivateMemory, "privateMemory", QT_TRANSLATE_NOOP("ActivityColumn", "Private Memory"), true, 0},
    {Column::SharedMemory, "sharedMemory", QT_TRANSLATE_NOOP("ActivityColumn", "Shared Memory"), true, 0},
    {Column::CompressedMemory, "compressedMemory", QT_TRANSLATE_NOOP("ActivityColumn", "Compressed Memory"), true, 0},
    {Column::PeakMemory, "peakMemory", QT_TRANSLATE_NOOP("ActivityColumn", "Peak Memory"), true, 0},
    {Column::PageIns, "pageIns", QT_TRANSLATE_NOOP("ActivityColumn", "Page Ins"), true, 0},
    {Column::EnergyImpact, "energyImpact", QT_TRANSLATE_NOOP("ActivityColumn", "Energy Impact"), true, 0},
    {Column::AverageEnergyImpact, "averageEnergyImpact", QT_TRANSLATE_NOOP("ActivityColumn", "Avg Energy Impact"), true, 0},
    {Column::PreventingSleep, "preventingSleep", QT_TRANSLATE_NOOP("ActivityColumn", "Preventing Sleep"), false, 0},
    {Column::BytesWritten, "bytesWritten", QT_TRANSLATE_NOOP("ActivityColumn", "Bytes Written"), true, 0},
    {Column::BytesRead, "bytesRead", QT_TRANSLATE_NOOP("ActivityColumn", "Bytes Read"), true, 0},
    {Column::ReadRate, "readRate", QT_TRANSLATE_NOOP("ActivityColumn", "Read/s"), true, 0},
    {Column::WriteRate, "writeRate", QT_TRANSLATE_NOOP("ActivityColumn", "Written/s"), true, 0},
    {Column::SentBytes, "sentBytes", QT_TRANSLATE_NOOP("ActivityColumn", "Sent Bytes (TCP)"), true, 0},
    {Column::ReceivedBytes, "receivedBytes", QT_TRANSLATE_NOOP("ActivityColumn", "Rcvd Bytes (TCP)"), true, 0},
    {Column::SentPackets, "sentPackets", QT_TRANSLATE_NOOP("ActivityColumn", "Sent Packets (TCP)"), true, 0},
    {Column::ReceivedPackets, "receivedPackets", QT_TRANSLATE_NOOP("ActivityColumn", "Rcvd Packets (TCP)"), true, 0},
    {Column::Pid, "pid", QT_TRANSLATE_NOOP("ActivityColumn", "PID"), true, 0},
    {Column::User, "user", QT_TRANSLATE_NOOP("ActivityColumn", "User"), false, 0},
};

const ColumnInfo &info(Column column)
{
    return kColumns[static_cast<int>(column)];
}

} // namespace

const TabColumns &tabColumns(Tab tab)
{
    using C = Column;
    // ADR-0038 "What each tab reads": the defaults, then the optional ones (Status waits for step 4, Preventing Sleep's
    // window flag for step 3).
    static const TabColumns cpu{{C::Name, C::CpuPercent, C::CpuTime, C::Threads, C::WakeUps, C::GpuPercent, C::GpuTime, C::OpenFiles,
                                 C::Kind, C::Command, C::Pid, C::User},
                                {C::Name, C::CpuPercent, C::CpuTime, C::Threads, C::GpuPercent, C::GpuTime, C::Pid, C::User},
                                C::CpuPercent};
    static const TabColumns memory{{C::Name, C::Memory, C::Threads, C::RealMemory, C::PrivateMemory, C::SharedMemory, C::CompressedMemory,
                                    C::PeakMemory, C::PageIns, C::Pid, C::User},
                                   {C::Name, C::Memory, C::Threads, C::Pid, C::User},
                                   C::Memory};
    static const TabColumns energy{{C::Name, C::EnergyImpact, C::AverageEnergyImpact, C::PreventingSleep, C::WakeUps, C::GpuPercent, C::Pid,
                                    C::User},
                                   {C::Name, C::EnergyImpact, C::PreventingSleep, C::Pid, C::User},
                                   C::EnergyImpact};
    static const TabColumns disk{{C::Name, C::BytesWritten, C::BytesRead, C::ReadRate, C::WriteRate, C::Pid, C::User},
                                 {C::Name, C::BytesWritten, C::BytesRead, C::Pid, C::User},
                                 C::BytesWritten};
    static const TabColumns network{{C::Name, C::SentBytes, C::ReceivedBytes, C::SentPackets, C::ReceivedPackets, C::Pid, C::User},
                                    {C::Name, C::SentBytes, C::ReceivedBytes, C::SentPackets, C::ReceivedPackets, C::Pid, C::User},
                                    C::SentBytes};
    switch (tab) {
    case Tab::Cpu:
        return cpu;
    case Tab::Memory:
        return memory;
    case Tab::Energy:
        return energy;
    case Tab::Disk:
        return disk;
    case Tab::Network:
        return network;
    }
    return cpu;
}

QString columnKey(Column column)
{
    return QString::fromLatin1(info(column).key);
}

std::optional<Column> columnFromKey(const QString &key)
{
    for (const ColumnInfo &c : kColumns) {
        if (key == QLatin1String(c.key))
            return c.column;
    }
    return std::nullopt;
}

QString columnTitle(Column column, bool swappedMemory)
{
    if (column == Column::CompressedMemory && swappedMemory)
        return QCoreApplication::translate("ActivityColumn", "Swapped Memory");
    return QCoreApplication::translate("ActivityColumn", info(column).title);
}

bool columnIsNumeric(Column column)
{
    return info(column).numeric;
}

unsigned readsForColumns(Tab tab, const std::vector<Column> &shown)
{
    unsigned reads = readsForTab(tab);
    for (Column c : shown)
        reads |= info(c).reads;
    return reads;
}

QString tabKey(Tab tab)
{
    switch (tab) {
    case Tab::Cpu:
        return QStringLiteral("cpu");
    case Tab::Memory:
        return QStringLiteral("memory");
    case Tab::Energy:
        return QStringLiteral("energy");
    case Tab::Disk:
        return QStringLiteral("disk");
    case Tab::Network:
        return QStringLiteral("network");
    }
    return QStringLiteral("cpu");
}

std::optional<Tab> tabFromKey(const QString &key)
{
    for (Tab t : {Tab::Cpu, Tab::Memory, Tab::Energy, Tab::Disk, Tab::Network}) {
        if (tabKey(t) == key)
            return t;
    }
    return std::nullopt;
}

} // namespace activity
