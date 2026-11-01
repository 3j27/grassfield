#include "archivelogic.h"

#include "filelogic.h"

#include <QRegularExpression>

namespace ArchiveLogic
{
namespace
{
// Longest first: ".tar.gz" before ".gz" (a lone .gz is no archive of several items: left to the applications).
const QStringList kExtensions = {QStringLiteral(".tar.gz"), QStringLiteral(".tar.bz2"), QStringLiteral(".tar.xz"), QStringLiteral(".tar.zst"),
                                 QStringLiteral(".tgz"),    QStringLiteral(".tbz2"),    QStringLiteral(".txz"),    QStringLiteral(".tzst"),
                                 QStringLiteral(".tar"),    QStringLiteral(".zip"),     QStringLiteral(".7z")};

QString extensionOf(const QString &name)
{
    for (const QString &ext : kExtensions) {
        if (name.size() > ext.size() && name.endsWith(ext, Qt::CaseInsensitive))
            return name.right(ext.size());
    }
    return {};
}
} // namespace

bool isArchive(const QString &name)
{
    return !extensionOf(name).isEmpty();
}

QString stripArchiveExtension(const QString &name)
{
    const QString ext = extensionOf(name);
    return ext.isEmpty() ? name : name.chopped(ext.size());
}

QString compressName(const QStringList &names, const std::function<bool(const QString &)> &exists)
{
    // The Finder's names; uniqueName counts " 2", " 3"… on the stem, the ".zip" stays last.
    const QString stem = names.size() == 1 ? names.first() : QStringLiteral("Archive");
    return FileLogic::uniqueName(stem, [&exists](const QString &candidate) { return exists(candidate + QStringLiteral(".zip")); }) + QStringLiteral(".zip");
}

QString expandName(const QString &archiveName, const QStringList &topLevel, const std::function<bool(const QString &)> &exists)
{
    if (topLevel.size() == 1) {
        // One item keeps its name: " 2" goes before its extension for a file ("notes 2.txt"), at the end for a folder.
        const QString &name = topLevel.first();
        if (!exists(name))
            return name;
        const int stem = FileLogic::baseNameLength(name, false);
        const QString base = name.left(stem);
        const QString ext = name.mid(stem);
        return FileLogic::uniqueName(base, [&](const QString &candidate) { return exists(candidate + ext); }) + ext;
    }
    return FileLogic::uniqueName(stripArchiveExtension(archiveName), exists);
}

QStringList compressArgs(const QString &archivePath, const QString &folder, const QStringList &names)
{
    QStringList args = {QStringLiteral("--format"), QStringLiteral("zip"), QStringLiteral("-s"), QStringLiteral(",^\\./,,S"),
                        QStringLiteral("-cf"),      archivePath,          QStringLiteral("-C"), folder,
                        QStringLiteral("--")};
    for (const QString &name : names)
        args.append(QStringLiteral("./") + name);
    return args;
}

QStringList expandArgs(const QString &archivePath, const QString &intoFolder)
{
    return {QStringLiteral("-xf"),           archivePath,
            QStringLiteral("-C"),            intoFolder,
            QStringLiteral("--no-same-owner"), QStringLiteral("--no-same-permissions"),
            QStringLiteral("--no-acls"),     QStringLiteral("--no-fflags"),
            QStringLiteral("--no-xattrs")};
}

QStringList listArgs(const QString &archivePath)
{
    return {QStringLiteral("-tvf"), archivePath};
}

std::optional<qint64> listedSize(const QString &listing)
{
    // "-rw-r--r--  0 user   group     1234 Oct 26 12:00 name": permissions, links, owner, group, size, date… An owner or
    // group with a space would shift the columns: any line whose fifth column is no number makes the size unknown.
    qint64 total = 0;
    static const QRegularExpression kSpaces(QStringLiteral("\\s+"));
    for (const QString &line : listing.split(QLatin1Char('\n'), Qt::SkipEmptyParts)) {
        const QStringList columns = line.trimmed().split(kSpaces);
        if (columns.size() < 6)
            return std::nullopt;
        bool ok = false;
        const qint64 size = columns.at(4).toLongLong(&ok);
        if (!ok || size < 0)
            return std::nullopt;
        total += size;
        if (total < 0)
            return std::nullopt;
    }
    return total;
}

Failure failureOf(const QString &stderrText)
{
    const QString t = stderrText.toLower();
    if (t.contains(QLatin1String("passphrase")) || t.contains(QLatin1String("encrypted")) || t.contains(QLatin1String("password")))
        return Failure::Encrypted;
    return Failure::Other;
}

} // namespace ArchiveLogic
