#pragma once

#include <QByteArray>
#include <QString>

// The Rotate Left / Rotate Right quick actions of the preview pane (docs/specs/files.md "Preview pane"). A JPEG turns
// without touching its pixels: its EXIF orientation tag is changed in place (or a minimal EXIF segment holding only the
// orientation is added when the file has none). PNG and BMP are decoded, turned and written again in their own lossless
// format. The kind is the content's, never the name's (a JPEG named .png is a JPEG). Every other kind is left alone (a lossy re-encode, the loss of an animation or of TIFF tags is never risked). A
// file that is rewritten keeps its permissions, its user extended attributes (tags) and access lists; a file owned by
// someone else, with hard links or animated is refused.
namespace ImageRotate
{
enum class Method {
    None,
    Orientation, // JPEG: the EXIF orientation tag
    Reencode,    // PNG, BMP: lossless formats written again
};

// The most a picture may weigh to be turned: it is read whole into memory, then decoded and encoded again (PNG, BMP) or
// copied with a new segment (a JPEG without EXIF). A larger file is refused and left as it is (128 MiB: Qt's decoder
// refuses pictures over 256 MB of pixels anyway, and a turn holds the file, the pixels and the result at once).
constexpr qint64 kMaxFileSize = 128 * 1024 * 1024;

// Whether a picture of type `mimeType` (as KIO reports it, from its name) gets the quick actions. Only that: what is done
// to the file is decided by its content (methodForContent), never by its name.
Method methodFor(const QByteArray &mimeType);

// How the bytes `head` (the start of a file) turn, whatever the file is called: a JPEG through its orientation tag, a
// real PNG or BMP written again in its own format (`format` receives "png" or "bmp"), anything else not at all (a GIF,
// a WebP or a TIFF named .png is not re-encoded).
Method methodForContent(const QByteArray &head, QByteArray *format = nullptr);

// EXIF orientation (1..8) of a picture shown with `orientation` and then turned a quarter clockwise or anticlockwise.
// An unknown value reads as 1.
int turned(int orientation, bool clockwise);

// Where a JPEG's orientation tag is: `exif` when the file has an EXIF segment, `offset` the file offset of the tag's
// 16-bit value (-1 when there is no tag), `bigEndian` its byte order, `value` the stored orientation (1 without a tag).
// `insertAt`: where a new EXIF segment goes when there is none (after the start marker and a JFIF segment). `valid`:
// the bytes start like a JPEG and the segments up to the image data parse.
struct JpegOrientation {
    bool valid = false;
    bool exif = false;
    qint64 offset = -1;
    bool bigEndian = false;
    int value = 1;
    qint64 insertAt = 2;
};
JpegOrientation findOrientation(const QByteArray &head);

// A minimal APP1 EXIF segment (marker included) whose only tag is the orientation.
QByteArray exifSegment(int orientation);

// Turns the picture at `path` a quarter clockwise or anticlockwise. `mimeType` (from the name) must be one methodFor
// accepts; the content then decides how (methodForContent), and a file over kMaxFileSize is refused. Returns an empty
// string, or the reason it could not (the file is then left as it was).
QString rotate(const QString &path, const QByteArray &mimeType, bool clockwise);
} // namespace ImageRotate
