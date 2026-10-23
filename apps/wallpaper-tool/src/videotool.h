#pragma once

#include <QJsonObject>
#include <QList>
#include <QSize>
#include <QString>
#include <QStringList>

#include <functional>

#include "wallpaperlogic.h"

// Video wallpapers of grassfield-wallpaper (ADR-0016 W7, option V1b): `probe` and `transcode`. The user's video is untrusted
// and is parsed ONLY by the ffmpeg and ffprobe programs (argument vectors, no shell, a protocol whitelist of plain files, low
// priority, killed with the helper); the shell then decodes only the H.264 file this module wrote. Everything pure (argument
// vectors, probe parsing, sizes, progress, the worst-case statistics) is a free function so that the unit tests run it
// without a video; probe() and transcode() are the functions that start a process.
namespace wallpaper::video {

constexpr int kMaxSeconds = 600;                           // wallpaper.videoMaxSeconds
constexpr qint64 kMaxSourceBytes = qint64(8) << 30;        // the source file
constexpr qint64 kMaxOutputBytes = qint64(512) << 20;      // wallpaper.videoMaxBytes: the transcoded file
constexpr double kMaxFps = 30.0;
constexpr int kToneFrames = 8;                             // frames sampled for the menu bar tone, besides the poster
constexpr int kTranscodeTimeoutSeconds = 1800;             // one run of ffmpeg (the shell kills the helper earlier)
constexpr int kProbeTimeoutSeconds = 30;
constexpr int kFrameTimeoutSeconds = 30;
constexpr qint64 kMaxProbeJsonBytes = 1024 * 1024;
// The only container formats ffmpeg may open (the demuxers behind the suffixes of videoSuffixes): a playlist (HLS, ffconcat, a
// text file naming other files) is refused whatever its name.
constexpr const char *kDemuxers = "mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,avi,ogg";
// Limits of the child programs: one allocation, the picture size (as the picture limits) and the address space.
constexpr qint64 kMaxAlloc = qint64(1) << 30;
constexpr qint64 kProbeAddressSpace = qint64(2) << 30;
constexpr qint64 kFrameAddressSpace = qint64(4) << 30;
constexpr qint64 kTranscodeAddressSpace = qint64(8) << 30;

// What ffprobe says about a video's first video stream (after the display rotation).
struct Info {
    double duration = 0;   // seconds
    int width = 0;         // displayed size (rotation applied)
    int height = 0;
    double fps = 0;        // average frame rate, 0 when unknown
    QString codec;         // codec name, e.g. "h264", "av1"
    bool audio = false;    // the file has an audio stream (it is dropped)
};

// Lower-case suffixes of the video files the Settings app offers (ffprobe decides what it can actually read).
QStringList videoSuffixes();
bool isVideoPath(const QString &path);

// ffprobe: one JSON document on stdout. The path is the value of `-i` (ffmpeg has no `--`) and starts with "/", so it is never read as
// an option or a protocol; the protocol whitelist is plain files and the format whitelist the containers of kDemuxers.
QStringList ffprobeArgs(const QString &path);
// Reads the JSON. Unsupported: no video stream (or no size). Unreadable: not JSON. TooLongVideo: longer than `maxSeconds`
// (a duration that is not known is Unreadable: a wallpaper loops, a stream of unknown length is not accepted).
ExitCode parseProbe(const QByteArray &json, int maxSeconds, Info *info, QString *reason);

// The transcoded size: the source fitted inside `limit` (never enlarged), each side even and at least 2.
QSize outputSize(const QSize &source, const QSize &limit);

// The ffmpeg argument vector of the transcode: H.264 (libx264) yuv420p at `size`, at most kMaxFps, no audio, no
// subtitles, no metadata, +faststart, at most `maxSeconds` and `maxBytes`, progress on stdout.
QStringList transcodeArgs(const QString &src, const QString &dst, const QSize &size, double sourceFps, int maxSeconds, qint64 maxBytes);

// One frame at `seconds` as a PNG on stdout (no scaling: the caller composes it).
QStringList frameArgs(const QString &file, double seconds);

// "out_time_us=<n>" (ffmpeg -progress) to the fraction done of `duration`, or -1 for any other line (or "N/A").
double progressOf(const QString &line, double duration);

// The strip statistics of several frames, worst case: the mean of the means, the lowest p5 and the highest p95, for the whole
// width and for each half ({rows, all, left, right} as stripStats). Empty input gives an empty object.
QJsonObject worstStrip(const QList<QJsonObject> &stats);

// The time of the poster frame: a tenth of the video, at most 5 s.
double posterSeconds(double duration);

// Cache key of the transcoded file: the source's real path, size and mtime and the output size (not the fit or colour: the
// same video at another fit reuses the file).
QString videoKey(const QString &realPath, qint64 bytes, qint64 mtimeMs, const QSize &size);

// <...>/grassfield/wallpapers/video or <...>/cache/wallpapers/video, absolute, no "." or ".." component.
bool outDirAllowed(const QString &out);

// ---- the processes ----

// Called by the video subcommands only: every other subcommand keeps the default action, so a superseded `prepare`, `list`, still
// `thumb` or `fetch` dies at once. A SIGTERM or SIGINT to the helper stops the running ffmpeg and ends the run with Cancelled (the handler is installed by main()).
void installSignalHandlers();

// ffprobe of a file already checked as a regular file.
ExitCode probe(const QString &ffprobe, const QString &path, int maxSeconds, Info *info, QString *reason);

struct TranscodeOptions {
    QString src;        // absolute path
    QString out;        // the video cache folder
    QSize limit;        // the output's physical size
    Fit fit = Fit::Fill;
    QColor color = Qt::black;
    int stripRows = 24;
    int maxSeconds = kMaxSeconds;
    qint64 maxBytes = kMaxOutputBytes;
    qint64 cacheMaxBytes = qint64(512) << 20;
    QStringList keep;   // files of the cache that must survive the pruning
    QString ffmpeg = QStringLiteral("/usr/bin/ffmpeg");
    QString ffprobe = QStringLiteral("/usr/bin/ffprobe");
};

// Transcodes (or finds in the cache) the video and writes the poster and the sidecar. `progress` is called with 0..1 as the
// encoding advances. `result` holds the sidecar fields: file (the poster), video (the H.264 file), width, height, duration,
// fps, codec, posterMs, mean, strip, key, cached.
ExitCode transcode(const TranscodeOptions &opts, const std::function<void(double)> &progress, QJsonObject *result, QString *reason);

// One frame of a video as a JPEG thumbnail of `width` (the Settings grid), ffprobe then ffmpeg.
ExitCode thumbnail(const QString &src, const QString &outFile, int width, QString *reason);

} // namespace wallpaper::video
