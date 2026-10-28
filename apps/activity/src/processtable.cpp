#include "processtable.h"

#include "format.h"

#include <QCoreApplication>
#include <QHash>

#include <algorithm>

namespace activity {

namespace {

struct ViewInfo {
    View view;
    const char *key;
    const char *title;
};

const ViewInfo kViews[] = {
    {View::All, "all", QT_TRANSLATE_NOOP("ActivityView", "All Processes")},
    {View::Mine, "mine", QT_TRANSLATE_NOOP("ActivityView", "My Processes")},
    {View::System, "system", QT_TRANSLATE_NOOP("ActivityView", "System Processes")},
    {View::OtherUsers, "otherUsers", QT_TRANSLATE_NOOP("ActivityView", "Other User Processes")},
    {View::Active, "active", QT_TRANSLATE_NOOP("ActivityView", "Active Processes")},
    {View::Inactive, "inactive", QT_TRANSLATE_NOOP("ActivityView", "Inactive Processes")},
    {View::Gpu, "gpu", QT_TRANSLATE_NOOP("ActivityView", "GPU Processes")},
    {View::Selected, "selected", QT_TRANSLATE_NOOP("ActivityView", "Selected Processes")},
};

bool own(const TableRow &row)
{
    return !row.kernel && row.process.own;
}

QString kindText(const TableRow &row)
{
    if (!own(row))
        return dash();
    switch (row.process.kind) {
    case Kind::App:
        return QCoreApplication::translate("ActivityTable", "App");
    case Kind::Session:
        return QCoreApplication::translate("ActivityTable", "Session");
    case Kind::Background:
    case Kind::System:
    case Kind::OtherUser:
        break;
    }
    return QCoreApplication::translate("ActivityTable", "Background");
}

} // namespace

QString viewKey(View view)
{
    for (const ViewInfo &v : kViews) {
        if (v.view == view)
            return QString::fromLatin1(v.key);
    }
    return QStringLiteral("all");
}

std::optional<View> viewFromKey(const QString &key)
{
    for (const ViewInfo &v : kViews) {
        if (key == QLatin1String(v.key))
            return v.view;
    }
    return std::nullopt;
}

QString viewTitle(View view)
{
    for (const ViewInfo &v : kViews) {
        if (v.view == view)
            return QCoreApplication::translate("ActivityView", v.title);
    }
    return QString();
}

const std::vector<View> &views()
{
    static const std::vector<View> all{View::All,      View::Mine,     View::System, View::OtherUsers,
                                       View::Active,   View::Inactive, View::Gpu,    View::Selected};
    return all;
}

QString rowKey(const TableRow &row)
{
    if (row.kernel)
        return QStringLiteral("kernel");
    return QString::number(row.process.pid) + QLatin1Char(':') + QString::number(row.process.start);
}

ProcessTable::ProcessTable(QObject *parent)
    : QAbstractListModel(parent)
{
    m_collator.setCaseSensitivity(Qt::CaseInsensitive);
    m_collator.setNumericMode(true);
    m_columns = tabColumns(Tab::Cpu).defaults;
}

void ProcessTable::setColumns(const std::vector<Column> &shown)
{
    m_columns = shown;
    if (!m_shown.empty())
        emit dataChanged(index(0), index(count() - 1), {CellsRole, AccessibleRole});
}

void ProcessTable::setSort(Column column, bool descending)
{
    if (column == m_sort && descending == m_descending)
        return;
    m_sort = column;
    m_descending = descending;
    rebuild();
}

void ProcessTable::setView(View view)
{
    if (view == View::Selected)
        m_selectedView = m_selected; // kept until another view is chosen (AM12)
    if (view == m_view && view != View::Selected)
        return;
    m_view = view;
    rebuild();
}

void ProcessTable::setSearch(const QString &text)
{
    const QString trimmed = text.trimmed();
    if (trimmed == m_search)
        return;
    m_search = trimmed;
    rebuild();
}

void ProcessTable::setSwappedMemory(bool swapped)
{
    m_swappedMemory = swapped;
}

void ProcessTable::setLocale(const QLocale &locale)
{
    if (locale == m_locale)
        return;
    m_locale = locale;
    if (!m_shown.empty())
        emit dataChanged(index(0), index(count() - 1), {CellsRole, AccessibleRole});
}

void ProcessTable::setRows(std::vector<TableRow> rows)
{
    m_all = std::move(rows);
    rebuild();
}

int ProcessTable::currentRow() const
{
    return m_current.isEmpty() ? -1 : indexOf(m_current);
}

int ProcessTable::rowCount(const QModelIndex &parent) const
{
    return parent.isValid() ? 0 : count();
}

QHash<int, QByteArray> ProcessTable::roleNames() const
{
    return {{CellsRole, "cells"},       {KeyRole, "rowKey"},         {PidRole, "pid"},       {NameRole, "name"},
            {IconRole, "icon"},         {SelectedRole, "selected"},  {CurrentRole, "current"}, {KernelRole, "kernel"},
            {OwnRole, "own"},           {AccessibleRole, "accessibleText"}};
}

QVariant ProcessTable::data(const QModelIndex &index, int role) const
{
    if (!index.isValid() || index.row() < 0 || index.row() >= count())
        return {};
    const TableRow &row = m_shown[static_cast<size_t>(index.row())];
    switch (role) {
    case CellsRole: {
        QStringList cells;
        cells.reserve(static_cast<qsizetype>(m_columns.size()));
        for (Column c : m_columns)
            cells << cellText(row, c);
        return cells;
    }
    case KeyRole:
        return rowKey(row);
    case PidRole:
        return row.kernel ? -1 : row.process.pid;
    case NameRole:
    case Qt::DisplayRole:
        return cellText(row, Column::Name);
    case IconRole:
        return row.icon;
    case SelectedRole:
        return m_selected.contains(rowKey(row));
    case CurrentRole:
        return rowKey(row) == m_current;
    case KernelRole:
        return row.kernel;
    case OwnRole:
        return own(row);
    case AccessibleRole: {
        QStringList parts{cellText(row, Column::Name)};
        for (Column c : m_columns) {
            if (c != Column::Name)
                parts << columnTitle(c, m_swappedMemory) + QLatin1Char(' ') + cellText(row, c);
        }
        return parts.join(QStringLiteral(", "));
    }
    default:
        return {};
    }
}

QString ProcessTable::cellText(const TableRow &row, Column column) const
{
    const ProcessRow &p = row.process;
    const QLocale &locale = m_locale;
    if (row.kernel) {
        switch (column) {
        case Column::Name:
            return QCoreApplication::translate("ActivityTable", "Kernel");
        case Column::CpuPercent:
            return formatDecimal(p.cpuPercent, locale);
        case Column::CpuTime:
            return formatCpuTime(row.cpuSeconds, locale);
        case Column::Threads:
            return formatCount(p.threads, locale);
        case Column::User:
            return row.user;
        default:
            return dash();
        }
    }
    const bool mine = p.own;
    switch (column) {
    case Column::Name:
        return row.name;
    case Column::CpuPercent:
        return formatDecimal(p.cpuPercent, locale);
    case Column::CpuTime:
        return formatCpuTime(row.cpuSeconds, locale);
    case Column::Threads:
        return formatCount(p.threads, locale);
    case Column::WakeUps:
        return mine ? formatCount(p.wakeRate, locale) : dash();
    case Column::GpuPercent:
        // No client is no GPU work (0.0); another owner's descriptors cannot be read ("—"); a first sample has no rate yet.
        return !mine ? dash() : p.hasGpu ? formatDecimal(p.gpuPercent, locale) : formatDecimal(0, locale);
    case Column::GpuTime:
        return mine ? formatCpuTime(static_cast<double>(p.gpuNs) / 1e9, locale) : dash();
    case Column::OpenFiles:
        return mine ? formatCount(p.openFiles, locale) : dash();
    case Column::Kind:
        return kindText(row);
    case Column::Command:
        return mine && !p.command.empty() ? QString::fromStdString(p.command) : dash();
    case Column::Memory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.memory), locale) : dash();
    case Column::RealMemory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.realMemory), locale) : dash();
    case Column::PrivateMemory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.privateMemory), locale) : dash();
    case Column::SharedMemory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.sharedMemory), locale) : dash();
    case Column::CompressedMemory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.swapped), locale) : dash();
    case Column::PeakMemory:
        return p.hasMemory ? formatBytes(static_cast<double>(p.peakMemory), locale) : dash();
    case Column::PageIns:
        return formatCount(static_cast<double>(p.majorFaults), locale);
    case Column::EnergyImpact:
        return formatDecimal(p.energyImpact, locale);
    case Column::AverageEnergyImpact:
        return formatDecimal(p.averageEnergyImpact, locale);
    case Column::PreventingSleep:
        return row.preventingSleep ? QCoreApplication::translate("ActivityTable", "Yes") : QCoreApplication::translate("ActivityTable", "No");
    case Column::BytesWritten:
        return p.hasIo ? formatBytes(static_cast<double>(p.bytesWritten), locale) : dash();
    case Column::BytesRead:
        return p.hasIo ? formatBytes(static_cast<double>(p.bytesRead), locale) : dash();
    case Column::ReadRate:
        return p.hasIo ? formatBytes(p.readRate, locale) : dash();
    case Column::WriteRate:
        return p.hasIo ? formatBytes(p.writeRate, locale) : dash();
    case Column::SentBytes:
        return mine ? formatBytes(static_cast<double>(p.tcpSent), locale) : dash();
    case Column::ReceivedBytes:
        return mine ? formatBytes(static_cast<double>(p.tcpReceived), locale) : dash();
    case Column::SentPackets:
        return mine ? formatCount(static_cast<double>(p.tcpSegsOut), locale) : dash();
    case Column::ReceivedPackets:
        return mine ? formatCount(static_cast<double>(p.tcpSegsIn), locale) : dash();
    case Column::Pid:
        return QString::number(p.pid);
    case Column::User:
        return row.user;
    }
    return dash();
}

