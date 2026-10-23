#include "videotool.h"

#include <QBuffer>
#include <QCryptographicHash>
#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QImage>
#include <QImageWriter>
#include <QJsonArray>
#include <QJsonDocument>
#include <QProcess>
#include <QProcessEnvironment>
#include <QThread>
#include <QElapsedTimer>

#include <algorithm>
#include <cmath>
#include <csignal>

#include <sys/prctl.h>
#include <sys/resource.h>
#include <unistd.h>

namespace wallpaper::video {

namespace {

volatile std::sig_atomic_t g_stop = 0;

void onSignal(int)
{
    g_stop = 1;
}

double rate(const QString &text)
{
    // "30000/1001" or "30" or "0/0".
    const QStringList p = text.split(QLatin1Char('/'));
    bool ok = false;
    const double a = p.value(0).toDouble(&ok);
    if (!ok)
        return 0;
    if (p.size() == 1)
        return a;
    const double b = p.value(1).toDouble(&ok);
    return ok && b > 0 ? a / b : 0;
}

// Display rotation of a stream in degrees (0, 90, 180, 270): the display matrix side data (recent ffprobe) or the old rotate tag.
int rotationOf(const QJsonObject &stream)
{
    double deg = 0;
    const QJsonArray side = stream.value(QStringLiteral("side_data_list")).toArray();
    for (const QJsonValue &v : side) {
        const QJsonValue r = v.toObject().value(QStringLiteral("rotation"));
        if (r.isDouble())
            deg = r.toDouble();
    }
    const QJsonValue tag = stream.value(QStringLiteral("tags")).toObject().value(QStringLiteral("rotate"));
    if (deg == 0 && tag.isString())
        deg = tag.toString().toDouble();
    int d = int(std::lround(deg)) % 360;
    if (d < 0)
        d += 360;
    return d;
}

struct Run {
    bool started = false;
    bool timedOut = false;
    bool aborted = false;
    bool overflow = false;
    int code = -1;
    QByteArray out;
    QByteArray err;
};

// Runs a program (argument vector, no shell) with a deadline. Lines of stdout go to `onLine` as they arrive (the progress);
// otherwise stdout is collected up to `maxOut` bytes (more: the process is killed, `overflow`). The process runs at a low
// priority and dies with the helper (PDEATHSIG); a stop signal to the helper kills it.
Run run(const QString &program, const QStringList &args, int timeoutSeconds, qint64 maxOut, qint64 dataLimit, const std::function<void(const QString &)> &onLine = nullptr)
{
    Run r;
    QProcess p;
    p.setProgram(program);
    p.setArguments(args);
    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    // glibc reserves arena address space per thread: two arenas keep the footprint the same on 8 and on 64 cores.
    env.insert(QStringLiteral("MALLOC_ARENA_MAX"), QStringLiteral("2"));
    p.setProcessEnvironment(env);
    p.setChildProcessModifier([dataLimit] {
        ::prctl(PR_SET_PDEATHSIG, SIGKILL);
        ::setpriority(PRIO_PROCESS, 0, 10);
        // A hostile file cannot make the decoder take all the memory: the child's heap is capped (a failed allocation ends the
        // run as a failure). RLIMIT_DATA, not RLIMIT_AS: it counts the memory in use, not the address space that threads reserve.
        if (dataLimit > 0) {
            struct rlimit lim;
            lim.rlim_cur = lim.rlim_max = rlim_t(dataLimit);
            ::setrlimit(RLIMIT_DATA, &lim);
        }
    });
    p.start();
    if (!p.waitForStarted(5000))
        return r;
    r.started = true;
    p.closeWriteChannel();
    QElapsedTimer clock;
    clock.start();
    QByteArray pending;
    auto drain = [&] {
        const QByteArray chunk = p.readAllStandardOutput();
        if (onLine) {
            pending += chunk;
            int nl;
            while ((nl = pending.indexOf('\n')) >= 0) {
                onLine(QString::fromUtf8(pending.left(nl)));
                pending.remove(0, nl + 1);
            }
            if (pending.size() > 65536)
                pending.clear();
        } else {
            r.out += chunk;
        }
        if (r.err.size() < 65536)
            r.err += p.readAllStandardError().left(65536 - r.err.size());
        else
            p.readAllStandardError();
        if (r.out.size() > maxOut && !r.overflow) {
            r.overflow = true;
            p.kill();
        }
    };
    while (p.state() != QProcess::NotRunning) {
        p.waitForFinished(100);
        drain();
        if (g_stop && !r.aborted) {
            r.aborted = true;
            p.kill();
        }
        if (clock.elapsed() > qint64(timeoutSeconds) * 1000 && !r.timedOut) {
            r.timedOut = true;
            p.kill();
        }
    }
    p.waitForFinished(2000);
    drain();
    r.code = p.exitStatus() == QProcess::NormalExit ? p.exitCode() : -1;
    return r;
}

QString shortError(const QByteArray &err)
{
    QString s = QString::fromUtf8(err.right(400)).simplified();
    // Control characters never reach the shell's journal or the Settings caption.
    QString out;
    for (const QChar c : s)
        out += c.isPrint() ? c : QChar(' ');
    return out.left(200);
}

QByteArray encodeJpeg(const QImage &img, int quality)
{
    QByteArray bytes;
    QBuffer buffer(&bytes);
    buffer.open(QIODevice::WriteOnly);
    QImageWriter w(&buffer, "jpg");
    w.setQuality(quality);
    if (!w.write(img))
        return {};
    return bytes;
}

// One frame of `file` at `seconds`, null on failure.
QImage grabFrame(const QString &ffmpeg, const QString &file, double seconds, QString *reason, const QSize &fitInside = QSize())
{
    const Run r = run(ffmpeg, frameArgs(file, seconds, fitInside), kFrameTimeoutSeconds, qint64(96) << 20, kFrameDataLimit);
    if (r.aborted) {
        *reason = QStringLiteral("cancelled");
        return {};
    }
    if (!r.started || r.code != 0 || r.out.isEmpty()) {
        *reason = QStringLiteral("cannot read a frame: ") + shortError(r.err);
        return {};
    }
    const QImage img = QImage::fromData(r.out, "PNG");
    if (img.isNull() || img.width() > kMaxSide || img.height() > kMaxSide || qint64(img.width()) * img.height() > kMaxPixels) {
        *reason = QStringLiteral("a frame cannot be decoded");
        return {};
    }
    return img;
}

} // namespace

QStringList videoSuffixes()
{
    return {QStringLiteral("mp4"), QStringLiteral("m4v"), QStringLiteral("mov"), QStringLiteral("mkv"), QStringLiteral("webm"), QStringLiteral("avi"), QStringLiteral("ogv")};
}

bool isVideoPath(const QString &path)
{
    return videoSuffixes().contains(QFileInfo(path).suffix().toLower());
}

QStringList ffprobeArgs(const QString &path)
{
    return {QStringLiteral("-v"), QStringLiteral("error"), QStringLiteral("-protocol_whitelist"), QStringLiteral("file"), QStringLiteral("-format_whitelist"), QString::fromLatin1(kDemuxers), QStringLiteral("-print_format"), QStringLiteral("json"),
            QStringLiteral("-show_format"), QStringLiteral("-show_streams"), QStringLiteral("-i"), path};
}

ExitCode parseProbe(const QByteArray &json, int maxSeconds, Info *info, QString *reason)
{
    QJsonParseError err;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &err);
    if (err.error != QJsonParseError::NoError || !doc.isObject()) {
        *reason = QStringLiteral("ffprobe gave no JSON");
        return Unreadable;
    }
    const QJsonObject root = doc.object();
    QJsonObject stream;
    bool audio = false, found = false;
    for (const QJsonValue &v : root.value(QStringLiteral("streams")).toArray()) {
        const QJsonObject s = v.toObject();
        const QString type = s.value(QStringLiteral("codec_type")).toString();
        if (type == QLatin1String("audio"))
            audio = true;
        // A cover picture inside an audio file is a "video" stream with disposition attached_pic: not a video.
        if (type == QLatin1String("video") && !found && s.value(QStringLiteral("disposition")).toObject().value(QStringLiteral("attached_pic")).toInt() == 0) {
            stream = s;
            found = true;
        }
    }
    if (!found) {
        *reason = QStringLiteral("no video stream");
        return Unsupported;
    }
    int w = stream.value(QStringLiteral("width")).toInt();
    int h = stream.value(QStringLiteral("height")).toInt();
    if (w < 2 || h < 2 || w > kMaxSide || h > kMaxSide || qint64(w) * h > kMaxPixels) {
        *reason = QStringLiteral("the video size is out of range");
        return TooLargePicture;
    }
    const int rot = rotationOf(stream);
    if (rot == 90 || rot == 270)
        std::swap(w, h);
    double duration = root.value(QStringLiteral("format")).toObject().value(QStringLiteral("duration")).toString().toDouble();
    if (!(duration > 0))
        duration = stream.value(QStringLiteral("duration")).toString().toDouble();
    if (!(duration > 0) || !std::isfinite(duration)) {
        *reason = QStringLiteral("the video has no known duration");
        return Unreadable;
    }
    if (duration > maxSeconds) {
        *reason = QStringLiteral("the video is longer than %1 seconds").arg(maxSeconds);
        return TooLongVideo;
    }
    double fps = rate(stream.value(QStringLiteral("avg_frame_rate")).toString());
    if (!(fps > 0))
        fps = rate(stream.value(QStringLiteral("r_frame_rate")).toString());
    if (!std::isfinite(fps) || fps < 0 || fps > 1000)
        fps = 0;
    info->duration = duration;
    info->width = w;
    info->height = h;
    info->fps = fps;
    info->codec = stream.value(QStringLiteral("codec_name")).toString().left(32);
    for (QChar &c : info->codec) {
        if (!(c.isLetterOrNumber() || c == QLatin1Char('_') || c == QLatin1Char('-')))
            c = QLatin1Char('_');
    }
    info->audio = audio;
    return Ok;
}

