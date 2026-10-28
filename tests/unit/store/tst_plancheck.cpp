// The plan check (apps/store/src/plancheck.h; ADR-0037 e.4; spec SR15, SR22; acceptance A5) with a fake pacman: pacman -Qu
// with and without "[ignored]" lines, a plan that upgrades an installed package, a plan that does not resolve, a first file
// the mirror no longer has, the locks (db.lck, Omarchy's update lock held by another process), and an uninstall that breaks
// a dependency or takes a protected package along; a setup's recipe and pins against a made-up Omarchy folder (b.2, g).
#include "plancheck.h"
#include "storetest.h"

#include <QCryptographicHash>
#include <QDir>
#include <QFile>
#include <QProcess>
#include <QTemporaryDir>
#include <QThread>

#include <gtest/gtest.h>

using namespace grassfield::store;

namespace {

// A fake pacman whose answers depend on files in its folder: qu (pacman -Qu's output), installed (pacman -Qq), and the
// targets of -S --print and -Rs --print by name.
const QByteArray kPacman = R"SH(here=$(dirname "$0")
case "$1" in
  -Qu) [ -s "$here/qu" ] && cat "$here/qu" && exit 0; exit 1 ;;
  -Qq) cat "$here/installed" 2>/dev/null ;;
  -S) last=""; for a in "$@"; do last=$a; done
      case $last in
        xterm) printf '%s\n' 'libxaw 1.0.16-1 extra 230000 https://mirror.example/extra/os/x86_64/libxaw-1.0.16-1-x86_64.pkg.tar.zst' \
                 'xterm 411-1 extra 450000 https://mirror.example/extra/os/x86_64/xterm-411-1-x86_64.pkg.tar.zst' ;;
        needsglib) printf '%s\n' 'needsglib 1-1 extra 1000 https://mirror.example/needsglib-1-1.pkg.tar.zst' \
                     'glib2 2.86-1 core 5000000 https://mirror.example/glib2-2.86-1.pkg.tar.zst' ;;
        *) echo "error: target not found: $last" >&2; exit 1 ;;
      esac ;;
  -Si) printf '%s\n' 'Repository      : extra' 'Name            : libxaw' 'Installed Size  : 1.00 MiB' '' \
         'Repository      : extra' 'Name            : xterm' 'Installed Size  : 2.50 MiB' ;;
  -Rs) last=""; for a in "$@"; do last=$a; done
       case $last in
         xterm) printf '%s\n' 'xterm 411-1' 'libxaw 1.0.16-1' ;;
         probe-app) printf '%s\n' 'probe-app 1-1' 'efibootmgr 18-3' ;;
         glib2) echo "checking dependencies..." >&2
                echo "error: failed to prepare transaction (could not satisfy dependencies)" >&2
                echo ":: removing glib2 breaks dependency 'glib2' required by accountsservice"; exit 1 ;;
         *) echo "error: target not found: $last" >&2; exit 1 ;;
       esac ;;
  *) exit 1 ;;
esac)SH";

struct Fixture {
    QTemporaryDir dir;
    PlanTools tools;
    QStringList heads;
    int headStatus = 200;
    Fixture()
    {
        storetest::ensureApp();
        tools.pacman = storetest::script(dir.filePath(QStringLiteral("pacman")), kPacman);
        tools.dbLock = dir.filePath(QStringLiteral("db.lck"));
        tools.updateLock = dir.filePath(QStringLiteral("omarchy-update.lock"));
        tools.head = [this](const QUrl &url) {
            heads.append(url.toString());
            return headStatus;
        };
        storetest::writeFile(dir.filePath(QStringLiteral("installed")), "bash\nglibc\n");
    }
};

} // namespace

