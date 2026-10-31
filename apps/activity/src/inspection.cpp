#include "inspection.h"

#include "format.h"
#include "shownwatch.h"

#include <QDateTime>
#include <QPointer>
#include <QWindow>

#include <ctime>

namespace activity {

namespace {

double monotonicSeconds()
{
    timespec ts{};
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return static_cast<double>(ts.tv_sec) + static_cast<double>(ts.tv_nsec) / 1e9;
}

QVariantMap row(const QString &label, const QString &value)
{
    return {{QStringLiteral("label"), label}, {QStringLiteral("value"), value}};
}

// "—" for an empty text (a value the kernel refused, or another owner's that is never read).
QString orDash(const std::string &text)
{
    return text.empty() ? dash() : QString::fromStdString(text);
}

QString policyName(int policy)
{
    switch (policy) {
    case 0:
        return Inspection::tr("Normal");
    case 1:
        return Inspection::tr("Real-time, first in first out");
    case 2:
        return Inspection::tr("Real-time, round robin");
    case 3:
        return Inspection::tr("Batch");
    case 5:
        return Inspection::tr("Idle");
    case 6:
        return Inspection::tr("Deadline");
    default:
        return dash();
    }
}

} // namespace

void InspectRows::setRows(const QVariantList &rows)
{
    const int before = static_cast<int>(m_rows.size()), after = static_cast<int>(rows.size());
    if (after < before) {
        beginRemoveRows(QModelIndex(), after, before - 1);
        m_rows.erase(m_rows.begin() + after, m_rows.end());
        endRemoveRows();
    }
    int first = -1, last = -1;
    for (int i = 0; i < std::min(before, after); ++i) {
        if (m_rows.at(i) != rows.at(i)) {
            m_rows[i] = rows.at(i);
            first = first < 0 ? i : first;
            last = i;
        }
    }
    if (first >= 0)
        emit dataChanged(index(first), index(last));
    if (after > before) {
        beginInsertRows(QModelIndex(), before, after - 1);
        for (int i = before; i < after; ++i)
            m_rows.append(rows.at(i));
        endInsertRows();
    }
}

int InspectRows::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : static_cast<int>(m_rows.size());
}

QVariant InspectRows::data(const QModelIndex &index, int role) const
{
    if (role != Qt::UserRole + 1 || index.row() < 0 || index.row() >= m_rows.size())
        return {};
    return m_rows.at(index.row());
}

QHash<int, QByteArray> InspectRows::roleNames() const
{
    return {{Qt::UserRole + 1, "row"}};
}

Inspection::Inspection(Inspectors *registry, quint64 id, std::shared_ptr<ProcessInspector> reader, const QString &name,
                       const std::string &procRoot)
    : QObject(registry)
    , m_registry(registry)
    , m_id(id)
    , m_reader(std::move(reader))
    , m_pid(m_reader->pid())
    , m_start(m_reader->start())
    , m_name(name)
    , m_actions(procRoot)
    , m_memory(this)
    , m_statistics(this)
    , m_files(this)
{
    m_title = QStringLiteral("%1 (%2)").arg(m_name).arg(m_pid);
    m_timer.setInterval(m_registry->interval() * 1000);
    connect(&m_timer, &QTimer::timeout, this, [this] { refresh(false); });
    m_quick.setSingleShot(true);
    m_quick.setInterval(1000);
    connect(&m_quick, &QTimer::timeout, this, [this] { refresh(false); });
    refreshTexts();
}

QString Inspection::key() const
{
    return QStringLiteral("%1:%2").arg(m_pid).arg(m_start);
}

QString Inspection::hangsText() const
{
    // AM57: the times the shell's projection marked the process; there is no projection before step 3 (R11: no made-up 0).
    return dash();
}

void Inspection::setTab(const QString &tab)
{
    if (tab == m_tab || (tab != QLatin1String("memory") && tab != QLatin1String("statistics") && tab != QLatin1String("files")))
        return;
    m_tab = tab;
    emit tabChanged();
    emit changed(); // rowLabels
    if (m_shown)
        refresh(false); // the new tab's values now, not at the next interval
}