QSize outputSize(const QSize &source, const QSize &limit)
{
    if (source.width() < 1 || source.height() < 1 || limit.width() < 1 || limit.height() < 1)
        return QSize(2, 2);
    const double scale = std::min({1.0, double(limit.width()) / source.width(), double(limit.height()) / source.height()});
    auto even = [](double v) { return std::max(2, int(std::floor(v / 2.0)) * 2); };
    return QSize(even(source.width() * scale), even(source.height() * scale));
}

QSize videoLimit(const QSize &display)
{
    return QSize(std::min(display.width(), kMaxVideoWidth), std::min(display.height(), kMaxVideoHeight));
}

int threadCount(int cpus)
{
    return std::clamp(cpus, 1, kMaxThreads);
}

QStringList transcodeArgs(const QString &src, const QString &dst, const QSize &size, double sourceFps, int maxSeconds, qint64 maxBytes, int threads)
{
    const QString n = QString::number(std::clamp(threads, 1, kMaxThreads));
    QString filter = QStringLiteral("scale=%1:%2:flags=lanczos").arg(size.width()).arg(size.height());
    if (sourceFps > kMaxFps + 0.01 || sourceFps <= 0)
        filter += QStringLiteral(",fps=%1").arg(int(kMaxFps));
    filter += QStringLiteral(",setsar=1,format=yuv420p");
    // An unknown frame rate (0) gets the cap too: a variable-rate file is made constant at the cap.
    return {QStringLiteral("-nostdin"), QStringLiteral("-hide_banner"), QStringLiteral("-loglevel"), QStringLiteral("error"), QStringLiteral("-nostats"),
            QStringLiteral("-protocol_whitelist"), QStringLiteral("file"), QStringLiteral("-format_whitelist"), QString::fromLatin1(kDemuxers),
            QStringLiteral("-max_alloc"), QString::number(kMaxAlloc), QStringLiteral("-max_pixels"), QString::number(kMaxPixels),
            // Explicit thread counts, the same on every machine: the decoder (input option), the filter graph, the encoder.
            QStringLiteral("-filter_threads"), n, QStringLiteral("-threads"), n,
            QStringLiteral("-i"), src,
            QStringLiteral("-map"), QStringLiteral("0:v:0"), QStringLiteral("-an"), QStringLiteral("-sn"), QStringLiteral("-dn"),
            QStringLiteral("-map_metadata"), QStringLiteral("-1"), QStringLiteral("-map_chapters"), QStringLiteral("-1"),
            QStringLiteral("-vf"), filter,
            QStringLiteral("-threads"), n,
            QStringLiteral("-c:v"), QStringLiteral("libx264"), QStringLiteral("-preset"), QStringLiteral("fast"), QStringLiteral("-crf"), QStringLiteral("22"),
            QStringLiteral("-pix_fmt"), QStringLiteral("yuv420p"), QStringLiteral("-profile:v"), QStringLiteral("high"),
            QStringLiteral("-movflags"), QStringLiteral("+faststart"),
            QStringLiteral("-t"), QString::number(maxSeconds), QStringLiteral("-fs"), QString::number(maxBytes),
            QStringLiteral("-progress"), QStringLiteral("pipe:1"), QStringLiteral("-f"), QStringLiteral("mp4"), QStringLiteral("-y"), dst};
}

