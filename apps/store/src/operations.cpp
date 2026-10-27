#include "operations.h"

#include "childprocess.h"
#include "statefile.h"

#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QRandomGenerator>
#include <QRegularExpression>
#include <QThreadPool>

#include "storeview.h"

#include <csignal>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

namespace grassfield::store {

namespace {

constexpr qint64 kMaxDetails = 64 * 1024;
const QString kOperationKey = QStringLiteral("operation");

QByteArray readTail(const QString &path, qint64 max)
{
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return {};
    if (f.size() > max)
        f.seek(f.size() - max);
    return f.read(max);
}

bool isName(const QString &name)
{
    static const QRegularExpression re(QStringLiteral("^[a-z0-9@_+][a-z0-9@._+-]{0,127}$"));
    return re.match(name).hasMatch();
}

// The web app launchers of `dir` whose Exec is `omarchy-launch-webapp <url>` (storeview.h's reading), by file name.
QHash<QString, QString> webAppUrls(const QString &dir)
{
    QHash<QString, QString> out;
    QDirIterator it(dir, {QStringLiteral("*.desktop")}, QDir::Files);
    int seen = 0;
    while (it.hasNext() && seen++ < 2000) {
        const QString path = it.next();
        QFile f(path);
        if (!f.open(QIODevice::ReadOnly) || f.size() > 64 * 1024)
            continue;
        if (const auto entry = view::parseWebAppEntry(f.readAll()))
            out.insert(QFileInfo(path).completeBaseName(), entry->url);
    }
    return out;
}

} // namespace

QJsonObject OperationRecord::toJson() const
{
    QJsonArray planned;
    for (const PlannedPackage &p : plan)
        planned.append(QJsonObject{{QStringLiteral("name"), p.name}, {QStringLiteral("version"), p.version}});
    return {{QStringLiteral("id"), id},
            {QStringLiteral("kind"), kind},
            {QStringLiteral("path"), path},
            {QStringLiteral("app"), app},
            {QStringLiteral("name"), name},
            {QStringLiteral("packages"), QJsonArray::fromStringList(packages)},
            {QStringLiteral("plan"), planned},
            {QStringLiteral("webName"), webName},
            {QStringLiteral("webUrl"), webUrl},
            {QStringLiteral("startedAt"), startedAt.toUTC().toString(Qt::ISODate)}};
}

std::optional<OperationRecord> OperationRecord::fromJson(const QJsonObject &o)
{
    OperationRecord r;
    r.id = o.value(QStringLiteral("id")).toString();
    r.kind = o.value(QStringLiteral("kind")).toString();
    r.path = o.value(QStringLiteral("path")).toString();
    r.app = o.value(QStringLiteral("app")).toString().left(255);
    r.name = o.value(QStringLiteral("name")).toString().left(80);
    for (const QJsonValue &v : o.value(QStringLiteral("packages")).toArray())
        r.packages.append(v.toString());
    for (const QJsonValue &v : o.value(QStringLiteral("plan")).toArray()) {
        PlannedPackage p;
        p.name = v.toObject().value(QStringLiteral("name")).toString();
        p.version = v.toObject().value(QStringLiteral("version")).toString().left(128);
        if (!isName(p.name))
            return std::nullopt;
        r.plan.append(p);
    }
    r.webName = o.value(QStringLiteral("webName")).toString();
    r.webUrl = o.value(QStringLiteral("webUrl")).toString();
    r.startedAt = QDateTime::fromString(o.value(QStringLiteral("startedAt")).toString(), Qt::ISODate);
    const bool kindOk = r.kind == QLatin1String("install") || r.kind == QLatin1String("remove");
    const bool helperOk = r.path == QLatin1String("helper") && !r.packages.isEmpty() && r.packages.size() <= 64
        && std::all_of(r.packages.cbegin(), r.packages.cend(), isName);
    const bool webOk = r.path == QLatin1String("webapp") && isWebAppName(r.webName);
    if (!isOperationId(r.id) || !kindOk || !(helperOk || webOk))
        return std::nullopt;
    return r;
}

QString newOperationId()
{
    quint32 words[4];
    QRandomGenerator::system()->fillRange(words);
    QString id;
    for (quint32 w : words)
        id += QStringLiteral("%1").arg(w, 8, 16, QLatin1Char('0'));
    return id;
}

bool isOperationId(const QString &id)
{
    static const QRegularExpression re(QStringLiteral("^[0-9a-f]{32}$"));
    return re.match(id).hasMatch();
}

std::optional<int> helperExitCode(const QString &statusDir, const QString &id)
{
    if (!isOperationId(id))
        return std::nullopt;
    QFile f(statusDir + QLatin1Char('/') + id + QStringLiteral(".exit"));
    if (!f.open(QIODevice::ReadOnly))
        return std::nullopt;
    bool ok = false;
    const int code = f.read(16).trimmed().toInt(&ok);
    return ok && code >= 0 && code <= 255 ? std::optional<int>(code) : std::nullopt;
}

bool helperRunning(const QString &statusDir, const QString &id)
{
    if (!isOperationId(id))
        return false;
    QFile f(statusDir + QLatin1Char('/') + id + QStringLiteral(".started"));
    if (!f.open(QIODevice::ReadOnly))
        return false;
    const QList<QByteArray> fields = f.read(64).trimmed().split(' ');
    if (fields.size() != 2)
        return false;
    bool ok = false;
    const qint64 pid = fields.at(0).toLongLong(&ok);
    if (!ok || pid <= 1)
        return false;
    QFile stat(QStringLiteral("/proc/%1/stat").arg(pid));
    if (!stat.open(QIODevice::ReadOnly))
        return false;
    const QByteArray line = stat.read(4096);
    const int close = line.lastIndexOf(") ");
    if (close < 0)
        return false;
    const QList<QByteArray> rest = line.mid(close + 2).split(' ');
    // Field 3 (state) is rest[0], so field 22 (the start time) is rest[19].
    return rest.size() > 19 && rest.at(19) == fields.at(1);
}

int countLogged(const QByteArray &logTail, const QString &verb, const QStringList &names)
{
    const QByteArray marker = "[ALPM] " + verb.toLatin1() + ' ';
    int count = 0;
    for (const QByteArray &line : logTail.split('\n')) {
        const int at = line.indexOf(marker);
        if (at < 0)
            continue;
        const QByteArray rest = line.mid(at + marker.size());
        const int space = rest.indexOf(' ');
        if (space > 0 && names.contains(QString::fromUtf8(rest.left(space))))
            ++count;
    }
    return count;
}

Outcome judge(std::optional<int> exitCode, int present, int total)
{
    if (exitCode && *exitCode == 0 && present == total)
        return Outcome::Done;
    return present > 0 ? Outcome::Interrupted : Outcome::NotFinished;
}

Operations::Operations(const OperationsConfig &config, QObject *parent)
    : QObject(parent)
    , m_config(config)
{
    m_poll.setInterval(m_config.pollMs);
    connect(&m_poll, &QTimer::timeout, this, &Operations::poll);
    m_retry.setSingleShot(true);
    m_retry.setInterval(2000);
    connect(&m_retry, &QTimer::timeout, this, &Operations::startNext);
}

Operations::~Operations()
{
    // A running pkexec or helper is left to finish (it ends in pacman); QProcess would kill what it still owns.
    if (m_process) {
        m_process->disconnect(this);
        m_process->setParent(nullptr);
        m_process.clear();
    }
    releaseUpdateLock();
}

void Operations::enqueue(const OperationRecord &record)
{
    Item item;
    item.record = record;
    m_results.remove(record.app);
    m_queue.append(item);
    emit changed();
    startNext();
}

bool Operations::removeWaiting(const QString &id)
{
    for (qsizetype i = 0; i < m_queue.size(); ++i) {
        if (m_queue.at(i).record.id == id) {
            m_queue.removeAt(i);
            emit changed();
            return true;
        }
    }
    return false;
}

void Operations::dismiss(const QString &app)
{
    if (m_results.remove(app))
        emit changed();
}

bool Operations::queued(const QString &app) const
{
    if (m_current && m_current->record.app == app)
        return true;
    return std::any_of(m_queue.cbegin(), m_queue.cend(), [&app](const Item &i) { return i.record.app == app; });
}

QList<Operations::Item> Operations::items() const
{
    QList<Item> out;
    if (m_current)
        out.append(*m_current);
    out.append(m_queue);
    return out;
}

QVariantList Operations::list() const
{
    QVariantList out;
    for (const Item &i : items()) {
        static const char *states[] = {"waiting", "authorizing", "running", "checking"};
        out.append(QVariantMap{{QStringLiteral("id"), i.record.id},
                               {QStringLiteral("app"), i.record.app},
                               {QStringLiteral("name"), i.record.name},
                               {QStringLiteral("kind"), i.record.kind},
                               {QStringLiteral("state"), QString::fromLatin1(states[int(i.state)])},
                               {QStringLiteral("blocked"), i.blocked},
                               {QStringLiteral("done"), i.done},
                               {QStringLiteral("total"), int(i.record.plan.size())}});
    }
    return out;
}

bool Operations::takeUpdateLock()
{
    if (m_lockFd >= 0)
        return true;
    // Omarchy's update lock (omarchy-update-lock: the same file): close-on-exec, so pkexec and pacman never hold it.
    const int fd = ::open(QFile::encodeName(m_config.updateLock).constData(), O_WRONLY | O_CREAT | O_CLOEXEC | O_NOCTTY, 0600);
    if (fd < 0)
        return false;
    if (::flock(fd, LOCK_EX | LOCK_NB) != 0) {
        ::close(fd);
        return false;
    }
    m_lockFd = fd;
    return true;
}

void Operations::releaseUpdateLock()
{
    if (m_lockFd >= 0) {
        ::close(m_lockFd);
        m_lockFd = -1;
    }
}

void Operations::writeRecord(const OperationRecord &record)
{
    updateStoreState(m_config.stateFile, [&record](QJsonObject &state) { state.insert(kOperationKey, record.toJson()); });
}

void Operations::clearRecord()
{
    updateStoreState(m_config.stateFile, [](QJsonObject &state) { state.remove(kOperationKey); });
}

void Operations::startNext()
{
    if (m_current || m_queue.isEmpty())
        return;
    Item &next = m_queue.first();
    if (next.record.path == QLatin1String("helper")) {
        // Only when pacman is not running and Omarchy's update lock is free (taken here, held until the helper ends).
        if (QFileInfo::exists(m_config.dbLock) || !takeUpdateLock()) {
            if (!next.blocked) {
                next.blocked = true;
                emit changed();
            }
            m_retry.start();
            return;
        }
    }
    m_current = m_queue.takeFirst();
    m_current->blocked = false;
    m_current->record.startedAt = QDateTime::currentDateTimeUtc();
    m_output.clear();
    m_followOnly = false;
    writeRecord(m_current->record);
    if (m_current->record.path == QLatin1String("helper"))
        startHelper(*m_current);
    else
        startWebApp(*m_current);
    emit changed();
}

void Operations::startHelper(Item &item)
{
    item.state = State::Authorizing;
    m_logOffset = QFileInfo(m_config.pacmanLog).size();
    auto *p = new QProcess(this);
    m_process = p;
    p->setProgram(m_config.pkexec);
    p->setArguments(QStringList{m_config.helper, item.record.kind, item.record.id} + item.record.packages);
    p->setStandardInputFile(QProcess::nullDevice());
    p->setStandardOutputFile(QProcess::nullDevice());
    // A session of its own: a terminal the Store was started from never sends pacman a signal (S6).
    p->setChildProcessModifier([] { ::setsid(); });
    connect(p, &QProcess::readyReadStandardError, this, [this, p] {
        const QByteArray err = p->readAllStandardError();
        if (m_output.size() < kMaxDetails)
            m_output += err.left(kMaxDetails - m_output.size());
    });
    connect(p, &QProcess::finished, this, &Operations::processEnded);
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart && m_process == p)
            conclude(std::nullopt, QStringLiteral("%1: %2").arg(m_config.pkexec, p->errorString()));
    });
    m_runningSince = QDateTime();
    p->start();
    m_poll.start();
}

