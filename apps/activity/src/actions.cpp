#include "actions.h"

#include "runmode.h"
#include "units.h"

#include <QDebug>
#include <QPointer>
#include <QProcess>
#include <QTimer>

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

ProcessActions::ProcessActions(std::string procRoot, QObject *parent) : QObject(parent), m_procRoot(std::move(procRoot))
{
    // AM52: while Quit waits, the outcome is looked for at kShellQuitPollMs, up to its bound.
    m_outcome.setInterval(kShellQuitPollMs);
    connect(&m_outcome, &QTimer::timeout, this, &ProcessActions::pollOutcome);
    m_bound.setSingleShot(true);
    connect(&m_bound, &QTimer::timeout, this, [this] {
        // No outcome within the bound: what is still open gets Force Quit's offer.
        std::vector<int> open;
        for (const Pending &p : m_pending) {
            if (p.windowed && !p.answered)
                open.push_back(p.handle.pid());
        }
        for (int pid : open)
            takeShellAnswer(pid, QString());
    });
    // AM61: `qs ipc ... call activity quit <pid>`, its answer on stdout; killed at Quit's bound (AM52). Without a shell to
    // call (a dev session that names none) the answer is "" at once.
    m_shellQuit = [this](int pid, std::function<void(const QString &)> answer) {
        const QStringList ipc = grassfield::apps::runmode::shellIpcArgs();
        if (ipc.isEmpty()) {
            QTimer::singleShot(0, this, [answer] { answer(QString()); });
            return;
        }
        auto *process = new QProcess(this);
        QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
        for (const QString &key : env.keys()) {
            if (key.startsWith(QLatin1String("QS_")))
                env.remove(key);
        }
        process->setProcessEnvironment(env);
        process->setStandardErrorFile(QProcess::nullDevice());
        auto *timer = new QTimer(process);
        timer->setSingleShot(true);
        connect(timer, &QTimer::timeout, process, [process] { process->kill(); });
        auto replied = std::make_shared<bool>(false);
        const auto reply = [process, answer, replied](const QString &text) {
            if (*replied)
                return;
            *replied = true;
            answer(text);
            process->deleteLater();
        };
        connect(process, &QProcess::finished, process, [process, reply](int code, QProcess::ExitStatus status) {
            reply(status == QProcess::NormalExit && code == 0 ? QString::fromUtf8(process->readAllStandardOutput()).trimmed() : QString());
        });
        connect(process, &QProcess::errorOccurred, process, [reply](QProcess::ProcessError error) {
            if (error == QProcess::FailedToStart)
                reply(QString());
        });
        timer->start(m_shellQuitBound);
        process->start(QStringLiteral("qs"), ipc + QStringList{QStringLiteral("activity"), QStringLiteral("quit"), QString::number(pid)});
    };
}

void ProcessActions::adoptHooks(const ProcessActions &main)
{
    m_unitReader = main.m_unitReader;
    if (main.m_shellQuitSet) {
        m_shellQuit = main.m_shellQuit;
        m_shellQuitSet = true;
    }
    m_shellQuitBound = main.m_shellQuitBound;
}

void ProcessActions::setProjection(bool valid, QSet<int> windowPids)
{
    m_projection = valid;
    m_windowPids = valid ? std::move(windowPids) : QSet<int>();
}

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
        const std::string cgroup = m_unitReader ? m_unitReader(handle.pid()) : handle.cgroup();
        p.session = isSessionProcess(cgroup);
        p.appUnit = classify(cgroup, true, false, false) == Kind::App;
        if (p.appUnit && handle.tty() != 0) {
            // AD43: its parent now, read again through the descriptor and checked (not the pid the row or the sheet read).
            const std::string parent = m_unitReader ? m_unitReader(handle.currentPpid()) : handle.parentCgroup(m_procRoot);
            p.terminal = !cgroup.empty() && parent == cgroup;
        }
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
    m_waiting = 0;
    m_outcome.stop();
    m_bound.stop();
    ++m_generation; // a shell's answer still to come goes nowhere
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
        if (!underDevRoot(m_procRoot, p.handle.pid(), p.handle.start(), p.handle.currentPpid(), roots)) {
            qInfo().noquote() << "dev guard:" << what << "of pid" << p.handle.pid()
                              << "refused: it descends from no process GRASSFIELD_ACTIVITY_DEV_ROOTS names";
            return tr("Development session: only the nested session's processes can be quit.");
        }
    }
    return {};
}

QVariantMap ProcessActions::deliver(int sig, const char *what)
{
    std::vector<const Pending *> all;
    for (const Pending &p : m_pending)
        all.push_back(&p);
    return deliverTo(all, sig, what);
}