QStringList frameArgs(const QString &file, double seconds, const QSize &fitInside, int threads)
{
    QStringList scale;
    if (fitInside.isValid() && !fitInside.isEmpty())
        scale = {QStringLiteral("-vf"), QStringLiteral("scale='min(iw,%1)':'min(ih,%2)':force_original_aspect_ratio=decrease").arg(fitInside.width()).arg(fitInside.height())};
    QStringList a = {QStringLiteral("-nostdin"), QStringLiteral("-hide_banner"), QStringLiteral("-loglevel"), QStringLiteral("error"),
            QStringLiteral("-protocol_whitelist"), QStringLiteral("file"), QStringLiteral("-format_whitelist"), QString::fromLatin1(kDemuxers),
            QStringLiteral("-max_alloc"), QString::number(kMaxAlloc), QStringLiteral("-max_pixels"), QString::number(kMaxPixels),
            QStringLiteral("-threads"), QString::number(std::clamp(threads, 1, kMaxThreads)), QStringLiteral("-filter_threads"), QString::number(std::clamp(threads, 1, kMaxThreads)),
            QStringLiteral("-ss"), QString::number(std::max(0.0, seconds), 'f', 3), QStringLiteral("-i"), file,
            QStringLiteral("-frames:v"), QStringLiteral("1"), QStringLiteral("-an"), QStringLiteral("-sn")};
    a += scale;
    // Output-side threads too: the PNG encoder sizes its pool from the CPU count otherwise (74 threads at 64 cores).
    a += {QStringLiteral("-threads"), QString::number(std::clamp(threads, 1, kMaxThreads)), QStringLiteral("-f"), QStringLiteral("image2pipe"), QStringLiteral("-c:v"), QStringLiteral("png"), QStringLiteral("-")};
    return a;
}