void Operations::startWebApp(Item &item)
{
    item.state = State::Running;
    const OperationRecord &r = item.record;
    const QStringList argv = r.kind == QLatin1String("install")
        ? m_config.omarchy(QStringLiteral("omarchy-webapp-install"), {r.webName, r.webUrl, r.webIcon})
        : m_config.omarchy(QStringLiteral("omarchy-webapp-remove"), {r.webName});
    auto *p = new QProcess(this);
    m_process = p;
    p->setProgram(argv.value(0));
    p->setArguments(argv.mid(1));
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.insert(QStringLiteral("OMARCHY_REMOVE_NOTIFY"), QStringLiteral("false")); // no notification of its own
    p->setProcessEnvironment(env);
    p->setStandardInputFile(QProcess::nullDevice());
    p->setProcessChannelMode(QProcess::MergedChannels);
    p->setChildProcessModifier([] { ::setpgid(0, 0); });
    connect(p, &QProcess::readyReadStandardOutput, this, [this, p] {
        const QByteArray out = p->readAllStandardOutput();
        if (m_output.size() < kMaxDetails)
            m_output += out.left(kMaxDetails - m_output.size());
    });
    connect(p, &QProcess::finished, this, &Operations::processEnded);
    connect(p, &QProcess::errorOccurred, this, [this, p](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart && m_process == p)
            conclude(std::nullopt, p->errorString());
    });
    m_runningSince = QDateTime::currentDateTimeUtc();
    p->start();
    m_poll.start();
}