TEST(PlanCheck, Parsers)
{
    EXPECT_EQ(unfinishedUpdates("linux 6.17-1 -> 6.18-1\ngs-app 1-1 -> 2-1 [ignored]\n\n"), QStringList{QStringLiteral("linux 6.17-1 -> 6.18-1")});
    EXPECT_TRUE(unfinishedUpdates("gs-app 1-1 -> 2-1 [ignored]\n").isEmpty());
    const QList<PlannedPackage> plan = parsePlan("libxaw 1.0.16-1 extra 230000 https://m/libxaw.pkg\nxterm 411-1 extra 450000 https://m/xterm.pkg\n");
    ASSERT_EQ(plan.size(), 2);
    EXPECT_EQ(plan.at(1).name, QStringLiteral("xterm"));
    EXPECT_EQ(plan.at(1).version, QStringLiteral("411-1"));
    EXPECT_EQ(plan.at(1).repo, QStringLiteral("extra"));
    EXPECT_EQ(plan.at(1).downloadSize, 450000);
    EXPECT_TRUE(parsePlan("xterm 411-1 extra notasize https://m/x\n").isEmpty());
    EXPECT_TRUE(parsePlan("Xterm 411-1 extra 1 https://m/x\n").isEmpty());
    EXPECT_TRUE(parsePlan(":: Proceed? 1 2 3\n").isEmpty());
    const QHash<QString, qint64> sizes = installedSizes("Name            : xterm\nInstalled Size  : 2.50 MiB\n\nName : libxaw\nInstalled Size : 1.00 MiB\n");
    EXPECT_EQ(sizes.value(QStringLiteral("xterm")), qint64(2.5 * 1024 * 1024));
    EXPECT_EQ(sizes.value(QStringLiteral("libxaw")), 1024 * 1024);
}

TEST(PlanCheck, InstallPlan)
{
    Fixture f;
    const InstallPlan p = checkInstall({QStringLiteral("xterm")}, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::None);
    ASSERT_EQ(p.packages.size(), 2);
    EXPECT_EQ(p.packages.at(0).name, QStringLiteral("xterm")) << "the app's own package first";
    EXPECT_EQ(p.downloadSize, 680000);
    EXPECT_EQ(p.installedSize, qint64(3.5 * 1024 * 1024));
    EXPECT_EQ(f.heads, QStringList{QStringLiteral("https://mirror.example/extra/os/x86_64/xterm-411-1-x86_64.pkg.tar.zst")});
}

TEST(PlanCheck, InstallRefusals)
{
    Fixture f;
    EXPECT_EQ(checkInstall({QStringLiteral("xterm")}, f.tools, false, false).refusal, Refusal::Offline);
    EXPECT_EQ(checkInstall({QStringLiteral("-xterm")}, f.tools, true, false).refusal, Refusal::Failed);

    // The last system update did not finish (S12); a held package alone does not block.
    storetest::writeFile(f.dir.filePath(QStringLiteral("qu")), "linux 6.17-1 -> 6.18-1\nfirefox 140-1 -> 141-1 [ignored]\n");
    InstallPlan p = checkInstall({QStringLiteral("xterm")}, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::Unfinished);
    EXPECT_EQ(p.unfinished, QStringList{QStringLiteral("linux 6.17-1 -> 6.18-1")});
    storetest::writeFile(f.dir.filePath(QStringLiteral("qu")), "firefox 140-1 -> 141-1 [ignored]\n");
    EXPECT_EQ(checkInstall({QStringLiteral("xterm")}, f.tools, true, false).refusal, Refusal::None);
    QFile::remove(f.dir.filePath(QStringLiteral("qu")));

    // A plan that upgrades an installed package (S4), one that does not resolve, a first file gone from the mirror (S5).
    storetest::writeFile(f.dir.filePath(QStringLiteral("installed")), "glib2\n");
    p = checkInstall({QStringLiteral("needsglib")}, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::Outdated);
    EXPECT_EQ(p.upgrades, QStringList{QStringLiteral("glib2")});
    p = checkInstall({QStringLiteral("nothing")}, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::Outdated);
    EXPECT_TRUE(p.detail.contains(QStringLiteral("target not found")));
    f.headStatus = 404;
    EXPECT_EQ(checkInstall({QStringLiteral("xterm")}, f.tools, true, false).refusal, Refusal::Outdated);
    f.headStatus = 200;

    // pacman's lock, then Omarchy's update lock held by another process (S11).
    storetest::writeFile(f.tools.dbLock, "");
    EXPECT_EQ(checkInstall({QStringLiteral("xterm")}, f.tools, true, false).refusal, Refusal::Busy);
    EXPECT_EQ(checkInstall({QStringLiteral("xterm")}, f.tools, true, true).refusal, Refusal::None) << "the Store's own operation";
    QFile::remove(f.tools.dbLock);
    QProcess holder;
    holder.start(QStringLiteral("flock"), {QStringLiteral("-o"), f.tools.updateLock, QStringLiteral("sleep"), QStringLiteral("30")});
    ASSERT_TRUE(holder.waitForStarted());
    for (int i = 0; i < 50 && !lockHeld(f.tools.updateLock); ++i)
        QThread::msleep(50);
    EXPECT_TRUE(lockHeld(f.tools.updateLock));
    EXPECT_EQ(checkInstall({QStringLiteral("xterm")}, f.tools, true, false).refusal, Refusal::Busy);
    holder.kill();
    holder.waitForFinished();
    EXPECT_FALSE(lockHeld(f.tools.updateLock));
    EXPECT_FALSE(lockHeld(f.dir.filePath(QStringLiteral("missing.lock"))));
}

