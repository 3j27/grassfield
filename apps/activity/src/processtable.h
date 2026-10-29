// The table of processes (spec AM10 to AM19): one row per process of the last sample and the Kernel row, filtered by the
// view and the search, sorted by one column. A new sample keeps each row's identity (pid and start time): rows of ended
// processes go, new ones come in, the others change in place and move to their sorted place, so the list view keeps its
// scroll position (no model reset) and the selection follows its processes (AM11).
#pragma once

#include "columns.h"

#include <QAbstractListModel>
#include <QCollator>
#include <QLocale>
#include <QSet>
#include <QString>

#include <optional>
#include <vector>

namespace activity {

// AM12's views of step 2a (Hierarchically and Processes, by GPU come with step 2b; Windowed Processes with the shell's
// projection, step 3; Processes, by Type with step 4).
enum class View { All, Mine, System, OtherUsers, Active, Inactive, Gpu, Selected };

QString viewKey(View view);
std::optional<View> viewFromKey(const QString &key);
QString viewTitle(View view);
const std::vector<View> &views();

// A row as the table needs it: the sampler's row and what the window adds to it.
struct TableRow {
    ProcessRow process;
    bool kernel = false;       // AM20a: every kernel thread summed; never selectable for an action
    double cpuSeconds = 0;     // utime + stime in seconds (the sampler counts ticks)
    QString name;              // sanitized by the sampler (AM17)
    QString user;              // the owner's login name, or the uid when it has none
    QString appName;           // the app's name from its desktop entry (own processes of an app unit), for the search
    QString icon;              // a theme icon name; "" for the generic executable glyph
    bool preventingSleep = false; // AM38
};

// A row's identity across samples: the pid and its start time (pid -1 for the Kernel row). A plain value: the table
// compares thousands of them at each sample.
struct RowId {
    int pid = -1;
    quint64 start = 0;
    bool operator==(const RowId &other) const { return pid == other.pid && start == other.start; }
    bool operator!=(const RowId &other) const { return !(*this == other); }
};
inline size_t qHash(const RowId &id, size_t seed = 0)
{
    return qHashMulti(seed, id.pid, id.start);
}
RowId rowId(const TableRow &row);
// The identity as text ("<pid>:<start>", "kernel"), for the KeyRole.
QString rowKey(const TableRow &row);

class ProcessTable : public QAbstractListModel
{
    Q_OBJECT
    Q_PROPERTY(int count READ count NOTIFY countChanged)
    Q_PROPERTY(int selectedCount READ selectedCount NOTIFY selectionChanged)
    // The row the keyboard moves from (the last one clicked or moved to), -1 when none is shown.
    Q_PROPERTY(int currentRow READ currentRow NOTIFY selectionChanged)

public:
    enum Role {
        CellsRole = Qt::UserRole + 1, // the shown columns' texts, in order (the name first)
        KeyRole,
        PidRole,
        NameRole,
        IconRole,
        SelectedRole,
        CurrentRole,
        KernelRole,
        OwnRole,
        AccessibleRole, // the name and the values with their headers (spec "Accessibility")
    };

    explicit ProcessTable(QObject *parent = nullptr);

    void setColumns(const std::vector<Column> &shown); // the name first
    const std::vector<Column> &columns() const { return m_columns; }
    void setSort(Column column, bool descending);
    void setView(View view);
    void setSearch(const QString &text);
    void setSwappedMemory(bool swapped);
    // The formats' locale (grassfield.json region.formats, as the Store): sizes, decimals and counts (AM16).
    void setLocale(const QLocale &locale);
    // A new sample's rows: every process and the Kernel row.
    void setRows(std::vector<TableRow> rows);

    int count() const { return static_cast<int>(m_shown.size()); }
    int selectedCount() const { return static_cast<int>(m_selected.size()); }
    int currentRow() const;
    // The rows shown, in order (a copy, for the tests).
    std::vector<TableRow> shownRows() const;

    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

    // AM11: a click selects the row; Ctrl toggles it; Shift selects from the anchor to it.
    Q_INVOKABLE void click(int row, int modifiers);
    // The keyboard (spec "Keyboard"): Up, Down, Page Up, Page Down, Home and End move the current row; Shift extends.
    Q_INVOKABLE void moveCurrent(int delta, bool extend);
    Q_INVOKABLE void selectAll();
    Q_INVOKABLE void clearSelection();
    // AM19: the shown columns' headers, then one line per selected row in the table's order, values as shown, tab-separated.
    Q_INVOKABLE QString copyText() const;

    QString cellText(const TableRow &row, Column column) const;

signals:
    void countChanged();
    void selectionChanged();

private:
    bool accepts(const TableRow &row) const;
    bool less(const TableRow &a, const TableRow &b) const;
    double sortValue(const TableRow &row, Column column) const;
    QString sortText(const TableRow &row, Column column) const;
    void rebuild();
    void pruneSelection();
    int indexOf(const RowId &id) const;
    void selectRange(int from, int to);

    std::vector<Column> m_columns;
    Column m_sort = Column::CpuPercent;
    bool m_descending = true;
    View m_view = View::All;
    QString m_search;
    bool m_swappedMemory = false;
    QLocale m_locale;
    std::vector<TableRow> m_all;      // the last sample
    std::vector<TableRow> m_previous; // the sample before, alive while a new one's changes are signalled
    // What the view and the search keep, sorted: rows of m_all (of m_previous while a new sample comes in), never copied.
    std::vector<const TableRow *> m_shown;
    QSet<RowId> m_selected;
    QSet<RowId> m_selectedView; // Selected Processes: the rows selected when the view was chosen
    std::optional<RowId> m_anchor, m_current;
    QCollator m_collator;
};

} // namespace activity
