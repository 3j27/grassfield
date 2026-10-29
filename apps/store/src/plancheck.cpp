#include "plancheck.h"

#include "childprocess.h"
#include "pacman.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
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
    static const QRegularExpression recipe(QStringLiteral(R"(\A(omarchy-(install|remove)-[a-z0-9-]+|omarchy-pkg-aur-add|omarchy-pkg-drop)\z)"));
    const QString path = QStringLiteral("bin/") + setup.recipe;
    const QFileInfo program(setup.root + QLatin1Char('/') + path);
    if (!recipe.match(setup.recipe).hasMatch() || !program.isFile() || !program.isExecutable())
        return path;
    for (const QString &required : requiredPins(setup.recipe)) {
        if (std::none_of(setup.pins.cbegin(), setup.pins.cend(), [&required](const auto &pin) { return pin.first == required; }))
            return required;
    }
    return omarchyDifference(setup.root, setup.pins);
}

} // namespace

QString databasesBehind(const QByteArray &softwareUpdate, const QDateTime &synced)
{
    if (softwareUpdate.size() > 512 * 1024 || !synced.isValid())
        return {};
    const QJsonObject o = QJsonDocument::fromJson(softwareUpdate).object();
    const QDateTime checked = QDateTime::fromString(o.value(QStringLiteral("checkedAt")).toString(), Qt::ISODate);
    if (o.value(QStringLiteral("version")).toInt() != 1 || o.value(QStringLiteral("state")).toString() != QLatin1String("available")
        || !checked.isValid() || checked <= synced)
        return {};
    // Grassfield's own release alone is not the mirror's: the Store installs nothing from Grassfield's repository.
    const int others = o.value(QStringLiteral("others")).toInt();
    const QString omarchy = o.value(QStringLiteral("omarchy")).toObject().value(QStringLiteral("available")).toString();
    if (others <= 0 && omarchy.isEmpty())
        return {};
    return QStringLiteral("Software Update, %1: %2 other updates%3; the package databases date from %4")
        .arg(checked.toUTC().toString(Qt::ISODate))
        .arg(qMax(0, others))
        .arg(omarchy.isEmpty() ? QString() : QStringLiteral(", Omarchy ") + omarchy.left(64))
        .arg(synced.toUTC().toString(Qt::ISODate));
}

QDateTime newestSync(const QString &syncDir)
{
    QDateTime newest;
    for (const QFileInfo &f : QDir(syncDir).entryInfoList({QStringLiteral("*.db")}, QDir::Files)) {
        if (!newest.isValid() || f.lastModified() > newest)
            newest = f.lastModified();
    }
    return newest;
}

bool downloadGone(const QString &log)
{
    // pacman's own lines (LC_ALL=C): "error: failed retrieving file '<file>' from <host> : The requested URL returned error:
    // 404", or "... : Exceeded the maximum allowed file size (16384) with 16384 bytes" for an error page served as the file.
    static const QRegularExpression gone(QStringLiteral(R"(^error: failed retrieving file '[^']+' from \S+ : )"
                                                        R"((The requested URL returned error: (404|410)|Exceeded the maximum allowed file size))"),
                                         QRegularExpression::MultilineOption);
    return gone.match(log).hasMatch();
}

