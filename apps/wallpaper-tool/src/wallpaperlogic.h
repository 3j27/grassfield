#pragma once

#include <QColor>
#include <QImage>
#include <QJsonObject>
#include <QSize>
#include <QString>
#include <QStringList>

// Pure logic of grassfield-wallpaper (ADR-0016): the one-shot helper that parses the user's pictures so that the
// shell never has to. Everything it opens is untrusted: bounded sizes, regular files only, no network.
namespace wallpaper {

// Exit codes (ui/Grassfield/Ui/WallpaperConfig.js EXIT/REASONS name the same numbers).
enum ExitCode {
    Ok = 0,
    Usage = 2,
    NotFound = 3,
    NotRegular = 4,
    TooLargeFile = 5,
    TooLargePicture = 6,
    Unreadable = 7,
    Unsupported = 8,
    Timeout = 9,
    WriteFailed = 10,
};

// Caps (the same as Grassfield Preview, docs/specs/preview.md).
constexpr int kMaxSide = 16384;                       // px per side
constexpr qint64 kMaxPixels = qint64(64) * 1000 * 1000; // 64 MP
constexpr int kAllocationLimitMb = 256;               // QImageReader allocation limit
constexpr qint64 kMaxFileBytes = qint64(256) * 1024 * 1024;
constexpr int kMaxListEntries = 100000;

enum class Fit { Fill, Fit, Stretch, Center, Tile };

bool parseFit(const QString &name, Fit *fit);
// "WxH" with both sides in 1..kMaxSide.
bool parseSize(const QString &text, QSize *size);

// Why a file cannot be used, before any decoding: NotFound, NotRegular (FIFO, device, directory), TooLargeFile.
// A symlink is followed (the target is checked); a loop is Unreadable.
ExitCode checkFile(const QString &path, qint64 maxBytes, qint64 *bytes = nullptr, qint64 *mtimeMs = nullptr);

// The size of a picture from its header, or an error code: Unsupported (no handler), Unreadable (corrupt header),
// TooLargePicture (a side over kMaxSide or more than kMaxPixels). The size is the displayed one (EXIF orientation applied).
ExitCode probePicture(const QString &path, QSize *size);

// Decode a picture for an output of `target` physical pixels and the fit mode: EXIF orientation applied, converted to
// sRGB when it carries another profile, scaled while decoding when the format allows it. Returns a null image and the
// code on failure.
ExitCode loadPicture(const QString &path, const QSize &target, Fit fit, QImage *out);

// The picture composed on an output-sized canvas: Fill covers and crops (centred), Fit shows it whole on `backdrop`,
// Stretch ignores the aspect, Center keeps its size (cropped when larger), Tile repeats it at its own size.
QImage compose(const QImage &src, const QSize &target, Fit fit, const QColor &backdrop);

// Relative luminance (WCAG, 0 black .. 1 white) statistics of the top `rows` rows of an image: the mean, the 5th and the
// 95th percentile, for the whole width and for each half (the menu bar's tone, ADR-0016 section 7).
QJsonObject stripStats(const QImage &img, int rows);
// The mean colour of an image as a "#rrggbb" string.
QString meanColor(const QImage &img);

// Cache key of a prepared picture: SHA-256 (hex, 32 chars) of the source's real path, size and mtime, the output size,
// the fit and the backdrop colour.
QString cacheKey(const QString &realPath, qint64 bytes, qint64 mtimeMs, const QSize &target, Fit fit, const QColor &backdrop, int stripRows);

// A folder's pictures: one level, regular files with a supported extension, hidden names skipped, sorted by name
// (UTF-16 order, as JavaScript compares). `supported` holds lower-case suffixes. NotFound when the folder is missing,
// NotRegular when it is not a directory, Unreadable when it cannot be read.
ExitCode listFolder(const QString &folder, const QStringList &supported, int max, QStringList *files, bool *truncated, qint64 *mtimeMs);

// Lower-case suffixes of the picture formats this build can decode, intersected with the formats wanted for wallpapers.
QStringList supportedSuffixes();

// A file name the helper itself creates in its cache folders: 32 hex digits and .jpg, .png or .json (thumbnails: a "t" first).
bool isCacheName(const QString &name);

// Creates the output folder with mode 0700 in one mkdir (no check-then-chmod race); a folder that already exists is used as it
// is, its permissions untouched. False when it cannot be created or is not writable.
bool ensureCacheDir(const QString &path);

// The only --out folders the helper accepts: <...>/grassfield/wallpapers/{prepared,thumbs} or <...>/cache/wallpapers/{prepared,
// thumbs}, absolute, no "." or ".." component. The helper owns those folders: it prunes names of its own form in them, so it
// must never be pointed at any other folder.
bool outDirAllowed(const QString &out);

// Removes the oldest of the helper's own files (isCacheName; nothing else in the folder, no symlink) of `dir` (by modification time) until the total is at most `maxBytes`. The files of `keep` (the
// pictures on screen, the one just written) and their sidecars are never removed, nor is anything younger than a minute.
void pruneCache(const QString &dir, qint64 maxBytes, const QStringList &keep);

// True when a JPEG file ends with its EOI marker (a truncated file does not).
bool jpegComplete(const QString &path);

// Writes `data` to `path` through a temporary file in the same directory and a rename (atomic).
bool writeAtomic(const QString &path, const QByteArray &data);

} // namespace wallpaper
