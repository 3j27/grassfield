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

// Types whose default handler runs them whatever their permission bits: Windows programs and scripts (Wine, a script
// host), Java archives and Web Start files (java -jar, javaws), AppImages (an AppImage launcher integration), registry
// files. Opening one is running it.
bool runsWhenOpened(const Facts &f)
{
    return isOrInherits(f, {"application/x-ms-dos-executable", "application/x-msdownload", "application/x-ms-ne-executable",
                            "application/vnd.microsoft.portable-executable", "application/x-dosexec", "application/x-lx-executable",
                            "application/x-msi", "application/x-ms-shortcut", "application/x-msdos-program", "application/x-bat",
                            "application/x-powershell", "text/vbscript", "text/vbscript.encode", "text/x-ms-regedit", "application/hta",
                            "application/java-archive", "application/x-java-archive", "application/x-java-jnlp-file",
                            "application/vnd.appimage", "application/x-iso9660-appimage"});
}

// The same by name, for a file whose content the MIME database reads otherwise (the handler KIO picks can follow the name).
bool runsWhenOpenedByName(const QString &name)
{
    static const char *const kExtensions[] = {".exe", ".com", ".scr", ".cpl", ".msi", ".lnk", ".bat", ".cmd", ".ps1", ".vbs", ".vbe", ".wsf",
                                              ".hta", ".reg", ".jar", ".jnlp", ".appimage"};
    for (const char *e : kExtensions) {
        if (name.endsWith(QLatin1String(e), Qt::CaseInsensitive))
            return true;
    }
    return false;
}

// Native programs and scripts: shared-mime-info makes scripts (shell, Python, Perl, Ruby, Lua, ...) and AppImages
// sub-classes of application/x-executable; position-independent programs are application/x-pie-executable or
// application/x-sharedlib.
bool programType(const Facts &f)
{
    return isOrInherits(f, {"application/x-executable", "application/x-pie-executable", "application/x-sharedlib", "application/x-shellscript",
                            "text/x-shellscript"});
}

bool desktopName(const QString &name)
{
    return name.endsWith(QLatin1String(".desktop"), Qt::CaseInsensitive) || name.endsWith(QLatin1String(".kdelnk"), Qt::CaseInsensitive)
        || name == QLatin1String(".directory");
}
} // namespace

DesktopKeys parseDesktopEntry(const QByteArray &text)
{
    DesktopKeys keys;
    bool inEntry = false;
    int types = 0;
    int urls = 0;
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
        // KConfig keeps the LAST value of a repeated key, and "URL[$e]" is KDE's shell-expanded URL: a key given twice
        // (in one group or across repeated groups), or URL with URL[$e], is ambiguous, and the caller refuses it.
        if (key == "Type") {
            ++types;
            keys.type = value;
        } else if (key == "URL" || key.startsWith("URL[")) {
            ++urls;
            keys.url = value;
        }
    }
    keys.ambiguous = types > 1 || urls > 1;
    return keys;
}

QUrl webLink(const Facts &f)
{
    if (f.desktopAmbiguous || f.desktopType != QLatin1String("Link"))
        return {};
    const QUrl target(f.desktopUrl, QUrl::StrictMode);
    const QString scheme = target.scheme().toLower();
    if (!target.isValid() || (scheme != QLatin1String("http") && scheme != QLatin1String("https")) || target.host().isEmpty())
        return {};
    return target;
}

Verdict verdict(const Facts &f)
{
    // Remote items (a share, sftp): KIO never runs a remote executable, but it downloads a remote file and runs the handler
    // of its type, so what runs when opened is refused by name; desktop entries too (never handed to KIO).
    if (!f.local) {
        if (desktopName(f.fileName))
            return Verdict::RefuseLauncher;
        return runsWhenOpenedByName(f.fileName) ? Verdict::RefuseProgram : Verdict::Open;
    }
    if (!f.regularFile)
        return Verdict::Open;
    // Desktop entries are never handed to KIO, a web link included: KIO downloads a link's target and runs the handler of
    // the type the server announces, or the application named in X-KDE-LastOpenedWith (review of a5646b8). A web link
    // (a .webloc on macOS) opens its address in the default web browser only (FilesApp::open); everything else is refused.
    if (f.desktopEntry || f.mimeType == QLatin1String("application/x-desktop") || f.mimeAncestors.contains(QLatin1String("application/x-desktop"))
        || desktopName(f.fileName))
        return webLink(f).isValid() ? Verdict::OpenWebLinkInBrowser : Verdict::RefuseLauncher;
    if (runsWhenOpened(f) || runsWhenOpenedByName(f.fileName))
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
    if (!f.local) {
        f.fileName = url.fileName();
        return f;
    }
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
    const QByteArray head = file.read(f.desktopEntry ? kMaxDesktopBytes + 1 : 4);
    f.shebang = head.startsWith("#!");
    f.elf = head.startsWith("\x7f" "ELF");
    if (f.desktopEntry) {
        const DesktopKeys keys = parseDesktopEntry(head.left(kMaxDesktopBytes));
        f.desktopType = keys.type;
        f.desktopUrl = keys.url;
        // Longer than what was read: keys past the end are unknown (KConfig would read them), so it is ambiguous.
        f.desktopAmbiguous = keys.ambiguous || head.size() > kMaxDesktopBytes;
    }
    return f;
}

} // namespace LaunchGuard
