// pacman's databases as the user reads them (ADR-0037 c (3)): LC_ALL=C outputs, the repositories the Store offers only.
#include "pacman.h"
#include "storetest.h"

#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace grassfield::store;

TEST(Pacman, SyncList)
{
    const QList<SyncPackage> list = parseSyncList("core bash 5.3.3-2 [installed]\n"
                                                  "extra gimp 3.0.4-1\n"
                                                  "extra mpv 1:0.40.0-6 [installed: 1:0.39.0-1]\n"
                                                  "multilib steam 1.0.0.85-1\n"
                                                  "omarchy spotify 1:1.2.60-1\n"
                                                  "grassfield grassfield-desktop 1.0.0-1 [installed]\n"
                                                  "testing gimp 3.1.0-1\n"
                                                  "extra -bad 1-1\n"
                                                  "garbage\n");
    ASSERT_EQ(list.size(), 5);
    EXPECT_EQ(list.at(0).name, QStringLiteral("bash"));
    EXPECT_TRUE(list.at(0).installed);
    EXPECT_FALSE(list.at(1).installed);
    EXPECT_TRUE(list.at(2).installed); // a version of it is installed
    EXPECT_EQ(list.at(4).repo, QStringLiteral("omarchy"));
}

TEST(Pacman, NamesAndSizes)
{
    EXPECT_EQ(parseNameList("gimp\nmpv\n\n-bad\nUpper\n"), (QSet<QString>{QStringLiteral("gimp"), QStringLiteral("mpv")}));
    EXPECT_EQ(parseSize(QStringLiteral("21.56 MiB")), qint64(21.56 * 1024 * 1024 + 0.5));
    EXPECT_EQ(parseSize(QStringLiteral("512.00 B")), 512);
    EXPECT_EQ(parseSize(QStringLiteral("1.00 GiB")), qint64(1) << 30);
    EXPECT_EQ(parseSize(QStringLiteral("many")), -1);
}

TEST(Pacman, PackageInfo)
{
    const auto info = parsePackageInfo("Repository      : extra\n"
                                       "Name            : gimp\n"
                                       "Version         : 3.0.4-1\n"
                                       "Description     : GNU Image Manipulation Program\n"
                                       "Architecture    : x86_64\n"
                                       "URL             : https://www.gimp.org/\n"
                                       "Licenses        : GPL-3.0-or-later  LGPL-3.0-or-later\n"
                                       "Depends On      : babl  dbus-glib\n"
                                       "                  gegl\n"
                                       "Download Size   : 21.56 MiB\n"
                                       "Installed Size  : 120.00 MiB\n"
                                       "\n"
                                       "Repository      : extra\nName            : other\n");
    ASSERT_TRUE(info);
    EXPECT_EQ(info->repo, QStringLiteral("extra"));
    EXPECT_EQ(info->name, QStringLiteral("gimp"));
    EXPECT_EQ(info->version, QStringLiteral("3.0.4-1"));
    EXPECT_EQ(info->description, QStringLiteral("GNU Image Manipulation Program"));
    EXPECT_EQ(info->url, QStringLiteral("https://www.gimp.org/"));
    EXPECT_EQ(info->licenses, (QStringList{QStringLiteral("GPL-3.0-or-later"), QStringLiteral("LGPL-3.0-or-later")}));
    EXPECT_EQ(info->downloadSize, parseSize(QStringLiteral("21.56 MiB")));
    EXPECT_EQ(info->installedSize, 120 * 1024 * 1024);
    // An http URL is not offered; a description with a control character comes out plain.
    const auto plain = parsePackageInfo("Name            : x\nURL             : http://x.org\nDescription     : a\x1b[31mred\n");
    ASSERT_TRUE(plain);
    EXPECT_TRUE(plain->url.isEmpty());
    EXPECT_EQ(plain->description, QStringLiteral("a[31mred"));
    EXPECT_FALSE(parsePackageInfo("error: package 'nope' was not found\n"));
}

TEST(Pacman, QueriesRunPacmanAsTheUserWithAnArgumentVector)
{
    QTemporaryDir dir;
    const QString args = dir.filePath(QStringLiteral("args"));
    const QString pacman = storetest::script(dir.filePath(QStringLiteral("pacman")),
                                             "printf '%s|' \"$@\" >> '" + args.toUtf8() + "'; echo >> '" + args.toUtf8() + "'\n"
                                             "case $1 in\n"
                                             "-Sl) echo 'extra gimp 3.0.4-1 [installed]' ;;\n"
                                             "-Qqe) echo gimp ;;\n"
                                             "-Qqm) exit 1 ;;\n"
                                             "-Si) printf 'Name            : %s\\nVersion         : 1-1\\n' \"$3\" ;;\n"
                                             "esac");
    const Pacman p(pacman);
    EXPECT_EQ(p.syncList().size(), 1);
    EXPECT_EQ(p.explicitlyInstalled(), QSet<QString>{QStringLiteral("gimp")});
    EXPECT_TRUE(p.foreign().isEmpty()); // exit 1: none
    EXPECT_EQ(p.info(QStringLiteral("gimp"))->name, QStringLiteral("gimp"));
    EXPECT_FALSE(p.info(QStringLiteral("--needed"))); // never passed to pacman
    QFile f(args);
    ASSERT_TRUE(f.open(QIODevice::ReadOnly));
    EXPECT_EQ(QString::fromUtf8(f.readAll()), QStringLiteral("-Sl|\n-Qqe|\n-Qqm|\n-Si|--|gimp|\n"));
}

// The build day of pacman -Si (C locale's %c), shown as What's New's date when AppStream has no release.
TEST(Pacman, BuildDate)
{
    EXPECT_EQ(parseBuildDate(QStringLiteral("Thu Oct 15 08:27:03 2026")), QDate(2026, 10, 15));
    EXPECT_EQ(parseBuildDate(QStringLiteral("Sun Oct  4 00:00:00 2026")), QDate(2026, 10, 4));
    EXPECT_FALSE(parseBuildDate(QStringLiteral("jeu. 15 oct. 2026 08:27:03")).isValid());
    EXPECT_FALSE(parseBuildDate(QString()).isValid());
    const auto info = parsePackageInfo("Repository      : core\nName            : pacman\nVersion         : 7.1.0-3\n"
                                       "Build Date      : Thu Oct 15 08:27:03 2026\n");
    ASSERT_TRUE(info);
    EXPECT_EQ(info->buildDate, QDate(2026, 10, 15));
}