void Operations::poll()
{
    if (!m_current || m_concluding)
        return;
    Item &item = *m_current;
    const qint64 elapsed = item.record.startedAt.msecsTo(QDateTime::currentDateTimeUtc());
    if (item.record.path == QLatin1String("webapp")) {
        // Past its limit: SIGTERM to its group, SIGKILL 5 s later (it touches only the user's files).
        if (m_process && m_process->processId() > 0 && elapsed > m_config.webAppMs) {
            const pid_t pid = pid_t(m_process->processId());
            ::kill(-pid, SIGTERM);
            QTimer::singleShot(5000, this, [pid, p = m_process] {
                if (p && p->state() != QProcess::NotRunning)
                    ::kill(-pid, SIGKILL);
            });
            m_output += "\n(stopped after its time limit)";
        }
        return;
    }
    const QString dir = m_config.statusDir;
    const bool started = QFileInfo::exists(dir + QLatin1Char('/') + item.record.id + QStringLiteral(".started"));
    if (item.state == State::Authorizing) {
        if (started) {
            item.state = State::Running;
            m_runningSince = QDateTime::currentDateTimeUtc();
            emit changed();
        } else if (!m_followOnly && elapsed > m_config.authorizationMs && m_process && m_process->processId() > 0) {
            // Still waiting for the password: pkexec is the user's process until it starts the helper (a root process
            // then, which no user can signal).
            m_output += "\n(the request for permission timed out)";
            ::kill(pid_t(m_process->processId()), SIGTERM);
            return;
        }
    }
    if (item.state == State::Running) {
        const QByteArray tail = [this] {
            QFile f(m_config.pacmanLog);
            if (!f.open(QIODevice::ReadOnly) || f.size() < m_logOffset)
                return QByteArray();
            f.seek(m_logOffset);
            return f.read(8 * 1024 * 1024);
        }();
        QStringList names;
        for (const PlannedPackage &p : item.record.plan)
            names.append(p.name);
        const int done = countLogged(tail, item.record.kind == QLatin1String("install") ? QStringLiteral("installed") : QStringLiteral("removed"), names);
        if (done != item.done) {
            item.done = done;
            emit changed();
        }
        if (m_followOnly) {
            // A helper of an earlier run: it ends with its exit file.
            if (const auto code = helperExitCode(dir, item.record.id))
                conclude(code, QString());
            else if (!helperRunning(dir, item.record.id))
                conclude(std::nullopt, QString());
            return;
        }
        if (m_runningSince.isValid() && m_runningSince.msecsTo(QDateTime::currentDateTimeUtc()) > m_config.helperMs) {
            // It still runs, past 2 h: the Store stops waiting and reads the state; it never signals it.
            m_output += "\n(the Store stopped waiting for it)";
            conclude(std::nullopt, QStringLiteral("lostTrack"));
        }
    }
}

