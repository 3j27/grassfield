#pragma once

#include <QByteArray>
#include <QSize>
#include <QString>
#include <QStringList>

#include <atomic>

// Pure logic of Grassfield Preview (no GUI): argument validation, file-type routing and size caps.
// Everything the viewer opens is untrusted: only local regular files, bounded sizes.
namespace preview {

enum class Kind { Image, Pdf, Text, Audio, Video, Unsupported };

// Caps (docs/specs/preview.md).
constexpr int kMaxImageSide = 16384;               // px per side
constexpr int kAllocationLimitMb = 256;            // QImageReader allocation limit
constexpr qint64 kMaxImageBytes = qint64(kAllocationLimitMb) * 1024 * 1024;
constexpr qint64 kMaxTextBytes = 2 * 1024 * 1024; // plain text / code
constexpr int kMaxFiles = 200;                     // files accepted on one command line

// Local path for a command line argument (a path or a file: URL), empty with `error` set when the
// argument is rejected (other schemes, remote file hosts, empty). Relative paths use `cwd`.
QString localPathFromArgument(const QString &arg, const QString &cwd, QString *error = nullptr);

// Routing by MIME type: images, PDF, text and code, audio, video.
Kind classify(const QString &path);
QString kindName(Kind kind);

// An image of this size (4 bytes per pixel) fits the per-side and allocation caps.
bool imageSizeAllowed(const QSize &size);
// Dimensions from the first bytes of a PNG file (IHDR), invalid when it is not a PNG. Used to say
// "too large" for images the decoder refuses before reporting their size.
QSize pngSize(const QByteArray &head);
// "File too large" check for text.
bool textSizeAllowed(qint64 bytes);
// NUL bytes in the sample: not text.
bool looksBinary(const QByteArray &sample);

// Canonical (symlink-resolved) path under /proc, /sys or /dev: never previewed.
bool isSystemPath(const QString &canonical);

// Command line: accepted local paths (at most kMaxFiles, regular files only, duplicates removed) and
// one message per rejected argument.
struct Arguments {
    QStringList paths;
    QStringList errors;
};
Arguments resolveArguments(const QStringList &args, const QString &cwd);

// The other files of the folder of `path`, in the order Grassfield Files shows them (same comparison: numeric,
// case-insensitive names; the Files view settings decide key and direction). Only regular, readable, visible files
// of the wanted kind (by file name: images only, or every kind Preview can show). `path` itself is always in the list
// at its sorted position, hidden or unreadable or not (the macOS model: the opened file is shown, an unreadable one with
// an error); unreadable siblings are skipped. At most kMaxFiles entries (a window around `path`). Read only. Meant for
// a worker thread: `cancel` (when set to true) stops the listing early and gives just `path`.
struct SortSpec {
    int key = 0; // 0 name, 1 kind, 2 date, 3 size (FileLogic::SortKey)
    bool descending = false;
    bool foldersFirst = true; // folders are not listed: kept for the shared comparison
};
struct Browse {
    QStringList paths;
    int index = 0; // position of the opened file in `paths`
};
enum class BrowseKinds { ImagesOnly, Previewable };
Browse browseFolder(const QString &path, BrowseKinds kinds, const SortSpec &sort, const std::atomic_bool *cancel = nullptr);
// View sort settings of Grassfield Files (QSettings Grassfield/Files, read only; defaults when absent).
SortSpec filesSortSpec();

} // namespace preview
