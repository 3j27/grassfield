#include "previewlogic.h"

#include <QDir>
#include <QFileInfo>
#include <QMimeDatabase>
#include <QRegularExpression>
#include <QUrl>

namespace preview {

QString localPathFromArgument(const QString &arg, const QString &cwd, QString *error)
{
    const auto fail = [error](const QString &message) {
        if (error)
            *error = message;
        return QString();
    };
    if (arg.trimmed().isEmpty())
        return fail(QStringLiteral("empty argument"));
    // Something that looks like "scheme:" and is not an existing relative file name is a URL.
    static const QRegularExpression scheme(QStringLiteral("^[A-Za-z][A-Za-z0-9+.-]+:"));
    const bool urlLike = scheme.match(arg).hasMatch() && !QFileInfo::exists(QDir(cwd).absoluteFilePath(arg));
    if (urlLike) {
        const QUrl url(arg, QUrl::StrictMode);
        if (!url.isValid() || url.scheme().toLower() != QLatin1String("file"))
            return fail(QStringLiteral("only local files are supported: %1").arg(arg));
        if (!url.host().isEmpty() && url.host() != QLatin1String("localhost"))
            return fail(QStringLiteral("remote file hosts are not supported: %1").arg(arg));
        if (url.hasQuery() || url.hasFragment())
            return fail(QStringLiteral("not a plain file URL: %1").arg(arg));
        const QString local = url.host().isEmpty() ? url.toLocalFile() : url.path();
        return local.isEmpty() ? fail(QStringLiteral("not a local file: %1").arg(arg)) : QDir::cleanPath(local);
    }
    return QDir::cleanPath(QDir(cwd).absoluteFilePath(arg));
}

Kind classify(const QString &path)
{
    const QMimeDatabase db;
    const QMimeType mime = db.mimeTypeForFile(path, QMimeDatabase::MatchDefault);
    const QString name = mime.name();
    if (name == QLatin1String("application/pdf"))
        return Kind::Pdf;
    if (name.startsWith(QLatin1String("image/")))
        return Kind::Image;
    if (name.startsWith(QLatin1String("video/")))
        return Kind::Video;
    if (name.startsWith(QLatin1String("audio/")))
        return Kind::Audio;
    // Ogg is audio for the player whatever the sniffed container says.
    if (name == QLatin1String("application/ogg"))
        return Kind::Audio;
    if (mime.inherits(QStringLiteral("text/plain")) || name.startsWith(QLatin1String("text/")))
        return Kind::Text;
    return Kind::Unsupported;
}

QString kindName(Kind kind)
{
    switch (kind) {
    case Kind::Image: return QStringLiteral("image");
    case Kind::Pdf: return QStringLiteral("pdf");
    case Kind::Text: return QStringLiteral("text");
    case Kind::Audio: return QStringLiteral("audio");
    case Kind::Video: return QStringLiteral("video");
    case Kind::Unsupported: break;
    }
    return QStringLiteral("unsupported");
}

bool imageSizeAllowed(const QSize &size)
{
    if (size.width() <= 0 || size.height() <= 0)
        return false;
    if (size.width() > kMaxImageSide || size.height() > kMaxImageSide)
        return false;
    return qint64(size.width()) * size.height() * 4 <= kMaxImageBytes;
}

QSize pngSize(const QByteArray &head)
{
    static const char signature[] = "\x89PNG\r\n\x1a\n";
    // 8 bytes signature, 4 length, "IHDR", 4 width, 4 height.
    if (head.size() < 24 || !head.startsWith(QByteArray(signature, 8)) || head.mid(12, 4) != "IHDR")
        return {};
    const auto be32 = [&head](int offset) {
        const auto *p = reinterpret_cast<const uchar *>(head.constData()) + offset;
        return (quint32(p[0]) << 24) | (quint32(p[1]) << 16) | (quint32(p[2]) << 8) | quint32(p[3]);
    };
    const quint32 w = be32(16);
    const quint32 h = be32(20);
    if (w == 0 || h == 0 || w > 0x7FFFFFFF || h > 0x7FFFFFFF)
        return {};
    return QSize(int(w), int(h));
}

bool textSizeAllowed(qint64 bytes)
{
    return bytes >= 0 && bytes <= kMaxTextBytes;
}

bool looksBinary(const QByteArray &sample)
{
    return sample.contains('\0');
}

Arguments resolveArguments(const QStringList &args, const QString &cwd)
{
    Arguments out;
    for (const QString &arg : args) {
        QString why;
        const QString path = localPathFromArgument(arg, cwd, &why);
        if (path.isEmpty()) {
            out.errors << why;
            continue;
        }
        const QFileInfo info(path);
        if (!info.isFile()) { // follows symlinks; rejects directories, devices, FIFOs, sockets
            out.errors << QStringLiteral("not a regular file: %1").arg(path);
            continue;
        }
        if (out.paths.contains(path))
            continue;
        if (out.paths.size() >= kMaxFiles) {
            out.errors << QStringLiteral("too many files (limit %1)").arg(kMaxFiles);
            break;
        }
        out.paths << path;
    }
    return out;
}

} // namespace preview
