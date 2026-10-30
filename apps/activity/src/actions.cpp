#include "actions.h"

#include "runmode.h"
#include "units.h"

#include <QDebug>

#include <cerrno>
#include <csignal>
#include <cstring>
#include <unistd.h>

namespace activity
{
namespace
{

QString errorText(int error)
{
    return QString::fromLocal8Bit(std::strerror(error));
}

} // namespace

ProcessActions::ProcessActions(std::string procRoot, QObject *parent) : QObject(parent), m_procRoot(std::move(procRoot)) {}

bool ProcessActions::canQuit() const
{
    if (m_targets.empty())
        return false;
    for (const Target &t : m_targets) {
        if (!t.own || t.kernel)
            return false;
    }
    return true;
}

bool ProcessActions::canSignal() const
{
    return m_targets.size() == 1 && canQuit();
}

QString ProcessActions::refusal() const
{
    if (m_targets.empty() || canQuit())
        return {};
    return tr("You can only quit your own processes.");
}

void ProcessActions::setSelection(std::vector<Target> targets)
{
    if (targets == m_targets)
        return;
    m_targets = std::move(targets);
    emit selectionChanged();
}

QVariantList ProcessActions::signalChoices(bool withStop)
{
    const struct {
        int number;
        const char *title;
    } all[] = {
        {SIGHUP, QT_TR_NOOP("Hangup (SIGHUP)")},
        {SIGINT, QT_TR_NOOP("Interrupt (SIGINT)")},
        {SIGQUIT, QT_TR_NOOP("Quit (SIGQUIT)")},
        {SIGABRT, QT_TR_NOOP("Abort (SIGABRT)")},
        {SIGKILL, QT_TR_NOOP("Kill (SIGKILL)")},
        {SIGALRM, QT_TR_NOOP("Alarm (SIGALRM)")},
        {SIGTERM, QT_TR_NOOP("Terminate (SIGTERM)")},
        {SIGUSR1, QT_TR_NOOP("User Defined 1 (SIGUSR1)")},
        {SIGUSR2, QT_TR_NOOP("User Defined 2 (SIGUSR2)")},
        {SIGSTOP, QT_TR_NOOP("Stop (SIGSTOP)")},
        {SIGCONT, QT_TR_NOOP("Continue (SIGCONT)")},
    };
    QVariantList out;
    for (const auto &s : all) {
        if (s.number == SIGSTOP && !withStop)
            continue;
        out << QVariantMap{{QStringLiteral("number"), s.number}, {QStringLiteral("title"), tr(s.title)}};
    }
    return out;
}

QVariantMap ProcessActions::prepare(const QString &action)
{
    release();
    const bool signal = action == QLatin1String("signal");
    if (signal ? !canSignal() : !canQuit())
        return {{QStringLiteral("ok"), false}};
    const int self = static_cast<int>(getpid());
    QString session;
    bool anySelf = false;
    for (const Target &t : m_targets) {
        ProcessHandle handle = ProcessHandle::open(m_procRoot, t.pid, t.start);
        if (!handle.valid())
            continue; // AM51: it ended, or its pid is another process's now
        Pending p;
        p.name = t.name;
        p.self = t.pid == self;
        // AM52, AM54: the unit, read now through the descriptor (a row keeps no cgroup path, AD25).
        const std::string cgroup = m_unitReader ? m_unitReader(handle) : handle.cgroup();
        p.session = isSessionProcess(cgroup);
        p.appUnit = classify(cgroup, true, false, false) == Kind::App;
        p.handle = std::move(handle);
        if (p.session && session.isEmpty())
            session = p.name;
        anySelf = anySelf || p.self;
        m_pending.push_back(std::move(p));
    }
    if (m_pending.empty())
        return {{QStringLiteral("ok"), false}};
    const Pending &first = m_pending.front();
    QVariantMap out{{QStringLiteral("ok"), true},
                    {QStringLiteral("count"), static_cast<int>(m_pending.size())},
                    {QStringLiteral("name"), first.name},
                    {QStringLiteral("pid"), first.handle.pid()},
                    {QStringLiteral("session"), session},
                    {QStringLiteral("self"), anySelf}};
    // AM55: no Stop for a session process (a stopped compositor or shell freezes the screen and the lock) or the app itself.
    if (signal)
        out.insert(QStringLiteral("signals"), signalChoices(!first.session && !first.self));
    return out;
}

void ProcessActions::release()
{
    m_pending.clear();
}

QVariantMap ProcessActions::done()
{
    return {{QStringLiteral("done"), true}};
}

QVariantMap ProcessActions::failed(const QString &error, bool unsafe)
{
    return {{QStringLiteral("done"), false}, {QStringLiteral("error"), error}, {QStringLiteral("unsafe"), unsafe}};
}

QString ProcessActions::devRefusal(const char *what) const
{
    if (!grassfield::apps::runmode::dev())
        return {};
    const std::vector<DevRoot> roots = readDevRoots(grassfield::apps::runmode::devValue("ACTIVITY_DEV_ROOTS").toStdString());
    for (const Pending &p : m_pending) {
        if (p.self)
            continue;
        if (!underDevRoot(m_procRoot, p.handle.pid(), p.handle.start(), p.handle.ppid(), roots)) {
            qInfo().noquote() << "dev guard:" << what << "of pid" << p.handle.pid()
                              << "refused: it descends from no process GRASSFIELD_ACTIVITY_DEV_ROOTS names";
            return tr("Development session: only the nested session's processes can be quit.");
        }
    }
    return {};
}

QVariantMap ProcessActions::deliver(int sig, const char *what)
{
    bool failedOne = false;
    for (const Pending &p : m_pending) {
        const int error = p.handle.signal(sig);
        // AM53: a process that ended meanwhile is silent; any other error is the journal's, with its reason.
        if (error != 0 && error != ESRCH) {
            qWarning().noquote() << "activity:" << what << "of" << p.name << "(pid" << p.handle.pid() << ") failed:" << errorText(error);
            failedOne = true;
        }
    }
    if (!failedOne)
        return done();
    return failed(std::strcmp(what, "signal") == 0 ? tr("The signal couldn't be sent.") : tr("The process couldn't be quit."));
}

QVariantMap ProcessActions::quit()
{
    if (m_pending.empty())
        return done();
    if (const QString refused = devRefusal("quit"); !refused.isEmpty())
        return failed(refused);
    // AM52: a process of an app unit is quit by the shell, which closes its windows so the app can save or ask (step 3, the
    // projection and `activity quit`). Without it, no process of an app unit is quit by a signal: the sheet offers Force
    // Quit only (AM75: no shell, Quit as AM52).
    for (const Pending &p : m_pending) {
        if (p.appUnit && !p.self)
            return failed(m_pending.size() == 1 ? tr("The process couldn't be quit safely.") : tr("These processes couldn't all be quit safely."), true);
    }
    // AM54: the app's own row closes its window instead of a signal; the others get SIGTERM.
    bool self = false;
    std::vector<Pending> others;
    for (Pending &p : m_pending) {
        if (p.self)
            self = true;
        else
            others.push_back(std::move(p));
    }
    m_pending = std::move(others);
    const QVariantMap result = deliver(SIGTERM, "quit");
    if (self)
        emit closeWindowRequested();
    return result;
}

QVariantMap ProcessActions::forceQuit()
{
    if (m_pending.empty())
        return done();
    for (const Pending &p : m_pending) {
        if (p.self)
            return failed(tr("This app can't force quit itself."));
    }
    if (const QString refused = devRefusal("force quit"); !refused.isEmpty())
        return failed(refused);
    return deliver(SIGKILL, "force quit");
}

QVariantMap ProcessActions::send(int signal)
{
    if (m_pending.size() != 1)
        return done();
    const Pending &p = m_pending.front();
    if (p.self)
        return failed(tr("This app can't force quit itself."));
    bool offered = false;
    for (const QVariant &v : signalChoices(!p.session)) {
        if (v.toMap().value(QStringLiteral("number")).toInt() == signal)
            offered = true;
    }
    if (!offered)
        return failed(tr("The signal couldn't be sent."));
    if (const QString refused = devRefusal("signal"); !refused.isEmpty())
        return failed(refused);
    return deliver(signal, "signal");
}

} // namespace activity