double ProcessTable::sortValue(const TableRow &row, Column column) const
{
    const ProcessRow &p = row.process;
    const bool mine = own(row);
    switch (column) {
    case Column::CpuPercent:
        return p.cpuPercent;
    case Column::CpuTime:
        return row.cpuSeconds;
    case Column::Threads:
        return p.threads;
    case Column::Pid:
        return row.kernel ? -1 : p.pid;
    default:
        break;
    }
    if (row.kernel)
        return -1;
    switch (column) {
    case Column::WakeUps:
        return mine ? p.wakeRate : -1;
    case Column::GpuPercent:
        return !mine ? -1 : p.hasGpu ? p.gpuPercent : 0;
    case Column::GpuTime:
        return mine ? static_cast<double>(p.gpuNs) : -1;
    case Column::OpenFiles:
        return mine ? p.openFiles : -1;
    case Column::Memory:
        return p.hasMemory ? static_cast<double>(p.memory) : -1;
    case Column::RealMemory:
        return p.hasMemory ? static_cast<double>(p.realMemory) : -1;
    case Column::PrivateMemory:
        return p.hasMemory ? static_cast<double>(p.privateMemory) : -1;
    case Column::SharedMemory:
        return p.hasMemory ? static_cast<double>(p.sharedMemory) : -1;
    case Column::CompressedMemory:
        return p.hasMemory ? static_cast<double>(p.swapped) : -1;
    case Column::PeakMemory:
        return p.hasMemory ? static_cast<double>(p.peakMemory) : -1;
    case Column::PageIns:
        return static_cast<double>(p.majorFaults);
    case Column::EnergyImpact:
        return p.energyImpact;
    case Column::AverageEnergyImpact:
        return p.averageEnergyImpact;
    case Column::BytesWritten:
        return p.hasIo ? static_cast<double>(p.bytesWritten) : -1;
    case Column::BytesRead:
        return p.hasIo ? static_cast<double>(p.bytesRead) : -1;
    case Column::ReadRate:
        return p.hasIo ? p.readRate : -1;
    case Column::WriteRate:
        return p.hasIo ? p.writeRate : -1;
    case Column::SentBytes:
        return mine ? static_cast<double>(p.tcpSent) : -1;
    case Column::ReceivedBytes:
        return mine ? static_cast<double>(p.tcpReceived) : -1;
    case Column::SentPackets:
        return mine ? static_cast<double>(p.tcpSegsOut) : -1;
    case Column::ReceivedPackets:
        return mine ? static_cast<double>(p.tcpSegsIn) : -1;
    default:
        return -1;
    }
}