QStringList requiredPins(const QString &recipe)
{
    QStringList out{QStringLiteral("bin/") + recipe};
    if (recipe == QLatin1String("omarchy-pkg-aur-add"))
        out.append(QStringLiteral("bin/omarchy-pkg-missing"));
    return out;
}

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
    // The mirror has moved on since the databases were synced: the system is updated first, before anything downloads.
    if (!tools.behind.isEmpty()) {
        plan.refusal = Refusal::Outdated;
        plan.detail = tools.behind;
        return plan;
    }

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
    // Every file still on the mirror (S5; the owner's rc1-7 failed on its 30th file, after the first had answered): a 404
    // means the databases are older than the mirror. At most 64 files are asked, and none more once one goes unanswered
    // (a mirror that does not answer is pacman's to report, not a plan's).
    if (tools.head) {
        for (qsizetype i = 0; i < plan.packages.size() && i < 64; ++i) {
            const QString url = plan.packages.at(i).url;
            const int status = tools.head(QUrl(url));
            if (status == 404 || status == 410) {
                plan.refusal = Refusal::Outdated;
                plan.detail = QStringLiteral("%1: HTTP %2").arg(url).arg(status);
                return plan;
            }
            if (status <= 0)
                break;
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

InstallPlan checkAurInstall(const QString &name, const SetupCheck &setup, const std::function<AurAnswer(const QStringList &)> &info,
                            const PlanTools &tools, bool online, bool ownOperation)
{
    constexpr int kRounds = 6;
    constexpr int kBuiltMax = 25;
    InstallPlan plan;
    if (!isName(name)) {
        plan.refusal = Refusal::Failed;
        return plan;
    }
    if (const QString differs = setupDifference(setup); !differs.isEmpty()) {
        plan.refusal = Refusal::OmarchyChanged;
        plan.detail = differs;
        return plan;
    }
    if (!online) {
        plan.refusal = Refusal::Offline;
        return plan;
    }
    plan.refusal = readiness(tools, ownOperation, &plan.unfinished, &plan.detail);
    if (plan.refusal != Refusal::None)
        return plan;
    if (!tools.behind.isEmpty()) { // as any install (checkInstall): the system first
        plan.refusal = Refusal::Outdated;
        plan.detail = tools.behind;
        return plan;
    }
    // Whatever pacman resolves the name to (the package, a provider of it, a group of that name): yay would install that
    // from the repositories, not the AUR's. pacman -Sp, as the user (S10): exit 0 resolved; 1 with "target not found"
    // (LC_ALL=C, childprocess.cpp) not in the repositories; anything else is not an answer.
    const ChildResult sp = runChild(tools.pacman, {QStringLiteral("-Sp"), QStringLiteral("--print-format"), QStringLiteral("%n"),
                                                   QStringLiteral("--"), name});
    if (!sp.started || sp.timedOut || sp.overflow) {
        plan.refusal = Refusal::Failed;
        plan.detail = firstLines(sp.err);
        return plan;
    }
    if (sp.exitCode == 0) {
        plan.refusal = Refusal::Repository;
        plan.detail = name;
        return plan;
    }
    if (!sp.err.contains("target not found: " + name.toUtf8())) {
        plan.refusal = Refusal::Failed;
        plan.detail = firstLines(sp.err + sp.out);
        return plan;
    }

    QStringList pending{name}, repoNames;
    QSet<QString> seen{name};
    for (int round = 0; round < kRounds && !pending.isEmpty(); ++round) {
        const AurAnswer answer = info(pending);
        if (!answer.ok) {
            plan.refusal = Refusal::Failed;
            plan.detail = QStringLiteral("aur.archlinux.org: ") + answer.error;
            return plan;
        }
        QStringList dependencies;
        for (const QString &n : pending) {
            const auto it = std::find_if(answer.packages.cbegin(), answer.packages.cend(), [&n](const AurPackage &p) { return p.name == n; });
            if (it == answer.packages.cend()) {
                plan.refusal = Refusal::NotOnAur;
                plan.detail = n;
                return plan;
            }
            PlannedPackage built;
            built.name = it->name;
            built.version = it->version;
            built.repo = QStringLiteral("aur");
            plan.built.append(built);
            plan.incomplete = plan.incomplete || it->dependenciesUnread;
            dependencies += it->depends + it->makeDepends + it->checkDepends;
        }
        pending.clear();
        dependencies.removeDuplicates();
        if (dependencies.isEmpty())
            break;
        // What the system lacks (pacman -T prints those; exit 127 when there are some, 0 when none).
        const ChildResult t = runChild(tools.pacman, QStringList{QStringLiteral("-T"), QStringLiteral("--")} + dependencies);
        if (!t.started || t.timedOut || t.overflow || (t.exitCode != 0 && t.exitCode != 127)) {
            plan.refusal = Refusal::Failed;
            plan.detail = firstLines(t.err);
            return plan;
        }
        QStringList missing;
        for (const QByteArray &line : t.out.split('\n')) {
            const QString dependency = dependencyName(QString::fromUtf8(line).trimmed());
            if (!dependency.isEmpty() && !seen.contains(dependency) && !repoNames.contains(dependency) && !missing.contains(dependency))
                missing.append(dependency);
        }
        // From the repositories when pacman resolves the name (a package, or one that provides it), else from the AUR.
        for (int attempt = 0; attempt < 2 && !missing.isEmpty(); ++attempt) {
            const ChildResult r = runChild(tools.pacman, QStringList{QStringLiteral("-S"), QStringLiteral("--print"), QStringLiteral("--print-format"),
                                                                     QStringLiteral("%n"), QStringLiteral("--")}
                                                             + missing);
            if (r.ok()) {
                repoNames += missing;
                missing.clear();
                break;
            }
            QStringList notFound;
            static const QRegularExpression target(QStringLiteral("^error: target not found: (\\S+)$"));
            for (const QByteArray &line : r.err.split('\n')) {
                const QRegularExpressionMatch m = target.match(QString::fromUtf8(line).trimmed());
                if (m.hasMatch() && missing.contains(m.captured(1)))
                    notFound.append(m.captured(1));
            }
            if (notFound.isEmpty()) {
                plan.refusal = Refusal::Outdated;
                plan.detail = firstLines(r.err + r.out);
                return plan;
            }
            for (const QString &n : notFound) {
                missing.removeAll(n);
                seen.insert(n);
                pending.append(n);
            }
        }
        if (!missing.isEmpty()) {
            plan.refusal = Refusal::Outdated;
            plan.detail = missing.join(QLatin1Char(' '));
            return plan;
        }
        if (plan.built.size() + pending.size() > kBuiltMax) {
            plan.refusal = Refusal::Failed;
            plan.detail = QStringLiteral("more than %1 packages to build from the AUR").arg(kBuiltMax);
            return plan;
        }
    }
    if (!pending.isEmpty()) {
        plan.refusal = Refusal::Failed;
        plan.detail = QStringLiteral("dependencies more than %1 levels deep in the AUR").arg(kRounds);
        return plan;
    }
    // The repositories' part as any install's: what pacman adds, never an upgrade, its first file still on the mirror.
    if (!repoNames.isEmpty()) {
        const InstallPlan repo = checkInstall(repoNames, tools, online, true);
        if (repo.refusal != Refusal::None) {
            plan.refusal = repo.refusal;
            plan.detail = repo.detail;
            plan.upgrades = repo.upgrades;
            return plan;
        }
        plan.packages = repo.packages;
        plan.downloadSize = repo.downloadSize;
        plan.installedSize = repo.installedSize;
    }
    return plan;
}

} // namespace grassfield::store
