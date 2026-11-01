// Inspect's windows (ADR-0038 AD13, AD45; spec AM57 to AM59): one Inspection behind each window, read on the sampler's
// thread (AD35) at the update frequency while its window is on screen (AM8), and the registry that opens them, one per
// process (a second request brings the open window forward).
#pragma once

#include "actions.h"
#include "inspect.h"

#include <QAbstractListModel>
#include <QHash>
#include <QLocale>
#include <QObject>
#include <QSet>
#include <QTimer>
#include <QVariantList>

#include <functional>
#include <memory>

class QWindow;

namespace activity {

class Inspectors;

// The rows of one tab as its window lists them (AM58): a list whose rows change in place at each read, so the window keeps
// its scroll position (as the table, AM11). One role, so a delegate reads it as `modelData`: {label, value}, or {fd, text}.
class InspectRows : public QAbstractListModel
{
    Q_OBJECT

public:
    using QAbstractListModel::QAbstractListModel;
    // The new rows: those that changed are signalled, the count grows or shrinks at the end; never a reset.
    void setRows(const QVariantList &rows);
    const QVariantList &rows() const { return m_rows; }
    int rowCount(const QModelIndex &parent = QModelIndex()) const override;
    QVariant data(const QModelIndex &index, int role) const override;
    QHash<int, QByteArray> roleNames() const override;

private:
    QVariantList m_rows;
};

class Inspection : public QObject
{
    Q_OBJECT
    // "<name> (<pid>)", the window's title (AM57).
    Q_PROPERTY(QString title READ title CONSTANT)
    // "<pid>:<start>", as the table's KeyRole.
    Q_PROPERTY(QString key READ key CONSTANT)
    Q_PROPERTY(int pid READ pid CONSTANT)
    // The first read has come (until then the window shows no value).
    Q_PROPERTY(bool ready READ ready NOTIFY changed)
    Q_PROPERTY(bool own READ own NOTIFY changed)
    // The header (AM57): texts as shown, "—" for what is unknown.
    Q_PROPERTY(QString parentText READ parentText NOTIFY changed)
    Q_PROPERTY(bool canInspectParent READ canInspectParent NOTIFY changed)
    Q_PROPERTY(QString groupText READ groupText NOTIFY changed)
    Q_PROPERTY(QString userText READ userText NOTIFY changed)
    Q_PROPERTY(QString cpuText READ cpuText NOTIFY changed)
    Q_PROPERTY(QString hangsText READ hangsText NOTIFY changed)
    // The tabs (AM58): {label, value} in order (InspectRows); the labels of the tab shown, for their column's width.
    Q_PROPERTY(QObject *memoryModel READ memoryModel CONSTANT)
    Q_PROPERTY(QObject *statisticsModel READ statisticsModel CONSTANT)
    Q_PROPERTY(QStringList rowLabels READ rowLabels NOTIFY changed)
    // Open Files and Ports: {fd, text} in descriptor order, and what the list leaves out or why it is empty.
    Q_PROPERTY(QObject *filesModel READ filesModel CONSTANT)
    Q_PROPERTY(QString filesNote READ filesNote NOTIFY changed)
    // "memory", "statistics" or "files": the tab shown, which says what a read covers beyond the header (AD10).
    Q_PROPERTY(QString tab READ tab WRITE setTab NOTIFY tabChanged)
    // AM59: Quit, through AM50's sheets, for this process alone.
    Q_PROPERTY(QObject *actions READ actions CONSTANT)

public:
    Inspection(Inspectors *registry, quint64 id, std::shared_ptr<ProcessInspector> reader, const QString &name,
               const std::string &procRoot);

    QString title() const { return m_title; }
    QString key() const;
    int pid() const { return m_pid; }
    quint64 start() const { return m_start; }
    quint64 id() const { return m_id; }
    bool ready() const { return m_ready; }
    bool own() const { return m_details.own; }
    QString parentText() const { return m_parentText; }
    bool canInspectParent() const { return m_ready && m_details.hasParent; }
    QString groupText() const { return m_groupText; }
    QString userText() const { return m_userText; }
    QString cpuText() const { return m_cpuText; }
    QString hangsText() const;
    QObject *memoryModel() { return &m_memory; }
    QObject *statisticsModel() { return &m_statistics; }
    QObject *filesModel() { return &m_files; }
    QStringList rowLabels() const;
    // The rows as the models hold them (the tests).
    QVariantList memoryRows() const { return m_memory.rows(); }
    QVariantList statisticsRows() const { return m_statistics.rows(); }
    QVariantList files() const { return m_files.rows(); }
    QString filesNote() const { return m_filesNote; }
    QString tab() const { return m_tab; }
    void setTab(const QString &tab);
    QObject *actions() { return &m_actions; }
    ProcessActions &processActions() { return m_actions; }
    const ProcessDetails &details() const { return m_details; }

