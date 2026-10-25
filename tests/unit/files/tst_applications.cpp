// Unit tests for apps/files/src/applicationslogic.h (the Applications location of Files). Fixture desktop entries in a
// temporary tree; nothing is launched. The shell's hidden-entries.sh is the reference of the visibility rules: the same tree
// goes through it and through ApplicationsLogic, and both must agree on every entry.
#include <gtest/gtest.h>

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QProcess>
#include <QRegularExpression>
#include <QSet>
#include <QTemporaryDir>

#include "applicationslogic.h"

using namespace ApplicationsLogic;

namespace
{
void write(const QString &path, const QByteArray &text)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile f(path);
    ASSERT_TRUE(f.open(QIODevice::WriteOnly)) << path.toStdString();
    f.write(text);
}

QByteArray app(const QString &extra = QString(), const QString &name = QStringLiteral("x"))
{
    return QStringLiteral("[Desktop Entry]\nType=Application\nName=%1\nExec=%1\n%2\n[Desktop Action a]\nOnlyShowIn=Never;\n").arg(name, extra).toUtf8();
}

Environment envFor(const QString &home, const QString &sys)
{
    Environment env = processEnvironment();
    env.applicationDirs = {home + QStringLiteral("/applications"), sys + QStringLiteral("/applications")};
    env.currentDesktop = {QStringLiteral("Hyprland")};
    env.locales.clear();
    return env;
}

QSet<QString> ids(const QList<Entry> &list)
{
    QSet<QString> s;
    for (const Entry &e : list)
        s.insert(e.id);
    return s;
}
} // namespace