void Operations::processEnded(int exitCode, QProcess::ExitStatus status)
{
    auto *p = qobject_cast<QProcess *>(sender());
    if (!p || p != m_process)
        return;
    std::optional<int> code;
    if (status == QProcess::NormalExit)
        code = exitCode;
    if (m_current && m_current->record.path == QLatin1String("helper")) {
        // The helper's own exit file is the code when there is one (pkexec's is the same; pkexec alone gives 126, 127).
        if (const auto fileCode = helperExitCode(m_config.statusDir, m_current->record.id))
            code = fileCode;
    }
    conclude(code, QString());
}

QString Operations::helperLog(const QString &id) const
{
    return QString::fromUtf8(readTail(m_config.statusDir + QLatin1Char('/') + id + QStringLiteral(".log"), kMaxDetails));
}

void Operations::readState(const OperationRecord &record, std::function<void(int, int)> then)
{
    QPointer<Operations> self(this);
    const QString pacman = m_config.pacman;
    const QString applications = m_config.applications;
    QThreadPool::globalInstance()->start([self, record, pacman, applications, then] {
        int present = 0, total = 0;
        if (record.path == QLatin1String("helper")) {
            QStringList names;
            for (const PlannedPackage &p : record.plan)
                names.append(p.name);
            total = int(names.size());
            QHash<QString, QString> versions;
            if (!names.isEmpty()) {
                const ChildResult r = runChild(pacman, QStringList{QStringLiteral("-Q"), QStringLiteral("--")} + names);
                if (r.started && !r.timedOut && !r.overflow) {
                    for (const QByteArray &line : r.out.split('\n')) {
                        const QList<QByteArray> f = line.trimmed().split(' ');
                        if (f.size() == 2)
                            versions.insert(QString::fromUtf8(f.at(0)), QString::fromUtf8(f.at(1)));
                    }
                }
            }
            for (const PlannedPackage &p : record.plan) {
                const bool there = versions.value(p.name) == p.version;
                // An install wants each one there at its version; a removal wants each one gone.
                if (record.kind == QLatin1String("install") ? there : !versions.contains(p.name))
                    ++present;
            }
        } else {
            total = 1;
            const QHash<QString, QString> urls = webAppUrls(applications);
            const bool there = urls.value(record.webName) == record.webUrl;
            present = record.kind == QLatin1String("install") ? there : !urls.contains(record.webName);
        }
        QMetaObject::invokeMethod(self.data(), [self, then, present, total] {
            if (self)
                then(present, total);
        });
    });
}