QVariantMap ProcessActions::deliverTo(const std::vector<const Pending *> &targets, int sig, const char *what)
{
    bool failedOne = false;
    for (const Pending *t : targets) {
        const Pending &p = *t;
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
    if (m_waiting > 0)
        return {{QStringLiteral("pending"), true}};
    if (const QString refused = devRefusal("quit"); !refused.isEmpty())
        return failed(refused);
    // AM52, decided before anything is sent: a process that owns windows (the projection) is quit by the shell, which closes
    // them so the app can save or ask (AM61); a process without windows gets SIGTERM, and so does a command run in a terminal
    // (AD43, the integrator's decision on the review of 1153365). Without a projection (no shell, AM75) the process that
    // started an app unit is not quit by a signal: the sheet offers Force Quit only.
    for (Pending &p : m_pending) {
        p.windowed = !p.self && m_projection && m_windowPids.contains(p.handle.pid());
        if (!p.self && !p.windowed && p.appUnit && !p.terminal && !m_projection)
            return failed(m_pending.size() == 1 ? tr("The process couldn't be quit safely.") : tr("These processes couldn't all be quit safely."), true);
    }
    // AM54: the app's own row closes its window instead of a signal, once the others are done.
    std::vector<const Pending *> plain;
    int windowed = 0;
    m_waitSelf = m_waitUnsafe = false;
    for (const Pending &p : m_pending) {
        if (p.self)
            m_waitSelf = true;
        else if (p.windowed)
            ++windowed;
        else
            plain.push_back(&p);
    }
    m_waitFailed = !deliverTo(plain, SIGTERM, "quit").value(QStringLiteral("done")).toBool();
    if (windowed == 0) {
        if (m_waitSelf && !m_waitFailed)
            emit closeWindowRequested();
        return m_waitFailed ? failed(tr("The process couldn't be quit.")) : done();
    }
    m_waiting = windowed;
    ++m_generation;
    for (Pending &p : m_pending)
        p.answered = false;
    for (const Pending &p : m_pending) {
        if (p.windowed)
            askShell(p);
    }
    m_outcome.start();
    m_bound.start(m_shellQuitBound);
    return {{QStringLiteral("pending"), true}};
}

void ProcessActions::askShell(const Pending &p)
{
    const int pid = p.handle.pid();
    const quint64 generation = m_generation;
    QPointer<ProcessActions> self(this);
    // The answer always comes later, on this object's thread (never inside quit(), which then says "pending").
    m_shellQuit(pid, [self, pid, generation](const QString &answer) {
        if (!self)
            return;
        QMetaObject::invokeMethod(
            self.data(),
            [self, pid, generation, answer] {
                if (self && generation == self->m_generation)
                    self->takeShellAnswer(pid, answer);
            },
            Qt::QueuedConnection);
    });
}

void ProcessActions::pollOutcome()
{
    // The shell's close done, whatever its answer's delay: the process ended, or it owns no window in the projection now.
    std::vector<int> quit;
    for (const Pending &p : m_pending) {
        if (!p.windowed || p.answered)
            continue;
        const bool ended = p.handle.signal(0) == ESRCH;
        if (ended || (m_projection && !m_windowPids.contains(p.handle.pid())))
            quit.push_back(p.handle.pid());
    }
    for (int pid : quit)
        takeShellAnswer(pid, QStringLiteral("ok"));
}

void ProcessActions::takeShellAnswer(int pid, const QString &answer)
{
    Pending *found = nullptr;
    for (Pending &p : m_pending) {
        if (p.windowed && p.handle.pid() == pid)
            found = &p;
    }
    if (!found || found->answered || m_waiting <= 0)
        return;
    found->answered = true;
    if (answer == QLatin1String("no-windows")) {
        // Its windows closed meanwhile: a signal, through the descriptor, as a process without windows.
        if (!deliverTo({found}, SIGTERM, "quit").value(QStringLiteral("done")).toBool())
            m_waitFailed = true;
    } else if (answer != QLatin1String("ok")) {
        qInfo().noquote() << "activity: the shell did not quit pid" << pid << ":" << (answer.isEmpty() ? QStringLiteral("no answer") : answer);
        m_waitUnsafe = true;
    }
    if (--m_waiting == 0) {
        m_outcome.stop();
        m_bound.stop();
        finishQuit();
    }
}

void ProcessActions::finishQuit()
{
    QVariantMap result;
    if (m_waitUnsafe)
        result = failed(m_pending.size() == 1 ? tr("The process couldn't be quit safely.") : tr("These processes couldn't all be quit safely."), true);
    else if (m_waitFailed)
        result = failed(tr("The process couldn't be quit."));
    else
        result = done();
    if (m_waitSelf && !m_waitUnsafe && !m_waitFailed)
        emit closeWindowRequested();
    emit quitFinished(result);
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
        return failed(tr("This app can't send a signal to itself."));
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