// The visibility rules of the shell's Apps grid, run on the same tree: an id the script hides is not listed, any other is.
TEST(Applications, AgreesWithTheShellsHiddenEntriesScript)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sys = tmp.filePath(QStringLiteral("sys")), home = tmp.filePath(QStringLiteral("home"));
    const QString sa = sys + QStringLiteral("/applications/"), ha = home + QStringLiteral("/applications/");
    QStringList all;
    auto put = [&](const QString &dir, const QString &id, const QByteArray &text, bool count = true) {
        write(dir + id + QStringLiteral(".desktop"), text);
        if (count)
            all << id;
    };
    put(sa, QStringLiteral("only-hypr"), app(QStringLiteral("OnlyShowIn=Hyprland;")));
    put(sa, QStringLiteral("only-kde"), app(QStringLiteral("OnlyShowIn=KDE;")));
    put(sa, QStringLiteral("only-multi"), app(QStringLiteral("OnlyShowIn=KDE;Hyprland;")));
    put(sa, QStringLiteral("not-hypr"), app(QStringLiteral("NotShowIn=Hyprland;")));
    put(sa, QStringLiteral("not-kde"), app(QStringLiteral("NotShowIn=KDE;")));
    put(sa, QStringLiteral("plain"), app());
    put(sa, QStringLiteral("sub/nested"), app(QStringLiteral("OnlyShowIn=KDE;")), false);
    all << QStringLiteral("sub-nested");
    put(sa, QStringLiteral("shadow-a"), app(QStringLiteral("OnlyShowIn=KDE;")));
    put(ha, QStringLiteral("shadow-a"), app(), false);
    put(sa, QStringLiteral("shadow-b"), app());
    put(ha, QStringLiteral("shadow-b"), app(QStringLiteral("NotShowIn=Hyprland;")), false);
    write(sa + QStringLiteral("crlf-kde.desktop"), "[Desktop Entry]\r\nType=Application\r\nName=x\r\nOnlyShowIn=KDE;\r\n");
    write(sa + QStringLiteral("crlf-hypr.desktop"), "[Desktop Entry]\r\nType=Application\r\nName=x\r\nOnlyShowIn=Hyprland;\r\n");
    write(sa + QStringLiteral("spaced-kde.desktop"), "[Desktop Entry]\nType=Application\nName = x\nOnlyShowIn = KDE;\n");
    write(sa + QStringLiteral("spaced-not.desktop"), "[Desktop Entry]\nType=Application\nName = x\nNotShowIn\t=\tHyprland;\n");
    all << QStringLiteral("crlf-kde") << QStringLiteral("crlf-hypr") << QStringLiteral("spaced-kde") << QStringLiteral("spaced-not");
    write(tmp.filePath(QStringLiteral("linked/deep/x.desktop")), app(QStringLiteral("OnlyShowIn=KDE;")));
    ASSERT_TRUE(QFile::link(tmp.filePath(QStringLiteral("linked")), sa + QStringLiteral("link")));
    all << QStringLiteral("link-deep-x");
    for (const char *h : {"avahi-discover", "bssh", "bvnc", "lstopo", "org.fcitx.fcitx5-qt6-gui-wrapper"})
        put(sa, QString::fromLatin1(h), app(QStringLiteral("Categories=System;")));
    put(sa, QStringLiteral("fcitx5-configtool"), app(QStringLiteral("Categories=Settings;")));
    write(sa + QStringLiteral("foot.desktop"), "[Desktop Entry]\nType=Application\nName=Foot\nExec=foot\nCategories=System;TerminalEmulator;\n");
    write(sa + QStringLiteral("footclient.desktop"), "[Desktop Entry]\nType=Application\nName=Foot Client\nExec=footclient\nCategories=System;TerminalEmulator;\n");
    write(sa + QStringLiteral("foot-server.desktop"), "[Desktop Entry]\nType=Application\nName=Foot Server\nExec=foot --server\nCategories=System;TerminalEmulator;\n");
    write(sa + QStringLiteral("kitty.desktop"), "[Desktop Entry]\nType=Application\nName=Kitty\nExec=/usr/bin/kitty --single-instance\nCategories=System;TerminalEmulator;\n");
    write(sa + QStringLiteral("mailclient.desktop"), "[Desktop Entry]\nType=Application\nName=Mail Client\nExec=mailclient\nCategories=Network;Email;\n");
    all << QStringLiteral("foot") << QStringLiteral("footclient") << QStringLiteral("foot-server") << QStringLiteral("kitty") << QStringLiteral("mailclient");

    const QString script = QDir::cleanPath(QFileInfo(QStringLiteral(__FILE__)).absoluteDir().filePath(QStringLiteral("../../../shell/launchpad/hidden-entries.sh")));
    ASSERT_TRUE(QFileInfo::exists(script)) << script.toStdString();
    QProcess sh;
    QProcessEnvironment penv;
    penv.insert(QStringLiteral("XDG_DATA_HOME"), home);
    penv.insert(QStringLiteral("XDG_DATA_DIRS"), sys);
    penv.insert(QStringLiteral("XDG_CURRENT_DESKTOP"), QStringLiteral("Hyprland"));
    penv.insert(QStringLiteral("PATH"), QStringLiteral("/usr/bin:/bin"));
    sh.setProcessEnvironment(penv);
    sh.start(QStringLiteral("sh"), {script});
    ASSERT_TRUE(sh.waitForFinished(20000));
    QSet<QString> hidden;
    for (const QString &line : QString::fromUtf8(sh.readAllStandardOutput()).split(QLatin1Char('\n'), Qt::SkipEmptyParts))
        hidden.insert(line);
    ASSERT_GT(hidden.size(), 10);

    const QSet<QString> listed = ids(listApplications(envFor(home, sys)));
    for (const QString &id : std::as_const(all)) {
        EXPECT_EQ(listed.contains(id), !hidden.contains(id)) << id.toStdString() << (hidden.contains(id) ? " (hidden by the script)" : " (shown by the script)");
    }
    // Nothing is listed that the fixture does not hold.
    for (const QString &id : listed)
        EXPECT_TRUE(all.contains(id)) << id.toStdString();
}

TEST(Applications, DefaultHelperIdsAreTheScriptsDefaults)
{
    const QString script = QDir::cleanPath(QFileInfo(QStringLiteral(__FILE__)).absoluteDir().filePath(QStringLiteral("../../../shell/launchpad/hidden-entries.sh")));
    QFile f(script);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    const QRegularExpressionMatch m = QRegularExpression(QStringLiteral("GRASSFIELD_HELPER_IDS-([^}]*)\\}")).match(QString::fromUtf8(f.readAll()));
    ASSERT_TRUE(m.hasMatch());
    QStringList fromScript = m.captured(1).split(QLatin1Char(' '), Qt::SkipEmptyParts);
    QStringList ours = defaultHelperIds();
    fromScript.sort();
    ours.sort();
    EXPECT_EQ(ours, fromScript);
}

