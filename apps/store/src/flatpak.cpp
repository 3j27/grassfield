#include "flatpak.h"

#include "catalog.h"
#include "childprocess.h"

#include <QElapsedTimer>
#include <QProcess>
#include <QRegularExpression>
#include <QSysInfo>

#include <cerrno>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <pty.h>
#include <sys/ioctl.h>
#include <sys/prctl.h>
#include <unistd.h>

namespace grassfield::store {

namespace {

constexpr qint64 kTerminalMax = 1024 * 1024; // the plan's output, at most

// A ref's arch or branch: letters, digits, "_", "." and "-", never first a "." or "-", never "..".
bool isPart(const QString &part, int max)
{
    static const QRegularExpression re(QStringLiteral(R"(\A[A-Za-z0-9_][A-Za-z0-9._-]*\z)"));
    return part.size() <= max && re.match(part).hasMatch() && !part.contains(QLatin1String(".."));
}

// flatpak's last words when a command failed: its error lines, else the last lines it wrote.
QString lastWords(const QStringList &lines)
{
    QStringList errors;
    for (const QString &l : lines) {
        if (l.startsWith(QLatin1String("error:")) || l.startsWith(QLatin1String("Error:")))
            errors.append(l.trimmed());
    }
    const QStringList chosen = errors.isEmpty() ? lines.mid(qMax(0, int(lines.size()) - 6)) : errors;
    return cleanPlainText(chosen.join(QLatin1Char('\n')).trimmed(), 2000, true);
}

QString childWords(const ChildResult &r, const QString &command)
{
    if (!r.started)
        return command + QStringLiteral(": could not be started");
    if (r.timedOut)
        return command + QStringLiteral(": no answer in time");
    const QString words = lastWords(terminalLines(r.err + r.out));
    return words.isEmpty() ? QStringLiteral("%1: exit %2").arg(command).arg(r.exitCode) : words;
}

ChildOptions options(const FlatpakTools &tools, int timeoutMs)
{
    ChildOptions o;
    o.timeoutMs = timeoutMs;
    o.maxOut = 4 * 1024 * 1024;
    o.extraEnv = tools.env;
    o.cancel = tools.cancel;
    return o;
}

// A command on a pseudo-terminal of the Store's own (flatpak asks its questions only on one, S23), answering what
// flatpakPrompt reads: yes for a runtime the app requires, no to proceed (the table is then complete) and to anything else.
struct TerminalRun {
    bool started = false, proceeded = false, other = false, timedOut = false;
    int exitCode = -1;
    QByteArray output;
};

TerminalRun runPlan(const QString &program, const QStringList &args, const QProcessEnvironment &extraEnv, int timeoutMs)
{
    TerminalRun r;
    int master = -1, slave = -1;
    winsize size{};
    size.ws_row = 50;
    size.ws_col = 250; // wide enough that flatpak's table never shortens an id
    if (::openpty(&master, &slave, nullptr, nullptr, &size) != 0)
        return r;
    ::fcntl(master, F_SETFD, FD_CLOEXEC);
    QProcess p;
    p.setProgram(program);
    p.setArguments(args);
    QProcessEnvironment env;
    env.insert(QStringLiteral("PATH"), QStringLiteral("/usr/bin:/bin"));
    env.insert(QStringLiteral("LC_ALL"), QStringLiteral("C"));
    env.insert(QStringLiteral("TERM"), QStringLiteral("dumb"));
    for (const QString &key : extraEnv.keys())
        env.insert(key, extraEnv.value(key));
    p.setProcessEnvironment(env);
    p.setStandardInputFile(QProcess::nullDevice());
    p.setStandardOutputFile(QProcess::nullDevice());
    p.setStandardErrorFile(QProcess::nullDevice());
    p.setChildProcessModifier([slave] {
        // A session of its own whose controlling terminal is the pseudo-terminal: its three standard files.
        ::setsid();
        ::ioctl(slave, TIOCSCTTY, 0);
        ::dup2(slave, STDIN_FILENO);
        ::dup2(slave, STDOUT_FILENO);
        ::dup2(slave, STDERR_FILENO);
        if (slave > STDERR_FILENO)
            ::close(slave);
        ::prctl(PR_SET_PDEATHSIG, SIGKILL);
    });
    p.start();
    r.started = p.waitForStarted(5000);
    ::close(slave);
    if (!r.started) {
        ::close(master);
        return r;
    }
    const qint64 pid = p.processId();
    const auto answer = [master](const char *text) {
        const ssize_t n = ::write(master, text, ::strlen(text));
        Q_UNUSED(n);
    };
    QElapsedTimer clock;
    clock.start();
    qsizetype answered = 0;
    int runtimes = 0;
    bool ended = false;
    while (!ended) {
        pollfd fd{master, POLLIN, 0};
        const int ready = ::poll(&fd, 1, 100);
        if (ready > 0 && (fd.revents & POLLIN)) {
            char buffer[4096];
            const ssize_t got = ::read(master, buffer, sizeof buffer);
            if (got > 0)
                r.output.append(buffer, got);
            else if (got == 0 || (errno != EINTR && errno != EAGAIN))
                ended = true; // EIO: every holder of the terminal's other side is gone
        } else if (ready > 0 && (fd.revents & (POLLHUP | POLLERR))) {
            ended = true;
        }
        const QStringList pending = terminalLines(r.output.mid(answered));
        const FlatpakPrompt prompt = flatpakPrompt(pending);
        if (prompt != FlatpakPrompt::None && (r.proceeded || r.other)) {
            // Past the plan, or after a question of another kind: no to everything (0 to a choice) until it ends.
            answer(pending.join(QLatin1Char(' ')).contains(QLatin1String("[0-")) ? "0\n" : "n\n");
            answered = r.output.size();
        } else {
            switch (prompt) {
            case FlatpakPrompt::None:
                break;
            case FlatpakPrompt::RequiredRuntime:
                // Yes adds the runtime to the plan; nothing is installed before "Proceed". Never more than a few.
                if (++runtimes > 8) {
                    answer("n\n");
                    r.other = true;
                } else {
                    answer("y\n");
                }
                answered = r.output.size();
                break;
            case FlatpakPrompt::Proceed:
                answer("n\n");
                r.proceeded = true;
                answered = r.output.size();
                break;
            case FlatpakPrompt::Other:
                answer(pending.join(QLatin1Char(' ')).contains(QLatin1String("[0-")) ? "0\n" : "n\n");
                r.other = true;
                answered = r.output.size();
                break;
            }
        }
        if (r.output.size() > kTerminalMax || clock.elapsed() > timeoutMs) {
            r.timedOut = true;
            ::kill(-pid_t(pid), SIGTERM);
            if (!p.waitForFinished(5000)) {
                ::kill(-pid_t(pid), SIGKILL);
                p.waitForFinished(2000);
            }
            ::close(master);
            return r;
        }
    }
    if (p.waitForFinished(5000) && p.exitStatus() == QProcess::NormalExit)
        r.exitCode = p.exitCode();
    ::close(master);
    return r;
}

} // namespace

bool isFlatpakAppRef(const QString &ref)
{
    const QStringList parts = ref.split(QLatin1Char('/'));
    return ref.size() <= 400 && parts.size() == 4 && parts.at(0) == QLatin1String("app") && isFlatpakId(parts.at(1))
        && isPart(parts.at(2), 32) && isPart(parts.at(3), 64);
}

bool isFlatpakRef(const QString &ref)
{
    const QStringList parts = ref.split(QLatin1Char('/'));
    return ref.size() <= 400 && parts.size() == 4 && (parts.at(0) == QLatin1String("app") || parts.at(0) == QLatin1String("runtime"))
        && isFlatpakId(parts.at(1)) && isPart(parts.at(2), 32) && isPart(parts.at(3), 64);
}

QString flatpakRefId(const QString &ref)
{
    return isFlatpakAppRef(ref) ? ref.section(QLatin1Char('/'), 1, 1) : QString();
}

QString flatpakArch()
{
    const QString cpu = QSysInfo::currentCpuArchitecture();
    if (cpu == QLatin1String("x86_64") || cpu == QLatin1String("i386") || cpu == QLatin1String("arm"))
        return cpu;
    if (cpu == QLatin1String("arm64"))
        return QStringLiteral("aarch64");
    return {};
}

QSet<QString> parseFlatpakList(const QByteArray &out)
{
    QSet<QString> ids;
    for (const QByteArray &line : out.split('\n')) {
        const QString id = QString::fromUtf8(line).trimmed();
        if (isFlatpakId(id))
            ids.insert(id);
    }
    return ids;
}

bool hasFlathubRemote(const QByteArray &out)
{
    for (const QByteArray &line : out.split('\n')) {
        if (QString::fromUtf8(line).trimmed() == kFlathubRemote)
            return true;
    }
    return false;
}

QStringList terminalLines(const QByteArray &output)
{
    static const QRegularExpression escapes(QStringLiteral(R"(\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(\x07|\x1b\\)|\x1b[()][0-9A-Za-z]|\x1b[=>78])"));
    QString text = QString::fromUtf8(output);
    text.remove(escapes);
    text.replace(QLatin1String("\r\n"), QLatin1String("\n"));
    text.replace(QLatin1Char('\r'), QLatin1Char('\n'));
    return text.split(QLatin1Char('\n'));
}

qint64 parseFlatpakSize(const QString &text)
{
    static const QRegularExpression re(QStringLiteral(R"(\A\s*([0-9]+(?:[.,][0-9]+)?)[\s\x{00A0}?]*(bytes?|[kMGT]B)\s*\z)"));
    const QRegularExpressionMatch m = re.match(text);
    if (!m.hasMatch())
        return -1;
    QString number = m.captured(1);
    number.replace(QLatin1Char(','), QLatin1Char('.'));
    bool ok = false;
    const double value = number.toDouble(&ok);
    if (!ok)
        return -1;
    const QString unit = m.captured(2);
    double factor = 1;
    if (unit == QLatin1String("kB"))
        factor = 1e3;
    else if (unit == QLatin1String("MB"))
        factor = 1e6;
    else if (unit == QLatin1String("GB"))
        factor = 1e9;
    else if (unit == QLatin1String("TB"))
        factor = 1e12;
    return qint64(value * factor);
}

QList<FlatpakRow> parseFlatpakPlan(const QStringList &lines)
{
    // " 1.     org.freedesktop.Platform.GL.default   25.08       i  flathub < 147.9 MB" (S23); the download column may say
    // "(partial)" after its size.
    static const QRegularExpression row(QStringLiteral(R"(\A\s*([0-9]{1,3})\.\s+(\S+)\s+(\S+)\s+([iur])\s+(\S+)(?:\s+<?\s*(.*?))?\s*(?:\(partial\))?\s*\z)"));
    QList<FlatpakRow> out;
    for (const QString &line : lines) {
        if (line.contains(QLatin1String("Proceed with these changes")))
            break;
        const QRegularExpressionMatch m = row.match(line);
        if (!m.hasMatch() || m.captured(1).toInt() != out.size() + 1 || m.captured(5) != kFlathubRemote)
            continue;
        FlatpakRow r;
        r.id = m.captured(2).left(255);
        r.branch = m.captured(3).left(64);
        r.op = m.captured(4);
        r.download = parseFlatpakSize(m.captured(6));
        out.append(r);
    }
    return out;
}

FlatpakPrompt flatpakPrompt(const QStringList &lines)
{
    int last = int(lines.size()) - 1;
    while (last >= 0 && lines.at(last).trimmed().isEmpty())
        --last;
    if (last < 0)
        return FlatpakPrompt::None;
    const QString line = lines.at(last).trimmed();
    // flatpak's questions end "[Y/n]: " or, for a choice, "[0-2]: "; a line still on its way does not.
    if (!line.endsWith(QLatin1String("]:")))
        return FlatpakPrompt::None;
    if (line == QLatin1String("Proceed with these changes to the user installation? [Y/n]:"))
        return FlatpakPrompt::Proceed;
    if (line == QLatin1String("Do you want to install it? [Y/n]:")) {
        static const QRegularExpression required(QStringLiteral(R"(\ARequired runtime for \S+ \(runtime/\S+\) found in remote flathub\z)"));
        int previous = last - 1;
        while (previous >= 0 && lines.at(previous).trimmed().isEmpty())
            --previous;
        if (previous >= 0 && required.match(lines.at(previous).trimmed()).hasMatch())
            return FlatpakPrompt::RequiredRuntime;
    }
    return FlatpakPrompt::Other;
}

std::optional<QStringList> flatpakAccess(const QByteArray &metadata)
{
    const std::optional<FlatpakPermissions> permissions = flatpakPermissions(metadata);
    if (!permissions)
        return std::nullopt;
    return permissions->access;
}

FlatpakFacts parseFlatpakInfo(const QByteArray &out)
{
    FlatpakFacts facts;
    static const QRegularExpression field(QStringLiteral(R"(\A\s*(Version|License|Download Size|Installed Size|Installed):\s*(.*?)\s*\z)"));
    for (const QString &line : terminalLines(out)) {
        const QRegularExpressionMatch m = field.match(line);
        if (!m.hasMatch())
            continue;
        const QString key = m.captured(1), value = m.captured(2);
        if (key == QLatin1String("Version"))
            facts.version = cleanPlainText(value, 64, false);
        else if (key == QLatin1String("License"))
            facts.license = cleanPlainText(value, 200, false);
        else if (key == QLatin1String("Download Size"))
            facts.download = parseFlatpakSize(value);
        else
            facts.installed = parseFlatpakSize(value);
    }
    return facts;
}

int flatpakSteps(const QByteArray &output, bool install)
{
    static const QRegularExpression installing(QStringLiteral(R"(\A\s*(?:Installing|Updating)\s+((?:app|runtime)/\S+))"));
    static const QRegularExpression uninstalling(QStringLiteral(R"(\A\s*Uninstalling\s+((?:app|runtime)/\S+))"));
    QSet<QString> refs;
    for (const QString &line : terminalLines(output)) {
        const QRegularExpressionMatch m = (install ? installing : uninstalling).match(line);
        if (m.hasMatch())
            refs.insert(m.captured(1));
    }
    return int(refs.size());
}

QProcessEnvironment flatpakEnvironment()
{
    const QProcessEnvironment system = QProcessEnvironment::systemEnvironment();
    QProcessEnvironment env;
    for (const char *key : {"HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS",
                            "FLATPAK_USER_DIR", "http_proxy", "https_proxy", "HTTP_PROXY", "HTTPS_PROXY", "no_proxy", "NO_PROXY"}) {
        const QString name = QLatin1String(key);
        if (system.contains(name))
            env.insert(name, system.value(name));
    }
    return env;
}

std::optional<QSet<QString>> listFlatpakApps(const FlatpakTools &tools)
{
    const ChildResult r = runChild(tools.flatpak, {QStringLiteral("list"), QStringLiteral("--user"), QStringLiteral("--app"),
                                                   QStringLiteral("--columns=application")},
                                   options(tools, 20000));
    if (!r.ok())
        return std::nullopt;
    return parseFlatpakList(r.out);
}

bool flathubAdded(const FlatpakTools &tools)
{
    const ChildResult r = runChild(tools.flatpak, {QStringLiteral("remotes"), QStringLiteral("--user"), QStringLiteral("--columns=name")},
                                   options(tools, 20000));
    return r.ok() && hasFlathubRemote(r.out);
}

QString addFlathub(const FlatpakTools &tools)
{
    const ChildResult r = runChild(tools.flatpak, {QStringLiteral("remote-add"), QStringLiteral("--user"), QStringLiteral("--if-not-exists"),
                                                   kFlathubRemote, kFlathubRepoFile},
                                   options(tools, 60000));
    if (!r.ok())
        return childWords(r, QStringLiteral("flatpak remote-add"));
    return refreshFlathubAppStream(tools);
}

QString refreshFlathubAppStream(const FlatpakTools &tools)
{
    const ChildResult r = runChild(tools.flatpak, {QStringLiteral("update"), QStringLiteral("--user"), QStringLiteral("--appstream"), kFlathubRemote},
                                   options(tools, 180000));
    return r.ok() ? QString() : childWords(r, QStringLiteral("flatpak update --appstream"));
}

bool flatpakInstalled(const FlatpakTools &tools, const QString &appId)
{
    // `list`, not `info`'s exit code: flatpak 1.18.4's info prints every field, then may abort on an assertion (S28).
    const std::optional<QSet<QString>> apps = isFlatpakId(appId) ? listFlatpakApps(tools) : std::nullopt;
    return apps && apps->contains(appId);
}

std::optional<FlatpakFacts> flatpakFacts(const FlatpakTools &tools, const QString &target, bool installed)
{
    if (installed ? !isFlatpakId(target) : !isFlatpakAppRef(target))
        return std::nullopt;
    const QStringList head = installed ? QStringList{QStringLiteral("info"), QStringLiteral("--user")}
                                       : QStringList{QStringLiteral("remote-info"), QStringLiteral("--user")};
    const QStringList where = installed ? QStringList{QStringLiteral("--"), target} : QStringList{kFlathubRemote, target};
    const ChildResult info = runChild(tools.flatpak, head + where, options(tools, 30000));
    // Its lines, whatever its exit code: flatpak 1.18.4 prints every field, then may abort on an assertion (a remote
    // without a collection id, S28); an app it does not know prints no Ref.
    if (!info.started || info.timedOut || info.overflow || !info.out.contains("Ref:"))
        return std::nullopt;
    FlatpakFacts facts = parseFlatpakInfo(info.out);
    const ChildResult meta = runChild(tools.flatpak, head + QStringList{QStringLiteral("--show-metadata")} + where, options(tools, 30000));
    if (meta.ok()) {
        facts.permissions = flatpakPermissions(meta.out);
        if (facts.permissions)
            facts.access = facts.permissions->access;
    }
    return facts;
}

QList<FlatpakUpdate> parseFlatpakUpdates(const QByteArray &out)
{
    QList<FlatpakUpdate> updates;
    for (const QByteArray &raw : out.split('\n')) {
        const QStringList f = QString::fromUtf8(raw).trimmed().split(QLatin1Char('\t'));
        if (f.size() != 4 || updates.size() >= kMaxFlatpakUpdates)
            continue;
        FlatpakUpdate u;
        u.id = f.at(0).trimmed();
        u.branch = f.at(1).trimmed();
        u.origin = f.at(2).trimmed();
        u.ref = f.at(3).trimmed();
        const QStringList parts = u.ref.split(QLatin1Char('/'));
        if (!isFlatpakRef(u.ref) || parts.at(1) != u.id || parts.at(3) != u.branch || u.origin.isEmpty() || u.origin.size() > 64)
            continue;
        u.app = parts.at(0) == QLatin1String("app");
        updates.append(u);
    }
    return updates;
}

std::optional<QList<FlatpakUpdate>> listFlatpakUpdates(const FlatpakTools &tools)
{
    const ChildResult r = runChild(tools.flatpak, {QStringLiteral("remote-ls"), QStringLiteral("--user"), QStringLiteral("--updates"),
                                                   QStringLiteral("--columns=application,branch,origin,ref")},
                                   options(tools, 60000));
    if (!r.ok())
        return std::nullopt;
    return parseFlatpakUpdates(r.out);
}

bool isFlatpakCommit(const QString &commit)
{
    static const QRegularExpression re(QStringLiteral("\\A[0-9a-f]{64}\\z"));
    return re.match(commit).hasMatch();
}

QString flatpakRemoteCommit(const FlatpakTools &tools, const QString &ref)
{
    if (!isFlatpakRef(ref))
        return {};
    const ChildResult r = runChild(tools.flatpak, {QStringLiteral("remote-info"), QStringLiteral("--user"), QStringLiteral("--show-commit"),
                                                   kFlathubRemote, ref},
                                   options(tools, 30000));
    const QString commit = r.ok() ? QString::fromLatin1(r.out).section(QLatin1Char('\n'), 0, 0).trimmed() : QString();
    return isFlatpakCommit(commit) ? commit : QString();
}

QString flatpakInstalledCommit(const FlatpakTools &tools, const QString &ref)
{
    if (!isFlatpakRef(ref))
        return {};
    const ChildResult r = runChild(tools.flatpak, {QStringLiteral("info"), QStringLiteral("--user"), QStringLiteral("--show-commit"),
                                                   QStringLiteral("--"), ref},
                                   options(tools, 30000));
    const QString commit = r.ok() ? QString::fromLatin1(r.out).section(QLatin1Char('\n'), 0, 0).trimmed() : QString();
    return isFlatpakCommit(commit) ? commit : QString();
}

std::optional<QList<FlatpakPermissionChange>> flatpakPermissionChanges(const FlatpakTools &tools, const QString &ref, const QString &commit)
{
    if (!isFlatpakAppRef(ref) || (!commit.isEmpty() && !isFlatpakCommit(commit)))
        return std::nullopt;
    const ChildResult installed = runChild(tools.flatpak, {QStringLiteral("info"), QStringLiteral("--user"), QStringLiteral("--show-metadata"),
                                                           QStringLiteral("--"), ref},
                                           options(tools, 30000));
    // The commit the update will deploy (S32a: --commit reads it even once a newer one is published).
    QStringList newerArgs{QStringLiteral("remote-info"), QStringLiteral("--user"), QStringLiteral("--show-metadata")};
    if (!commit.isEmpty())
        newerArgs << QStringLiteral("--commit=") + commit;
    newerArgs << kFlathubRemote << ref;
    const ChildResult newer = runChild(tools.flatpak, newerArgs, options(tools, 30000));
    if (!installed.ok() || !newer.ok())
        return std::nullopt;
    // The installed side read narrowest, the newer widest (ADR-0049): no new grant hides behind an old one read generously.
    const std::optional<FlatpakPermissions> before = flatpakPermissions(installed.out, FlatpakReading::Narrowest);
    const std::optional<FlatpakPermissions> after = flatpakPermissions(newer.out);
    // Both of the app the ref names: metadata of another app is not this update's.
    const QString id = flatpakRefId(ref);
    if (!before || !after || before->appId != id || after->appId != id)
        return std::nullopt;
    return diffFlatpakPermissions(*before, *after);
}

InstallPlan checkFlatpakInstall(const QString &ref, const FlatpakTools &tools, bool online)
{
    InstallPlan plan;
    plan.installedSize = -1;
    if (!online) {
        plan.refusal = Refusal::Offline;
        return plan;
    }
    if (!isFlatpakAppRef(ref)) {
        plan.refusal = Refusal::Failed;
        plan.detail = QStringLiteral("not an app of Flathub: ") + ref.left(80);
        return plan;
    }
    // What it may reach: its metadata as Flathub serves it (S22); an app Flathub lacks ends here (exit 1).
    const ChildResult meta = runChild(tools.flatpak, {QStringLiteral("remote-info"), QStringLiteral("--user"), QStringLiteral("--show-metadata"),
                                                      kFlathubRemote, ref},
                                      options(tools, 30000));
    if (!meta.ok()) {
        plan.refusal = Refusal::Failed;
        plan.detail = childWords(meta, QStringLiteral("flatpak remote-info"));
        return plan;
    }
    const std::optional<FlatpakPermissions> permissions = flatpakPermissions(meta.out);
    if (!permissions) {
        // What it may reach must be said before it is installed (SD25): without its metadata, no plan.
        plan.refusal = Refusal::Failed;
        plan.detail = QStringLiteral("flatpak remote-info: no metadata for ") + ref.left(80);
        return plan;
    }
    plan.access = permissions->access;
    plan.permissions = permissions->grants;
    plan.morePermissions = permissions->more;
    // flatpak's own plan (SD25): the refs it would add with the app, its runtime and their extensions, answered no.
    const TerminalRun run = runPlan(tools.flatpak, {QStringLiteral("install"), QStringLiteral("--user"), kFlathubRemote, ref}, tools.env,
                                    tools.planMs);
    const QStringList lines = terminalLines(run.output);
    const QList<FlatpakRow> rows = parseFlatpakPlan(lines);
    if (!run.started || run.timedOut || !run.proceeded || run.other || rows.isEmpty()) {
        plan.refusal = Refusal::Failed;
        plan.detail = !run.started ? QStringLiteral("flatpak install: could not be started")
            : run.timedOut         ? QStringLiteral("flatpak install: no plan in time")
                                   : lastWords(lines);
        return plan;
    }
    for (const FlatpakRow &row : rows) {
        PlannedPackage p;
        p.name = row.id;
        p.version = row.branch;
        p.repo = kFlathubRemote;
        p.downloadSize = row.download;
        plan.packages.append(p);
        if (row.download > 0)
            plan.downloadSize += row.download;
    }
    return plan;
}

} // namespace grassfield::store