QString ProcessTable::sortText(const TableRow &row, Column column) const
{
    return cellText(row, column);
}

bool ProcessTable::less(const TableRow &a, const TableRow &b) const
{
    if (columnIsNumeric(m_sort)) {
        // What is unknown ("—", -1) sorts below every value, whichever way.
        const double va = sortValue(a, m_sort), vb = sortValue(b, m_sort);
        if (va != vb)
            return m_descending ? va > vb : va < vb;
    } else {
        const int c = m_collator.compare(sortText(a, m_sort), sortText(b, m_sort));
        if (c != 0)
            return m_descending ? c > 0 : c < 0;
    }
    // Ties keep one order, the pid's (the Kernel row first): rows never swap between two samples for nothing.
    const int pa = a.kernel ? -1 : a.process.pid, pb = b.kernel ? -1 : b.process.pid;
    return pa < pb;
}

bool ProcessTable::accepts(const TableRow &row) const
{
    const ProcessRow &p = row.process;
    switch (m_view) {
    case View::All:
        break;
    case View::Mine:
        if (!own(row))
            return false;
        break;
    case View::System:
        if (!row.kernel && !p.systemAccount)
            return false;
        break;
    case View::OtherUsers:
        if (row.kernel || p.own || p.systemAccount)
            return false;
        break;
    case View::Active:
        if (!(p.cpuPercent > 0))
            return false;
        break;
    case View::Inactive:
        if (p.cpuPercent > 0)
            return false;
        break;
    case View::Gpu:
        if (row.kernel || p.gpuDevices.empty())
            return false;
        break;
    case View::Selected:
        if (!m_selectedView.contains(rowKey(row)))
            return false;
        break;
    }
    if (m_search.isEmpty())
        return true;
    // AM14: the name, the app's name, the user, the command (own processes only, AD25), or a pid that starts with the
    // digits typed; case-insensitive.
    const QString name = row.kernel ? cellText(row, Column::Name) : row.name;
    if (name.contains(m_search, Qt::CaseInsensitive) || row.appName.contains(m_search, Qt::CaseInsensitive)
        || row.user.contains(m_search, Qt::CaseInsensitive))
        return true;
    if (own(row) && QString::fromStdString(p.command).contains(m_search, Qt::CaseInsensitive))
        return true;
    bool digits = !m_search.isEmpty();
    for (const QChar ch : m_search)
        digits = digits && ch.isDigit();
    return digits && !row.kernel && QString::number(p.pid).startsWith(m_search);
}

