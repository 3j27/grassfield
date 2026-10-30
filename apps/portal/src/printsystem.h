// The printers of the session and their jobs (ADR-0035 D-7, step 6a; docs/specs/system-dialogs.md section 7, PR1, PR2, PR5),
// behind a seam the tests replace. CupsPrintSystem asks CUPS (libcups 2.4: cupsEnumDests, cupsConnectDest, cupsCopyDestInfo,
// cupsCreateDestJob, cupsStartDestDocument, cupsFinishDestDocument): every call runs on a thread of its own with a deadline and a
// cancel flag libcups reads, and answers on the caller's thread, so a printer on the network that does not answer never holds the
// sheet (PR5). Printer setup is not here: Settings > Printers adds printers (PR #8).
#pragma once

#include "printlogic.h"

#include <QHash>
#include <QList>
#include <QMutex>
#include <QObject>
#include <QPair>
#include <QPointer>
#include <QString>

#include <atomic>
#include <functional>
#include <memory>

class QThread;

namespace grassfield::portal {

class PrintSystem : public QObject
{
    Q_OBJECT

public:
    using Options = QList<QPair<QString, QString>>;
    // `ok` false: CUPS did not answer (no scheduler, or the deadline); the list is then empty.
    using DestinationsDone = std::function<void(const QList<print::Destination> &destinations, bool ok)>;
    using CapabilitiesDone = std::function<void(const print::Capabilities &capabilities)>;
    // "" when the job went to the printer's queue; else why it did not.
    using JobDone = std::function<void(const QString &error)>;

    using QObject::QObject;

    // Each answers once, on the caller's thread, unless `context` has gone by then.
    virtual void destinations(QObject *context, DestinationsDone done) = 0;
    // `known` false when the printer did not say in time.
    virtual void capabilities(const QString &printer, QObject *context, CapabilitiesDone done) = 0;
    // Sends what `fd` holds (taken: closed when done) to `printer` as one job named `title`, with `options`.
    virtual void submit(const QString &printer, const QString &title, const Options &options, int fd, QObject *context, JobDone done) = 0;
};

class CupsPrintSystem : public PrintSystem
{
    Q_OBJECT

public:
    struct Limits {
        // Looking for printers (local queues at once; others found on the network within this).
        int listMs = 3000;
        // Reaching a printer and reading what it supports.
        int capabilitiesMs = 8000;
        // Reaching a printer to send a job, and any wait while sending it (the document, the printer's answers).
        int connectMs = 10000;
        int idleMs = 30000;
        // The largest document a job takes.
        qint64 maxDocumentBytes = print::kMaxDocumentBytes;
    };

    explicit CupsPrintSystem(QObject *parent = nullptr);
    CupsPrintSystem(const Limits &limits, QObject *parent);
    // Cancels the calls still running and waits for them a short while (they read the cancel flag and their deadlines bound
    // the rest); a call still inside libcups after that is left to end on its own, its answer dropped.
    ~CupsPrintSystem() override;

    void destinations(QObject *context, DestinationsDone done) override;
    void capabilities(const QString &printer, QObject *context, CapabilitiesDone done) override;
    void submit(const QString &printer, const QString &title, const Options &options, int fd, QObject *context, JobDone done) override;

private:
    struct Call;
    // Runs `work` on a thread; `deliver` on this thread with its result, unless the deadline (ms; 0: none) came first, in which
    // case `timeout` runs instead. Both see the call's state.
    void run(int deadlineMs, std::function<void(Call &)> work, std::function<void(Call &)> deliver, std::function<void()> timeout);

    Limits m_limits;
    QList<std::shared_ptr<Call>> m_calls;
};

// Writes what `fd` holds (taken: closed when done) as `name` in `folder` (Save as PDF): only a PDF ("%PDF-" first), at most
// maxBytes. `folder` is the folder as the Save panel's answer named it, its links resolved then; it is opened from "/" one folder
// at a time without following a link, the document goes to a temporary file made there (O_EXCL, O_NOFOLLOW), synced, then renamed
// over `name`: a link put at the name is replaced, never followed, and a link put in place of a folder fails the write (integrator
// security review of step 6a, MAJOR 1). Never half a document; a source silent for idleMs fails; a regular file there keeps its
// permissions. "" on success, else why. Blocking: run it off the GUI thread.
QString writePdf(int fd, const QString &folder, const QString &name, int idleMs, qint64 maxBytes = print::kMaxDocumentBytes);

} // namespace grassfield::portal
