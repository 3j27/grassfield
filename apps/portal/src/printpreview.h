// The document an application sends with no sheet before it (org.freedesktop.impl.portal.Print's Print with no token; ADR-0035
// D-7, step 6b; docs/specs/system-dialogs.md section 7, PR2): kept in a private file of grassfield-portal's while the sheet is up,
// and shown in the sheet's preview, page by page.
//
// The document comes from the application, a sandboxed one too, and grassfield-portal runs as the user without a sandbox: it never
// reads the PDF itself. Each page is drawn by a child process of its own (this binary, "--print-preview"; Qt PDF, the pdfium that
// Preview uses), which reads the private file on its standard input and answers the page's pixels on its standard output: no bus
// address, no display, no descriptor but those three, limits on memory and CPU time, a deadline, killed with its parent, and,
// before it reads a byte of the document, a seccomp filter that refuses it sockets, programs, a signal to any process but
// itself, and any change to a file (no write, create, truncate, rename, link, removal or mode change; no io_uring, ptrace or
// namespaces). grassfield-portal then reads only a header and raw pixels (no image decoder runs on what the child answers).
#pragma once

#include <QImage>
#include <QQuickImageProvider>
#include <QSizeF>
#include <QString>
#include <QStringList>

#include <functional>

namespace grassfield::portal {

// The document read into a private file (spoolDocument).
struct Spooled {
    // The private file (an unlinked file, read and written by this process only), -1 when there is none.
    int fd = -1;
    qint64 size = 0;
    // The document is not a PDF ("%PDF-" first): nothing was kept.
    bool notPdf = false;
    // The application's descriptor was read from its own position (a pipe): the document cannot be sent on as it came. A file is
    // read where it is (pread), its position untouched, so the call can still go to x-d-p-gtk.
    bool consumed = false;
    // Why it could not be read ("" when it was, or when it is not a PDF).
    QString error;
};

// Reads the document at `fd` (taken: closed when done) into an unlinked file of its own in `folder` (O_TMPFILE, mode 0600): only
// a PDF, at most maxBytes; a source silent for idleMs, or `stopped` saying so (asked at least every 200 ms), ends it. Blocking:
// run it off the GUI thread.
Spooled spoolDocument(int fd, const QString &folder, int idleMs, qint64 maxBytes, const std::function<bool()> &stopped = {});
// A new descriptor on the private file, read-only, from its start (its own position: several readers at once), -1 on failure.
int reopenSpool(int spoolFd);

// A page drawn by the child.
struct Rendered {
    bool ok = false;
    // The document's pages, and the size of the page asked, in points.
    int pages = 0;
    QSizeF pageSize;
    // The page fitted in the size asked, on white (null when no size was asked).
    QImage image;
};

// The largest side of a page drawn for the preview, in pixels.
constexpr int kMaxPreviewSide = 2048;

// Draws page `page` (0-based) of the private file `spoolFd` within `max` (an empty size: only the page count and that page's size)
// in a child process: `command` (this binary and "--print-preview", or a test's), its deadline `deadlineMs`; `stopped` ends it
// early. Blocking: run it off the GUI thread.
Rendered renderPreview(const QStringList &command, int spoolFd, int page, const QSize &max, int deadlineMs,
                       const std::function<bool()> &stopped = {});

// The child's side: "<binary> --print-preview <page> <width> <height>", the document on standard input.
bool isPreviewChildInvocation(int argc, char **argv);
int previewChildMain(int argc, char **argv);

// The seccomp filter the child installs before it reads the document (see above): true when installed. Exposed for the tests.
bool confineRenderer();

// The pages drawn, for the QML (image://printpreview/<key>), until Print removes them (their request ended).
class PreviewImages
{
public:
    static QString insert(const QImage &image);
    static QImage value(const QString &key);
    static void remove(const QString &key);
    static int size();
};

// image://printpreview/<key>: a page PreviewImages holds (no work here; the child drew it).
class PrintPreviewProvider : public QQuickImageProvider
{
public:
    PrintPreviewProvider();
    QImage requestImage(const QString &id, QSize *size, const QSize &requestedSize) override;
};

} // namespace grassfield::portal