int ProcessTable::indexOf(const QString &key) const
{
    for (size_t i = 0; i < m_shown.size(); ++i) {
        if (rowKey(m_shown[i]) == key)
            return static_cast<int>(i);
    }
    return -1;
}

void ProcessTable::rebuild()
{
    const int before = count();
    std::vector<TableRow> target;
    target.reserve(m_all.size());
    for (const TableRow &r : m_all) {
        if (accepts(r))
            target.push_back(r);
    }
    std::stable_sort(target.begin(), target.end(), [this](const TableRow &a, const TableRow &b) { return less(a, b); });
    QHash<QString, int> wanted;
    wanted.reserve(static_cast<qsizetype>(target.size()));
    for (size_t i = 0; i < target.size(); ++i)
        wanted.insert(rowKey(target[i]), static_cast<int>(i));

    // The rows that left: removed from the end, one run at a time.
    for (int i = count() - 1; i >= 0;) {
        if (wanted.contains(rowKey(m_shown[static_cast<size_t>(i)]))) {
            --i;
            continue;
        }
        const int last = i;
        while (i >= 0 && !wanted.contains(rowKey(m_shown[static_cast<size_t>(i)])))
            --i;
        beginRemoveRows(QModelIndex(), i + 1, last);
        m_shown.erase(m_shown.begin() + (i + 1), m_shown.begin() + (last + 1));
        endRemoveRows();
    }
    // The rows that stay take their new values where they are; the new ones come in at the end.
    QSet<QString> present;
    for (TableRow &r : m_shown) {
        const QString key = rowKey(r);
        present.insert(key);
        r = target[static_cast<size_t>(wanted.value(key))];
    }
    std::vector<TableRow> added;
    for (const TableRow &r : target) {
        if (!present.contains(rowKey(r)))
            added.push_back(r);
    }
    if (!added.empty()) {
        beginInsertRows(QModelIndex(), count(), count() + static_cast<int>(added.size()) - 1);
        m_shown.insert(m_shown.end(), added.begin(), added.end());
        endInsertRows();
    }
    // Then every row moves to its sorted place: a layout change, which keeps the view's scroll position (AM11).
    bool ordered = true;
    for (size_t i = 0; i < m_shown.size() && ordered; ++i)
        ordered = rowKey(m_shown[i]) == rowKey(target[i]);
    if (!ordered) {
        emit layoutAboutToBeChanged({}, QAbstractItemModel::VerticalSortHint);
        const QModelIndexList from = persistentIndexList();
        QModelIndexList to;
        to.reserve(from.size());
        for (const QModelIndex &i : from) {
            const int row = i.row() >= 0 && i.row() < count() ? wanted.value(rowKey(m_shown[static_cast<size_t>(i.row())]), -1) : -1;
            to << (row >= 0 ? index(row) : QModelIndex());
        }
        m_shown = std::move(target);
        changePersistentIndexList(from, to);
        emit layoutChanged({}, QAbstractItemModel::VerticalSortHint);
    } else {
        m_shown = std::move(target);
    }
    if (!m_shown.empty())
        emit dataChanged(index(0), index(count() - 1));
    pruneSelection();
    if (count() != before)
        emit countChanged();
}