double progressOf(const QString &line, double duration)
{
    static const QString key = QStringLiteral("out_time_us=");
    if (!line.startsWith(key) || !(duration > 0))
        return -1;
    bool ok = false;
    const qint64 us = line.mid(key.size()).trimmed().toLongLong(&ok);
    if (!ok || us < 0)
        return -1;
    return std::clamp(double(us) / (duration * 1e6), 0.0, 1.0);
}

QJsonObject worstStrip(const QList<QJsonObject> &stats)
{
    if (stats.isEmpty())
        return {};
    QJsonObject out;
    int rows = 0;
    for (const QJsonObject &s : stats)
        rows = std::max(rows, s.value(QStringLiteral("rows")).toInt());
    out.insert(QStringLiteral("rows"), rows);
    for (const char *name : {"all", "left", "right"}) {
        const QString key = QString::fromLatin1(name);
        double mean = 0, p5 = 1, p95 = 0;
        for (const QJsonObject &s : stats) {
            const QJsonObject h = s.value(key).toObject();
            mean += h.value(QStringLiteral("mean")).toDouble();
            p5 = std::min(p5, h.value(QStringLiteral("p5")).toDouble());
            p95 = std::max(p95, h.value(QStringLiteral("p95")).toDouble());
        }
        out.insert(key, QJsonObject{{QStringLiteral("mean"), mean / stats.size()}, {QStringLiteral("p5"), p5}, {QStringLiteral("p95"), p95}});
    }
    return out;
}