TEST(PlanCheck, RemovePlan)
{
    Fixture f;
    DenyList deny;
    deny.omarchy = {QStringLiteral("btop")};
    RemovePlan p = checkRemove({QStringLiteral("xterm")}, deny, f.tools, false);
    EXPECT_EQ(p.refusal, Refusal::None);
    ASSERT_EQ(p.packages.size(), 2);
    EXPECT_EQ(p.packages.at(1).name, QStringLiteral("libxaw"));
    p = checkRemove({QStringLiteral("probe-app")}, deny, f.tools, false);
    EXPECT_EQ(p.refusal, Refusal::Protected);
    EXPECT_EQ(p.protectedPackage, QStringLiteral("efibootmgr"));
    p = checkRemove({QStringLiteral("glib2")}, deny, f.tools, false);
    EXPECT_EQ(p.refusal, Refusal::Dependency);
    EXPECT_EQ(p.dependents, QStringList{QStringLiteral("accountsservice")});
    EXPECT_EQ(checkRemove({QStringLiteral("nothing")}, deny, f.tools, false).refusal, Refusal::Failed);
    storetest::writeFile(f.dir.filePath(QStringLiteral("qu")), "linux 6.17-1 -> 6.18-1\n");
    EXPECT_EQ(checkRemove({QStringLiteral("xterm")}, deny, f.tools, false).refusal, Refusal::Unfinished);
}

