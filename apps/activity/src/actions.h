// Quit, Force Quit and Send Signal (ADR-0038 e, AD30; spec AM50 to AM56): what the Stop button, the menus and the sheets
// of the window ask. The processes of a sheet are fixed when it opens (AM51: a /proc/<pid> descriptor each, the rows whose
// process ended or changed dropped), and every signal goes through those descriptors until the sheet closes.
#pragma once

#include "signals.h"

#include <QObject>
#include <QString>
#include <QVariantMap>

#include <functional>
#include <string>
#include <vector>

namespace activity
{

class ProcessActions : public QObject
{
    Q_OBJECT
    // AM50: Quit Process (and the sheet's Force Quit) act on the selection: the user's own processes only, never the
    // Kernel row.
    Q_PROPERTY(bool canQuit READ canQuit NOTIFY selectionChanged)
    // AM55: Send Signal to Process… acts on one of the user's own processes.
    Q_PROPERTY(bool canSignal READ canSignal NOTIFY selectionChanged)
    // Why the actions are off: another owner's process or the Kernel row is selected (the controls' tooltip); "" otherwise.
    Q_PROPERTY(QString refusal READ refusal NOTIFY selectionChanged)

public:
    // A selected row as the table shows it.
    struct Target {
        int pid = 0;
        quint64 start = 0;
        QString name;
        bool own = false;
        bool kernel = false;
        bool operator==(const Target &o) const
        {
            return pid == o.pid && start == o.start && name == o.name && own == o.own && kernel == o.kernel;
        }
    };

    explicit ProcessActions(std::string procRoot, QObject *parent = nullptr);

    bool canQuit() const;
    bool canSignal() const;
    QString refusal() const;
    void setSelection(std::vector<Target> targets);

    // A sheet opens (action "quit" or "signal"): a descriptor for each selected row (AM51). The answer: `ok` (false: no
    // process is left to act on, no sheet), `count`, `name` and `pid` (the first process), `session` (the name of a session
    // process among them, for the second sheet, AM54; "" when none), `self` (the app is among them) and, for "signal",
    // `signals`: [{number, title}] in AM55's order, without Stop for a session process or the app itself.
    Q_INVOKABLE QVariantMap prepare(const QString &action);
    // The sheet's buttons. The answer: `done` (the sheet closes), else `error` (its message, the sheet stays) and `unsafe`
    // (AM52: Quit could not be done safely; the sheet offers Force Quit only).
    Q_INVOKABLE QVariantMap quit();
    Q_INVOKABLE QVariantMap forceQuit();
    Q_INVOKABLE QVariantMap send(int signal);
    // The sheet closed: the descriptors go.
    Q_INVOKABLE void release();

    // AM55's signals in their order: the number and the pop-up's title.
    static QVariantList signalChoices(bool withStop);

    // Tests: the cgroup path of a process by its pid (by default a sheet process's and its parent's are read through their
    // descriptors). A test's children are in the unit of whatever runs the tests, an app's terminal or a container.
    using UnitReader = std::function<std::string(int pid)>;
    void setUnitReader(UnitReader reader) { m_unitReader = std::move(reader); }

signals:
    void selectionChanged();
    // AM54: the app's own row was quit; its window closes (which quits the app, AD17).
    void closeWindowRequested();

private:
    struct Pending {
        ProcessHandle handle;
        QString name;
        bool self = false;
        bool session = false;
        bool appUnit = false;
        // AD43: a command run in a terminal (a controlling terminal, and a parent in the same unit: not the process that
        // started the unit).
        bool terminal = false;
    };
    // The dev guard (AM56): "" when every pending process may be acted on, else the sheet's message (one journal line).
    QString devRefusal(const char *what) const;
    QVariantMap deliver(int sig, const char *what);
    static QVariantMap done();
    static QVariantMap failed(const QString &error, bool unsafe = false);

    std::string m_procRoot;
    UnitReader m_unitReader;
    std::vector<Target> m_targets;
    std::vector<Pending> m_pending;
};

} // namespace activity