void Operations::conclude(std::optional<int> exitCode, const QString &output)
{
    if (!m_current || m_concluding)
        return;
    m_concluding = true;
    m_poll.stop();
    const bool lostTrack = output == QLatin1String("lostTrack");
    if (!output.isEmpty() && !lostTrack)
        m_output += output.toUtf8();
    if (m_process) {
        m_process->disconnect(this);
        if (m_process->state() == QProcess::NotRunning)
            m_process->deleteLater();
        else
            m_process->setParent(nullptr); // left to finish: QProcess must not kill it
        m_process.clear();
    }
    m_current->state = State::Checking;
    emit changed();
    const OperationRecord record = m_current->record;
    readState(record, [this, record, exitCode, lostTrack](int present, int total) {
        releaseUpdateLock();
        Result result;
        result.app = record.app;
        result.kind = record.kind;
        result.record = record;
        result.present = present;
        result.total = total;
        QString details = QString::fromUtf8(m_output).trimmed();
        if (record.path == QLatin1String("helper")) {
            const QString log = helperLog(record.id).trimmed();
            details = log.isEmpty() ? details : (details.isEmpty() ? log : log + QLatin1Char('\n') + details);
        }
        result.details = details.right(kMaxDetails);
        const Outcome outcome = judge(exitCode, present, total);
        if (outcome == Outcome::Done) {
            result.outcome.clear();
        } else if (lostTrack) {
            result.outcome = QStringLiteral("lostTrack");
        } else if (exitCode && present == 0) {
            // Nothing happened: what the exit code says (the helper's codes, pkexec's 126 and 127).
            switch (*exitCode) {
            case 126:
                result.outcome = details.contains(QLatin1String("timed out")) ? QStringLiteral("timedOut") : QStringLiteral("cancelled");
                break;
            case 127:
                result.outcome = QStringLiteral("didNotStart");
                break;
            case 3:
                result.outcome = QStringLiteral("busy");
                break;
            case 4:
                result.outcome = QStringLiteral("unfinished");
                break;
            case 5:
                result.outcome = QStringLiteral("outdated");
                break;
            case 6:
                result.outcome = QStringLiteral("refused");
                break;
            case 7:
                result.outcome = QStringLiteral("notApp");
                break;
            default:
                result.outcome = QStringLiteral("failed");
            }
        } else if (!exitCode && present == 0 && details.contains(QLatin1String("timed out"))) {
            result.outcome = QStringLiteral("timedOut");
        } else {
            result.outcome = outcome == Outcome::Interrupted ? QStringLiteral("interrupted") : QStringLiteral("notFinished");
        }
        if (!result.outcome.isEmpty())
            m_results.insert(record.app, result);
        else
            m_results.remove(record.app);
        clearRecord();
        m_current.reset();
        m_concluding = false;
        emit changed();
        emit finished(record.app);
        if (m_queue.isEmpty())
            emit idle();
        startNext();
    });
}

void Operations::recover()
{
    const auto record = OperationRecord::fromJson(readStoreState(m_config.stateFile).value(kOperationKey).toObject());
    if (!record) {
        clearRecord();
        return;
    }
    Item item;
    item.record = *record;
    item.state = State::Running;
    m_current = item;
    m_output.clear();
    if (record->path == QLatin1String("helper") && !helperExitCode(m_config.statusDir, record->id) && helperRunning(m_config.statusDir, record->id)) {
        // Still running: followed again until its exit file comes (its lock is taken when free).
        m_followOnly = true;
        m_logOffset = 0;
        m_runningSince = QDateTime::currentDateTimeUtc();
        takeUpdateLock();
        m_poll.start();
        emit changed();
        return;
    }
    conclude(record->path == QLatin1String("helper") ? helperExitCode(m_config.statusDir, record->id) : std::nullopt, QString());
}

} // namespace grassfield::store