TEST(PlanCheck, Setups)
{
    Fixture f;
    const QString root = f.dir.filePath(QStringLiteral("omarchy"));
    QDir().mkpath(root + QStringLiteral("/bin"));
    QDir().mkpath(root + QStringLiteral("/install/helpers"));
    storetest::script(root + QStringLiteral("/bin/omarchy-install-xterm"), "omarchy-pkg-add xterm");
    storetest::script(root + QStringLiteral("/bin/omarchy-remove-xterm"), "omarchy-pkg-drop xterm");
    const QString helper = root + QStringLiteral("/install/helpers/x.sh");
    storetest::writeFile(helper, "true\n");
    const auto sha = [&root](const QString &path) {
        QFile file(root + QLatin1Char('/') + path);
        return file.open(QIODevice::ReadOnly) ? QString::fromLatin1(QCryptographicHash::hash(file.readAll(), QCryptographicHash::Sha256).toHex()) : QString();
    };
    const QList<std::pair<QString, QString>> pins{
        {QStringLiteral("bin/omarchy-install-xterm"), sha(QStringLiteral("bin/omarchy-install-xterm"))},
        {QStringLiteral("bin/omarchy-remove-xterm"), sha(QStringLiteral("bin/omarchy-remove-xterm"))},
        {QStringLiteral("install/helpers/x.sh"), sha(QStringLiteral("install/helpers/x.sh"))}};
    const SetupCheck install{root, QStringLiteral("omarchy-install-xterm"), pins};
    const SetupCheck remove{root, QStringLiteral("omarchy-remove-xterm"), pins};
    DenyList deny;
    deny.omarchy = {QStringLiteral("btop")};

    // Every pin matches: the plan of its packages, as for a repository app.
    EXPECT_EQ(omarchyDifference(root, pins), QString());
    InstallPlan p = checkSetupInstall({QStringLiteral("xterm")}, install, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::None);
    EXPECT_EQ(p.packages.size(), 2);
    RemovePlan r = checkSetupRemove({QStringLiteral("xterm")}, remove, deny, f.tools, false);
    EXPECT_EQ(r.refusal, Refusal::None);
    EXPECT_EQ(r.packages.size(), 2);

    // A file the recipe sources changed (an Omarchy update the catalog has not checked yet): refused before pacman, the file
    // named; the same once it is gone.
    storetest::writeFile(helper, "true # changed\n");
    p = checkSetupInstall({QStringLiteral("xterm")}, install, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::OmarchyChanged);
    EXPECT_EQ(p.detail, QStringLiteral("install/helpers/x.sh"));
    EXPECT_TRUE(p.packages.isEmpty());
    r = checkSetupRemove({QStringLiteral("xterm")}, remove, deny, f.tools, false);
    EXPECT_EQ(r.refusal, Refusal::OmarchyChanged);
    EXPECT_EQ(r.detail, QStringLiteral("install/helpers/x.sh"));
    QFile::remove(helper);
    EXPECT_EQ(omarchyDifference(root, pins), QStringLiteral("install/helpers/x.sh"));
    storetest::writeFile(helper, "true\n");
    EXPECT_EQ(omarchyDifference(root, pins), QString());

    // A recipe the pins do not name, one that is not executable or not there, one of the wrong pattern; no pins at all.
    SetupCheck unpinned = install;
    unpinned.pins.removeFirst();
    EXPECT_EQ(checkSetupInstall({QStringLiteral("xterm")}, unpinned, f.tools, true, false).detail, QStringLiteral("bin/omarchy-install-xterm"));
    QFile::setPermissions(root + QStringLiteral("/bin/omarchy-install-xterm"), QFile::ReadOwner | QFile::WriteOwner);
    EXPECT_EQ(checkSetupInstall({QStringLiteral("xterm")}, install, f.tools, true, false).refusal, Refusal::OmarchyChanged);
    QFile::setPermissions(root + QStringLiteral("/bin/omarchy-install-xterm"), QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    SetupCheck missing = install;
    missing.recipe = QStringLiteral("omarchy-install-missing");
    EXPECT_EQ(checkSetupInstall({QStringLiteral("xterm")}, missing, f.tools, true, false).detail, QStringLiteral("bin/omarchy-install-missing"));
    SetupCheck odd = install;
    odd.recipe = QStringLiteral("../omarchy-install-xterm");
    EXPECT_EQ(checkSetupInstall({QStringLiteral("xterm")}, odd, f.tools, true, false).refusal, Refusal::OmarchyChanged);
    EXPECT_EQ(omarchyDifference(root, {}), QStringLiteral("(no pins)"));
    SetupCheck none = install;
    none.pins.clear();
    EXPECT_EQ(checkSetupInstall({QStringLiteral("xterm")}, none, f.tools, true, false).refusal, Refusal::OmarchyChanged);

    // With the pins matching again, the other refusals are the repository's.
    storetest::writeFile(f.dir.filePath(QStringLiteral("qu")), "linux 6.17-1 -> 6.18-1\n");
    EXPECT_EQ(checkSetupInstall({QStringLiteral("xterm")}, install, f.tools, true, false).refusal, Refusal::Unfinished);
}
