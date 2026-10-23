// Unit tests for apps/files/src/launchguard.{h,cpp} (gtest; GF-AUDIT-001 GF-070, DT-10). Built and run by
// scripts/dev/test.sh. The inspect() cases use real files and the installed shared-mime-info database, as Files does.
#include "launchguard.h"

#include <QDir>
#include <QFile>
#include <QTemporaryDir>

#include <gtest/gtest.h>

using namespace LaunchGuard;

namespace
{
Facts localFile(const QString &name, const QString &mime, QStringList ancestors = {}, bool executable = false)
{
    Facts f;
    f.local = true;
    f.regularFile = true;
    f.fileName = name;
    f.mimeType = mime;
    f.mimeAncestors = std::move(ancestors);
    f.executable = executable;
    return f;
}

Facts desktop(const QString &name, const QString &type, const QString &url = {})
{
    Facts f = localFile(name, QStringLiteral("application/x-desktop"), {QStringLiteral("text/plain")});
    f.desktopEntry = true;
    f.desktopType = type;
    f.desktopUrl = url;
    return f;
}

class Files : public ::testing::Test
{
protected:
    QTemporaryDir dir;

    QString write(const QString &name, const QByteArray &bytes, bool executable)
    {
        const QString path = dir.filePath(name);
        QFile f(path);
        EXPECT_TRUE(f.open(QIODevice::WriteOnly));
        f.write(bytes);
        f.close();
        QFile::Permissions p = QFile::ReadOwner | QFile::WriteOwner;
        if (executable)
            p |= QFile::ExeOwner;
        EXPECT_TRUE(QFile::setPermissions(path, p));
        return path;
    }

    Verdict of(const QString &path)
    {
        return verdict(inspect(QUrl::fromLocalFile(path)));
    }
};

const QByteArray kApp = "[Desktop Entry]\nType=Application\nName=Invoice\nExec=touch /tmp/gf-dt10\n";
} // namespace

TEST(LaunchGuardVerdict, LaunchersAreRefused)
{
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Application"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Service"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QString())), Verdict::RefuseLauncher) << "no Type: fail closed";
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Unknown"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Link"), QStringLiteral("file:///usr/bin/foot"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Link"), QStringLiteral("/home/u/run.sh"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Link"), QStringLiteral("smb://host/x"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("t.desktop"), QStringLiteral("Link"), QStringLiteral("https://"))), Verdict::RefuseLauncher) << "no host";
}

TEST(LaunchGuardVerdict, WebLinksAndFolderSettingsOpen)
{
    EXPECT_EQ(verdict(desktop(QStringLiteral("site.desktop"), QStringLiteral("Link"), QStringLiteral("https://example.org/"))), Verdict::Open);
    EXPECT_EQ(verdict(desktop(QStringLiteral("site.desktop"), QStringLiteral("Link"), QStringLiteral("HTTP://example.org/a"))), Verdict::Open);
    EXPECT_EQ(verdict(desktop(QStringLiteral(".directory"), QStringLiteral("Directory"))), Verdict::Open);
}

TEST(LaunchGuardVerdict, ADesktopNameIsALauncherWhateverTheType)
{
    // A desktop entry the MIME database does not recognize (no [Desktop Entry] header) is still refused by its name.
    Facts f = localFile(QStringLiteral("Invoice.pdf.desktop"), QStringLiteral("text/plain"));
    EXPECT_EQ(verdict(f), Verdict::RefuseLauncher);
    f.fileName = QStringLiteral("OLD.KDELNK");
    EXPECT_EQ(verdict(f), Verdict::RefuseLauncher);
}

TEST(LaunchGuardVerdict, ExecutablesAreRefusedDocumentsOpen)
{
    const QString exe = QStringLiteral("application/x-executable");
    EXPECT_EQ(verdict(localFile(QStringLiteral("tool"), QStringLiteral("application/x-pie-executable"), {QStringLiteral("application/x-sharedlib")}, true)), Verdict::RefuseProgram);
    EXPECT_EQ(verdict(localFile(QStringLiteral("run.sh"), QStringLiteral("application/x-shellscript"), {exe, QStringLiteral("text/plain")}, true)), Verdict::RefuseProgram);
    EXPECT_EQ(verdict(localFile(QStringLiteral("run.py"), QStringLiteral("text/x-python3"), {QStringLiteral("text/x-python"), exe}, true)), Verdict::RefuseProgram);
    EXPECT_EQ(verdict(localFile(QStringLiteral("App.AppImage"), QStringLiteral("application/vnd.appimage"), {exe}, true)), Verdict::RefuseProgram);
    // Without the permission bit a script is text and opens in its editor (KIO and macOS do the same).
    EXPECT_EQ(verdict(localFile(QStringLiteral("run.sh"), QStringLiteral("application/x-shellscript"), {exe, QStringLiteral("text/plain")}, false)), Verdict::Open);
    // Every file of a FAT or NTFS volume has the permission bit: documents still open.
    EXPECT_EQ(verdict(localFile(QStringLiteral("report.pdf"), QStringLiteral("application/pdf"), {}, true)), Verdict::Open);
    EXPECT_EQ(verdict(localFile(QStringLiteral("notes.txt"), QStringLiteral("text/plain"), {}, true)), Verdict::Open);
    // ... unless the content says it is a program.
    Facts shebang = localFile(QStringLiteral("notes.txt"), QStringLiteral("text/plain"), {}, true);
    shebang.shebang = true;
    EXPECT_EQ(verdict(shebang), Verdict::RefuseProgram);
    Facts elf = localFile(QStringLiteral("photo.jpg"), QStringLiteral("image/jpeg"), {}, true);
    elf.elf = true;
    EXPECT_EQ(verdict(elf), Verdict::RefuseProgram);
}

