#include "printsystem.h"

#include <QDeadlineTimer>
#include <QFileInfo>
#include <QSaveFile>
#include <QThread>
#include <QTimer>

#include <cups/cups.h>

#include <poll.h>
#include <unistd.h>

#include <algorithm>
#include <cerrno>

namespace grassfield::portal {

using print::Capabilities;
using print::Destination;
using print::Media;

struct CupsPrintSystem::Call {
    // Set by the deadline or the destructor; libcups reads it (cupsEnumDests, cupsConnectDest) and the workers between steps.
    // A plain int, as libcups' API takes it: written once (0 to 1) on the GUI thread and only read elsewhere; a worker that
    // reads it late does one more step, bounded by its own limits.
    int cancel = 0;
    std::atomic<bool> answered{false};
    QThread *thread = nullptr;
    QList<Destination> destinations;
    bool ok = false;
    Capabilities capabilities;
    QString error;
};

namespace {

QString fromUtf8(const char *s)
{
    return s ? QString::fromUtf8(s) : QString();
}

// The destination named `name`, from the scheduler and the printers it knows (a copy the caller frees), or null.
cups_dest_t *findDestination(const QString &name, int msec, int *cancel)
{
    struct Found {
        QByteArray name;
        cups_dest_t *dest = nullptr;
        int count = 0;
    } found{name.toUtf8(), nullptr, 0};
    cupsEnumDests(
        CUPS_DEST_FLAGS_NONE, msec, cancel, 0, 0,
        [](void *data, unsigned flags, cups_dest_t *dest) -> int {
            auto *f = static_cast<Found *>(data);
            if (flags & CUPS_DEST_FLAGS_REMOVED)
                return 1;
            if (!dest->instance && f->name == dest->name) {
                f->count = cupsCopyDest(dest, f->count, &f->dest);
                return 0; // found: stop
            }
            return 1;
        },
        &found);
    return found.dest;
}

// Stops a request that waits longer than its limit (httpSetTimeout's callback: 0 stops).
int stopWaiting(http_t *, void *)
{
    return 0;
}

Media mediaOf(http_t *http, cups_dest_t *dest, cups_dinfo_t *info, cups_size_t &size)
{
    Media m;
    m.name = fromUtf8(size.media);
    m.displayName = fromUtf8(cupsLocalizeDestMedia(http, dest, info, CUPS_MEDIA_FLAGS_DEFAULT, &size));
    if (m.displayName.isEmpty() || m.displayName == m.name)
        m.displayName = print::mediaDisplayName(m.name);
    m.widthMm = size.width / 100.0;
    m.heightMm = size.length / 100.0;
    m.topMm = size.top / 100.0;
    m.bottomMm = size.bottom / 100.0;
    m.leftMm = size.left / 100.0;
    m.rightMm = size.right / 100.0;
    return m;
}

} // namespace

CupsPrintSystem::CupsPrintSystem(QObject *parent)
    : CupsPrintSystem(Limits{}, parent)
{
}

CupsPrintSystem::CupsPrintSystem(const Limits &limits, QObject *parent)
    : PrintSystem(parent)
    , m_limits(limits)
{
}

CupsPrintSystem::~CupsPrintSystem()
{
    for (const auto &call : std::as_const(m_calls))
        call->cancel = 1;
    QDeadlineTimer deadline(3500);
    for (const auto &call : std::as_const(m_calls)) {
        if (call->thread && !call->thread->wait(deadline)) {
            // Still inside libcups: it ends on its own (its limits bound it); its QThread is left, never destroyed running.
            call->thread->setParent(nullptr);
            call->thread = nullptr;
        }
    }
}

void CupsPrintSystem::run(int deadlineMs, std::function<void(Call &)> work, std::function<void(Call &)> deliver,
                          std::function<void()> timeout)
{
    auto call = std::make_shared<Call>();
    // The worker holds the call (its result and cancel flag) as long as it runs, whatever happens to this object.
    call->thread = QThread::create([call, work] { work(*call); });
    call->thread->setParent(this);
    m_calls.append(call);
    connect(call->thread, &QThread::finished, this, [this, call, deliver] {
        m_calls.removeOne(call);
        if (call->thread) {
            call->thread->deleteLater();
            call->thread = nullptr;
        }
        if (!call->answered.exchange(true))
            deliver(*call);
    });
    if (deadlineMs > 0) {
        QTimer::singleShot(deadlineMs, this, [call, timeout] {
            call->cancel = 1;
            if (!call->answered.exchange(true))
                timeout();
        });
    }
    call->thread->start();
}

void CupsPrintSystem::destinations(QObject *context, DestinationsDone done)
{
    const QPointer<QObject> guard(context);
    const int msec = m_limits.listMs;
    run(
        msec + 2000,
        [msec](Call &call) {
            struct List {
                QList<Destination> out;
            } list;
            // Local queues come at once; a printer CUPS finds on the network within msec.
            const int ok = cupsEnumDests(
                CUPS_DEST_FLAGS_NONE, msec, &call.cancel, 0, 0,
                [](void *data, unsigned flags, cups_dest_t *dest) -> int {
                    auto *l = static_cast<List *>(data);
                    if (dest->instance)
                        return 1; // lpoptions' instances are one printer's settings, not printers
                    const QString name = fromUtf8(dest->name);
                    for (qsizetype i = 0; i < l->out.size(); ++i) {
                        if (l->out.at(i).name == name) {
                            if (flags & CUPS_DEST_FLAGS_REMOVED)
                                l->out.removeAt(i);
                            return 1;
                        }
                    }
                    if (flags & CUPS_DEST_FLAGS_REMOVED)
                        return 1;
                    Destination d;
                    d.name = name;
                    d.displayName = fromUtf8(cupsGetOption("printer-info", dest->num_options, dest->options)).simplified();
                    if (d.displayName.isEmpty())
                        d.displayName = name;
                    d.location = fromUtf8(cupsGetOption("printer-location", dest->num_options, dest->options)).simplified();
                    d.isDefault = dest->is_default != 0;
                    l->out.append(d);
                    return l->out.size() < 256 ? 1 : 0;
                },
                &list);
            call.destinations = list.out;
            call.ok = ok != 0 || !list.out.isEmpty();
        },
        [guard, done](Call &call) {
            if (guard)
                done(call.destinations, call.ok);
        },
        [guard, done] {
            if (guard)
                done({}, false);
        });
}

void CupsPrintSystem::capabilities(const QString &printer, QObject *context, CapabilitiesDone done)
{
    const QPointer<QObject> guard(context);
    const int msec = m_limits.capabilitiesMs;
    run(
        msec + 2000,
        [printer, msec](Call &call) {
            cups_dest_t *dest = findDestination(printer, msec / 2, &call.cancel);
            if (!dest || call.cancel)
                return cupsFreeDests(dest ? 1 : 0, dest);
            char resource[1024] = {};
            http_t *http = cupsConnectDest(dest, CUPS_DEST_FLAGS_NONE, msec / 2, &call.cancel, resource, sizeof resource, nullptr, nullptr);
            if (!http) {
                cupsFreeDests(1, dest);
                return;
            }
            httpSetTimeout(http, msec / 1000.0, stopWaiting, nullptr);
            if (cups_dinfo_t *info = call.cancel ? nullptr : cupsCopyDestInfo(http, dest)) {
                Capabilities caps;
                const int count = cupsGetDestMediaCount(http, dest, info, CUPS_MEDIA_FLAGS_DEFAULT);
                for (int i = 0; i < count && i < 200 && !call.cancel; ++i) {
                    cups_size_t size;
                    if (cupsGetDestMediaByIndex(http, dest, info, i, CUPS_MEDIA_FLAGS_DEFAULT, &size) && size.width > 0 && size.length > 0) {
                        const Media m = mediaOf(http, dest, info, size);
                        if (!print::findMedia(caps.media, m.name).name.isEmpty())
                            continue;
                        caps.media.append(m);
                    }
                }
                // The user's own default for this printer (lpoptions), else the printer's (media-default): libcups 2.4's
                // cupsGetDestMediaDefault reads only the first and falls back to US Letter, whatever the printer says.
                if (const char *own = cupsGetOption(CUPS_MEDIA, dest->num_options, dest->options))
                    caps.defaultMedia = fromUtf8(own);
                if (caps.defaultMedia.isEmpty()) {
                    if (ipp_attribute_t *given = cupsFindDestDefault(http, dest, info, CUPS_MEDIA))
                        caps.defaultMedia = fromUtf8(ippGetString(given, 0, nullptr));
                }
                cups_size_t size;
                if (caps.defaultMedia.isEmpty() && cupsGetDestMediaDefault(http, dest, info, CUPS_MEDIA_FLAGS_DEFAULT, &size))
                    caps.defaultMedia = fromUtf8(size.media);
                caps.twoSided = cupsCheckDestSupported(http, dest, info, CUPS_SIDES, CUPS_SIDES_TWO_SIDED_PORTRAIT) != 0;
                caps.color = cupsCheckDestSupported(http, dest, info, CUPS_PRINT_COLOR_MODE, CUPS_PRINT_COLOR_MODE_COLOR) != 0;
                if (ipp_attribute_t *copies = cupsFindDestSupported(http, dest, info, CUPS_COPIES);
                    copies && ippGetValueTag(copies) == IPP_TAG_RANGE) {
                    int upper = 0;
                    ippGetRange(copies, 0, &upper);
                    caps.maxCopies = std::clamp(upper, 1, print::kMaxCopies);
                } else {
                    caps.maxCopies = 1;
                }
                caps.known = !call.cancel;
                call.capabilities = caps;
                cupsFreeDestInfo(info);
            }
            httpClose(http);
            cupsFreeDests(1, dest);
        },
        [guard, done](Call &call) {
            if (guard)
                done(call.capabilities);
        },
        [guard, done] {
            if (guard)
                done(Capabilities{});
        });
}

void CupsPrintSystem::submit(const QString &printer, const QString &title, const Options &options, int fd, QObject *context, JobDone done)
{
    const QPointer<QObject> guard(context);
    const Limits limits = m_limits;
    // No deadline over the whole job (a long document takes the time it takes): its steps have theirs (connectMs, idleMs).
    run(
        0,
        [printer, title, options, fd, limits](Call &call) {
            const auto fail = [&call](const QString &why) { call.error = why; };
            cups_dest_t *dest = findDestination(printer, limits.connectMs / 2, &call.cancel);
            if (!dest) {
                ::close(fd);
                return fail(QStringLiteral("the printer “%1” is not known to CUPS").arg(printer));
            }
            char resource[1024] = {};
            http_t *http = cupsConnectDest(dest, CUPS_DEST_FLAGS_NONE, limits.connectMs, &call.cancel, resource, sizeof resource, nullptr, nullptr);
            // The limit before the first request on the connection (a printer that takes the connection and never answers;
            // review of step 6a, MINOR 3).
            if (http)
                httpSetTimeout(http, limits.idleMs / 1000.0, stopWaiting, nullptr);
            cups_dinfo_t *info = http ? cupsCopyDestInfo(http, dest) : nullptr;
            if (!http || !info) {
                ::close(fd);
                if (http)
                    httpClose(http);
                cupsFreeDests(1, dest);
                return fail(QStringLiteral("cannot reach the printer: %1").arg(fromUtf8(cupsLastErrorString())));
            }
            int numOptions = 0;
            cups_option_t *cupsOptions = nullptr;
            for (const auto &o : options)
                numOptions = cupsAddOption(o.first.toUtf8().constData(), o.second.toUtf8().constData(), numOptions, &cupsOptions);
            const QByteArray name = title.left(255).toUtf8();
            int job = 0;
            const ipp_status_t created = cupsCreateDestJob(http, dest, info, &job, name.constData(), numOptions, cupsOptions);
            cupsFreeOptions(numOptions, cupsOptions);
            bool sent = false;
            if (created <= IPP_STATUS_OK_CONFLICTING && job > 0
                && cupsStartDestDocument(http, dest, info, job, name.constData(), CUPS_FORMAT_AUTO, 0, nullptr, 1) == HTTP_STATUS_CONTINUE) {
                char buffer[65536];
                bool reading = true;
                while (reading && !call.cancel) {
                    pollfd p{fd, POLLIN, 0};
                    const int ready = ::poll(&p, 1, limits.idleMs);
                    if (ready < 0 && errno == EINTR)
                        continue;
                    if (ready <= 0) {
                        call.error = QStringLiteral("the document stopped coming");
                        break;
                    }
                    const ssize_t n = ::read(fd, buffer, sizeof buffer);
                    if (n < 0 && errno == EINTR)
                        continue;
                    if (n < 0) {
                        call.error = QStringLiteral("cannot read the document");
                        break;
                    }
                    if (n == 0) {
                        reading = false;
                        break;
                    }
                    if (cupsWriteRequestData(http, buffer, size_t(n)) != HTTP_STATUS_CONTINUE) {
                        call.error = QStringLiteral("the printer stopped taking the document");
                        break;
                    }
                }
                const ipp_status_t finished = cupsFinishDestDocument(http, dest, info);
                sent = call.error.isEmpty() && !reading && finished <= IPP_STATUS_OK_CONFLICTING;
            }
            if (!sent) {
                if (call.error.isEmpty())
                    call.error = QStringLiteral("the printer refused the job: %1").arg(fromUtf8(cupsLastErrorString()));
                if (job > 0)
                    cupsCancelDestJob(http, dest, job);
            }
            ::close(fd);
            cupsFreeDestInfo(info);
            httpClose(http);
            cupsFreeDests(1, dest);
        },
        [guard, done](Call &call) {
            if (guard)
                done(call.error);
        },
        [] {});
}

QString writePdf(int fd, const QString &path, int idleMs)
{
    QSaveFile out(path);
    QString error;
    // The first bytes, until there are enough to tell a PDF ("%PDF-"); then everything goes straight to the file.
    QByteArray head;
    char buffer[65536];
    for (;;) {
        pollfd p{fd, POLLIN, 0};
        const int ready = ::poll(&p, 1, idleMs);
        if (ready < 0 && errno == EINTR)
            continue;
        if (ready <= 0) {
            error = QStringLiteral("the document stopped coming");
            break;
        }
        const ssize_t n = ::read(fd, buffer, sizeof buffer);
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0) {
            error = QStringLiteral("cannot read the document");
            break;
        }
        if (n == 0)
            break;
        if (!out.isOpen()) {
            head.append(buffer, qsizetype(n));
            if (head.size() < 5)
                continue;
            if (!head.startsWith("%PDF-")) {
                error = QStringLiteral("the document is not a PDF");
                break;
            }
            if (!out.open(QIODevice::WriteOnly) || out.write(head) != head.size()) {
                error = QStringLiteral("cannot write “%1”: %2").arg(path, out.errorString());
                break;
            }
            continue;
        }
        if (out.write(buffer, qint64(n)) != qint64(n)) {
            error = QStringLiteral("cannot write “%1”: %2").arg(path, out.errorString());
            break;
        }
    }
    ::close(fd);
    if (error.isEmpty() && !out.isOpen())
        error = QStringLiteral("the document is not a PDF");
    if (!error.isEmpty()) {
        if (out.isOpen())
            out.cancelWriting();
        return error;
    }
    if (!out.commit())
        return QStringLiteral("cannot write “%1”: %2").arg(path, out.errorString());
    return {};
}

} // namespace grassfield::portal
