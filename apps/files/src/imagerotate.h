#pragma once

#include <QByteArray>
#include <QString>

// The Rotate Left / Rotate Right quick actions of the preview pane (docs/specs/files.md "Preview pane"). A JPEG turns
// without touching its pixels: its EXIF orientation tag is changed in place (or a minimal EXIF segment holding only the
// orientation is added when the file has none). PNG, BMP and TIFF are decoded, turned and written again in their own
// lossless format. Every other kind is left alone (a lossy re-encode or the loss of an animation is never risked). A
// file that is rewritten keeps its permissions and its user extended attributes (tags, folder looks are folders only).
namespace ImageRotate
{
enum class Method {
    None,
    Orientation, // JPEG: the EXIF orientation tag
    Reencode,    // PNG, BMP, TIFF: lossless formats written again
};

// How `path` would turn, from its content type (`mimeType`, as KIO reports it).
Method methodFor(const QByteArray &mimeType);

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

// Turns the picture at `path` a quarter clockwise or anticlockwise. Returns an empty string, or the reason it could not.
QString rotate(const QString &path, const QByteArray &mimeType, bool clockwise);
} // namespace ImageRotate
