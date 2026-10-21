// grassfield-wallpaper: the one-shot helper that parses the user's wallpaper pictures (ADR-0016).
//
//   grassfield-wallpaper prepare --size WxH --fit F --color #rrggbb --out DIR [--strip-rows N] [--cache-max-bytes N] -- SRC
//   grassfield-wallpaper thumb   --width W --out DIR -- SRC
//   grassfield-wallpaper list    [--max N] -- FOLDER
//   grassfield-wallpaper formats
//
// One JSON object on stdout, and the exit code (wallpaper::ExitCode). Never a daemon, never the network. The shell and
// the Settings app run it with an argument vector; the shell then decodes only this tool's own output.
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImageReader>
#include <QImageWriter>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QBuffer>
#include <QTextStream>

#include "wallpaperlogic.h"

using namespace wallpaper;

namespace {

int finish(const QJsonObject &obj, int code)
{
    QJsonObject o = obj;
    o.insert(QStringLiteral("ok"), code == Ok);
    o.insert(QStringLiteral("code"), code);
    QTextStream(stdout) << QString::fromUtf8(QJsonDocument(o).toJson(QJsonDocument::Compact)) << '\n';
    return code;
}

int fail(int code, const QString &reason)
{
    return finish({{QStringLiteral("reason"), reason}}, code);
}

struct Args {
    QHash<QString, QString> options;
    QString positional;
    bool ok = true;
    QString error;
};

// Options with a value from `known`, then "--", then exactly one positional (when `wantPositional`).
Args parseArgs(const QStringList &args, const QStringList &known, bool wantPositional)
{
    Args a;
    int i = 0;
    for (; i < args.size(); ++i) {
        const QString &s = args[i];
        if (s == QLatin1String("--")) {
            ++i;
            break;
        }
        if (!s.startsWith(QLatin1String("--")) || !known.contains(s.mid(2)) || i + 1 >= args.size()) {
            a.ok = false;
            a.error = QStringLiteral("bad option: ") + s;
            return a;
        }
        a.options.insert(s.mid(2), args[i + 1]);
        ++i;
    }
    const QStringList rest = args.mid(i);
    if (wantPositional) {
        if (rest.size() != 1) {
            a.ok = false;
            a.error = QStringLiteral("expected one path after --");
            return a;
        }
        a.positional = rest[0];
    } else if (!rest.isEmpty()) {
        a.ok = false;
        a.error = QStringLiteral("unexpected argument");
    }
    return a;
}

bool makeDir(const QString &dir)
{
    if (!QDir().mkpath(dir))
        return false;
    return QFile::setPermissions(dir, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
}

const char *reasonName(int code)
{
    switch (code) {
    case NotFound:
        return "not found";
    case NotRegular:
        return "not a regular file";
    case TooLargeFile:
        return "file too large";
    case TooLargePicture:
        return "picture too large";
    case Unreadable:
        return "unreadable";
    case Unsupported:
        return "unsupported format";
    default:
        return "failed";
    }
}

QByteArray encode(const QImage &img, const char *format, int quality)
{
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    QImageWriter w(&buffer, format);
    if (quality >= 0)
        w.setQuality(quality);
    if (!w.write(img))
        return {};
    return bytes;
}

int cmdPrepare(const QStringList &args)
{
    const Args a = parseArgs(args, {QStringLiteral("size"), QStringLiteral("fit"), QStringLiteral("color"), QStringLiteral("out"), QStringLiteral("strip-rows"), QStringLiteral("cache-max-bytes")}, true);
    if (!a.ok)
        return fail(Usage, a.error);
    QSize target;
    Fit fit;
    if (!parseSize(a.options.value(QStringLiteral("size")), &target))
        return fail(Usage, QStringLiteral("bad --size"));
    if (!parseFit(a.options.value(QStringLiteral("fit")), &fit))
        return fail(Usage, QStringLiteral("bad --fit"));
    const QColor backdrop(a.options.value(QStringLiteral("color")));
    if (!backdrop.isValid() || !a.options.value(QStringLiteral("color")).startsWith(QLatin1Char('#')) || a.options.value(QStringLiteral("color")).size() != 7)
        return fail(Usage, QStringLiteral("bad --color"));
    const QString out = a.options.value(QStringLiteral("out"));
    if (!out.startsWith(QLatin1Char('/')))
        return fail(Usage, QStringLiteral("--out must be absolute"));
    bool okRows = true;
    const int rows = a.options.contains(QStringLiteral("strip-rows")) ? a.options.value(QStringLiteral("strip-rows")).toInt(&okRows) : 24;
    if (!okRows || rows < 1 || rows > 512)
        return fail(Usage, QStringLiteral("bad --strip-rows"));
    const qint64 cap = a.options.contains(QStringLiteral("cache-max-bytes")) ? a.options.value(QStringLiteral("cache-max-bytes")).toLongLong() : qint64(512) * 1024 * 1024;
    if (!a.positional.startsWith(QLatin1Char('/')))
        return fail(Usage, QStringLiteral("the picture path must be absolute"));

    qint64 bytes = 0, mtime = 0;
    if (const ExitCode c = checkFile(a.positional, kMaxFileBytes, &bytes, &mtime))
        return fail(c, QString::fromLatin1(reasonName(c)));
    const QString real = QFileInfo(a.positional).canonicalFilePath();
    const QString key = cacheKey(real, bytes, mtime, target, fit, backdrop, rows);
    const bool png = fit == Fit::Center || fit == Fit::Tile;
    const QString image = out + QLatin1Char('/') + key + (png ? QStringLiteral(".png") : QStringLiteral(".jpg"));
    const QString sidecar = out + QLatin1Char('/') + key + QStringLiteral(".json");
    if (!makeDir(out))
        return fail(WriteFailed, QStringLiteral("cannot create the output folder"));

    // Cache hit: the sidecar names the picture; both exist.
    QFile cached(sidecar);
    if (QFileInfo::exists(image) && cached.open(QIODevice::ReadOnly)) {
        const QJsonObject o = QJsonDocument::fromJson(cached.readAll()).object();
        cached.close();
        if (o.value(QStringLiteral("key")).toString() == key) {
            QFile touch(image);
            if (touch.open(QIODevice::ReadWrite | QIODevice::ExistingOnly)) {
                touch.setFileTime(QDateTime::currentDateTime(), QFileDevice::FileModificationTime);
                touch.close();
            }
            QJsonObject r = o;
            r.insert(QStringLiteral("cached"), true);
            return finish(r, Ok);
        }
    }

    QImage src;
    if (const ExitCode c = loadPicture(a.positional, target, fit, &src))
        return fail(c, QString::fromLatin1(reasonName(c)));
    const QImage composed = compose(src, target, fit, backdrop);
    const QByteArray data = encode(composed, png ? "png" : "jpg", png ? -1 : 95);
    if (data.isEmpty() || !writeAtomic(image, data))
        return fail(WriteFailed, QStringLiteral("cannot write the picture"));
    QFile::setPermissions(image, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    QJsonObject meta{{QStringLiteral("key"), key},
                     {QStringLiteral("file"), image},
                     {QStringLiteral("width"), composed.width()},
                     {QStringLiteral("height"), composed.height()},
                     {QStringLiteral("source"), a.positional},
                     {QStringLiteral("mean"), meanColor(composed)},
                     {QStringLiteral("strip"), stripStats(composed, rows)}};
    if (!writeAtomic(sidecar, QJsonDocument(meta).toJson(QJsonDocument::Compact)))
        return fail(WriteFailed, QStringLiteral("cannot write the sidecar"));
    QFile::setPermissions(sidecar, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    pruneCache(out, cap, image);
    meta.insert(QStringLiteral("cached"), false);
    return finish(meta, Ok);
}

int cmdThumb(const QStringList &args)
{
    const Args a = parseArgs(args, {QStringLiteral("width"), QStringLiteral("out")}, true);
    if (!a.ok)
        return fail(Usage, a.error);
    bool ok = false;
    const int width = a.options.value(QStringLiteral("width")).toInt(&ok);
    if (!ok || width < 16 || width > 1024)
        return fail(Usage, QStringLiteral("bad --width"));
    const QString out = a.options.value(QStringLiteral("out"));
    if (!out.startsWith(QLatin1Char('/')) || !a.positional.startsWith(QLatin1Char('/')))
        return fail(Usage, QStringLiteral("paths must be absolute"));
    qint64 bytes = 0, mtime = 0;
    if (const ExitCode c = checkFile(a.positional, kMaxFileBytes, &bytes, &mtime))
        return fail(c, QString::fromLatin1(reasonName(c)));
    const QSize target(width, width * 10 / 16);
    const QString key = QStringLiteral("t") + cacheKey(QFileInfo(a.positional).canonicalFilePath(), bytes, mtime, target, Fit::Fill, QColor(Qt::black), 0).mid(1);
    const QString image = out + QLatin1Char('/') + key + QStringLiteral(".jpg");
    if (!makeDir(out))
        return fail(WriteFailed, QStringLiteral("cannot create the output folder"));
    if (!QFileInfo::exists(image)) {
        QImage src;
        if (const ExitCode c = loadPicture(a.positional, target, Fit::Fill, &src))
            return fail(c, QString::fromLatin1(reasonName(c)));
        const QByteArray data = encode(compose(src, target, Fit::Fill, QColor(Qt::black)), "jpg", 85);
        if (data.isEmpty() || !writeAtomic(image, data))
            return fail(WriteFailed, QStringLiteral("cannot write the thumbnail"));
        QFile::setPermissions(image, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        pruneCache(out, qint64(64) * 1024 * 1024, image);
    }
    return finish({{QStringLiteral("file"), image}, {QStringLiteral("width"), target.width()}, {QStringLiteral("height"), target.height()}}, Ok);
}

int cmdList(const QStringList &args)
{
    const Args a = parseArgs(args, {QStringLiteral("max")}, true);
    if (!a.ok)
        return fail(Usage, a.error);
    bool ok = true;
    const int max = a.options.contains(QStringLiteral("max")) ? a.options.value(QStringLiteral("max")).toInt(&ok) : 10000;
    if (!ok || max < 1)
        return fail(Usage, QStringLiteral("bad --max"));
    if (!a.positional.startsWith(QLatin1Char('/')))
        return fail(Usage, QStringLiteral("the folder path must be absolute"));
    QStringList files;
    bool truncated = false;
    qint64 mtime = 0;
    if (const ExitCode c = listFolder(a.positional, supportedSuffixes(), max, &files, &truncated, &mtime))
        return fail(c, QString::fromLatin1(reasonName(c)));
    return finish({{QStringLiteral("files"), QJsonArray::fromStringList(files)}, {QStringLiteral("truncated"), truncated}, {QStringLiteral("mtime"), double(mtime)}}, Ok);
}

} // namespace

int main(int argc, char *argv[])
{
    // Untrusted pictures: every decoder is bounded to this much memory.
    QImageReader::setAllocationLimit(kAllocationLimitMb);
    QCoreApplication app(argc, argv);
    const QStringList args = app.arguments().mid(1);
    if (args.isEmpty())
        return fail(Usage, QStringLiteral("usage: grassfield-wallpaper prepare|thumb|list|formats"));
    const QString sub = args[0];
    const QStringList rest = args.mid(1);
    if (sub == QLatin1String("prepare"))
        return cmdPrepare(rest);
    if (sub == QLatin1String("thumb"))
        return cmdThumb(rest);
    if (sub == QLatin1String("list"))
        return cmdList(rest);
    if (sub == QLatin1String("formats"))
        return finish({{QStringLiteral("suffixes"), QJsonArray::fromStringList(supportedSuffixes())}}, Ok);
    return fail(Usage, QStringLiteral("unknown subcommand"));
}