TEST(Applications, OnlyApplicationsThatAreShownAndInstalledAreListed)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sys = tmp.filePath(QStringLiteral("sys")), home = tmp.filePath(QStringLiteral("home"));
    const QString sa = sys + QStringLiteral("/applications/");
    write(sa + QStringLiteral("ok.desktop"), app());
    write(sa + QStringLiteral("notype.desktop"), "[Desktop Entry]\nName=x\nExec=x\n");
    write(sa + QStringLiteral("link.desktop"), "[Desktop Entry]\nType=Link\nName=x\nURL=https://example.org/\n");
    write(sa + QStringLiteral("dir.desktop"), "[Desktop Entry]\nType=Directory\nName=x\n");
    write(sa + QStringLiteral("nodisplay.desktop"), app(QStringLiteral("NoDisplay=true")));
    write(sa + QStringLiteral("nodisplay-false.desktop"), app(QStringLiteral("NoDisplay=false")));
    write(sa + QStringLiteral("hidden.desktop"), app(QStringLiteral("Hidden=true")));
    write(sa + QStringLiteral("tryexec-missing.desktop"), app(QStringLiteral("TryExec=/nonexistent/grassfield-test-program")));
    write(sa + QStringLiteral("tryexec-present.desktop"), app(QStringLiteral("TryExec=/bin/sh")));
    write(sa + QStringLiteral("tryexec-path.desktop"), app(QStringLiteral("TryExec=sh")));
    write(sa + QStringLiteral("tryexec-path-missing.desktop"), app(QStringLiteral("TryExec=grassfield-test-no-such-program")));
    write(sa + QStringLiteral("action-only.desktop"), "[Desktop Entry]\nType=Application\nName=y\n[Desktop Action x]\nNoDisplay=true\nType=Link\n");
    write(sa + QStringLiteral("readme.txt"), "not a desktop entry");
    const QSet<QString> got = ids(listApplications(envFor(home, sys)));
    const QSet<QString> want = {QStringLiteral("ok"), QStringLiteral("nodisplay-false"), QStringLiteral("tryexec-present"),
                                QStringLiteral("tryexec-path"), QStringLiteral("action-only")};
    EXPECT_EQ(got, want);
}

TEST(Applications, SortedByNameThenIdWithNumbersByValue)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sa = tmp.filePath(QStringLiteral("sys/applications/"));
    write(sa + QStringLiteral("b.desktop"), app(QString(), QStringLiteral("banana")));
    write(sa + QStringLiteral("a.desktop"), app(QString(), QStringLiteral("Apple")));
    write(sa + QStringLiteral("c10.desktop"), app(QString(), QStringLiteral("App 10")));
    write(sa + QStringLiteral("c2.desktop"), app(QString(), QStringLiteral("App 2")));
    write(sa + QStringLiteral("z-same.desktop"), app(QString(), QStringLiteral("Same")));
    write(sa + QStringLiteral("a-same.desktop"), app(QString(), QStringLiteral("Same")));
    const QList<Entry> list = listApplications(envFor(tmp.filePath(QStringLiteral("home")), tmp.filePath(QStringLiteral("sys"))));
    QStringList order;
    for (const Entry &e : list)
        order << e.id;
    EXPECT_EQ(order, (QStringList{QStringLiteral("c2"), QStringLiteral("c10"), QStringLiteral("a"), QStringLiteral("b"), QStringLiteral("a-same"), QStringLiteral("z-same")}));
}

