#pragma once

#include <QByteArray>
#include <QImage>
#include <QSize>
#include <QString>
#include <QStringList>

// Decoding of an application's absolute Icon= path (the desktop entry is not trusted: any user can plant one). The shell never
// decodes such a file itself (shell/services/image-copy.py re-encodes it out of process); Files has no helper, so it is
// stricter in what it decodes in its own process, and never on the GUI thread (AppIconProvider answers asynchronously, image://appicon):
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
constexpr int kMaxSvgElements = 5000;
constexpr int kMaxSvgUses = 64;                     // <use> can multiply: a chain of them is a CPU bomb

// True when the SVG document `data` refers to nothing outside itself and has no construct that does: no DTD or entity, no
// processing instruction, no script, foreignObject, animation of an href, no <image> or <feImage> at all (QtSvg opens even
// "#name" as a file relative to the working directory; a data: image is not bounded in pixels), no href other than "#id",
// no <use> of an element that contains a <use> (the copies would multiply), no xml:base, no CSS url() other than "#id", no CSS @-rule or backslash escape, a UTF-8
// document of bounded depth and size.
bool svgIsSelfContained(const QByteArray &data);

// Decodes the bytes of an icon file by the rules above.
QImage decode(const QByteArray &data, const QSize &want);

// readIconFile + decode, in this process. Only for tests and for the decoder child: Files itself uses loadIsolated.
QImage load(const QString &path, const QStringList &roots, const QSize &want);

// The decode a running Files uses: the checked bytes go to a child process of Files itself ("--decode-icon", decodeChildMain)
// that decodes them under an address-space and CPU limit and answers a PNG on stdout; the parent only ever decodes that PNG.
// A decode that has not ended after kDecodeDeadlineMs is killed (the icon falls back to the generic one, and the path is not
// tried again in this run), so a slow or hostile icon can neither starve the others nor outlive Files: shutdown() kills every
// child at quit and the child also dies with its parent (PDEATHSIG). Blocking: call it off the GUI thread. A null image for
// anything refused, too slow or failed.
QImage loadIsolated(const QString &path, const QStringList &roots, const QSize &want);
void shutdown();                 // quit: no new decode, every running child killed
// The function that stops the decodes at exit (imageproviders.cpp: AppIconProvider::shutdown). loadIsolated registers it with
// std::atexit again after its first starts: exit-time actions run in the reverse order of their registration, so a hook that
// was registered before Qt's process internals and the other statics a decode creates ran after they were destroyed, with a
// worker still inside them (a bad_alloc or a SIGSEGV in 1 exit of 100 on a loaded machine). Idempotent.
void setExitHook(void (*hook)());
bool isDecodeChildInvocation(int argc, char **argv);
int decodeChildMain(int argc, char **argv); // "--decode-icon <w> <h>": icon file bytes on stdin, PNG on stdout; 0 = ok, 1 = refused
// Tests: another program (and its arguments before <w> <h>) as the decoder, a shorter deadline. Empty program = the default.
void setDecoderForTests(const QString &program, const QStringList &arguments, int deadlineMs);
int runningDecodes();            // children running now (tests)

constexpr int kDecodeDeadlineMs = 3000;

} // namespace AppIcons