TEST(LaunchGuardVerdict, WindowsProgramsAreRefusedWithoutThePermissionBit)
{
    EXPECT_EQ(verdict(localFile(QStringLiteral("setup.exe"), QStringLiteral("application/x-ms-dos-executable"))), Verdict::RefuseProgram);
    EXPECT_EQ(verdict(localFile(QStringLiteral("setup.exe"), QStringLiteral("application/x-ms-ne-executable"), {QStringLiteral("application/x-msdownload")})), Verdict::RefuseProgram);
    EXPECT_EQ(verdict(localFile(QStringLiteral("setup.msi"), QStringLiteral("application/x-msi"))), Verdict::RefuseProgram);
}

TEST(LaunchGuardVerdict, RemoteItemsAndFoldersGoToKio)
{
    Facts remote = desktop(QStringLiteral("t.desktop"), QStringLiteral("Application"));
    remote.local = false;
    EXPECT_EQ(verdict(remote), Verdict::Open) << "KIO opens remote launchers and scripts as text";
    Facts folder = localFile(QStringLiteral("bin"), QStringLiteral("inode/directory"), {}, true);
    folder.regularFile = false;
    EXPECT_EQ(verdict(folder), Verdict::Open);
}

TEST(LaunchGuardParse, DesktopEntryGroupOnly)
{
    QString type, url;
    parseDesktopEntry("# c\n[Other]\nType=Link\n[Desktop Entry]\n Type = Application \nURL=x\nType=Link\n[Desktop Action a]\nURL=y\n", &type, &url);
    EXPECT_EQ(type, QStringLiteral("Application")) << "the first Type of [Desktop Entry] wins";
    EXPECT_EQ(url, QStringLiteral("x"));
    parseDesktopEntry("[KDE Desktop Entry]\nType=Link\nURL[$e]=https://example.org\n", &type, &url);
    EXPECT_EQ(type, QStringLiteral("Link"));
    EXPECT_EQ(url, QStringLiteral("https://example.org"));
    parseDesktopEntry("Type=Link\nURL=https://example.org\n", &type, &url);
    EXPECT_TRUE(type.isEmpty()) << "keys outside the group do not count";
    EXPECT_TRUE(url.isEmpty());
}

// DT-10 on real files: t.desktop (Type=Application, Exec=touch …), once executable, once not, never opens.
TEST_F(Files, Dt10LauncherRefusedWithAndWithoutPermission)
{
    ASSERT_TRUE(dir.isValid());
    EXPECT_EQ(of(write(QStringLiteral("t.desktop"), kApp, true)), Verdict::RefuseLauncher);
    EXPECT_EQ(of(write(QStringLiteral("u.desktop"), kApp, false)), Verdict::RefuseLauncher);
    EXPECT_EQ(of(write(QStringLiteral("Invoice.pdf.desktop"), kApp, false)), Verdict::RefuseLauncher);
    // The same content under another name is a document by name: KIO sees it as text too.
    const Facts renamed = inspect(QUrl::fromLocalFile(write(QStringLiteral("readme.txt"), kApp, false)));
    EXPECT_EQ(verdict(renamed), Verdict::Open) << renamed.mimeType.toStdString();
    EXPECT_EQ(of(write(QStringLiteral("site.desktop"), "[Desktop Entry]\nType=Link\nURL=https://example.org/\n", false)), Verdict::Open);
    EXPECT_EQ(of(write(QStringLiteral("file.desktop"), "[Desktop Entry]\nType=Link\nURL=file:///usr/bin/true\n", false)), Verdict::RefuseLauncher);
    const QString unreadable = write(QStringLiteral("locked.desktop"), "[Desktop Entry]\nType=Link\nURL=https://example.org/\n", false);
    ASSERT_TRUE(QFile::setPermissions(unreadable, QFileDevice::Permissions()));
    EXPECT_EQ(of(unreadable), Verdict::RefuseLauncher) << "an unreadable entry has no known Type: refused";
    QFile::setPermissions(unreadable, QFile::ReadOwner | QFile::WriteOwner);
}

TEST_F(Files, ScriptsAndProgramsOnDisk)
{
    ASSERT_TRUE(dir.isValid());
    EXPECT_EQ(of(write(QStringLiteral("run.sh"), "#!/bin/sh\ntouch /tmp/gf-dt10\n", true)), Verdict::RefuseProgram);
    EXPECT_EQ(of(write(QStringLiteral("run2.sh"), "#!/bin/sh\ntouch /tmp/gf-dt10\n", false)), Verdict::Open);
    EXPECT_EQ(of(write(QStringLiteral("noext"), "#!/usr/bin/env python3\nprint(1)\n", true)), Verdict::RefuseProgram);
    EXPECT_EQ(of(write(QStringLiteral("notes.txt"), "just text\n", true)), Verdict::Open);
    EXPECT_EQ(of(write(QStringLiteral("setup.exe"), QByteArray("MZ\x90\x00", 4) + QByteArray(60, '\0'), false)), Verdict::RefuseProgram);
    // A real native program, copied and through a symbolic link (the link's target decides).
    QFile truebin(QStringLiteral("/usr/bin/true"));
    if (truebin.exists()) {
        const QString copy = dir.filePath(QStringLiteral("tool"));
        ASSERT_TRUE(QFile::copy(truebin.fileName(), copy));
        ASSERT_TRUE(QFile::setPermissions(copy, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
        EXPECT_EQ(of(copy), Verdict::RefuseProgram);
        const QString link = dir.filePath(QStringLiteral("report"));
        ASSERT_TRUE(QFile::link(copy, link));
        EXPECT_EQ(of(link), Verdict::RefuseProgram);
    }
    EXPECT_EQ(of(dir.path()), Verdict::Open) << "a folder navigates";
}
