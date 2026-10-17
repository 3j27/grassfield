#pragma once

#include <QByteArray>
#include <QSize>
#include <QString>
#include <QStringList>

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

// Command line: accepted local paths (at most kMaxFiles, regular files only, duplicates removed) and
// one message per rejected argument.
struct Arguments {
    QStringList paths;
    QStringList errors;
};
Arguments resolveArguments(const QStringList &args, const QString &cwd);

} // namespace preview
