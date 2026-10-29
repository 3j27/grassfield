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
    // Every file of the plan is asked of the mirror, not the first alone (the owner's rc1-7 failed on a later one).
    EXPECT_EQ(f.heads, (QStringList{QStringLiteral("https://mirror.example/extra/os/x86_64/xterm-411-1-x86_64.pkg.tar.zst"),
                                    QStringLiteral("https://mirror.example/extra/os/x86_64/libxaw-1.0.16-1-x86_64.pkg.tar.zst")}));
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

// A system older than its mirror (the integrator's note on PR #36: the owner's rc1-7, databases of 2026-09-08 and a mirror
// gone on, 404s mid-download): told before anything downloads, by Software Update's own answer or by any file of the plan
// the mirror no longer has; and recognised in pacman's messages when it happens anyway. Nothing ever syncs the databases.
TEST(PlanCheck, SystemOlderThanTheMirror)
{
    const QDateTime synced = QDateTime::fromString(QStringLiteral("2026-09-08T10:00:00Z"), Qt::ISODate);
    const auto answer = [](const char *state, const char *checked, int others, const char *omarchy) {
        return QStringLiteral(R"({"version":1,"state":"%1","checkedAt":"%2","others":%3,"omarchy":{"installed":"4.0.4","available":"%4"},
                                 "grassfield":{"installed":"1.0.0-1","available":"1.0.1-1"}})")
            .arg(QLatin1String(state), QLatin1String(checked)).arg(others).arg(QLatin1String(omarchy)).toUtf8();
    };
    // Updates for the system, found after the databases were synced: behind.
    const QString behind = databasesBehind(answer("available", "2026-10-28T23:00:00Z", 37, ""), synced);
    EXPECT_EQ(behind, QStringLiteral("Software Update, 2026-10-28T23:00:00Z: 37 other updates; the package databases date from 2026-09-08T10:00:00Z"));
    EXPECT_FALSE(databasesBehind(answer("available", "2026-10-28T23:00:00Z", 0, "4.0.6"), synced).isEmpty()) << "an Omarchy release";
    // Not behind: the databases synced after that answer, Grassfield's own release alone, nothing available, no answer.
    EXPECT_TRUE(databasesBehind(answer("available", "2026-09-07T23:00:00Z", 37, ""), synced).isEmpty());
    EXPECT_TRUE(databasesBehind(answer("available", "2026-10-28T23:00:00Z", 0, ""), synced).isEmpty());
    EXPECT_TRUE(databasesBehind(answer("up-to-date", "2026-10-28T23:00:00Z", 0, ""), synced).isEmpty());
    EXPECT_TRUE(databasesBehind(answer("failed", "2026-10-28T23:00:00Z", 37, ""), synced).isEmpty());
    EXPECT_TRUE(databasesBehind(answer("available", "", 37, ""), synced).isEmpty());
    EXPECT_TRUE(databasesBehind(answer("available", "2026-10-28T23:00:00Z", 37, ""), QDateTime()).isEmpty());
    EXPECT_TRUE(databasesBehind("not json", synced).isEmpty());

    // The databases' age: the newest *.db of pacman's sync folder.
    QTemporaryDir sync;
    EXPECT_FALSE(newestSync(sync.path()).isValid());
    storetest::writeFile(sync.filePath(QStringLiteral("core.db")), "db");
    storetest::writeFile(sync.filePath(QStringLiteral("extra.db")), "db");
    storetest::writeFile(sync.filePath(QStringLiteral("extra.files")), "files");
    QFile core(sync.filePath(QStringLiteral("core.db")));
    ASSERT_TRUE(core.open(QIODevice::ReadWrite));
    ASSERT_TRUE(core.setFileTime(synced, QFileDevice::FileModificationTime));
    QFile extra(sync.filePath(QStringLiteral("extra.db")));
    ASSERT_TRUE(extra.open(QIODevice::ReadWrite));
    ASSERT_TRUE(extra.setFileTime(synced.addDays(1), QFileDevice::FileModificationTime));
    EXPECT_EQ(newestSync(sync.path()), synced.addDays(1));

    // pacman's own lines, as the owner's helper log had them.
    EXPECT_TRUE(downloadGone(QStringLiteral(
        "(1/30) checking keys in keyring\n"
        "error: failed retrieving file 'kstatusnotifieritem-6.29.0-1-x86_64.pkg.tar.zst' from stable-mirror.omarchy.org : The requested URL returned error: 404\n"
        "error: failed to commit transaction (failed to retrieve some files)\n")));
    EXPECT_TRUE(downloadGone(QStringLiteral(
        "error: failed retrieving file 'mariadb-12.3.3-2-x86_64.pkg.tar.zst.sig' from stable-mirror.omarchy.org : Exceeded the maximum allowed file size (16384) with 16384 bytes\n")));
    EXPECT_TRUE(downloadGone(QStringLiteral("error: failed retrieving file 'a-1-1-any.pkg.tar.zst' from m.example : The requested URL returned error: 410")));
    EXPECT_FALSE(downloadGone(QStringLiteral("error: failed retrieving file 'a-1-1-any.pkg.tar.zst' from m.example : The requested URL returned error: 401")));
    EXPECT_FALSE(downloadGone(QStringLiteral("error: failed retrieving file 'a-1-1-any.pkg.tar.zst' from m.example : Could not resolve host: m.example")));
    EXPECT_FALSE(downloadGone(QStringLiteral("error: failed to commit transaction (conflicting files)\na: /usr/bin/a exists in filesystem")));
    EXPECT_FALSE(downloadGone(QStringLiteral("note: error: failed retrieving file 'x' from m : The requested URL returned error: 404"))) << "pacman's line only";

    Fixture f;
    // Software Update says the system is behind: refused before pacman plans or the mirror is asked.
    f.tools.behind = behind;
    InstallPlan p = checkInstall({QStringLiteral("xterm")}, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::Outdated);
    EXPECT_EQ(p.detail, behind);
    EXPECT_TRUE(p.packages.isEmpty());
    EXPECT_TRUE(f.heads.isEmpty());
    // The last update unfinished still says so first (its own words, the same Software Update).
    storetest::writeFile(f.dir.filePath(QStringLiteral("qu")), "linux 6.17-1 -> 6.18-1\n");
    EXPECT_EQ(checkInstall({QStringLiteral("xterm")}, f.tools, true, false).refusal, Refusal::Unfinished);
    QFile::remove(f.dir.filePath(QStringLiteral("qu")));
    f.tools.behind.clear();

    // A later file of the plan gone from the mirror: refused, its address in Details.
    f.tools.head = [&f](const QUrl &url) {
        f.heads.append(url.toString());
        return url.path().contains(QStringLiteral("libxaw")) ? 404 : 200;
    };
    p = checkInstall({QStringLiteral("xterm")}, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::Outdated);
    EXPECT_EQ(p.detail, QStringLiteral("https://mirror.example/extra/os/x86_64/libxaw-1.0.16-1-x86_64.pkg.tar.zst: HTTP 404"));
    // A mirror that does not answer: no more files asked, nothing refused (pacman says what happens).
    f.heads.clear();
    f.tools.head = [&f](const QUrl &url) {
        f.heads.append(url.toString());
        return 0;
    };
    EXPECT_EQ(checkInstall({QStringLiteral("xterm")}, f.tools, true, false).refusal, Refusal::None);
    EXPECT_EQ(f.heads.size(), 1);
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

