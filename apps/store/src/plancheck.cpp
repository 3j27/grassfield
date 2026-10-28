#include "plancheck.h"

#include "childprocess.h"
#include "pacman.h"

#include <QCryptographicHash>
#include <QFile>
#include <QFileInfo>
#include <QRegularExpression>
#include <QSet>

#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>

namespace grassfield::store {

namespace {

bool isName(const QString &name)
{
    static const QRegularExpression re(QStringLiteral(R"(\A[a-z0-9@_+][a-z0-9@._+-]{0,127}\z)"));
    return re.match(name).hasMatch();
}

// The installed packages (pacman -Qq), as the user.
QSet<QString> installedNames(const QString &pacman)
{
    const ChildResult r = runChild(pacman, {QStringLiteral("-Qq")});
    QSet<QString> out;
    if (!r.ok())
        return out;
    for (const QByteArray &line : r.out.split('\n')) {
        if (!line.isEmpty())
            out.insert(QString::fromUtf8(line));
    }
    return out;
}

QString firstLines(const QByteArray &text, int lines = 12)
{
    return QString::fromUtf8(text).trimmed().section(QLatin1Char('\n'), 0, lines - 1).left(2000);
}

// The locks and pacman -Qu, shared by both checks: Refusal::None when they allow an operation.
Refusal readiness(const PlanTools &tools, bool ownOperation, QStringList *unfinished, QString *detail)
{
    if (!ownOperation && (QFileInfo::exists(tools.dbLock) || lockHeld(tools.updateLock)))
        return Refusal::Busy;
    const ChildResult qu = runChild(tools.pacman, {QStringLiteral("-Qu")});
    // pacman -Qu exits 1 when it lists nothing.
    if (!qu.started || qu.timedOut || qu.overflow || (qu.exitCode != 0 && qu.exitCode != 1)) {
        *detail = firstLines(qu.err);
        return Refusal::Failed;
    }
    *unfinished = unfinishedUpdates(qu.out);
    return unfinished->isEmpty() ? Refusal::None : Refusal::Unfinished;
}

// The recipe is an executable file of Omarchy's bin/ that the pins name, and every pinned file matches: "" or what differs.
QString setupDifference(const SetupCheck &setup)
{
    static const QRegularExpression recipe(QStringLiteral(R"(\Aomarchy-(install|remove)-[a-z0-9-]+\z)"));
    const QString path = QStringLiteral("bin/") + setup.recipe;
    const QFileInfo program(setup.root + QLatin1Char('/') + path);
    if (!recipe.match(setup.recipe).hasMatch() || !program.isFile() || !program.isExecutable())
        return path;
    if (std::none_of(setup.pins.cbegin(), setup.pins.cend(), [&path](const auto &pin) { return pin.first == path; }))
        return path;
    return omarchyDifference(setup.root, setup.pins);
}

} // namespace

QString omarchyDifference(const QString &root, const QList<std::pair<QString, QString>> &pins)
{
    if (pins.isEmpty())
        return QStringLiteral("(no pins)");
    for (const auto &[path, digest] : pins) {
        QFile f(root + QLatin1Char('/') + path);
        QCryptographicHash hash(QCryptographicHash::Sha256);
        if (!f.open(QIODevice::ReadOnly) || !hash.addData(&f) || QString::fromLatin1(hash.result().toHex()) != digest)
            return path;
    }
    return {};
}

QStringList unfinishedUpdates(const QByteArray &pacmanQu)
{
    QStringList out;
    for (const QByteArray &raw : pacmanQu.split('\n')) {
        const QString line = QString::fromUtf8(raw).trimmed();
        if (line.isEmpty() || line.endsWith(QLatin1String(" [ignored]")))
            continue;
        out.append(line);
    }
    return out;
}

QList<PlannedPackage> parsePlan(const QByteArray &out)
{
    QList<PlannedPackage> plan;
    for (const QByteArray &raw : out.split('\n')) {
        const QString line = QString::fromUtf8(raw).trimmed();
        if (line.isEmpty())
            continue;
        const QStringList f = line.split(QLatin1Char(' '));
        bool ok = false;
        PlannedPackage p;
        if (f.size() == 5) {
            p.name = f.at(0);
            p.version = f.at(1);
            p.repo = f.at(2);
            p.downloadSize = f.at(3).toLongLong(&ok);
            p.url = f.at(4);
        }
        if (!ok || !isName(p.name) || p.version.isEmpty() || p.repo.isEmpty() || p.url.isEmpty())
            return {};
        plan.append(p);
    }
    return plan;
}

QHash<QString, qint64> installedSizes(const QByteArray &pacmanSi)
{
    QHash<QString, qint64> out;
    QString name;
    for (const QByteArray &raw : pacmanSi.split('\n')) {
        const QString line = QString::fromUtf8(raw);
        const int colon = line.indexOf(QLatin1Char(':'));
        if (colon < 0)
            continue;
        const QString key = line.left(colon).trimmed();
        const QString value = line.mid(colon + 1).trimmed();
        if (key == QLatin1String("Name"))
            name = value;
        else if (key == QLatin1String("Installed Size") && !name.isEmpty())
            out.insert(name, parseSize(value));
    }
    return out;
}

bool lockHeld(const QString &path)
{
    const int fd = ::open(QFile::encodeName(path).constData(), O_RDONLY | O_CLOEXEC | O_NOCTTY);
    if (fd < 0)
        return false;
    const bool held = ::flock(fd, LOCK_EX | LOCK_NB) != 0;
    ::close(fd); // closing it lets the lock go
    return held;
}

InstallPlan checkInstall(const QStringList &packages, const PlanTools &tools, bool online, bool ownOperation)
{
    InstallPlan plan;
    if (packages.isEmpty() || !std::all_of(packages.cbegin(), packages.cend(), isName)) {
        plan.refusal = Refusal::Failed;
        return plan;
    }
    if (!online) {
        plan.refusal = Refusal::Offline;
        return plan;
    }
    plan.refusal = readiness(tools, ownOperation, &plan.unfinished, &plan.detail);
    if (plan.refusal != Refusal::None)
        return plan;

    // What pacman would add (S10): --needed leaves out what is there; a dependency it must update shows as an installed
    // package, which this database (equal to the system's, -Qu being empty) can only mean for a package held back.
    const ChildResult r = runChild(tools.pacman, QStringList{QStringLiteral("-S"), QStringLiteral("--needed"), QStringLiteral("--print"),
                                                             QStringLiteral("--print-format"), QStringLiteral("%n %v %r %s %l"),
                                                             QStringLiteral("--")}
                                                     + packages);
    if (!r.ok()) {
        plan.refusal = r.started && !r.timedOut && !r.overflow ? Refusal::Outdated : Refusal::Failed;
        plan.detail = firstLines(r.err);
        return plan;
    }
    plan.packages = parsePlan(r.out);
    if (plan.packages.isEmpty()) {
        plan.refusal = Refusal::Failed;
        plan.detail = firstLines(r.out + r.err);
        return plan;
    }
    // The app's own packages first, in the order asked.
    std::stable_sort(plan.packages.begin(), plan.packages.end(), [&packages](const PlannedPackage &a, const PlannedPackage &b) {
        const auto rank = [&packages](const QString &n) {
            const qsizetype i = packages.indexOf(n);
            return i < 0 ? packages.size() : i;
        };
        return rank(a.name) < rank(b.name);
    });
    const QSet<QString> installed = installedNames(tools.pacman);
    for (const PlannedPackage &p : plan.packages) {
        if (installed.contains(p.name))
            plan.upgrades.append(p.name);
        plan.downloadSize += qMax<qint64>(0, p.downloadSize);
    }
    if (!plan.upgrades.isEmpty()) {
        plan.refusal = Refusal::Outdated;
        return plan;
    }
    // The first file still on the mirror (S5): a 404 means the databases are older than the mirror.
    if (tools.head) {
        const int status = tools.head(QUrl(plan.packages.constFirst().url));
        if (status == 404 || status == 410) {
            plan.refusal = Refusal::Outdated;
            plan.detail = QStringLiteral("%1: HTTP %2").arg(plan.packages.constFirst().url).arg(status);
            return plan;
        }
    }
    QStringList names;
    for (const PlannedPackage &p : plan.packages)
        names.append(p.name);
    const ChildResult si = runChild(tools.pacman, QStringList{QStringLiteral("-Si"), QStringLiteral("--")} + names);
    if (si.ok()) {
        const QHash<QString, qint64> sizes = installedSizes(si.out);
        for (const PlannedPackage &p : plan.packages)
            plan.installedSize += qMax<qint64>(0, sizes.value(p.name, 0));
    }
    return plan;
}

RemovePlan checkRemove(const QStringList &packages, const DenyList &deny, const PlanTools &tools, bool ownOperation)
{
    RemovePlan plan;
    if (packages.isEmpty() || !std::all_of(packages.cbegin(), packages.cend(), isName)) {
        plan.refusal = Refusal::Failed;
        return plan;
    }
    QStringList unfinished;
    plan.refusal = readiness(tools, ownOperation, &unfinished, &plan.detail);
    if (plan.refusal == Refusal::Unfinished)
        plan.detail = unfinished.join(QLatin1Char('\n'));
    if (plan.refusal != Refusal::None)
        return plan;
    // What -Rns removes: -Rs --print (pacman refuses --print with -n, S16).
    const ChildResult r = runChild(tools.pacman, QStringList{QStringLiteral("-Rs"), QStringLiteral("--print"), QStringLiteral("--print-format"),
                                                             QStringLiteral("%n %v"), QStringLiteral("--")}
                                                     + packages);
    if (!r.ok()) {
        // The "breaks dependency" lines go to stdout, "error: failed to prepare transaction" to stderr (probed, pacman 7).
        plan.dependents = dependentsFromError(r.out + '\n' + r.err);
        plan.refusal = plan.dependents.isEmpty() ? Refusal::Failed : Refusal::Dependency;
        plan.detail = firstLines(r.err + r.out);
        return plan;
    }
    QStringList lines;
    for (const QByteArray &raw : r.out.split('\n')) {
        const QString line = QString::fromUtf8(raw).trimmed();
        if (line.isEmpty())
            continue;
        const QString name = line.section(QLatin1Char(' '), 0, 0);
        if (!isName(name)) {
            plan.refusal = Refusal::Failed;
            return plan;
        }
        lines.append(line);
        PlannedPackage p;
        p.name = name;
        p.version = line.section(QLatin1Char(' '), 1, 1);
        plan.packages.append(p);
    }
    plan.protectedPackage = protectedInPlan(lines, deny);
    if (!plan.protectedPackage.isEmpty())
        plan.refusal = Refusal::Protected;
    return plan;
}

InstallPlan checkSetupInstall(const QStringList &packages, const SetupCheck &setup, const PlanTools &tools, bool online, bool ownOperation)
{
    const QString differs = setupDifference(setup);
    if (!differs.isEmpty()) {
        InstallPlan plan;
        plan.refusal = Refusal::OmarchyChanged;
        plan.detail = differs;
        return plan;
    }
    return checkInstall(packages, tools, online, ownOperation);
}

RemovePlan checkSetupRemove(const QStringList &packages, const SetupCheck &setup, const DenyList &deny, const PlanTools &tools, bool ownOperation)
{
    const QString differs = setupDifference(setup);
    if (!differs.isEmpty()) {
        RemovePlan plan;
        plan.refusal = Refusal::OmarchyChanged;
        plan.detail = differs;
        return plan;
    }
    return checkRemove(packages, deny, tools, ownOperation);
}

} // namespace grassfield::store
