#include "print.h"

#include "chooserlogic.h"
#include "printsystem.h"

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QRandomGenerator>
#include <QThread>

#include <KIO/CommandLauncherJob>

#include <fcntl.h>
#include <unistd.h>

#include <algorithm>
#include <limits>
#include <memory>

namespace grassfield::portal {

namespace {

constexpr int kMaxTickets = 64;

// A vardict as the frontend passes it, or as x-d-p-gtk answers it: a nested a{sv} is a QDBusArgument until read.
QVariantMap mapOf(const QVariant &value)
{
    if (value.metaType() == QMetaType::fromType<QDBusArgument>())
        return qdbus_cast<QVariantMap>(value.value<QDBusArgument>());
    if (value.metaType() == QMetaType::fromType<QVariantMap>())
        return value.toMap();
    return {};
}

// GTK's settings are strings; its page setup strings and doubles: anything else is dropped on the way.
QVariantMap typed(const QVariantMap &map, bool doubles)
{
    QVariantMap out;
    for (auto it = map.cbegin(); it != map.cend() && out.size() < 128; ++it) {
        const QMetaType t = it.value().metaType();
        if (t == QMetaType::fromType<QString>() && it.key().size() <= 64)
            out.insert(it.key(), it.value().toString().left(4096));
        else if (doubles && t == QMetaType::fromType<double>() && it.key().size() <= 64)
            out.insert(it.key(), it.value().toDouble());
    }
    return out;
}

// A file name as given (one line, no folder), or "".
QString plainName(const QVariant &value)
{
    if (value.metaType() != QMetaType::fromType<QString>())
        return {};
    const QString name = chooser::oneLine(value.toString()).left(200);
    return name.contains(QLatin1Char('/')) || name == QLatin1String(".") || name == QLatin1String("..") ? QString() : name;
}

} // namespace

Print::Print(const QDBusConnection &bus, PrintSystem *system, const Options &options, QObject *parent)
    : RequestHost(bus, QStringLiteral("org.freedesktop.impl.portal.Print"),
                  Limits{options.gtkService, options.uiDeadlineMs, options.idleQuitMs, options.maxPending, false}, parent)
    , m_system(system)
    , m_options(options)
{
}

Print::~Print()
{
    for (QThread *writer : findChildren<QThread *>(Qt::FindDirectChildrenOnly)) {
        if (!writer->wait(3500))
            writer->setParent(nullptr); // never destroyed while it runs
    }
}

QVariantMap Print::toQml(const QString &appId, const QString &parentWindow, const QString &title, const QVariantMap &settings,
                         const QVariantMap &pageSetup, const QVariantMap &options)
{
    const QVariantMap o = print::prepareOptions(options);
    const bool current = o.value(QStringLiteral("hasCurrentPage")).toBool();
    const bool selection = o.value(QStringLiteral("hasSelection")).toBool();
    const print::Choices choices = print::initialChoices({}, {}, typed(settings, false), typed(pageSetup, true), current, selection);
    return {
        {QStringLiteral("appId"), appId},
        {QStringLiteral("title"), chooser::oneLine(title)},
        {QStringLiteral("modal"), o.value(QStringLiteral("modal"))},
        {QStringLiteral("parented"), !parentWindow.isEmpty()},
        {QStringLiteral("acceptLabel"), o.value(QStringLiteral("acceptLabel"))},
        {QStringLiteral("hasCurrentPage"), current},
        {QStringLiteral("hasSelection"), selection},
        {QStringLiteral("canSavePdf"), o.value(QStringLiteral("formats")).toStringList().contains(QStringLiteral("pdf"))},
        {QStringLiteral("outputBasename"), plainName(settings.value(QStringLiteral("output-basename")))},
        {QStringLiteral("choices"), print::toQml(choices)},
    };
}

void Print::handlePrepare(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                          const QVariantMap &settings, const QVariantMap &pageSetup, const QVariantMap &options, const QDBusMessage &message)
{
    message.setDelayedReply(true);
    const int id = begin(handle, message, appId, parentWindow);
    if (id == 0)
        return;
    const QVariantMap sheet = toQml(appId, parentWindow, title, settings, pageSetup, options);
    Pending p;
    p.appId = appId;
    p.parentWindow = parentWindow;
    p.title = sheet.value(QStringLiteral("title")).toString();
    p.settings = typed(settings, false);
    p.pageSetup = typed(pageSetup, true);
    p.hasCurrentPage = sheet.value(QStringLiteral("hasCurrentPage")).toBool();
    p.hasSelection = sheet.value(QStringLiteral("hasSelection")).toBool();
    p.canSavePdf = sheet.value(QStringLiteral("canSavePdf")).toBool();
    p.choices = print::fromQml(sheet.value(QStringLiteral("choices")).toMap(), print::Choices{});
    m_pending.insert(id, p);
    if (!startUi(id))
        return;
    emit opened(id, sheet);
    listPrinters(id);
}

void Print::listPrinters(int id)
{
    if (!m_pending.contains(id) || !isOpen(id) || !m_system)
        return;
    m_system->destinations(this, [this, id](const QList<print::Destination> &found, bool ok) {
        const auto it = m_pending.find(id);
        if (it == m_pending.end() || !isOpen(id))
            return;
        QList<print::Destination> list = found;
        // The default first, then by name.
        std::stable_sort(list.begin(), list.end(), [](const print::Destination &a, const print::Destination &b) {
            if (a.isDefault != b.isDefault)
                return a.isDefault;
            return a.displayName.localeAwareCompare(b.displayName) < 0;
        });
        QVariantList printers;
        QString current;
        const QString asked = it->settings.value(QStringLiteral("printer")).toString();
        for (const print::Destination &d : std::as_const(list)) {
            printers.append(print::toQml(d));
            // The one the application last printed with (its settings' "printer"), else the default, else the first.
            if (d.name == asked)
                current = d.name;
        }
        if (current.isEmpty() && !list.isEmpty())
            current = list.first().name;
        if (!it->printer.isEmpty() && std::any_of(list.cbegin(), list.cend(), [&](const print::Destination &d) { return d.name == it->printer; }))
            current = it->printer;
        emit printersListed(id, printers, current, ok);
        if (!current.isEmpty() && (current != it->printer || !it->capabilities.known))
            choosePrinter(id, current, print::toQml(it->choices));
    });
}

void Print::choosePrinter(int id, const QString &printer, const QVariantMap &choices)
{
    const auto it = m_pending.find(id);
    if (it == m_pending.end() || !isOpen(id) || !m_system)
        return;
    it->choices = print::fromQml(choices, it->choices);
    it->printer = printer;
    it->capabilities = {};
    m_system->capabilities(printer, this, [this, id, printer](const print::Capabilities &caps) {
        const auto p = m_pending.find(id);
        // Another printer chosen meanwhile: its own answer comes.
        if (p == m_pending.end() || !isOpen(id) || p->printer != printer)
            return;
        p->capabilities = caps;
        // The choices made so far, as the new printer takes them (its paper, two sides and colour where it has them).
        print::Choices current = p->choices;
        current.printer = printer;
        current.outputUri.clear();
        // Pages being typed may not read yet: they are carried as typed, apart from the rest.
        print::Choices rest = current;
        if (rest.pages == QLatin1String("ranges"))
            rest.pages = QStringLiteral("all");
        QVariantMap settings, pageSetup;
        print::Choices carried = print::toGtk(rest, &settings, &pageSetup)
            ? print::initialChoices(printer, caps, settings, pageSetup, p->hasCurrentPage, p->hasSelection)
            : print::initialChoices(printer, caps, p->settings, p->pageSetup, p->hasCurrentPage, p->hasSelection);
        if (current.pages == QLatin1String("ranges")) {
            carried.pages = current.pages;
            carried.ranges = current.ranges;
        }
        p->choices = carried;
        emit printerChosen(id, printer, print::toQml(caps), print::toQml(carried));
    });
}

QString Print::tidyRanges(const QString &ranges) const
{
    QList<print::PageRange> parsed;
    return print::parseRanges(ranges, &parsed) ? print::shownRanges(parsed) : QString();
}

bool Print::answer(int id, int response, const QVariantMap &choices)
{
    const auto it = m_pending.find(id);
    if (it == m_pending.end() || !isOpen(id))
        return true;
    if (response != 0) {
        finish(id, 1, {});
        return true;
    }
    print::Choices c = print::fromQml(choices, it->choices);
    if (!c.outputUri.isEmpty()) {
        // Save as PDF: only when the application can make a PDF; no printer.
        if (!it->canSavePdf)
            return false;
        c.printer.clear();
    } else if (c.printer.isEmpty() || c.printer != it->printer) {
        // To print, the printer the sheet chose (choosePrinter) and whose options it read.
        return false;
    }
    QVariantMap settings, pageSetup;
    if (!print::toGtk(c, &settings, &pageSetup))
        return false;
    Ticket t;
    t.appId = it->appId;
    t.printer = c.printer;
    t.capabilities = it->capabilities;
    t.choices = c;
    const uint token = issue(t);
    finish(id, 0, {{QStringLiteral("settings"), settings}, {QStringLiteral("page-setup"), pageSetup}, {QStringLiteral("token"), QVariant::fromValue(token)}});
    return true;
}

void Print::addPrinter()
{
    if (m_options.addPrinterCommand.isEmpty())
        return;
    auto *job = new KIO::CommandLauncherJob(m_options.addPrinterCommand.first(), m_options.addPrinterCommand.mid(1), this);
    job->setDesktopName(QStringLiteral("org.grassfield.Settings"));
    connect(job, &KJob::result, this, [job] {
        if (job->error())
            qWarning("grassfield-portal: cannot open Settings > Printers: %s", qPrintable(job->errorString()));
    });
    job->start();
}

void Print::savePdf(int id, const QString &name, const QString &title)
{
    const auto it = m_pending.find(id);
    if (it == m_pending.end() || !isOpen(id) || !it->canSavePdf || m_saving.contains(id) || !m_panelBus || !m_panelBus->isConnected()) {
        emit pdfCancelled(id);
        return;
    }
    QString file = plainName(name);
    if (file.isEmpty())
        file = QStringLiteral("Document");
    if (!file.endsWith(QLatin1String(".pdf"), Qt::CaseInsensitive))
        file += QStringLiteral(".pdf");
    const QString handle = QStringLiteral("/org/freedesktop/portal/desktop/request/grassfield/print%1_%2").arg(id).arg(++m_saves);
    // This process's FileChooser, through the bus (its unique name: never another backend's), from the second connection: the
    // Open and Save panels' own path.
    QDBusMessage call = QDBusMessage::createMethodCall(m_bus.baseService(), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                       QStringLiteral("org.freedesktop.impl.portal.FileChooser"), QStringLiteral("SaveFile"));
    call << QVariant::fromValue(QDBusObjectPath(handle)) << it->appId << it->parentWindow << chooser::oneLine(title)
         << QVariantMap{{QStringLiteral("current_name"), file}, {QStringLiteral("modal"), true}};
    m_saving.insert(id, handle);
    auto *watcher = new QDBusPendingCallWatcher(m_panelBus->asyncCall(call, std::numeric_limits<int>::max()), this);
    connect(watcher, &QDBusPendingCallWatcher::finished, this, [this, id, handle](QDBusPendingCallWatcher *w) {
        w->deleteLater();
        if (m_saving.value(id) != handle)
            return;
        m_saving.remove(id);
        if (!m_pending.contains(id) || !isOpen(id))
            return;
        const QDBusMessage reply = w->reply();
        QString uri;
        if (reply.type() == QDBusMessage::ReplyMessage && reply.signature() == QLatin1String("ua{sv}")
            && reply.arguments().at(0).toUInt() == 0) {
            const QStringList uris = mapOf(reply.arguments().at(1)).value(QStringLiteral("uris")).toStringList();
            if (uris.size() == 1 && !print::localPdfPath(uris.first()).isEmpty())
                uri = uris.first();
        }
        if (uri.isEmpty())
            emit pdfCancelled(id);
        else
            emit pdfChosen(id, uri);
    });
}

uint Print::issue(const Ticket &ticket)
{
    dropExpired();
    // The oldest go first when an application keeps asking without printing.
    while (m_tickets.size() >= kMaxTickets) {
        auto oldest = m_tickets.begin();
        for (auto it = m_tickets.begin(); it != m_tickets.end(); ++it)
            if (it->age.elapsed() > oldest->age.elapsed())
                oldest = it;
        m_tickets.erase(oldest);
    }
    uint token = 0;
    do {
        token = QRandomGenerator::system()->generate();
    } while (token == 0 || m_tickets.contains(token));
    Ticket t = ticket;
    t.age.start();
    m_tickets.insert(token, t);
    return token;
}

void Print::dropExpired()
{
    for (auto it = m_tickets.begin(); it != m_tickets.end();)
        it = it->age.elapsed() > m_options.tokenLifetimeMs ? m_tickets.erase(it) : std::next(it);
}

void Print::handlePrint(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                        const QDBusUnixFileDescriptor &fd, const QVariantMap &options, const QDBusMessage &message)
{
    message.setDelayedReply(true);
    const int id = begin(handle, message, appId, parentWindow);
    if (id == 0)
        return;
    dropExpired();
    const QVariant given = options.value(QStringLiteral("token"));
    const uint token = given.metaType() == QMetaType::fromType<uint>() ? given.toUInt() : 0;
    const auto it = m_tickets.find(token);
    if (token == 0 || it == m_tickets.end() || it->appId != appId) {
        // No sheet of ours before it (x-d-p-gtk's token, or none): x-d-p-gtk prints it, with its own dialog if it must ask.
        forward(id);
        return;
    }
    const Ticket t = it.value();
    m_tickets.erase(it);
    const int document = fd.isValid() ? ::fcntl(fd.fileDescriptor(), F_DUPFD_CLOEXEC, 3) : -1;
    if (document < 0) {
        qWarning("grassfield-portal: Print came without a readable document");
        finish(id, 2, {});
        return;
    }
    printWithTicket(id, t, chooser::oneLine(title), document);
}

void Print::printWithTicket(int id, const Ticket &ticket, const QString &title, int fd)
{
    if (!ticket.choices.outputUri.isEmpty()) {
        const QString path = print::localPdfPath(ticket.choices.outputUri);
        if (path.isEmpty()) {
            ::close(fd);
            finish(id, 2, {});
            return;
        }
        auto error = std::make_shared<QString>();
        const int idle = m_options.fileIdleMs;
        QThread *writer = QThread::create([fd, path, idle, error] { *error = writePdf(fd, path, idle); });
        writer->setParent(this);
        connect(writer, &QThread::finished, this, [this, id, writer, error] {
            writer->deleteLater();
            if (!error->isEmpty())
                qWarning("grassfield-portal: Save as PDF: %s", qPrintable(*error));
            finish(id, error->isEmpty() ? 0 : 2, {});
        });
        writer->start();
        return;
    }
    if (!m_system) {
        ::close(fd);
        finish(id, 2, {});
        return;
    }
    const QString name = title.isEmpty() ? QStringLiteral("Document") : title;
    m_system->submit(ticket.printer, name, print::cupsOptions(ticket.choices, ticket.capabilities), fd, this, [this, id](const QString &error) {
        if (!error.isEmpty())
            qWarning("grassfield-portal: the print job did not go: %s", qPrintable(error));
        finish(id, error.isEmpty() ? 0 : 2, {});
    });
}

void Print::ended(int id)
{
    m_pending.remove(id);
    // Its Save panel goes too (the application closed the request meanwhile).
    const QString saving = m_saving.take(id);
    if (!saving.isEmpty() && m_panelBus)
        m_panelBus->asyncCall(QDBusMessage::createMethodCall(m_bus.baseService(), saving, QStringLiteral("org.freedesktop.impl.portal.Request"),
                                                             QStringLiteral("Close")));
}

QVariantMap Print::relayed(const QVariantMap &gtkResults) const
{
    // The interface's results: GTK's settings (strings), page setup (strings and doubles) and token (u).
    QVariantMap out;
    if (gtkResults.contains(QStringLiteral("settings")))
        out.insert(QStringLiteral("settings"), typed(mapOf(gtkResults.value(QStringLiteral("settings"))), false));
    if (gtkResults.contains(QStringLiteral("page-setup")))
        out.insert(QStringLiteral("page-setup"), typed(mapOf(gtkResults.value(QStringLiteral("page-setup"))), true));
    const QVariant token = gtkResults.value(QStringLiteral("token"));
    if (token.metaType() == QMetaType::fromType<uint>())
        out.insert(QStringLiteral("token"), token);
    return out;
}

PrintAdaptor::PrintAdaptor(QObject *exported, grassfield::portal::Print *print)
    : QDBusAbstractAdaptor(exported)
    , m_print(print)
{
}

uint PrintAdaptor::PreparePrint(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                                const QVariantMap &settings, const QVariantMap &page_setup, const QVariantMap &options,
                                const QDBusMessage &message, QVariantMap &results)
{
    Q_UNUSED(results)
    m_print->handlePrepare(handle, app_id, parent_window, title, settings, page_setup, options, message);
    return 2;
}

uint PrintAdaptor::Print(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                         const QDBusUnixFileDescriptor &fd, const QVariantMap &options, const QDBusMessage &message, QVariantMap &results)
{
    Q_UNUSED(results)
    m_print->handlePrint(handle, app_id, parent_window, title, fd, options, message);
    return 2;
}

} // namespace grassfield::portal