TEST(Applications, NamesAndDetailsFollowTheLocale)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString sa = tmp.filePath(QStringLiteral("sys/applications/"));
    write(sa + QStringLiteral("calc.desktop"),
          "[Desktop Entry]\nType=Application\nName=Calculator\nName[fr]=Calculatrice\nName[fr_CA]=Calculatrice canadienne\nGenericName=Calculator\n"
          "GenericName[fr]=Calculatrice de bureau\nComment=Do sums\nComment[fr]=Faire des calculs\nIcon=accessories-calculator\nExec=calc %U\nCategories=Utility;Calculator;\n");
    write(sa + QStringLiteral("pic.desktop"), "[Desktop Entry]\nType=Application\nName=Pic\nIcon=/usr/share/pixmaps/pic.png\nExec=pic\n");
    write(sa + QStringLiteral("noname.desktop"), "[Desktop Entry]\nType=Application\nExec=x\n");
    Environment env = envFor(tmp.filePath(QStringLiteral("home")), tmp.filePath(QStringLiteral("sys")));
    auto find = [](const QList<Entry> &list, const QString &id) {
        for (const Entry &e : list) {
            if (e.id == id)
                return e;
        }
        return Entry();
    };
    Entry c = find(listApplications(env), QStringLiteral("calc"));
    EXPECT_EQ(c.name, QStringLiteral("Calculator"));
    EXPECT_EQ(c.icon, QStringLiteral("accessories-calculator"));
    EXPECT_EQ(c.categories, (QStringList{QStringLiteral("Utility"), QStringLiteral("Calculator")}));
    EXPECT_EQ(c.exec, QStringLiteral("calc %U"));
    env.locales = localeCandidates(QStringLiteral("fr_FR.UTF-8"));
    EXPECT_EQ(env.locales, (QStringList{QStringLiteral("fr_FR"), QStringLiteral("fr")}));
    c = find(listApplications(env), QStringLiteral("calc"));
    EXPECT_EQ(c.name, QStringLiteral("Calculatrice"));
    EXPECT_EQ(c.genericName, QStringLiteral("Calculatrice de bureau"));
    EXPECT_EQ(c.comment, QStringLiteral("Faire des calculs"));
    env.locales = localeCandidates(QStringLiteral("fr_CA"));
    EXPECT_EQ(find(listApplications(env), QStringLiteral("calc")).name, QStringLiteral("Calculatrice canadienne"));
    // An absolute icon path is kept as written; a name-less entry shows its id.
    EXPECT_EQ(find(listApplications(env), QStringLiteral("pic")).icon, QStringLiteral("/usr/share/pixmaps/pic.png"));
    EXPECT_EQ(find(listApplications(env), QStringLiteral("noname")).name, QStringLiteral("noname"));
    EXPECT_TRUE(localeCandidates(QStringLiteral("C")).isEmpty());
    EXPECT_EQ(localeCandidates(QStringLiteral("de_DE@euro")), (QStringList{QStringLiteral("de_DE"), QStringLiteral("de")}));
}

TEST(Applications, TheUserDirectoryShadowsTheSystemOne)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    write(tmp.filePath(QStringLiteral("sys/applications/tool.desktop")), app(QString(), QStringLiteral("System tool")));
    write(tmp.filePath(QStringLiteral("home/applications/tool.desktop")), app(QString(), QStringLiteral("My tool")));
    const QList<Entry> list = listApplications(envFor(tmp.filePath(QStringLiteral("home")), tmp.filePath(QStringLiteral("sys"))));
    ASSERT_EQ(list.size(), 1);
    EXPECT_EQ(list.first().name, QStringLiteral("My tool"));
    EXPECT_EQ(list.first().path, tmp.filePath(QStringLiteral("home/applications/tool.desktop")));
}

TEST(Applications, UrlsRoundTrip)
{
    EXPECT_TRUE(isLocationUrl(locationUrl()));
    EXPECT_FALSE(isLocationUrl(QUrl::fromLocalFile(QStringLiteral("/tmp"))));
    EXPECT_FALSE(isLocationUrl(QUrl(QStringLiteral("trash:/"))));
    for (const QString &id : {QStringLiteral("firefox"), QStringLiteral("org.gnome.Calculator"), QStringLiteral("kde-foo bar"), QStringLiteral("a+b%c")})
        EXPECT_EQ(entryId(entryUrl(id)), id);
    EXPECT_EQ(entryId(QUrl::fromLocalFile(QStringLiteral("/tmp/x"))), QString());
    EXPECT_EQ(entryId(locationUrl()), QString());
}
