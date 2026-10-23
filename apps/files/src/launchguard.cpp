#include "launchguard.h"

#include <QFile>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QMimeType>

namespace LaunchGuard
{
namespace
{
constexpr qint64 kMaxDesktopBytes = 64 * 1024;

bool isOrInherits(const Facts &f, std::initializer_list<const char *> types)
{
    for (const char *t : types) {
        const QString name = QLatin1String(t);
        if (f.mimeType == name || f.mimeAncestors.contains(name))
            return true;
    }
    return false;
}

// Programs whose default handler runs them whatever their permission bits (Wine for Windows programs).
bool windowsProgram(const Facts &f)
{
    return isOrInherits(f, {"application/x-ms-dos-executable", "application/x-msdownload", "application/x-ms-ne-executable",
                            "application/vnd.microsoft.portable-executable", "application/x-msi", "application/x-ms-shortcut",
                            "application/x-msdos-program", "application/x-bat"});
}

// Native programs and scripts: shared-mime-info makes scripts (shell, Python, Perl, Ruby, Lua, ...) and AppImages
// sub-classes of application/x-executable; position-independent programs are application/x-pie-executable or
// application/x-sharedlib.
bool programType(const Facts &f)
{
    return isOrInherits(f, {"application/x-executable", "application/x-pie-executable", "application/x-sharedlib", "application/x-shellscript",
                            "text/x-shellscript", "application/vnd.appimage", "application/x-iso9660-appimage"});
}

bool desktopName(const QString &name)
{
    return name.endsWith(QLatin1String(".desktop"), Qt::CaseInsensitive) || name.endsWith(QLatin1String(".kdelnk"), Qt::CaseInsensitive);
}
} // namespace

void parseDesktopEntry(const QByteArray &text, QString *type, QString *url)
{
    type->clear();
    url->clear();
    bool inEntry = false;
    bool haveType = false;
    bool haveUrl = false;
    for (const QByteArray &raw : text.split('\n')) {
        const QByteArray line = raw.trimmed();
        if (line.isEmpty() || line.startsWith('#'))
            continue;
        if (line.startsWith('[')) {
            inEntry = line == "[Desktop Entry]" || line == "[KDE Desktop Entry]";
            continue;
        }
        if (!inEntry)
            continue;
        const int eq = line.indexOf('=');
        if (eq <= 0)
            continue;
        const QByteArray key = line.left(eq).trimmed();
        const QString value = QString::fromUtf8(line.mid(eq + 1).trimmed());
        // The first value wins (as KConfig reads a key); "URL[$e]" is KDE's shell-expanded form of URL.
        if (key == "Type" && !haveType) {
            *type = value;
            haveType = true;
        } else if ((key == "URL" || key == "URL[$e]") && !haveUrl) {
            *url = value;
            haveUrl = true;
        }
    }
}

Verdict verdict(const Facts &f)
{
    // Remote items: KIO never runs a remote program or launcher (remote scripts and .desktop files open as text).
    if (!f.local || !f.regularFile)
        return Verdict::Open;
    if (f.desktopEntry || f.mimeType == QLatin1String("application/x-desktop") || f.mimeAncestors.contains(QLatin1String("application/x-desktop"))
        || desktopName(f.fileName)) {
        // A folder's settings file opens as text.
        if (f.fileName == QLatin1String(".directory"))
            return Verdict::Open;
        // A web link (a .webloc on macOS) opens in the browser; a link to anything else (a file, a program) does not.
        if (f.desktopType == QLatin1String("Link")) {
            const QUrl target(f.desktopUrl);
            const QString scheme = target.scheme().toLower();
            if (target.isValid() && (scheme == QLatin1String("http") || scheme == QLatin1String("https")) && !target.host().isEmpty())
                return Verdict::Open;
        }
        return Verdict::RefuseLauncher;
    }
    if (windowsProgram(f))
        return Verdict::RefuseProgram;
    if (f.executable && (programType(f) || f.shebang || f.elf))
        return Verdict::RefuseProgram;
    // Documents, also with the permission bit (every file of a FAT or NTFS volume has it), open in their app.
    return Verdict::Open;
}

Facts inspect(const QUrl &url)
{
    Facts f;
    f.local = url.isLocalFile();
    if (!f.local)
        return f;
    const QString path = url.toLocalFile();
    const QFileInfo info(path);
    f.fileName = info.fileName();
    f.regularFile = info.isFile();
    f.executable = f.regularFile && info.isExecutable();
    if (!f.regularFile)
        return f;
    const QMimeType mime = QMimeDatabase().mimeTypeForFile(info);
    f.mimeType = mime.name();
    f.mimeAncestors = mime.allAncestors();
    f.desktopEntry = desktopName(f.fileName) || f.mimeType == QLatin1String("application/x-desktop")
        || f.mimeAncestors.contains(QLatin1String("application/x-desktop"));
    if (!f.desktopEntry && !f.executable)
        return f;
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return f; // unreadable: a desktop entry without a Type is refused; an executable falls back to its type
    const QByteArray head = file.read(f.desktopEntry ? kMaxDesktopBytes : 4);
    f.shebang = head.startsWith("#!");
    f.elf = head.startsWith("\x7f" "ELF");
    if (f.desktopEntry)
        parseDesktopEntry(head, &f.desktopType, &f.desktopUrl);
    return f;
}

} // namespace LaunchGuard