unsigned Inspection::reads() const
{
    if (m_tab == QLatin1String("statistics"))
        return InspectStatistics;
    if (m_tab == QLatin1String("files"))
        return InspectFiles;
    return InspectMemory;
}

void Inspection::setShown(bool shown)
{
    if (shown == m_shown)
        return;
    m_shown = shown;
    if (!shown) {
        m_timer.stop();
        m_quick.stop();
        return;
    }
    refresh(m_wasShown); // back on screen: the % CPU restarts from this read (AM8)
    m_wasShown = true;
    m_quick.start();
    m_timer.start(m_registry->interval() * 1000);
}

void Inspection::watch(QWindow *window)
{
    // The watch goes with its window; the inspection may go first (its window closed, the app quitting).
    if (window)
        new ShownWatch(window, [self = QPointer<Inspection>(this)](bool shown) {
            if (self)
                self->setShown(shown);
        });
}

QStringList Inspection::rowLabels() const
{
    QStringList labels;
    for (const QVariant &row : (m_tab == QLatin1String("statistics") ? m_statistics : m_memory).rows())
        labels << row.toMap().value(QStringLiteral("label")).toString();
    return labels;
}

void Inspection::inspectParent()
{
    if (canInspectParent())
        m_registry->open(m_details.ppid, m_details.parentStart);
}

void Inspection::setInterval(int seconds)
{
    m_timer.setInterval(seconds * 1000);
}

void Inspection::refresh(bool forget)
{
    if (m_busy) {
        m_again = true;
        m_againForget = m_againForget || forget;
        return;
    }
    m_busy = true;
    m_registry->request(this, reads(), forget);
}

void Inspection::take(unsigned what, const ProcessDetails &details)
{
    m_busy = false;
    if (!details.alive) {
        m_timer.stop();
        m_quick.stop();
        emit ended();
        return;
    }
    // Another tab's values stay from its last read (a tab's values come with its reads): no "—" between a tab chosen and
    // its first read.
    ProcessDetails before = std::move(m_details);
    m_details = details;
    if (!(what & InspectMemory))
        m_details.proportionalMemory = before.proportionalMemory;
    if (!(what & InspectStatistics)) {
        m_details.hasSwitches = before.hasSwitches;
        m_details.voluntarySwitches = before.voluntarySwitches;
        m_details.involuntarySwitches = before.involuntarySwitches;
        m_details.readCalls = before.readCalls;
        m_details.writeCalls = before.writeCalls;
        m_details.unit = std::move(before.unit);
        m_details.command = std::move(before.command);
        m_details.executable = std::move(before.executable);
        m_details.workingFolder = std::move(before.workingFolder);
    }
    if (what & InspectFiles) {
        m_filesRead = true;
    } else {
        m_details.hasFiles = before.hasFiles;
        m_details.files = std::move(before.files);
        m_details.moreFiles = before.moreFiles;
    }
    m_ready = true;
    // AM59: Quit acts on this process alone, with AM50's rules (own processes only).
    m_actions.setSelection({ProcessActions::Target{m_pid, m_start, m_name, m_details.own, false}});
    refreshTexts();
    if (m_again) {
        const bool forget = m_againForget;
        m_again = m_againForget = false;
        if (m_shown) // off screen meanwhile: nothing more (AM8)
            refresh(forget);
    }
}

