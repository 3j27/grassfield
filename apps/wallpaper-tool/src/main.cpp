// grassfield-wallpaper: the one-shot helper that parses the user's wallpaper pictures (ADR-0016).
//
//   grassfield-wallpaper prepare --size WxH --fit F --color #rrggbb --out DIR [--strip-rows N] [--cache-max-bytes N] -- SRC
//   grassfield-wallpaper thumb   --width W --out DIR -- SRC
//   grassfield-wallpaper list    [--max N] -- FOLDER
//   grassfield-wallpaper formats
//   grassfield-wallpaper probe     -- VIDEO
//   grassfield-wallpaper transcode --size WxH --fit F --color #rrggbb --out DIR [--strip-rows N] [--cache-max-bytes N] [--max-seconds N]
//                                  [--max-bytes N] [--keep FILE] -- VIDEO     (ADR-0016 W7; progress lines {"progress":0.4} then the result)
//   grassfield-wallpaper fetch commons|apod --date YYYY-MM-DD --out DIR [--width N] [--lang en|fr] [--base-url URL]   (ADR-0016 step 2)
//   grassfield-wallpaper latest commons|apod --out DIR
//
// One JSON object on stdout, and the exit code (wallpaper::ExitCode). Never a daemon. Only `fetch` uses the network (curl). The shell and
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