double posterSeconds(double duration)
{
    return std::clamp(duration / 10.0, 0.0, 5.0);
}

QString videoKey(const QString &realPath, qint64 bytes, qint64 mtimeMs, const QSize &size)
{
    QByteArray in = realPath.toUtf8();
    in += '\0' + QByteArray::number(bytes) + '\0' + QByteArray::number(mtimeMs) + '\0';
    in += QByteArray::number(size.width()) + 'x' + QByteArray::number(size.height());
    in += QByteArray("\0vid1", 5);
    return QString::fromLatin1(QCryptographicHash::hash(in, QCryptographicHash::Sha256).toHex().left(32));
}

bool outDirAllowed(const QString &out)
{
    if (!out.startsWith(QLatin1Char('/')))
        return false;
    const QStringList parts = out.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    if (parts.contains(QStringLiteral("..")) || parts.contains(QStringLiteral(".")) || parts.size() < 4)
        return false;
    const int n = parts.size();
    return parts[n - 1] == QLatin1String("video") && parts[n - 2] == QLatin1String("wallpapers") && (parts[n - 3] == QLatin1String("grassfield") || parts[n - 3] == QLatin1String("cache"));
}

void installSignalHandlers()
{
    struct sigaction sa;
    sa.sa_handler = onSignal;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    ::sigaction(SIGTERM, &sa, nullptr);
    ::sigaction(SIGINT, &sa, nullptr);
}

ExitCode probe(const QString &ffprobe, const QString &path, int maxSeconds, Info *info, QString *reason)
{
    const Run r = run(ffprobe, ffprobeArgs(path), kProbeTimeoutSeconds, kMaxProbeJsonBytes, kProbeDataLimit);
    if (r.aborted) {
        *reason = QStringLiteral("cancelled");
        return Cancelled;
    }
    if (!r.started) {
        *reason = QStringLiteral("ffprobe is not installed");
        return FfmpegMissing;
    }
    if (r.timedOut) {
        *reason = QStringLiteral("ffprobe timed out");
        return Timeout;
    }
    if (r.overflow) {
        *reason = QStringLiteral("ffprobe answered too much");
        return Unreadable;
    }
    if (r.code != 0) {
        // The file is not a media file ffprobe understands.
        *reason = QStringLiteral("not a video: ") + shortError(r.err);
        return Unsupported;
    }
    return parseProbe(r.out, maxSeconds, info, reason);
}

namespace {

// Removes the temporary files of one run on every way out.
struct Cleanup {
    QStringList paths;
    ~Cleanup()
    {
        for (const QString &p : std::as_const(paths))
            QFile::remove(p);
    }
};

void dropStaleTemporaries(const QString &dir)
{
    const QDateTime stale = QDateTime::currentDateTime().addSecs(-3600);
    const QFileInfoList all = QDir(dir).entryInfoList(QDir::Files | QDir::NoSymLinks | QDir::NoDotAndDotDot | QDir::Hidden);
    for (const QFileInfo &f : all) {
        if (f.fileName().startsWith(QStringLiteral(".vt-")) && f.fileName().endsWith(QStringLiteral(".mp4")) && f.lastModified() < stale)
            QFile::remove(f.absoluteFilePath());
    }
}

} // namespace