namespace {

// A fake pacman for the AUR's plan: -Si answers for a repository's package (gimp), -T lists the dependencies the system
// lacks (it has glibc, cmake, bash), -S --print resolves the repositories' names (gtk3 and gtk-common, python, git) and says
// "target not found" for any other; -S --needed --print (the repositories' part, as any install) and -Si of several give
// their lines and sizes.
const QByteArray kAurPacman = R"SH(here=$(dirname "$0")
have=" glibc cmake bash "
repo=" gtk3 python git "
case "$1" in
  -Qu) [ -s "$here/qu" ] && cat "$here/qu" && exit 0; exit 1 ;;
  -Qq) printf '%s\n' glibc cmake bash ;;
  -T) shift; [ "$1" = -- ] && shift; rc=0
      for d in "$@"; do n=${d%%[<>=]*}; case $have in *" $n "*) ;; *) echo "$d"; rc=127 ;; esac; done
      echo "$*" >>"$here/asked-T"; exit $rc ;;
  -Sp) n=; for a in "$@"; do n=$a; done
       case $n in
         gimp) echo gimp; exit 0 ;;
         pdf-viewer) echo zathura; exit 0 ;;
         locked) echo 'error: failed to init transaction (unable to lock database)' >&2; exit 1 ;;
         example) echo 'error: target not found: example-app' >&2; exit 1 ;;
         *) echo "error: target not found: $n" >&2; exit 1 ;;
       esac ;;
  -Si) [ "$3" = gimp ] && { echo 'Name            : gimp'; exit 0; }
       [ "$2" = -- ] && [ $# -gt 3 ] && { printf 'Name            : %s\nInstalled Size  : 1.00 MiB\n\n' gtk3 gtk-common; exit 0; }
       exit 1 ;;
  -S) names=no; for a in "$@"; do [ "$a" = "%n" ] && names=yes; done
      case $names in
        yes) rc=0; past=no
           for a in "$@"; do [ $past = yes ] && { case $repo in *" $a "*) echo "$a" ;; *) echo "error: target not found: $a" >&2; rc=1 ;; esac; }
             [ "$a" = -- ] && past=yes; done; exit $rc ;;
        *) past=no
           for a in "$@"; do [ $past = yes ] && case $a in
               gtk3) echo 'gtk3 1:3.24.50-1 extra 7000000 https://mirror.example/extra/gtk3.pkg.tar.zst'
                     echo 'gtk-common 1:3.24.50-1 extra 300000 https://mirror.example/extra/gtk-common.pkg.tar.zst' ;;
               python) echo 'python 3.14.0-1 core 20000000 https://mirror.example/core/python.pkg.tar.zst' ;;
               git) echo 'git 2.52.0-1 extra 6000000 https://mirror.example/extra/git.pkg.tar.zst' ;;
             esac; [ "$a" = -- ] && past=yes; done; exit 0 ;;
      esac ;;
  *) exit 1 ;;