#include "commonsfetch.h"
#include "runmode.h"
#include "videotool.h"
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
    QStringList keeps; // --keep FILE (repeatable): prepared pictures that must survive the cache pruning
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
        if (s.mid(2) == QLatin1String("keep"))
            a.keeps << args[i + 1];
        else
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
    case TooLongVideo:
        return "video too long";
    case TranscodeFailed:
        return "transcode failed";
    case FfmpegMissing:
        return "ffmpeg is missing";
    case Cancelled:
        return "cancelled";
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
    const Args a = parseArgs(args, {QStringLiteral("size"), QStringLiteral("fit"), QStringLiteral("color"), QStringLiteral("out"), QStringLiteral("strip-rows"), QStringLiteral("cache-max-bytes"), QStringLiteral("keep")}, true);
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
    if (!outDirAllowed(out))
        return fail(Usage, QStringLiteral("--out must be the wallpaper cache (.../grassfield/wallpapers/prepared or thumbs)"));
    if (!ensureCacheDir(out))
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
                     {QStringLiteral("real"), real},
                     {QStringLiteral("mean"), meanColor(composed)},
                     {QStringLiteral("strip"), stripStats(composed, rows)}};
    if (!writeAtomic(sidecar, QJsonDocument(meta).toJson(QJsonDocument::Compact)))
        return fail(WriteFailed, QStringLiteral("cannot write the sidecar"));
    QFile::setPermissions(sidecar, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    pruneCache(out, cap, a.keeps + QStringList{image});
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
    if (const ExitCode c = checkFile(a.positional, video::isVideoPath(a.positional) ? video::kMaxSourceBytes : kMaxFileBytes, &bytes, &mtime))
        return fail(c, QString::fromLatin1(reasonName(c)));
    const QSize target(width, width * 10 / 16);
    const bool isVideo = video::isVideoPath(a.positional);
    const QString key = QStringLiteral("t") + cacheKey(QFileInfo(a.positional).canonicalFilePath(), bytes, mtime, target, Fit::Fill, QColor(Qt::black), 0).mid(1);
    const QString image = out + QLatin1Char('/') + key + QStringLiteral(".jpg");
    if (!outDirAllowed(out))
        return fail(Usage, QStringLiteral("--out must be the wallpaper cache (.../grassfield/wallpapers/prepared or thumbs)"));
    if (!ensureCacheDir(out))
        return fail(WriteFailed, QStringLiteral("cannot create the output folder"));
    if (!QFileInfo::exists(image) && isVideo) {
        // A video's thumbnail is one of its frames (Settings > Wallpaper, the Videos grid).
        video::installSignalHandlers();
        QString why;
        if (const ExitCode c = video::thumbnail(a.positional, image, width, &why))
            return fail(c, why);
        pruneCache(out, qint64(64) * 1024 * 1024, {image});
    } else if (!QFileInfo::exists(image)) {
        QImage src;
        if (const ExitCode c = loadPicture(a.positional, target, Fit::Fill, &src))
            return fail(c, QString::fromLatin1(reasonName(c)));
        const QByteArray data = encode(compose(src, target, Fit::Fill, QColor(Qt::black)), "jpg", 85);
        if (data.isEmpty() || !writeAtomic(image, data))
            return fail(WriteFailed, QStringLiteral("cannot write the thumbnail"));
        QFile::setPermissions(image, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        pruneCache(out, qint64(64) * 1024 * 1024, {image});
    }
    return finish({{QStringLiteral("file"), image}, {QStringLiteral("real"), QFileInfo(a.positional).canonicalFilePath()}, {QStringLiteral("width"), target.width()}, {QStringLiteral("height"), target.height()}}, Ok);
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

// Writes one JSON line and flushes it at once (the progress of a transcode is read line by line while it runs).
void emitLine(const QJsonObject &o)
{
    const QByteArray line = QJsonDocument(o).toJson(QJsonDocument::Compact) + '\n';
    fwrite(line.constData(), 1, size_t(line.size()), stdout);
    fflush(stdout);
}

int cmdProbe(const QStringList &args)
{
    const Args a = parseArgs(args, {}, true);
    if (!a.ok)
        return fail(Usage, a.error);
    if (!a.positional.startsWith(QLatin1Char('/')))
        return fail(Usage, QStringLiteral("the video path must be absolute"));
    if (!video::isVideoPath(a.positional))
        return fail(Unsupported, QStringLiteral("not a video file name"));
    if (const ExitCode c = checkFile(a.positional, video::kMaxSourceBytes))
        return fail(c, QString::fromLatin1(reasonName(c)));
    video::installSignalHandlers();
    video::Info info;
    QString why;
    if (const ExitCode c = video::probe(QStringLiteral("/usr/bin/ffprobe"), a.positional, video::kMaxSeconds, &info, &why))
        return fail(c, why);
    return finish({{QStringLiteral("duration"), info.duration},
                   {QStringLiteral("width"), info.width},
                   {QStringLiteral("height"), info.height},
                   {QStringLiteral("fps"), info.fps},
                   {QStringLiteral("codec"), info.codec},
                   {QStringLiteral("audio"), info.audio},
                   {QStringLiteral("real"), QFileInfo(a.positional).canonicalFilePath()}},
                  Ok);
}

int cmdTranscode(const QStringList &args)
{
    const Args a = parseArgs(args, {QStringLiteral("size"), QStringLiteral("fit"), QStringLiteral("color"), QStringLiteral("out"), QStringLiteral("strip-rows"), QStringLiteral("cache-max-bytes"), QStringLiteral("max-seconds"), QStringLiteral("max-bytes"), QStringLiteral("keep")}, true);
    if (!a.ok)
        return fail(Usage, a.error);
    video::TranscodeOptions o;
    if (!parseSize(a.options.value(QStringLiteral("size")), &o.limit))
        return fail(Usage, QStringLiteral("bad --size"));
    if (!parseFit(a.options.value(QStringLiteral("fit")), &o.fit))
        return fail(Usage, QStringLiteral("bad --fit"));
    const QString color = a.options.value(QStringLiteral("color"));
    o.color = QColor(color);
    if (!o.color.isValid() || !color.startsWith(QLatin1Char('#')) || color.size() != 7)
        return fail(Usage, QStringLiteral("bad --color"));
    o.out = a.options.value(QStringLiteral("out"));
    if (!video::outDirAllowed(o.out))
        return fail(Usage, QStringLiteral("--out must be the video cache (.../grassfield/wallpapers/video)"));
    bool ok = true;
    if (a.options.contains(QStringLiteral("strip-rows"))) {
        o.stripRows = a.options.value(QStringLiteral("strip-rows")).toInt(&ok);
        if (!ok || o.stripRows < 1 || o.stripRows > 512)
            return fail(Usage, QStringLiteral("bad --strip-rows"));
    }
    if (a.options.contains(QStringLiteral("cache-max-bytes")))
        o.cacheMaxBytes = a.options.value(QStringLiteral("cache-max-bytes")).toLongLong();
    if (a.options.contains(QStringLiteral("max-seconds"))) {
        o.maxSeconds = a.options.value(QStringLiteral("max-seconds")).toInt(&ok);
        if (!ok || o.maxSeconds < 1 || o.maxSeconds > video::kMaxSeconds)
            return fail(Usage, QStringLiteral("bad --max-seconds"));
    }
    if (a.options.contains(QStringLiteral("max-bytes"))) {
        o.maxBytes = a.options.value(QStringLiteral("max-bytes")).toLongLong(&ok);
        if (!ok || o.maxBytes < 1024 || o.maxBytes > video::kMaxOutputBytes)
            return fail(Usage, QStringLiteral("bad --max-bytes"));
    }
    if (!a.positional.startsWith(QLatin1Char('/')))
        return fail(Usage, QStringLiteral("the video path must be absolute"));
    if (!video::isVideoPath(a.positional))
        return fail(Unsupported, QStringLiteral("not a video file name"));
    video::installSignalHandlers();
    o.src = a.positional;
    o.keep = a.keeps;
    QJsonObject result;
    QString why;
    const ExitCode c = video::transcode(o, [](double f) { emitLine({{QStringLiteral("progress"), f}}); }, &result, &why);
    if (c != Ok)
        return fail(c, why);
    return finish(result, Ok);
}

// `fetch commons`: the day's Wikimedia Commons picture into the online cache (a fetch of a day already cached is a no-op).
int cmdFetch(const QStringList &args)
{
    if (args.isEmpty() || !commons::providerKnown(args[0]))
        return fail(Usage, QStringLiteral("usage: fetch commons|apod --date YYYY-MM-DD --out DIR"));
    const QString provider = args[0];
    const Args a = parseArgs(args.mid(1), {QStringLiteral("date"), QStringLiteral("out"), QStringLiteral("width"), QStringLiteral("lang"), QStringLiteral("base-url")}, false);
    if (!a.ok)
        return fail(Usage, a.error);
    commons::Options o;
    o.provider = provider;
    o.date = a.options.value(QStringLiteral("date"));
    if (!commons::validDate(o.date))
        return fail(Usage, QStringLiteral("bad --date"));
    o.out = a.options.value(QStringLiteral("out"));
    if (!commons::outDirAllowedFor(provider, o.out))
        return fail(Usage, QStringLiteral("--out must be the online cache (.../grassfield/wallpapers/online/<provider>)"));
    bool ok = true;
    o.width = a.options.contains(QStringLiteral("width")) ? a.options.value(QStringLiteral("width")).toInt(&ok) : commons::kDefaultWidth;
    if (!ok || o.width < 640 || o.width > commons::kDefaultWidth)
        return fail(Usage, QStringLiteral("bad --width"));
    o.lang = a.options.value(QStringLiteral("lang"), QStringLiteral("en"));
    if (o.lang != QLatin1String("en") && o.lang != QLatin1String("fr"))
        return fail(Usage, QStringLiteral("bad --lang"));
    o.dev = grassfield::apps::runmode::dev();
    o.baseUrl = a.options.value(QStringLiteral("base-url"));
    if (a.options.contains(QStringLiteral("base-url")) && !commons::baseUrlAllowed(o.baseUrl, o.dev))
        return fail(Usage, QStringLiteral("--base-url is only for a dev session and only http://127.0.0.1:<port>"));
    if (QFileInfo::exists(QStringLiteral("/usr/bin/curl")))
        o.curl = QStringLiteral("/usr/bin/curl");
    QJsonObject result;
    QString reason;
    const ExitCode c = provider == QLatin1String("apod") ? commons::fetchApod(o, &result, &reason) : commons::fetchCommons(o, &result, &reason);
    if (c != Ok)
        return fail(c, reason);
    return finish(result, Ok);
}

int cmdLatest(const QStringList &args)
{
    if (args.isEmpty() || !commons::providerKnown(args[0]))
        return fail(Usage, QStringLiteral("usage: latest commons|apod --out DIR"));
    const QString provider = args[0];
    const Args a = parseArgs(args.mid(1), {QStringLiteral("out")}, false);
    if (!a.ok)
        return fail(Usage, a.error);
    const QString out = a.options.value(QStringLiteral("out"));
    if (!commons::outDirAllowedFor(provider, out))
        return fail(Usage, QStringLiteral("--out must be the online cache (.../grassfield/wallpapers/online/<provider>)"));
    return finish(commons::latestCached(out, QString(), provider), Ok);
}

} // namespace

int main(int argc, char *argv[])
{
    // Untrusted pictures: every decoder is bounded to this much memory.
    QImageReader::setAllocationLimit(kAllocationLimitMb);
    QCoreApplication app(argc, argv);
    const QStringList args = app.arguments().mid(1);
    if (args.isEmpty())
        return fail(Usage, QStringLiteral("usage: grassfield-wallpaper prepare|thumb|list|formats|probe|transcode|fetch|latest"));
    const QString sub = args[0];
    const QStringList rest = args.mid(1);
    if (sub == QLatin1String("prepare"))
        return cmdPrepare(rest);
    if (sub == QLatin1String("thumb"))
        return cmdThumb(rest);
    if (sub == QLatin1String("list"))
        return cmdList(rest);
    if (sub == QLatin1String("probe"))
        return cmdProbe(rest);
    if (sub == QLatin1String("transcode"))
        return cmdTranscode(rest);
    if (sub == QLatin1String("fetch"))
        return cmdFetch(rest);
    if (sub == QLatin1String("latest"))
        return cmdLatest(rest);
    if (sub == QLatin1String("formats"))
        return finish({{QStringLiteral("suffixes"), QJsonArray::fromStringList(supportedSuffixes())}}, Ok);
    return fail(Usage, QStringLiteral("unknown subcommand"));
}
