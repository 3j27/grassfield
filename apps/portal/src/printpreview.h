// The document an application sends with no sheet before it (org.freedesktop.impl.portal.Print's Print with no token; ADR-0035
// D-7, step 6b; docs/specs/system-dialogs.md section 7, PR2): kept in a private file of grassfield-portal's while the sheet is up,
// and shown in the sheet's preview, page by page.
//
// The document comes from the application, a sandboxed one too, and grassfield-portal runs as the user without a sandbox: it never
// reads the PDF itself. Each page is drawn by a child process of its own (this binary, "--print-preview"; Qt PDF, the pdfium that
// Preview uses), which reads the private file on its standard input (descriptor 0, never a path) and answers the page's pixels on
// its standard output. The child (ADR-0035 6-10, as the security review of step 6b required it, 6-20 to 6-22):
// - starts in a session of its own (setsid: no terminal), with an allow-listed environment (no bus address, display or the
//   user's variables), no descriptor but its three, at most 512 MiB of data, 10 s of CPU, the OOM killer's first choice, a
//   deadline, killed with its parent; one child at a time for the whole process;
// - before it reads a byte of the document, restricts itself with Landlock to reading files and folders under /usr (the fonts;
//   no file of the user's, no /proc, no /dev/tty; no write anywhere; no TCP; signals and abstract sockets scoped to itself where
//   the kernel has ABI 6), then installs a seccomp allow-list measured on what Qt PDF calls (anything else fails: no socket, no
//   program, no fork, a thread only, no ioctl, no lock, no inotify, a signal or a resource limit only for itself);
// - draws nothing when either cannot be installed (an older kernel, another architecture): the sheet says "No Preview" and the
//   document still prints.
// grassfield-portal then reads only a header and raw pixels (no image decoder runs on what the child answers).
#pragma once

#include <QImage>
#include <QQuickImageProvider>
#include <QSizeF>
#include <QString>
#include <QStringList>

#include <atomic>
#include <functional>
#include <memory>

namespace grassfield::portal {

// What the documents kept at once may take together, across every request (ADR-0035 6-21): a document that would go over it
// is not kept (its print fails). Thread-safe.
class SpoolBudget
{
public:
    explicit SpoolBudget(qint64 total)
        : m_total(total)
    {
    }
    // Takes `bytes` when they fit, else nothing (false).
    bool take(qint64 bytes);
    void give(qint64 bytes);
    qint64 used() const { return m_used.load(); }

private:
    const qint64 m_total;
    std::atomic<qint64> m_used{0};
};

// How a document is read (spoolDocument): `stopped` ends it (asked at least every 200 ms); `mayConsume` is asked once before
// the first byte of a pipe is read (its bytes then cannot go on to x-d-p-gtk; false: nothing is read); `budget` is the budget
// shared by every document kept at once (none: maxBytes alone).
struct SpoolHooks {
    std::function<bool()> stopped;
    std::function<bool()> mayConsume;
    std::shared_ptr<SpoolBudget> budget;
};

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
    // What it took of the budget (the owner gives it back when the file goes).
    qint64 reserved = 0;
};

// Reads the document at `fd` (taken: closed when done) into an unlinked file of its own in `folder` (O_TMPFILE, mode 0600; the
// folder made 0700 when missing): only a PDF, at most maxBytes and what the budget has left; a source silent for idleMs ends it.
// A file is read from where its descriptor stands (what x-d-p-gtk would read), its position untouched. Blocking: run it off the
// GUI thread.
Spooled spoolDocument(int fd, const QString &folder, int idleMs, qint64 maxBytes, const SpoolHooks &hooks = {});
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

// The Landlock domain and the seccomp allow-list the child installs before it reads the document (see above): true when both
// are installed, false (and the child draws nothing) when either cannot be. Exposed for the tests.
bool confineRenderer();
// The environment the child gets: only the locale's variables (and a sanitizer build's options). Exposed for the tests.
QStringList rendererEnvironment();

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