void ProcessTable::pruneSelection()
{
    // A process that ended, or that the view or the search no longer shows, leaves the selection: an action never applies to
    // a row the user cannot see (AM11).
    QSet<QString> shown;
    for (const TableRow &r : m_shown)
        shown.insert(rowKey(r));
    const QSet<QString> was = m_selected;
    const QString current = m_current;
    m_selected.intersect(shown);
    if (!shown.contains(m_anchor))
        m_anchor.clear();
    if (!shown.contains(m_current))
        m_current.clear();
    if (m_selected != was || m_current != current)
        emit selectionChanged();
}

void ProcessTable::selectRange(int from, int to)
{
    m_selected.clear();
    const int lo = std::min(from, to), hi = std::max(from, to);
    for (int i = lo; i <= hi; ++i)
        m_selected.insert(rowKey(m_shown[static_cast<size_t>(i)]));
}

void ProcessTable::click(int row, int modifiers)
{
    if (row < 0 || row >= count())
        return;
    const QString key = rowKey(m_shown[static_cast<size_t>(row)]);
    if ((modifiers & Qt::ShiftModifier) && !m_anchor.isEmpty()) {
        selectRange(indexOf(m_anchor), row);
    } else if (modifiers & Qt::ControlModifier) {
        if (m_selected.contains(key))
            m_selected.remove(key);
        else
            m_selected.insert(key);
        m_anchor = key;
    } else {
        m_selected = {key};
        m_anchor = key;
    }
    m_current = key;
    emit dataChanged(index(0), index(count() - 1), {SelectedRole, CurrentRole});
    emit selectionChanged();
}

void ProcessTable::moveCurrent(int delta, bool extend)
{
    if (m_shown.empty())
        return;
    const int from = currentRow();
    const int to = std::clamp(from < 0 ? (delta >= 0 ? 0 : count() - 1) : from + delta, 0, count() - 1);
    const QString key = rowKey(m_shown[static_cast<size_t>(to)]);
    if (extend && !m_anchor.isEmpty()) {
        selectRange(indexOf(m_anchor), to);
    } else {
        m_selected = {key};
        m_anchor = key;
    }
    m_current = key;
    emit dataChanged(index(0), index(count() - 1), {SelectedRole, CurrentRole});
    emit selectionChanged();
}

void ProcessTable::selectAll()
{
    for (const TableRow &r : m_shown)
        m_selected.insert(rowKey(r));
    if (!m_shown.empty())
        emit dataChanged(index(0), index(count() - 1), {SelectedRole});
    emit selectionChanged();
}

void ProcessTable::clearSelection()
{
    if (m_selected.isEmpty())
        return;
    m_selected.clear();
    emit dataChanged(index(0), index(count() - 1), {SelectedRole});
    emit selectionChanged();
}

QString ProcessTable::copyText() const
{
    QStringList lines;
    QStringList header;
    for (Column c : m_columns)
        header << columnTitle(c, m_swappedMemory);
    lines << header.join(QLatin1Char('\t'));
    for (const TableRow &r : m_shown) {
        if (!m_selected.contains(rowKey(r)))
            continue;
        QStringList cells;
        for (Column c : m_columns)
            cells << cellText(r, c);
        lines << cells.join(QLatin1Char('\t'));
    }
    return lines.join(QLatin1Char('\n')) + QLatin1Char('\n');
}

} // namespace activity