esac)SH";

} // namespace

// An AUR package's plan (step 3b2): the AUR's command and pins as a setup's, then a repository's name refused, an unknown
// one refused, and what yay would build (the AUR's, read in rounds) and what pacman adds (the repositories', checked as any
// install).
TEST(PlanCheck, AurPlans)
{
    Fixture f;
    f.tools.pacman = storetest::script(f.dir.filePath(QStringLiteral("aurpacman")), kAurPacman);
    const QString root = f.dir.filePath(QStringLiteral("omarchy"));
    QDir().mkpath(root + QStringLiteral("/bin"));
    storetest::script(root + QStringLiteral("/bin/omarchy-pkg-aur-add"), "omarchy-pkg-missing \"$@\" && yay -S --noconfirm --needed \"$@\"");
    storetest::script(root + QStringLiteral("/bin/omarchy-pkg-missing"), "exit 0");
    const auto pin = [&root](const QString &rel) {
        QFile file(root + QLatin1Char('/') + rel);
        return std::pair{rel, file.open(QIODevice::ReadOnly) ? QString::fromLatin1(QCryptographicHash::hash(file.readAll(), QCryptographicHash::Sha256).toHex())
                                                             : QString()};
    };
    const SetupCheck setup{root, QStringLiteral("omarchy-pkg-aur-add"),
                           {pin(QStringLiteral("bin/omarchy-pkg-aur-add")), pin(QStringLiteral("bin/omarchy-pkg-missing"))}};
    const DenyList deny{{QStringLiteral("btop")}, {QStringLiteral("glibc")}};
    const AurAnswer all = parseAurAnswer(storetest::readFixture(QStringLiteral("aur/info.json")), QStringLiteral("multiinfo"));
    QList<QStringList> asked;
    const auto info = [&all, &asked](const QStringList &names) {
        asked.append(names);
        AurAnswer out{true, {}, {}};
        for (const AurPackage &p : all.packages) {
            if (names.contains(p.name))
                out.packages.append(p);
        }
        return out;
    };
    const auto names = [](const QList<PlannedPackage> &list) {
        QStringList out;
        for (const PlannedPackage &p : list)
            out.append(p.name + QLatin1Char(' ') + p.version);
        return out;
    };

    // example-app-bin: it and example-lib (an AUR dependency) built; gtk3 (and what it needs) from the repositories; cmake
    // and glibc are there.
    InstallPlan p = checkAurInstall(QStringLiteral("example-app-bin"), setup, info, deny, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::None) << p.detail.toStdString();
    EXPECT_EQ(names(p.built), (QStringList{QStringLiteral("example-app-bin 2.4.1-1"), QStringLiteral("example-lib 1.3-2")}));
    EXPECT_EQ(p.built.at(0).repo, QStringLiteral("aur"));
    EXPECT_EQ(names(p.packages), (QStringList{QStringLiteral("gtk3 1:3.24.50-1"), QStringLiteral("gtk-common 1:3.24.50-1")}));
    EXPECT_EQ(p.downloadSize, 7300000);
    EXPECT_EQ(p.installedSize, 2 * 1024 * 1024);
    EXPECT_FALSE(p.incomplete);
    EXPECT_EQ(asked, (QList<QStringList>{{QStringLiteral("example-app-bin")}, {QStringLiteral("example-lib")}}));
    EXPECT_EQ(f.heads, (QStringList{QStringLiteral("https://mirror.example/extra/gtk3.pkg.tar.zst"), QStringLiteral("https://mirror.example/extra/gtk-common.pkg.tar.zst")}))
        << "the repositories' files, as any install's";

    // The system older than the mirror (Software Update's answer): refused as any install, the AUR not asked.
    f.tools.behind = QStringLiteral("Software Update: 37 other updates");
    asked.clear();
    p = checkAurInstall(QStringLiteral("example-app-bin"), setup, info, deny, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::Outdated);
    EXPECT_EQ(p.detail, QStringLiteral("Software Update: 37 other updates"));
    EXPECT_TRUE(asked.isEmpty());
    f.tools.behind.clear();

    // A repository has it, or a package that provides it (yay installs what pacman resolves): from there; pacman that does
    // not answer is no answer. The AUR does not know it, or one of its dependencies is on neither.
    p = checkAurInstall(QStringLiteral("gimp"), setup, info, deny, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::Repository);
    p = checkAurInstall(QStringLiteral("pdf-viewer"), setup, info, deny, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::Repository) << "a provider in the repositories";
    p = checkAurInstall(QStringLiteral("locked"), setup, info, deny, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::Failed);
    EXPECT_TRUE(p.detail.contains(QLatin1String("unable to lock database"))) << p.detail.toStdString();
    p = checkAurInstall(QStringLiteral("nope"), setup, info, deny, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::NotOnAur);
    EXPECT_EQ(p.detail, QStringLiteral("nope"));
    p = checkAurInstall(QStringLiteral("example-tool-git"), setup, info, deny, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::NotOnAur) << "its checkdepends python-pytest is on neither";
    EXPECT_EQ(p.detail, QStringLiteral("python-pytest"));
    // pacman's "target not found" for a longer name only (example-app for example) is no answer about this one.
    p = checkAurInstall(QStringLiteral("example"), setup, info, deny, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::Failed);

    // Never a name of the deny list (the integrator's note on PR #36): the app's, refused before pacman or the AUR is asked;
    // a dependency the AUR would build, refused at it.
    asked.clear();
    for (const QString &name : {QStringLiteral("omarchy-theme-example"), QStringLiteral("grassfield-shell-git"), QStringLiteral("yay-bin"),
                                QStringLiteral("btop"), QStringLiteral("glibc"), QStringLiteral("linux-example"), QStringLiteral("example-firmware")}) {
        p = checkAurInstall(name, setup, info, deny, f.tools, true, false);
        EXPECT_EQ(p.refusal, Refusal::Protected) << name.toStdString();
        EXPECT_EQ(p.protectedPackage, name);
    }
    EXPECT_TRUE(asked.isEmpty());
    DenyList lib = deny;
    lib.omarchy.insert(QStringLiteral("example-lib"));
    p = checkAurInstall(QStringLiteral("example-app-bin"), setup, info, lib, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::Protected);
    EXPECT_EQ(p.protectedPackage, QStringLiteral("example-lib")) << "a dependency the AUR would build";

    // The AUR does not answer; offline; the pins; the last update unfinished; an unread dependency marks the plan.
    const auto silent = [](const QStringList &) { return AurAnswer{false, {}, QStringLiteral("unavailable")}; };
    EXPECT_EQ(checkAurInstall(QStringLiteral("example-app-bin"), setup, silent, deny, f.tools, true, false).refusal, Refusal::Failed);
    EXPECT_EQ(checkAurInstall(QStringLiteral("example-app-bin"), setup, info, deny, f.tools, false, false).refusal, Refusal::Offline);
    SetupCheck changed = setup;
    changed.pins.first().second = QString(64, QLatin1Char('0'));
    p = checkAurInstall(QStringLiteral("example-app-bin"), changed, info, deny, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::OmarchyChanged);
    EXPECT_EQ(p.detail, QStringLiteral("bin/omarchy-pkg-aur-add"));
    // The command's helper (omarchy-pkg-missing) not pinned: the catalog does not vouch for the command.
    SetupCheck helperless = setup;
    helperless.pins.removeLast();
    p = checkAurInstall(QStringLiteral("example-app-bin"), helperless, info, deny, f.tools, true, false);
    EXPECT_EQ(p.refusal, Refusal::OmarchyChanged);
    EXPECT_EQ(p.detail, QStringLiteral("bin/omarchy-pkg-missing"));
    SetupCheck wrong = setup;
    wrong.recipe = QStringLiteral("omarchy-pkg-add");
    EXPECT_EQ(checkAurInstall(QStringLiteral("example-app-bin"), wrong, info, deny, f.tools, true, false).refusal, Refusal::OmarchyChanged);
    EXPECT_EQ(checkAurInstall(QStringLiteral("-rf"), setup, info, deny, f.tools, true, false).refusal, Refusal::Failed);
    const auto unread = [&info](const QStringList &n) {
        AurAnswer a = info(n);
        for (AurPackage &p : a.packages)
            p.dependenciesUnread = true;
        return a;
    };
    EXPECT_TRUE(checkAurInstall(QStringLiteral("example-lib"), setup, unread, deny, f.tools, true, false).incomplete);
    storetest::writeFile(f.dir.filePath(QStringLiteral("qu")), "linux 6.17-1 -> 6.18-1\n");
    EXPECT_EQ(checkAurInstall(QStringLiteral("example-app-bin"), setup, info, deny, f.tools, true, false).refusal, Refusal::Unfinished);
}