void Inspection::refreshTexts()
{
    const QLocale &l = m_registry->locale();
    const ProcessDetails &d = m_details;
    const bool known = m_ready;
    const QString none = dash();

    if (known && d.hasParent) {
        QString name = m_registry->processName(d.ppid, d.parentStart);
        if (name.isEmpty())
            name = QString::fromStdString(d.parentComm);
        m_parentText = QStringLiteral("%1 (%2)").arg(name).arg(d.ppid);
    } else {
        m_parentText = none;
    }
    if (known) {
        const QString leader = d.pgrp == m_pid ? m_name : m_registry->processName(d.pgrp, 0);
        m_groupText = leader.isEmpty() ? QString::number(d.pgrp) : QStringLiteral("%1 (%2)").arg(leader).arg(d.pgrp);
        m_userText = QStringLiteral("%1 (%2)").arg(m_registry->userName(d.uid)).arg(d.uid);
        m_cpuText = formatDecimal(d.cpuPercent, l);
    } else {
        m_groupText = m_userText = m_cpuText = none;
    }

    const auto size = [&](uint64_t bytes) { return known && d.hasMemory ? formatBytes(static_cast<double>(bytes), l) : none; };
    m_memory.setRows({
        row(tr("Real Memory Size:"), size(d.realMemory)),
        row(tr("Virtual Memory Size:"), size(d.virtualMemory)),
        row(tr("Shared Memory Size:"), size(d.sharedMemory)),
        row(tr("Private Memory Size:"), size(d.privateMemory)),
        row(tr("Proportional Memory Size:"),
            known && d.proportionalMemory >= 0 ? formatBytes(static_cast<double>(d.proportionalMemory), l) : none),
        row(m_registry->swappedMemory() ? tr("Swapped Memory:") : tr("Compressed Memory:"), size(d.swapped)),
        row(tr("Peak Memory:"), size(d.peakMemory)),
    });

    const bool stats = known; // stat and status: every owner's
    const auto count = [&](uint64_t n, bool has) { return has ? formatCount(static_cast<double>(n), l) : none; };
    QString started = none;
    if (stats && d.started >= 0)
        started = l.toString(QDateTime::fromSecsSinceEpoch(static_cast<qint64>(d.started)), QLocale::ShortFormat);
    m_statistics.setRows({
        row(tr("Threads:"), stats ? formatCount(d.threads, l) : none),
        row(tr("User CPU Time:"), stats ? formatCpuTime(d.userSeconds, l) : none),
        row(tr("System CPU Time:"), stats ? formatCpuTime(d.systemSeconds, l) : none),
        row(tr("Voluntary Context Switches:"), count(d.voluntarySwitches, stats && d.hasSwitches)),
        row(tr("Involuntary Context Switches:"), count(d.involuntarySwitches, stats && d.hasSwitches)),
        row(tr("Minor Faults:"), count(d.minorFaults, stats)),
        row(tr("Major Faults:"), count(d.majorFaults, stats)),
        row(tr("Read Calls:"), count(static_cast<uint64_t>(d.readCalls), stats && d.readCalls >= 0)),
        row(tr("Write Calls:"), count(static_cast<uint64_t>(d.writeCalls), stats && d.writeCalls >= 0)),
        row(tr("Started:"), started),
        row(tr("Nice:"), stats ? l.toString(static_cast<qlonglong>(d.nice)) : none),
        row(tr("Scheduler Policy:"), stats ? policyName(d.policy) : none),
        row(tr("Unit:"), orDash(d.unit)),
        row(tr("Command:"), orDash(d.command)),
        row(tr("Executable:"), orDash(d.executable)),
        row(tr("Working Folder:"), orDash(d.workingFolder)),
    });

    QVariantList files;
    files.reserve(static_cast<qsizetype>(d.files.size()));
    for (const Descriptor &f : d.files) {
        const QString local = QString::fromStdString(f.local), remote = QString::fromStdString(f.remote);
        QString text;
        switch (f.kind) {
        case Descriptor::Kind::File:
        case Descriptor::Kind::Other:
            text = QString::fromStdString(f.name);
            break;
        case Descriptor::Kind::Pipe:
            text = tr("Pipe");
            break;
        case Descriptor::Kind::Tcp:
            text = f.listening ? tr("TCP %1 (listening)").arg(local)
                 : remote.isEmpty() ? tr("TCP %1").arg(local) : tr("TCP %1 to %2").arg(local, remote);
            break;
        case Descriptor::Kind::Udp:
            text = remote.isEmpty() ? tr("UDP %1").arg(local) : tr("UDP %1 to %2").arg(local, remote);
            break;
        case Descriptor::Kind::Local:
            text = f.name.empty() ? tr("Local socket") : tr("Local socket %1").arg(QString::fromStdString(f.name));
            break;
        }
        files << QVariantMap{{QStringLiteral("fd"), f.fd}, {QStringLiteral("text"), text}};
    }
    m_files.setRows(files);
    if (known && !d.own)
        m_filesNote = tr("The open files of another user's process can't be read.");
    else if (m_filesRead && !d.hasFiles)
        m_filesNote = tr("The open files of this process can't be read.");
    else if (d.moreFiles > 0)
        m_filesNote = tr("%1 more descriptors aren't listed.").arg(formatCount(static_cast<double>(d.moreFiles), l));
    else
        m_filesNote.clear();
    emit changed();
}

