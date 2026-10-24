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

// Review of a5646b8: a web link handed to KIO is downloaded and run by the handler of the type the server announces (or
// X-KDE-LastOpenedWith). A desktop entry never goes to KIO: a web link's address goes to the default web browser only.
TEST(LaunchGuardVerdict, WebLinksGoToTheBrowserNeverToKio)
{
    const Facts site = desktop(QStringLiteral("site.desktop"), QStringLiteral("Link"), QStringLiteral("https://example.org/"));
    EXPECT_EQ(verdict(site), Verdict::OpenWebLinkInBrowser);
    EXPECT_EQ(webLink(site), QUrl(QStringLiteral("https://example.org/")));
    EXPECT_EQ(verdict(desktop(QStringLiteral("site.desktop"), QStringLiteral("Link"), QStringLiteral("HTTP://example.org/a"))), Verdict::OpenWebLinkInBrowser);
    // The attack of the review: a link to a .msi on a server is still only an address for the browser (never KIO's fetch-and-run).
    EXPECT_EQ(verdict(desktop(QStringLiteral("invoice.desktop"), QStringLiteral("Link"), QStringLiteral("http://127.0.0.1:8000/payload.msi"))),
              Verdict::OpenWebLinkInBrowser);
    Facts ambiguous = site;
    ambiguous.desktopAmbiguous = true;
    EXPECT_EQ(verdict(ambiguous), Verdict::RefuseLauncher) << "a repeated key (KConfig keeps the last one): refused";
    EXPECT_FALSE(webLink(ambiguous).isValid());
    EXPECT_EQ(verdict(desktop(QStringLiteral(".directory"), QStringLiteral("Directory"))), Verdict::RefuseLauncher) << "never handed to KIO";
    EXPECT_EQ(verdict(desktop(QStringLiteral("ftp.desktop"), QStringLiteral("Link"), QStringLiteral("ftp://example.org/x"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("js.desktop"), QStringLiteral("Link"), QStringLiteral("javascript:alert(1)"))), Verdict::RefuseLauncher);
    EXPECT_EQ(verdict(desktop(QStringLiteral("bad.desktop"), QStringLiteral("Link"), QStringLiteral("https://exa mple.org/"))), Verdict::RefuseLauncher);
}

TEST(LaunchGuardVerdict, TypesThatRunWhenOpenedAreRefusedWithoutThePermissionBit)
{
    for (const char *mime : {"application/java-archive", "application/x-java-archive", "application/x-java-jnlp-file", "application/vnd.appimage",
                             "application/x-iso9660-appimage", "application/x-powershell", "text/vbscript", "text/vbscript.encode",
                             "text/x-ms-regedit", "application/hta", "application/x-dosexec"})
        EXPECT_EQ(verdict(localFile(QStringLiteral("item"), QLatin1String(mime))), Verdict::RefuseProgram) << mime;
    // By name too, whatever the content says (the handler can follow the name).
    for (const char *name : {"tool.jar", "start.jnlp", "App.AppImage", "fix.ps1", "a.VBS", "a.vbe", "keys.reg", "setup.MSI", "x.exe", "x.com",
                             "x.scr", "x.lnk", "x.bat", "x.cmd", "x.wsf", "x.hta", "x.cpl"})
        EXPECT_EQ(verdict(localFile(QLatin1String(name), QStringLiteral("text/plain"))), Verdict::RefuseProgram) << name;
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

TEST(LaunchGuardVerdict, RemoteItemsAreJudgedByName)
{
    Facts remote;
    remote.fileName = QStringLiteral("t.desktop");
    EXPECT_EQ(verdict(remote), Verdict::RefuseLauncher) << "a desktop entry on a share is never handed to KIO";
    remote.fileName = QStringLiteral("setup.msi");
    EXPECT_EQ(verdict(remote), Verdict::RefuseProgram) << "KIO downloads it and runs the handler of its type";
    remote.fileName = QStringLiteral("report.pdf");
    EXPECT_EQ(verdict(remote), Verdict::Open);
    Facts folder = localFile(QStringLiteral("bin"), QStringLiteral("inode/directory"), {}, true);
    folder.regularFile = false;
    EXPECT_EQ(verdict(folder), Verdict::Open);
}

TEST(LaunchGuardParse, DesktopEntryGroupOnlyAndRepeatedKeysAreAmbiguous)
{
    DesktopKeys k = parseDesktopEntry("# c\n[Other]\nType=Link\n[Desktop Entry]\n Type = Link \nURL=https://example.org\n[Desktop Action a]\nURL=y\n");
    EXPECT_EQ(k.type, QStringLiteral("Link"));
    EXPECT_EQ(k.url, QStringLiteral("https://example.org"));
    EXPECT_FALSE(k.ambiguous) << "keys of other groups do not count";
    // KConfig keeps the LAST value of a repeated key: any repetition is refused, in one group or across repeated groups.
    EXPECT_TRUE(parseDesktopEntry("[Desktop Entry]\nType=Link\nURL=https://example.org\nType=Application\n").ambiguous);
    EXPECT_TRUE(parseDesktopEntry("[Desktop Entry]\nType=Link\nURL=https://a.example\n[Desktop Entry]\nURL=https://b.example\n").ambiguous);
    EXPECT_TRUE(parseDesktopEntry("[Desktop Entry]\nType=Link\nURL=https://a.example\nURL[$e]=https://b.example\n").ambiguous);
    k = parseDesktopEntry("[KDE Desktop Entry]\nType=Link\nURL[$e]=https://example.org\n");
    EXPECT_EQ(k.url, QStringLiteral("https://example.org"));
    EXPECT_FALSE(k.ambiguous);
    k = parseDesktopEntry("Type=Link\nURL=https://example.org\n");
    EXPECT_TRUE(k.type.isEmpty()) << "keys outside the group do not count";
    EXPECT_TRUE(k.url.isEmpty());
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
    EXPECT_EQ(of(write(QStringLiteral("site.desktop"), "[Desktop Entry]\nType=Link\nURL=https://example.org/\n", false)), Verdict::OpenWebLinkInBrowser);
    // The review's file: a web link naming the application KIO should run the download with. Only the address is used.
    const Facts lastOpened = inspect(QUrl::fromLocalFile(write(QStringLiteral("payload.desktop"),
        "[Desktop Entry]\nType=Link\nURL=http://127.0.0.1:8000/payload.msi\nX-KDE-LastOpenedWith=attacker-chosen-app\n", false)));
    EXPECT_EQ(verdict(lastOpened), Verdict::OpenWebLinkInBrowser);
    EXPECT_EQ(webLink(lastOpened), QUrl(QStringLiteral("http://127.0.0.1:8000/payload.msi")));
    EXPECT_EQ(of(write(QStringLiteral("twice.desktop"), "[Desktop Entry]\nType=Link\nURL=https://example.org/\nURL=file:///usr/bin/true\n", false)),
              Verdict::RefuseLauncher) << "KConfig would use the last URL";
    EXPECT_EQ(of(write(QStringLiteral("big.desktop"), "[Desktop Entry]\nType=Link\nURL=https://example.org/\n#" + QByteArray(70 * 1024, 'x') + "\n", false)),
              Verdict::RefuseLauncher) << "longer than what is read: keys past the end are unknown";
    EXPECT_EQ(of(write(QStringLiteral(".directory"), "[Desktop Entry]\nIcon=folder-red\n", false)), Verdict::RefuseLauncher);
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
    EXPECT_EQ(of(write(QStringLiteral("tool.jar"), QByteArray("PK\x03\x04", 4) + QByteArray(60, '\0'), false)), Verdict::RefuseProgram);
    EXPECT_EQ(of(write(QStringLiteral("App.AppImage"), QByteArray("\x7f" "ELF", 4) + QByteArray(60, '\0'), false)), Verdict::RefuseProgram)
        << "an AppImage without the permission bit";
    EXPECT_EQ(of(write(QStringLiteral("fix.ps1"), "Remove-Item x\n", false)), Verdict::RefuseProgram);
    EXPECT_EQ(of(write(QStringLiteral("a.vbs"), "MsgBox 1\n", false)), Verdict::RefuseProgram);
    EXPECT_EQ(of(write(QStringLiteral("keys.reg"), "Windows Registry Editor Version 5.00\n", false)), Verdict::RefuseProgram);
    EXPECT_EQ(of(write(QStringLiteral("start.jnlp"), "<jnlp/>\n", false)), Verdict::RefuseProgram);
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
