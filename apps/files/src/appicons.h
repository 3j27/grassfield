#pragma once

#include <QByteArray>
#include <QImage>
#include <QSize>
#include <QString>
#include <QStringList>

// Decoding of an application's absolute Icon= path (the desktop entry is not trusted: any user can plant one). The shell never
// decodes such a file itself (shell/services/image-copy.py re-encodes it out of process); Files has no helper, so it is
// stricter in what it decodes in its own process, and never on the GUI thread (IconProvider answers asynchronously):
//   - the file must pass ApplicationsLogic::readIconFile (a regular file under the allowed roots, read from the checked
//     descriptor: a FIFO or device never blocks);
//   - the content is chosen by its magic bytes, never by the name or by Qt's format guessing: PNG, or SVG. JPEG, GIF, WebP,
//     PDF, TIFF and every other Qt image plugin are refused (a PDF named .png was once rendered);
//   - a PNG header must give a size within kMaxSide x kMaxSide before the pixels are decoded (the allocation is limited too);
//   - an SVG must be a UTF-8 document that refers to nothing outside itself (svgIsSelfContained). Qt 6.11's SVG reader follows
//     <image href> to any file and has no option against it (QtSvg::Options, probed: a href to a FIFO blocks with every
//     option), so references are refused before Qt sees the document.
// The result is scaled to fit `want` (at most kMaxSide) and is a null image for anything refused.
namespace AppIcons
{

constexpr int kMaxSide = 1024;                      // largest side of an application icon, in pixels (PNG header, SVG render)
constexpr qint64 kMaxPngBytes = 4 * 1024 * 1024;    // a 1024 x 1024 PNG is far below
constexpr qint64 kMaxSvgBytes = 512 * 1024;
constexpr int kMaxSvgDepth = 64;
constexpr int kMaxSvgElements = 20000;
constexpr int kMaxSvgUses = 64;                     // <use> can multiply: a chain of them is a CPU bomb

// True when the SVG document `data` refers to nothing outside itself and has no construct that does: no DTD or entity, no
// processing instruction, no script, foreignObject, animation of an href, no href other than "#id" (a data: image included:
// its pixels are not bounded), no xml:base, no CSS url() other than "#id", no CSS @-rule or backslash escape, a UTF-8
// document of bounded depth and size.
bool svgIsSelfContained(const QByteArray &data);

// Decodes the bytes of an icon file by the rules above.
QImage decode(const QByteArray &data, const QSize &want);

// readIconFile + decode.
QImage load(const QString &path, const QStringList &roots, const QSize &want);

} // namespace AppIcons