    // AM8: the window is on screen. A read now (its % CPU starting again after a time off screen), one a second later for
    // the % CPU, then one per interval; none while it is not.
    Q_INVOKABLE void setShown(bool shown);
    // Follows `window`'s exposure as the main window's (shownwatch.h).
    Q_INVOKABLE void watch(QWindow *window);
    // AM57: the Parent Process line was clicked: its own window.
    Q_INVOKABLE void inspectParent();

    // The registry's: the interval changed; a read came back; the names changed (a new sample).
    void setInterval(int seconds);
    // `what`: the InspectRead bits the read covered; another tab's values stay from its last read.
    void take(unsigned what, const ProcessDetails &details);
    void refreshTexts();

signals:
    void changed();
    void tabChanged();
    // AD45: the process ended; its window closes.
    void ended();

private:
    friend class Inspectors;
    void refresh(bool forget);
    unsigned reads() const;

    Inspectors *m_registry;
    quint64 m_id;
    std::shared_ptr<ProcessInspector> m_reader;
    int m_pid;
    quint64 m_start;
    QString m_name, m_title;
    ProcessActions m_actions;
    QTimer m_timer, m_quick;
    bool m_shown = false, m_busy = false, m_again = false, m_againForget = false, m_wasShown = false, m_ready = false;
    bool m_filesRead = false;
    QString m_tab = QStringLiteral("memory");
    ProcessDetails m_details;
    QString m_parentText, m_groupText, m_userText, m_cpuText, m_filesNote;
    InspectRows m_memory, m_statistics, m_files;
};

class Inspectors : public QObject
{
    Q_OBJECT

public:
    // `procRoot`, `uid`, `clockTicks`: the sampler's options.
    Inspectors(std::string procRoot, uint32_t uid, long clockTicks, QObject *parent = nullptr);
    ~Inspectors() override;

    // The reads run on `worker`'s thread (the sampler's, AD35); without one, on the caller's at once (tests).
    void setWorker(QObject *worker) { m_worker = worker; }
    void setInterval(int seconds);
    int interval() const { return m_interval; }
    void setLocale(const QLocale &locale);
    const QLocale &locale() const { return m_locale; }
    // AM34: VmSwap is Compressed Memory, or Swapped Memory when a swap is not zram's (the table's title).
    void setSwappedMemory(bool swapped);
    bool swappedMemory() const { return m_swapped; }
    // Names as the table shows them: a process by its pid and start time ("" when the last sample lacks it), a user by uid.
    using ProcessName = std::function<QString(int pid, quint64 start)>;
    using UserName = std::function<QString(uint32_t uid)>;
    void setNames(ProcessName processName, UserName userName);
    QString processName(int pid, quint64 start) const;
    QString userName(uint32_t uid) const;
    // A new sample: names may have come (a parent's, a group leader's).
    void namesChanged();
    // AM57: Recent hangs, the times the shell marked a process since the app opened; -1 without a projection.
    using Hangs = std::function<int(int pid, quint64 start)>;
    void setHangs(Hangs hangs) { m_hangs = std::move(hangs); }
    int hangs(int pid, quint64 start) const { return m_hangs ? m_hangs(pid, start) : -1; }
    // AM52, AM60: the projection, for each window's Quit.
    void setProjection(bool valid, QSet<int> windowPids);
    // The main window's actions, whose hooks each inspection's actions take (adoptHooks).
    void setMainActions(const ProcessActions *main) { m_mainActions = main; }

    // The inspection of a process, made when none is open; nullptr when the process ended or its pid names another one
    // now (AM51's check). `opened` follows, the window raised or made.
    Inspection *open(int pid, quint64 start, const QString &name = QString());
    // Its window closed.
    void close(Inspection *inspection);
    int count() const { return static_cast<int>(m_open.size()); }
    const std::string &procRoot() const { return m_procRoot; }

    // An Inspection's read (one at a time per inspection).
    void request(Inspection *inspection, unsigned what, bool forget);

signals:
    void opened(QObject *inspection);

private:
    const ProcessActions *m_mainActions = nullptr;
    void deliver(quint64 id, unsigned what, const ProcessDetails &details);

    std::string m_procRoot;
    uint32_t m_uid;
    long m_clockTicks;
    QObject *m_worker = nullptr;
    int m_interval = 5;
    QLocale m_locale;
    bool m_swapped = false;
    ProcessName m_processName;
    UserName m_userName;
    Hangs m_hangs;
    bool m_projectionValid = false;
    QSet<int> m_windowPids;
    quint64 m_nextId = 1;
    QHash<quint64, Inspection *> m_open;
};

} // namespace activity
