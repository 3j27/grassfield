// The Store's operations end to end on the real system of a throwaway container (run by tests/integration/store_helper.sh,
// never elsewhere): apps/store/src's plan check and queue as the user, with the real pkexec, grassfield-store-helper,
// polkit, pacman, and Omarchy's own web app commands. One command per run; each prints `key=value` lines for the test.
//   store_e2e install <package>      the plan, then the operation (pkexec + helper): plan=…, result=…
//   store_e2e remove <package>       the same for a removal (Omarchy's lists read where Omarchy installs them)
//   store_e2e webapp-install <name> <url> <icon-file>
//   store_e2e webapp-remove <name> <url>
//   store_e2e recover                what store.json's record says against the system (SR20)
#include "operations.h"
#include "plancheck.h"
#include "removal.h"

#include <QCoreApplication>
#include <QDir>
#include <QEventLoop>
#include <QFile>
#include <QProcess>
#include <QTextStream>
#include <QTimer>

#include <cstdio>

using namespace grassfield::store;

namespace {

void say(const QString &line)
{
    std::printf("%s\n", qPrintable(line));
    std::fflush(stdout);
}

QString names(const QList<PlannedPackage> &plan)
{
    QStringList out;
    for (const PlannedPackage &p : plan)
        out.append(p.name);
    return out.join(QLatin1Char(','));
}

QString refusalName(Refusal r)
{
    static const char *n[] = {"none", "busy", "unfinished", "outdated", "offline", "dependency", "protected", "failed"};
    return QString::fromLatin1(n[int(r)]);
}

// Runs the operation and waits for its end (10 minutes at most); prints its outcome, and whether Omarchy's update lock was
// held while it ran.
int run(Operations &ops, const OperationRecord &record, const QString &updateLock)
{
    QString ended;
    bool lockSeen = false;
    QObject::connect(&ops, &Operations::finished, &ops, [&ended](const QString &app) { ended = app; });
    QTimer probe;
    QObject::connect(&probe, &QTimer::timeout, &ops, [&] {
        if (ops.running() && lockHeld(updateLock))
            lockSeen = true;
    });
    probe.start(50);
    ops.enqueue(record);
    QEventLoop loop;
    QTimer deadline;
    deadline.setSingleShot(true);
    deadline.start(10 * 60 * 1000);
    while (ended.isEmpty() && deadline.isActive()) {
        QTimer::singleShot(20, &loop, &QEventLoop::quit);
        loop.exec();
    }
    if (ended.isEmpty()) {
        say(QStringLiteral("result=timeout"));
        return 1;
    }
    const auto results = ops.results();
    const Operations::Result r = results.value(record.app);
    say(QStringLiteral("result=%1").arg(results.contains(record.app) ? r.outcome : QStringLiteral("done")));
    say(QStringLiteral("present=%1/%2").arg(r.present).arg(r.total));
    say(QStringLiteral("lock-while-running=%1").arg(lockSeen ? 1 : 0));
    say(QStringLiteral("lock-after=%1").arg(lockHeld(updateLock) ? 1 : 0));
    if (!r.details.isEmpty())
        say(QStringLiteral("details=%1").arg(QString(r.details).replace(QLatin1Char('\n'), QLatin1String(" | ")).left(400)));
    return 0;
}

} // namespace

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const QStringList args = app.arguments().mid(1);
    if (args.isEmpty())
        return 2;
    const QString home = QDir::homePath();
    const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR", QStringLiteral("/tmp"));

    PlanTools tools;
    tools.pacman = QStringLiteral("/usr/bin/pacman");
    tools.dbLock = QStringLiteral("/var/lib/pacman/db.lck");
    tools.updateLock = runtime + QStringLiteral("/omarchy-update.lock");
    // The test repository is file://: its files exist, so no HEAD request is needed (the mirror's case is unit-tested).

    OperationsConfig config;
    config.pkexec = QStringLiteral("/usr/bin/pkexec");
    config.helper = QStringLiteral("/usr/lib/grassfield/grassfield-store-helper");
    config.statusDir = QStringLiteral("/run/grassfield-store");
    config.updateLock = tools.updateLock;
    config.dbLock = tools.dbLock;
    config.pacmanLog = QStringLiteral("/var/log/pacman.log");
    config.pacman = tools.pacman;
    config.stateFile = home + QStringLiteral("/.local/state/grassfield/store.json");
    config.applications = home + QStringLiteral("/.local/share/applications");
    const QString omarchy = qEnvironmentVariable("OMARCHY_PATH", QStringLiteral("/usr/share/omarchy"));
    config.omarchy = [omarchy](const QString &command, const QStringList &a) { return QStringList{omarchy + QStringLiteral("/bin/") + command} + a; };
    Operations ops(config);

    const QString command = args.at(0);
    OperationRecord r;
    r.id = newOperationId();
    if (command == QLatin1String("install") && args.size() == 2) {
        const InstallPlan plan = checkInstall({args.at(1)}, tools, true, false);
        say(QStringLiteral("plan=%1 packages=%2").arg(refusalName(plan.refusal), names(plan.packages)));
        if (plan.refusal != Refusal::None)
            return 0;
        r.kind = QStringLiteral("install");
        r.path = QStringLiteral("helper");
        r.app = args.at(1);
        r.name = args.at(1);
        r.packages = {args.at(1)};
        r.plan = plan.packages;
        return run(ops, r, tools.updateLock);
    }
    if (command == QLatin1String("remove") && args.size() == 2) {
        DenyList deny;
        for (const QString &list : {QStringLiteral("omarchy-base.packages"), QStringLiteral("omarchy-other.packages")}) {
            QFile f(QStringLiteral("/usr/share/omarchy/install/") + list);
            if (f.open(QIODevice::ReadOnly))
                deny.omarchy.unite(parsePackageList(f.readAll()));
        }
        deny.holdPkg = {QStringLiteral("pacman"), QStringLiteral("glibc")};
        const RemovePlan plan = checkRemove({args.at(1)}, deny, tools, false);
        say(QStringLiteral("plan=%1 packages=%2 dependents=%3").arg(refusalName(plan.refusal), names(plan.packages), plan.dependents.join(QLatin1Char(','))));
        if (plan.refusal != Refusal::None)
            return 0;
        r.kind = QStringLiteral("remove");
        r.path = QStringLiteral("helper");
        r.app = args.at(1);
        r.name = args.at(1);
        r.packages = {args.at(1)};
        r.plan = plan.packages;
        return run(ops, r, tools.updateLock);
    }
    if (command == QLatin1String("webapp-install") && args.size() == 4) {
        r.kind = QStringLiteral("install");
        r.path = QStringLiteral("webapp");
        r.app = QStringLiteral("webapp");
        r.name = args.at(1);
        r.webName = args.at(1);
        r.webUrl = args.at(2);
        r.webIcon = args.at(3);
        return run(ops, r, tools.updateLock);
    }
    if (command == QLatin1String("webapp-remove") && args.size() == 3) {
        r.kind = QStringLiteral("remove");
        r.path = QStringLiteral("webapp");
        r.app = QStringLiteral("webapp");
        r.name = args.at(1);
        r.webName = args.at(1);
        r.webUrl = args.at(2);
        return run(ops, r, tools.updateLock);
    }
    if (command == QLatin1String("recover")) {
        QString ended;
        QObject::connect(&ops, &Operations::finished, &ops, [&ended](const QString &a) { ended = a; });
        ops.recover();
        QEventLoop loop;
        for (int i = 0; i < 500 && ended.isEmpty(); ++i) {
            QTimer::singleShot(20, &loop, &QEventLoop::quit);
            loop.exec();
        }
        const auto results = ops.results();
        say(QStringLiteral("recovered=%1").arg(ended.isEmpty() ? QStringLiteral("nothing")
                                                               : results.contains(ended) ? results.value(ended).outcome : QStringLiteral("done")));
        if (results.contains(ended))
            say(QStringLiteral("present=%1/%2").arg(results.value(ended).present).arg(results.value(ended).total));
        return 0;
    }
    return 2;
}