ExitCode transcode(const TranscodeOptions &o, const std::function<void(double)> &progress, QJsonObject *result, QString *reason)
{
    if (!outDirAllowed(o.out) || !o.src.startsWith(QLatin1Char('/'))) {
        *reason = QStringLiteral("bad paths");
        return Usage;
    }
    qint64 bytes = 0, mtime = 0;
    if (const ExitCode c = checkFile(o.src, kMaxSourceBytes, &bytes, &mtime)) {
        *reason = QStringLiteral("the video cannot be used");
        return c;
    }
    if (!ensureCacheDir(o.out)) {
        *reason = QStringLiteral("cannot create the output folder");
        return WriteFailed;
    }
    Info info;
    if (const ExitCode c = probe(o.ffprobe, o.src, o.maxSeconds, &info, reason))
        return c;
    const QString real = QFileInfo(o.src).canonicalFilePath();
    // The video is fitted inside 3840x2160 whatever the display (a 5K display shows the 4K video scaled); the poster is composed on
    // the display itself. The file is shared by displays of any size above 4K.
    const QSize vlimit = videoLimit(o.limit);
    const QSize size = outputSize(QSize(info.width, info.height), vlimit);
    const QString key = videoKey(real, bytes, mtime, vlimit);
    const QString mp4 = o.out + QLatin1Char('/') + key + QStringLiteral(".mp4");
    // The poster and the sidecar are named by the fit and the colour too (the picture on screen follows them).
    const QString full = cacheKey(real, bytes, mtime, o.limit, o.fit, o.color, o.stripRows);
    const QString poster = o.out + QLatin1Char('/') + full + QStringLiteral(".jpg");
    const QString sidecar = o.out + QLatin1Char('/') + full + QStringLiteral(".json");
    const QStringList keep = o.keep + QStringList{mp4, poster};

    auto touch = [](const QString &path) {
        QFile f(path);
        if (f.open(QIODevice::ReadWrite | QIODevice::ExistingOnly)) {
            f.setFileTime(QDateTime::currentDateTime(), QFileDevice::FileModificationTime);
            f.close();
        }
    };
    // Whole cache hit: the three files and a sidecar that names this key.
    if (QFileInfo(mp4).isFile() && QFileInfo(poster).isFile()) {
        QFile f(sidecar);
        if (f.open(QIODevice::ReadOnly) && f.size() < 256 * 1024) {
            const QJsonObject cached = QJsonDocument::fromJson(f.readAll()).object();
            if (cached.value(QStringLiteral("key")).toString() == full) {
                touch(mp4);
                touch(poster);
                *result = cached;
                result->insert(QStringLiteral("cached"), true);
                return Ok;
            }
        }
    }

    dropStaleTemporaries(o.out);
    Cleanup cleanup;
    if (!QFileInfo(mp4).isFile()) {
        const QString tmp = o.out + QStringLiteral("/.vt-") + QString::number(::getpid()) + QStringLiteral(".mp4");
        cleanup.paths << tmp;
        double last = -1;
        auto onLine = [&](const QString &line) {
            const double f = progressOf(line, std::min<double>(info.duration, o.maxSeconds));
            if (f >= 0 && f - last >= 0.01) {
                last = f;
                if (progress)
                    progress(f);
            }
        };
        const Run r = run(o.ffmpeg, transcodeArgs(o.src, tmp, size, info.fps, o.maxSeconds, o.maxBytes, o.threads > 0 ? std::min(o.threads, kMaxThreads) : threadCount(QThread::idealThreadCount())), kTranscodeTimeoutSeconds, 0, o.dataLimit, onLine);
        if (r.aborted) {
            *reason = QStringLiteral("cancelled");
            return Cancelled;
        }
        if (!r.started) {
            *reason = QStringLiteral("ffmpeg is not installed");
            return FfmpegMissing;
        }
        if (r.timedOut) {
            *reason = QStringLiteral("ffmpeg timed out");
            return Timeout;
        }
        if (r.code != 0) {
            *reason = QStringLiteral("ffmpeg failed: ") + shortError(r.err);
            return TranscodeFailed;
        }
        qint64 outBytes = 0;
        if (checkFile(tmp, o.maxBytes, &outBytes) != Ok || outBytes < 1024) {
            *reason = QStringLiteral("the transcoded file is empty or over the size limit");
            return TranscodeFailed;
        }
        // Whatever ffmpeg wrote, the file the shell plays must be what was asked for: H.264, no larger than the output.
        Info made;
        QString why;
        if (probe(o.ffprobe, tmp, o.maxSeconds + 5, &made, &why) != Ok || made.codec != QLatin1String("h264") || made.width > vlimit.width() || made.height > vlimit.height() || made.fps > kMaxFps + 0.5 || made.audio) {
            *reason = QStringLiteral("the transcoded file is not what was asked for");
            return TranscodeFailed;
        }
        if (!QFile::rename(tmp, mp4)) {
            *reason = QStringLiteral("cannot write the video");
            return WriteFailed;
        }
        cleanup.paths.removeAll(tmp);
        QFile::setPermissions(mp4, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
        if (progress)
            progress(1.0);
    }

    // The poster, then the frames of the tone. Each frame is composed on the output exactly as the player will show it.
    QString why;
    const double posterAt = posterSeconds(info.duration);
    const QImage posterFrame = grabFrame(o.ffmpeg, mp4, posterAt, &why);
    if (posterFrame.isNull()) {
        *reason = why;
        return why == QLatin1String("cancelled") ? Cancelled : TranscodeFailed;
    }
    const QImage composedPoster = compose(posterFrame, o.limit, o.fit, o.color);
    const QByteArray jpg = encodeJpeg(composedPoster, 95);
    if (jpg.isEmpty() || !writeAtomic(poster, jpg)) {
        *reason = QStringLiteral("cannot write the poster");
        return WriteFailed;
    }
    QFile::setPermissions(poster, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    QList<QJsonObject> stats{stripStats(composedPoster, o.stripRows)};
    for (int i = 0; i < kToneFrames; ++i) {
        const QImage f = grabFrame(o.ffmpeg, mp4, (i + 0.5) * info.duration / kToneFrames, &why);
        if (f.isNull()) {
            if (why == QLatin1String("cancelled")) {
                *reason = why;
                return Cancelled;
            }
            continue; // a frame that cannot be read is skipped: the poster is already counted
        }
        stats << stripStats(compose(f, o.limit, o.fit, o.color), o.stripRows);
    }
    QJsonObject meta{{QStringLiteral("key"), full},
                     {QStringLiteral("file"), poster},
                     {QStringLiteral("video"), mp4},
                     {QStringLiteral("width"), composedPoster.width()},
                     {QStringLiteral("height"), composedPoster.height()},
                     {QStringLiteral("videoWidth"), size.width()},
                     {QStringLiteral("videoHeight"), size.height()},
                     {QStringLiteral("duration"), info.duration},
                     {QStringLiteral("fps"), std::min(info.fps > 0 ? info.fps : kMaxFps, kMaxFps)},
                     {QStringLiteral("codec"), info.codec},
                     {QStringLiteral("posterMs"), int(posterAt * 1000)},
                     {QStringLiteral("frames"), int(stats.size())},
                     {QStringLiteral("source"), o.src},
                     {QStringLiteral("real"), real},
                     {QStringLiteral("mean"), meanColor(composedPoster)},
                     {QStringLiteral("strip"), worstStrip(stats)}};
    if (!writeAtomic(sidecar, QJsonDocument(meta).toJson(QJsonDocument::Compact))) {
        *reason = QStringLiteral("cannot write the sidecar");
        return WriteFailed;
    }
    QFile::setPermissions(sidecar, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    pruneCache(o.out, o.cacheMaxBytes, keep);
    meta.insert(QStringLiteral("cached"), false);
    *result = meta;
    return Ok;
}

ExitCode thumbnail(const QString &src, const QString &outFile, int width, QString *reason)
{
    Info info;
    if (const ExitCode c = probe(QStringLiteral("/usr/bin/ffprobe"), src, kMaxSeconds, &info, reason))
        return c;
    const QImage frame = grabFrame(QStringLiteral("/usr/bin/ffmpeg"), src, posterSeconds(info.duration), reason, QSize(1280, 1280));
    if (frame.isNull())
        return *reason == QLatin1String("cancelled") ? Cancelled : TranscodeFailed;
    const QByteArray jpg = encodeJpeg(compose(frame, QSize(width, width * 10 / 16), Fit::Fill, QColor(Qt::black)), 85);
    if (jpg.isEmpty() || !writeAtomic(outFile, jpg)) {
        *reason = QStringLiteral("cannot write the thumbnail");
        return WriteFailed;
    }
    QFile::setPermissions(outFile, QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    return Ok;
}

} // namespace wallpaper::video