Inspectors::Inspectors(std::string procRoot, uint32_t uid, long clockTicks, QObject *parent)
    : QObject(parent), m_procRoot(std::move(procRoot)), m_uid(uid), m_clockTicks(clockTicks)
{
}

Inspectors::~Inspectors()
{
    // The inspections are children: deleted with the registry; a read on the worker's thread delivers to nothing.
    m_open.clear();
}

void Inspectors::setInterval(int seconds)
{
    m_interval = seconds;
    for (Inspection *i : std::as_const(m_open))
        i->setInterval(seconds);
}

void Inspectors::setLocale(const QLocale &locale)
{
    m_locale = locale;
    for (Inspection *i : std::as_const(m_open))
        i->refreshTexts();
}

void Inspectors::setSwappedMemory(bool swapped)
{
    if (swapped == m_swapped)
        return;
    m_swapped = swapped;
    for (Inspection *i : std::as_const(m_open))
        i->refreshTexts();
}

void Inspectors::setNames(ProcessName processName, UserName userName)
{
    m_processName = std::move(processName);
    m_userName = std::move(userName);
}

QString Inspectors::processName(int pid, quint64 start) const
{
    return m_processName ? m_processName(pid, start) : QString();
}

QString Inspectors::userName(uint32_t uid) const
{
    return m_userName ? m_userName(uid) : QString::number(uid);
}

void Inspectors::namesChanged()
{
    for (Inspection *i : std::as_const(m_open))
        i->refreshTexts();
}

Inspection *Inspectors::open(int pid, quint64 start, const QString &name)
{
    for (Inspection *i : std::as_const(m_open)) {
        if (i->pid() == pid && i->start() == start) {
            emit opened(i);
            return i;
        }
    }
    auto reader = std::make_shared<ProcessInspector>(m_procRoot, m_uid, m_clockTicks);
    if (!reader->open(pid, static_cast<uint64_t>(start)))
        return nullptr; // AM51: it ended, or its pid is another process's now
    QString shown = name.isEmpty() ? processName(pid, start) : name;
    if (shown.isEmpty()) // not in the last sample (a parent the view hides is still there): stat's name
        shown = QString::fromStdString(reader->read(0, monotonicSeconds()).comm);
    const quint64 id = m_nextId++;
    auto *inspection = new Inspection(this, id, std::move(reader), shown, m_procRoot);
    m_open.insert(id, inspection);
    emit opened(inspection);
    return inspection;
}

void Inspectors::close(Inspection *inspection)
{
    if (!inspection || !m_open.contains(inspection->id()))
        return;
    m_open.remove(inspection->id());
    inspection->deleteLater();
}

void Inspectors::request(Inspection *inspection, unsigned what, bool forget)
{
    std::shared_ptr<ProcessInspector> reader = inspection->m_reader;
    const quint64 id = inspection->id();
    if (!m_worker) {
        deliver(id, what, reader->read(what, monotonicSeconds(), forget));
        return;
    }
    // On the sampler's thread; the registry outlives it (ActivityApp stops the thread first), and an inspection closed
    // meanwhile is no longer listed, so its read goes nowhere.
    QMetaObject::invokeMethod(
        m_worker,
        [this, reader, what, forget, id] {
            auto details = std::make_shared<const ProcessDetails>(reader->read(what, monotonicSeconds(), forget));
            QMetaObject::invokeMethod(this, [this, id, what, details] { deliver(id, what, *details); }, Qt::QueuedConnection);
        },
        Qt::QueuedConnection);
}

void Inspectors::deliver(quint64 id, unsigned what, const ProcessDetails &details)
{
    if (Inspection *i = m_open.value(id))
        i->take(what, details);
}

} // namespace activity
