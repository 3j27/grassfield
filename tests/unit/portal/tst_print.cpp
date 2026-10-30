// grassfield-portal's print sheet (ADR-0035 D-7, step 6a; docs/specs/system-dialogs.md section 7, PR1-PR5, A-PR1): what the
// sheet is given (Print::toQml), and org.freedesktop.impl.portal.Print on the run's private bus (tst_filechooser.cpp's main)
// with a fake frontend, a fake x-d-p-gtk and a fake print system: PreparePrint's answer with GTK's keys and a token, the job
// Print sends with that token (the CUPS options, the document), the token good once for its application, Save as PDF, Cancel,
// a printer that refuses, no printer, another printer chosen, and the forward to x-d-p-gtk.
#include <gtest/gtest.h>

#include "print.h"
#include "printsystem.h"

#include <QDBusAbstractAdaptor>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusUnixFileDescriptor>
#include <QDeadlineTimer>
#include <QDir>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QTemporaryDir>
#include <QTest>
#include <QTimer>
#include <QUrl>

#include <cups/cups.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <functional>
#include <limits>
#include <memory>
#include <utility>

using namespace grassfield::portal;

extern QString g_address;

namespace {

constexpr auto kService = "org.freedesktop.impl.portal.desktop.grassfield";
constexpr auto kFakeGtk = "org.test.fakegtk.print";
constexpr int kDeadlineMs = 1500;

print::Media media(const QString &name, double w, double h)
{
    print::Media m;
    m.name = name;
    m.displayName = print::mediaDisplayName(name);
    m.widthMm = w;
    m.heightMm = h;
    m.topMm = m.bottomMm = m.leftMm = m.rightMm = 3;
    return m;
}

// CUPS as the backend sees it: two printers (Office the default: colour, two sides; Mono: neither), answered on the next
// turn of the event loop; the jobs it gets, their documents read to the end.
class FakePrintSystem : public PrintSystem
{
    Q_OBJECT
public:
    struct Job {
        QString printer;
        QString title;
        Options options;
        QByteArray document;
    };
    QList<print::Destination> printers{{QStringLiteral("Office"), QStringLiteral("Office Printer"), QStringLiteral("Hall"), true},
                                       {QStringLiteral("Mono"), QStringLiteral("Mono Laser"), QString(), false}};
    bool listed = true;
    QString refuse;
    QList<Job> jobs;
    QStringList asked;

    static print::Capabilities caps(const QString &printer)
    {
        print::Capabilities c;
        c.known = true;
        c.media = {media(QStringLiteral("iso_a4_210x297mm"), 210, 297), media(QStringLiteral("iso_a5_148x210mm"), 148, 210)};
        c.defaultMedia = QStringLiteral("iso_a4_210x297mm");
        c.twoSided = printer == QLatin1String("Office");
        c.color = printer == QLatin1String("Office");
        c.maxCopies = 50;
        return c;
    }

    void destinations(QObject *context, DestinationsDone done) override
    {
        QTimer::singleShot(0, context, [this, done] { done(listed ? printers : QList<print::Destination>{}, listed); });
    }
    void capabilities(const QString &printer, QObject *context, CapabilitiesDone done) override
    {
        asked << printer;
        QTimer::singleShot(0, context, [printer, done] { done(caps(printer)); });
    }
    void submit(const QString &printer, const QString &title, const Options &options, int fd, QObject *context, JobDone done) override
    {
        Job job{printer, title, options, {}};
        char buffer[4096];
        ssize_t n;
        while ((n = ::read(fd, buffer, sizeof buffer)) > 0)
            job.document.append(buffer, n);
        ::close(fd);
        jobs << job;
        QTimer::singleShot(0, context, [this, done] { done(refuse); });
    }
};

// x-d-p-gtk's Print as the forward sees it: holds each call until the test answers it.
class FakeGtkPrint : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.Print")
public:
    QStringList calls;
    QDBusMessage held;

public Q_SLOTS:
    uint PreparePrint(const QDBusObjectPath &handle, const QString &, const QString &, const QString &, const QVariantMap &,
                      const QVariantMap &, const QVariantMap &, const QDBusMessage &message, QVariantMap &)
    {
        calls << QStringLiteral("PreparePrint %1").arg(handle.path());
        message.setDelayedReply(true);
        held = message;
        return 0;
    }
    uint Print(const QDBusObjectPath &handle, const QString &, const QString &, const QString &, const QDBusUnixFileDescriptor &fd,
               const QVariantMap &options, const QDBusMessage &message, QVariantMap &)
    {
        calls << QStringLiteral("Print %1 token %2 fd %3")
                     .arg(handle.path())
                     .arg(options.value(QStringLiteral("token")).toUInt())
                     .arg(fd.isValid() ? QStringLiteral("valid") : QStringLiteral("none"));
        message.setDelayedReply(true);
        held = message;
        return 0;
    }
};

// The process's own FileChooser as Save as PDF calls it (SaveFile on the backend's own connection): holds the call until the
// test answers it, and records Close.
// A request's Request object, as the real FileChooser exports one at the handle: records Close.
class FakeRequest : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.Request")
public:
    QStringList *closes = nullptr;
    QString handle;

public Q_SLOTS:
    Q_SCRIPTABLE void Close() { closes->append(handle); }
};

class FakeSaveFile : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.FileChooser")
public:
    FakeSaveFile(QObject *parent, QDBusConnection *bus)
        : QDBusAbstractAdaptor(parent)
        , m_bus(bus)
    {
    }
    QStringList calls;
    QStringList closes;
    QDBusMessage held;
    QList<std::shared_ptr<FakeRequest>> requests;

public Q_SLOTS:
    uint SaveFile(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                  const QVariantMap &options, const QDBusMessage &message, QVariantMap &)
    {
        calls << QStringLiteral("SaveFile %1 %2 %3 %4 %5")
                     .arg(handle.path().section(QLatin1Char('/'), 0, -2), appId, parentWindow, title,
                          options.value(QStringLiteral("current_name")).toString());
        auto request = std::make_shared<FakeRequest>();
        request->closes = &closes;
        request->handle = handle.path();
        m_bus->registerObject(handle.path(), request.get(), QDBusConnection::ExportScriptableSlots);
        requests << request;
        message.setDelayedReply(true);
        held = message;
        return 0;
    }

private:
    QDBusConnection *m_bus;
};

struct Reply {
    bool done = false;
    bool error = false;
    uint response = 99;
    QVariantMap results;
    // The sheet's answer was refused (savedAs).
    bool refused = false;
};

QVariantMap mapOf(const QVariant &v)
{
    return v.metaType() == QMetaType::fromType<QDBusArgument>() ? qdbus_cast<QVariantMap>(v.value<QDBusArgument>()) : v.toMap();
}

class PrintTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        static int n = 0;
        const QString suffix = QString::number(++n);
        backendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("print-backend") + suffix));
        frontendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("print-frontend") + suffix));
        gtkBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("print-gtk") + suffix));
        panelBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("print-panels") + suffix));
        ASSERT_TRUE(backendBus->isConnected() && frontendBus->isConnected() && gtkBus->isConnected() && panelBus->isConnected());
        ASSERT_TRUE(dir.isValid());
        make({});
        ASSERT_TRUE(gtkBus->registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), &gtk, QDBusConnection::ExportAllSlots));
        ASSERT_TRUE(gtkBus->registerService(QString::fromLatin1(kFakeGtk)));
    }

    void make(const std::function<void(Print::Options &)> &adjust)
    {
        if (printer) {
            backendBus->unregisterService(QString::fromLatin1(kService));
            backendBus->unregisterObject(QStringLiteral("/org/freedesktop/portal/desktop"));
            exported.reset();
            printer.reset();
        }
        Print::Options options;
        options.gtkService = QString::fromLatin1(kFakeGtk);
        options.uiDeadlineMs = kDeadlineMs;
        options.idleQuitMs = 200;
        options.fileIdleMs = 2000;
        if (adjust)
            adjust(options);
        printer = std::make_unique<Print>(*backendBus, &system, options);
        printer->setUiLoader([] { return true; });
        printer->setPanelBus(*panelBus);
        exported = std::make_unique<QObject>();
        new PrintAdaptor(exported.get(), printer.get());
        saveFile = new FakeSaveFile(exported.get(), backendBus.get());
        ASSERT_TRUE(backendBus->registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), exported.get(), QDBusConnection::ExportAdaptors));
        ASSERT_TRUE(backendBus->registerService(QString::fromLatin1(kService)));
        // No window is presented: each test ends its sheet well within the deadline (kDeadlineMs) that would send it to x-d-p-gtk.
        QObject::connect(printer.get(), &Print::opened, printer.get(), [this](int id, const QVariantMap &sheet) { opened.append({id, sheet}); });
        QObject::connect(printer.get(), &Print::printersListed, printer.get(),
                         [this](int id, const QVariantList &list, const QString &current, bool ok) { listed.append({id, list, current, ok}); });
        QObject::connect(printer.get(), &Print::printerChosen, printer.get(),
                         [this](int id, const QString &name, const QVariantMap &caps, const QVariantMap &choices) {
                             chosen.append({id, name, caps, choices});
                         });
        QObject::connect(printer.get(), &Print::closed, printer.get(), [this](int id) { closed.append(id); });
    }

    void TearDown() override
    {
        backendBus->unregisterService(QString::fromLatin1(kService));
        backendBus->unregisterObject(QStringLiteral("/org/freedesktop/portal/desktop"));
        gtkBus->unregisterService(QString::fromLatin1(kFakeGtk));
        printer.reset();
        exported.reset();
        QDBusConnection::disconnectFromBus(backendBus->name());
        QDBusConnection::disconnectFromBus(frontendBus->name());
        QDBusConnection::disconnectFromBus(gtkBus->name());
        QDBusConnection::disconnectFromBus(panelBus->name());
    }

    std::shared_ptr<Reply> send(QDBusMessage m)
    {
        auto reply = std::make_shared<Reply>();
        auto *w = new QDBusPendingCallWatcher(frontendBus->asyncCall(m, std::numeric_limits<int>::max()));
        QObject::connect(w, &QDBusPendingCallWatcher::finished, w, [reply](QDBusPendingCallWatcher *watcher) {
            watcher->deleteLater();
            const QDBusMessage r = watcher->reply();
            reply->done = true;
            reply->error = r.type() != QDBusMessage::ReplyMessage;
            if (!reply->error && r.arguments().size() == 2) {
                reply->response = r.arguments().at(0).toUInt();
                reply->results = qdbus_cast<QVariantMap>(r.arguments().at(1));
            }
        });
        return reply;
    }

    // The frontend's calls (src/print.c): PreparePrint and Print on the backend's name, no timeout.
    std::shared_ptr<Reply> prepare(const QString &handle, const QVariantMap &settings, const QVariantMap &pageSetup, const QVariantMap &options,
                                   const QString &appId = QStringLiteral("org.example.Writer"))
    {
        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.Print"), QStringLiteral("PreparePrint"));
        m << QVariant::fromValue(QDBusObjectPath(handle)) << appId << QStringLiteral("wayland:abc") << QStringLiteral("Print") << settings
          << pageSetup << options;
        return send(m);
    }

    std::shared_ptr<Reply> printDocument(const QString &handle, const QByteArray &document, const QVariantMap &options,
                                         const QString &appId = QStringLiteral("org.example.Writer"))
    {
        QFile file(dir.filePath(QStringLiteral("doc-%1").arg(++docs)));
        EXPECT_TRUE(file.open(QIODevice::WriteOnly));
        file.write(document);
        file.close();
        const int fd = ::open(QFile::encodeName(file.fileName()).constData(), O_RDONLY | O_CLOEXEC);
        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.Print"), QStringLiteral("Print"));
        m << QVariant::fromValue(QDBusObjectPath(handle)) << appId << QString() << QStringLiteral("Print")
          << QVariant::fromValue(QDBusUnixFileDescriptor(fd)) << options;
        ::close(fd);
        return send(m);
    }

    bool waitFor(const std::function<bool()> &condition, int ms = 3000)
    {
        QDeadlineTimer deadline(ms);
        while (!condition() && !deadline.hasExpired())
            QTest::qWait(10);
        return condition();
    }

    // PreparePrint to the sheet with Office's options read, then the sheet's answer; the reply.
    std::shared_ptr<Reply> preparedAnswer(const QString &handle, const QVariantMap &edit, const QVariantMap &settings = {},
                                          const QVariantMap &options = {})
    {
        const qsizetype before = chosen.size();
        auto reply = prepare(handle, settings, {}, options);
        EXPECT_TRUE(waitFor([&] { return chosen.size() > before; })) << "the default printer's options read";
        if (chosen.size() <= before)
            return reply;
        const auto &last = chosen.last();
        QVariantMap choices = last.choices;
        for (auto it = edit.cbegin(); it != edit.cend(); ++it)
            choices.insert(it.key(), it.value());
        EXPECT_TRUE(printer->answer(last.id, 0, choices));
        EXPECT_TRUE(waitFor([&] { return reply->done; }));
        return reply;
    }

    // Save as PDF… on sheet `id`, the Save panel (the fake) answering `path`: true once the sheet has its file.
    bool choosePdf(int id, const QString &path)
    {
        bool picked = false;
        const auto connection = QObject::connect(printer.get(), &Print::pdfChosen, printer.get(), [&picked, id](int which, const QString &) {
            picked = picked || which == id;
        });
        const qsizetype calls = saveFile->calls.size();
        printer->savePdf(id, QStringLiteral("Report"), QStringLiteral("Save as PDF"));
        const bool asked = waitFor([&] { return saveFile->calls.size() > calls; });
        if (asked)
            backendBus->send(saveFile->held.createReply(QVariantList{
                QVariant::fromValue(0u), QVariantMap{{QStringLiteral("uris"), QStringList{QUrl::fromLocalFile(path).toString()}}}}));
        const bool ok = asked && waitFor([&] { return picked; });
        QObject::disconnect(connection);
        return ok;
    }

    // PreparePrint answered with Save as PDF to `path` as the Save panel chose it, the sheet answering `answered` (the same file
    // unless given).
    std::shared_ptr<Reply> savedAs(const QString &handle, const QString &path, const QString &answered = {})
    {
        const qsizetype before = chosen.size();
        auto reply = prepare(handle, {}, {}, {});
        EXPECT_TRUE(waitFor([&] { return chosen.size() > before; }));
        if (chosen.size() <= before)
            return reply;
        const int id = chosen.last().id;
        EXPECT_TRUE(choosePdf(id, path));
        QVariantMap choices = chosen.last().choices;
        choices.insert(QStringLiteral("outputUri"), QUrl::fromLocalFile(answered.isEmpty() ? path : answered).toString());
        if (!printer->answer(id, 0, choices)) {
            reply->refused = true;
            printer->answer(id, 1);
        }
        EXPECT_TRUE(waitFor([&] { return reply->done; }));
        return reply;
    }

    std::shared_ptr<Reply> printWith(const QString &handle, const std::shared_ptr<Reply> &prepared, const QByteArray &document)
    {
        return printDocument(handle, document, {{QStringLiteral("token"), QVariant::fromValue(prepared->results.value("token").toUInt())}});
    }

    struct Listed {
        int id;
        QVariantList printers;
        QString current;
        bool ok;
    };
    struct Chosen {
        int id;
        QString printer;
        QVariantMap capabilities;
        QVariantMap choices;
    };

    std::unique_ptr<QDBusConnection> backendBus, frontendBus, gtkBus, panelBus;
    FakePrintSystem system;
    std::unique_ptr<Print> printer;
    std::unique_ptr<QObject> exported;
    FakeSaveFile *saveFile = nullptr;
    FakeGtkPrint gtk;
    QTemporaryDir dir;
    int docs = 0;
    QList<QPair<int, QVariantMap>> opened;
    QList<Listed> listed;
    QList<Chosen> chosen;
    QList<int> closed;
};

const QString kHandle = QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/print");

} // namespace

// What the sheet is given first: one-line title, the accept label without its mnemonic, the pages the application has, Save as
// PDF only when it can make a PDF, and the application's own settings as the first choices (the printer not known yet).
TEST(PrintToQml, WhatTheSheetIsGiven)
{
    const QVariantMap sheet = Print::toQml(QStringLiteral("org.example.Writer"), QStringLiteral("wayland:abc"), QStringLiteral("Print\nnow"),
                                           {{QStringLiteral("n-copies"), QStringLiteral("2")}},
                                           {{QStringLiteral("Name"), QStringLiteral("iso_a5_148x210mm")}, {QStringLiteral("Width"), 148.0},
                                            {QStringLiteral("Height"), 210.0}},
                                           {{QStringLiteral("accept_label"), QStringLiteral("_Print")}, {QStringLiteral("has_current_page"), true},
                                            {QStringLiteral("supported_output_file_formats"), QStringList{QStringLiteral("ps")}}});
    EXPECT_EQ(sheet.value("title").toString(), QStringLiteral("Print now"));
    EXPECT_EQ(sheet.value("acceptLabel").toString(), QStringLiteral("Print"));
    EXPECT_TRUE(sheet.value("parented").toBool());
    EXPECT_TRUE(sheet.value("modal").toBool());
    EXPECT_TRUE(sheet.value("hasCurrentPage").toBool());
    EXPECT_FALSE(sheet.value("hasSelection").toBool());
    EXPECT_FALSE(sheet.value("canSavePdf").toBool()) << "this application makes PostScript only";
    const QVariantMap choices = sheet.value("choices").toMap();
    EXPECT_EQ(choices.value("copies").toInt(), 2);
    EXPECT_EQ(choices.value("media").toMap().value("name").toString(), QStringLiteral("iso_a5_148x210mm"));
    EXPECT_EQ(choices.value("printer").toString(), QString());
    EXPECT_TRUE(Print::toQml({}, {}, {}, {}, {}, {}).value("canSavePdf").toBool()) << "no formats given: all three";
    EXPECT_FALSE(Print::toQml({}, {}, {}, {}, {}, {}).value("parented").toBool());
}

// PR1, PR2: the sheet over PreparePrint, the default printer first and its options read; the answer is GTK's settings and page
// setup with a token; Print with that token sends the document to that printer with the copies, paper, sides and colour, never
// the pages (GTK rendered only those).
TEST_F(PrintTest, PreparePrintThenPrintWithItsToken)
{
    auto reply = prepare(kHandle, {{QStringLiteral("n-copies"), QStringLiteral("2")}, {QStringLiteral("print-pages"), QStringLiteral("ranges")},
                                   {QStringLiteral("page-ranges"), QStringLiteral("0-1")}},
                         {{QStringLiteral("Name"), QStringLiteral("iso_a5_148x210mm")}, {QStringLiteral("Width"), 148.0}, {QStringLiteral("Height"), 210.0}},
                         {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }));
    ASSERT_EQ(opened.size(), 1);
    ASSERT_EQ(listed.size(), 1);
    EXPECT_TRUE(listed.first().ok);
    EXPECT_EQ(listed.first().current, QStringLiteral("Office")) << "the default";
    ASSERT_EQ(listed.first().printers.size(), 2);
    EXPECT_EQ(listed.first().printers.first().toMap().value("displayName").toString(), QStringLiteral("Office Printer"));
    EXPECT_EQ(chosen.first().printer, QStringLiteral("Office"));
    EXPECT_TRUE(chosen.first().capabilities.value("twoSided").toBool());
    QVariantMap choices = chosen.first().choices;
    EXPECT_EQ(choices.value("copies").toInt(), 2);
    EXPECT_EQ(choices.value("ranges").toString(), QStringLiteral("1-2"));
    EXPECT_EQ(choices.value("media").toMap().value("name").toString(), QStringLiteral("iso_a5_148x210mm"));
    choices.insert(QStringLiteral("duplex"), QStringLiteral("horizontal"));
    choices.insert(QStringLiteral("color"), false);
    EXPECT_FALSE(reply->done);
    ASSERT_TRUE(printer->answer(opened.first().first, 0, choices));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 0u);
    const QVariantMap settings = mapOf(reply->results.value("settings"));
    const QVariantMap pageSetup = mapOf(reply->results.value("page-setup"));
    EXPECT_EQ(settings.value("printer").toString(), QStringLiteral("Office"));
    EXPECT_EQ(settings.value("n-copies").toString(), QStringLiteral("1")) << "GTK makes one copy; the job asks for two";
    EXPECT_FALSE(pageSetup.contains("PPDName"));
    EXPECT_EQ(settings.value("page-ranges").toString(), QStringLiteral("0-1"));
    EXPECT_EQ(settings.value("duplex").toString(), QStringLiteral("horizontal"));
    EXPECT_EQ(pageSetup.value("Name").toString(), QStringLiteral("iso_a5_148x210mm"));
    EXPECT_DOUBLE_EQ(pageSetup.value("Width").toDouble(), 148.0);
    ASSERT_EQ(reply->results.value("token").metaType(), QMetaType::fromType<uint>());
    const uint token = reply->results.value("token").toUInt();
    EXPECT_NE(token, 0u);

    auto job = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/job"), "%PDF-1.4 two pages",
                             {{QStringLiteral("token"), QVariant::fromValue(token)}});
    ASSERT_TRUE(waitFor([&] { return job->done; }));
    EXPECT_EQ(job->response, 0u);
    ASSERT_EQ(system.jobs.size(), 1);
    EXPECT_EQ(system.jobs.first().printer, QStringLiteral("Office"));
    EXPECT_EQ(system.jobs.first().document, QByteArray("%PDF-1.4 two pages"));
    using Options = PrintSystem::Options;
    EXPECT_EQ(system.jobs.first().options, (Options{{QStringLiteral("copies"), QStringLiteral("2")},
                                                    {QStringLiteral("multiple-document-handling"), QStringLiteral("separate-documents-collated-copies")},
                                                    {QStringLiteral("media"), QStringLiteral("iso_a5_148x210mm")},
                                                    {QStringLiteral("sides"), QStringLiteral("two-sided-long-edge")},
                                                    {QStringLiteral("print-color-mode"), QStringLiteral("monochrome")}}));
    EXPECT_TRUE(gtk.calls.isEmpty()) << "nothing went to x-d-p-gtk";

    // While a token waits for its Print the process is not idle (GTK may render for longer than the idle time).
    QTest::qWait(20);
    EXPECT_GE(printer->quietFor(), 15) << "the job's request is over, no token left";

    // The token is good once: a second Print with it is x-d-p-gtk's.
    auto again = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/again"), "%PDF-1.4",
                               {{QStringLiteral("token"), QVariant::fromValue(token)}});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 1; }));
    EXPECT_EQ(gtk.calls.first(), QStringLiteral("Print /org/freedesktop/portal/desktop/request/1_1/again token %1 fd valid").arg(token));
    EXPECT_EQ(system.jobs.size(), 1);
    QDBusMessage held = gtk.held;
    gtkBus->send(held.createReply(QVariantList{QVariant::fromValue(1u), QVariantMap{}}));
    ASSERT_TRUE(waitFor([&] { return again->done; }));
    EXPECT_EQ(again->response, 1u) << "x-d-p-gtk's answer, relayed";
}

// A token is its application's, and lives five minutes (x-d-p-gtk's rule): another application's Print, or a late one, goes to
// x-d-p-gtk; Print with no token too (step 6b brings Grassfield's sheet with a preview).
TEST_F(PrintTest, ATokenIsItsApplicationsAndExpires)
{
    auto reply = preparedAnswer(kHandle, {});
    const uint token = reply->results.value("token").toUInt();
    QTest::qWait(20);
    EXPECT_EQ(printer->quietFor(), 0) << "a token waits for its Print: the process must not quit (review of step 6a, MINOR 2)";
    auto other = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/other"), "%PDF-1.4",
                               {{QStringLiteral("token"), QVariant::fromValue(token)}}, QStringLiteral("org.example.Other"));
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 1; }));
    EXPECT_TRUE(system.jobs.isEmpty());
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(2u), QVariantMap{}}));
    ASSERT_TRUE(waitFor([&] { return other->done; }));
    // Still good for its own application after another's try.
    auto own = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/own"), "%PDF-1.4",
                             {{QStringLiteral("token"), QVariant::fromValue(token)}});
    ASSERT_TRUE(waitFor([&] { return own->done; }));
    EXPECT_EQ(own->response, 0u);
    EXPECT_EQ(system.jobs.size(), 1);

    auto none = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/none"), "%PDF-1.4", {});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 2; }));
    EXPECT_EQ(gtk.calls.last(), QStringLiteral("Print /org/freedesktop/portal/desktop/request/1_1/none token 0 fd valid"));
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(0u), QVariantMap{}}));
    ASSERT_TRUE(waitFor([&] { return none->done; }));

    // A live token keeps the process (its idle time passes, but it is not quiet); its expiry starts the idle time again.
    make([](Print::Options &o) {
        o.tokenLifetimeMs = 300;
        o.idleQuitMs = 50;
    });
    bool idled = false;
    QObject::connect(printer.get(), &Print::idle, printer.get(), [&idled] { idled = true; });
    auto late = preparedAnswer(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/late"), {});
    const uint lateToken = late->results.value("token").toUInt();
    ASSERT_TRUE(waitFor([&] { return idled; })) << "the idle time after the sheet";
    EXPECT_EQ(printer->quietFor(), 0) << "the token lives";
    EXPECT_FALSE(RequestHost::quiet({printer.get()}, 50));
    idled = false;
    ASSERT_TRUE(waitFor([&] { return idled; })) << "the idle time starts again once the token has expired";
    EXPECT_GE(printer->quietFor(), 50) << "quiet for the idle time since it started again";
    EXPECT_TRUE(RequestHost::quiet({printer.get()}, 50));
    printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/late2"), "%PDF-1.4",
                  {{QStringLiteral("token"), QVariant::fromValue(lateToken)}});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 3; })) << "an expired token is not ours any more";
    EXPECT_EQ(system.jobs.size(), 1);
}

// PR3: Save as PDF writes the document GTK made to the file chosen in the Save panel, and only there (integrator security review
// of step 6a): only a PDF, never half of one; never through a link (a link put at the name since the choice is replaced, its target
// untouched; a folder replaced by a link since the choice fails the write; a folder that was a link when chosen, as a user's
// Documents on another disk, is written through); the application gets no path back; an answer for any other file, or with no
// Save panel answer, is refused; an application that cannot make a PDF gets no Save as PDF.
TEST_F(PrintTest, SaveAsPdfWritesTheFileChosen)
{
    // No window is presented here: the deadline that would send the sheet to x-d-p-gtk is moved out of the way.
    make([](Print::Options &o) { o.uiDeadlineMs = 60000; });
    const QString target = dir.filePath(QStringLiteral("Report.pdf"));
    auto reply = savedAs(kHandle, target);
    ASSERT_EQ(reply->response, 0u);
    const QVariantMap settings = mapOf(reply->results.value("settings"));
    EXPECT_EQ(settings.value("output-uri").toString(), QStringLiteral("file:///dev/null")) << "never the user's path";
    EXPECT_EQ(settings.value("output-file-format").toString(), QStringLiteral("pdf"));
    EXPECT_FALSE(settings.contains("printer"));
    auto job = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/pdf"), reply, "%PDF-1.7 the report");
    ASSERT_TRUE(waitFor([&] { return job->done; }));
    EXPECT_EQ(job->response, 0u);
    QFile written(target);
    ASSERT_TRUE(written.open(QIODevice::ReadOnly));
    EXPECT_EQ(written.readAll(), QByteArray("%PDF-1.7 the report"));
    written.close();
    EXPECT_TRUE(system.jobs.isEmpty()) << "nothing printed";

    // Not a PDF: nothing written, the file there stays.
    auto second = savedAs(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/second"), target);
    auto bad = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/bad"), second, "%!PS-Adobe-3.0");
    ASSERT_TRUE(waitFor([&] { return bad->done; }));
    EXPECT_EQ(bad->response, 2u);
    ASSERT_TRUE(written.open(QIODevice::ReadOnly));
    EXPECT_EQ(written.readAll(), QByteArray("%PDF-1.7 the report"));
    written.close();

    // Only the file the Save panel answered.
    auto other = savedAs(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/other"), target, dir.filePath(QStringLiteral("Other.pdf")));
    EXPECT_TRUE(other->refused) << "another file than the Save panel's";
    EXPECT_EQ(other->response, 1u);
    const qsizetype before = chosen.size();
    auto unasked = prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/unasked"), {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return chosen.size() > before; }));
    QVariantMap choices = chosen.last().choices;
    choices.insert(QStringLiteral("outputUri"), QUrl::fromLocalFile(target).toString());
    EXPECT_FALSE(printer->answer(chosen.last().id, 0, choices)) << "no Save panel answer";
    EXPECT_TRUE(printer->answer(chosen.last().id, 1));

    // A link put at the name after the choice (an application that can write in the folder): the file takes the link's place,
    // what it pointed to is untouched.
    QTemporaryDir elsewhere;
    ASSERT_TRUE(elsewhere.isValid());
    const QString secret = elsewhere.filePath(QStringLiteral("bashrc"));
    QFile secretFile(secret);
    ASSERT_TRUE(secretFile.open(QIODevice::WriteOnly));
    secretFile.write("keep");
    secretFile.close();
    const QString linked = dir.filePath(QStringLiteral("Linked.pdf"));
    auto planted = savedAs(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/planted"), linked);
    ASSERT_EQ(planted->response, 0u);
    ASSERT_TRUE(QFile::link(secret, linked));
    auto through = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/through"), planted, "%PDF-1.7\necho owned");
    ASSERT_TRUE(waitFor([&] { return through->done; }));
    EXPECT_EQ(through->response, 0u);
    ASSERT_TRUE(secretFile.open(QIODevice::ReadOnly));
    EXPECT_EQ(secretFile.readAll(), QByteArray("keep")) << "the link's target is untouched";
    secretFile.close();
    EXPECT_FALSE(QFileInfo(linked).isSymLink()) << "the link replaced by the file";
    QFile replaced(linked);
    ASSERT_TRUE(replaced.open(QIODevice::ReadOnly));
    EXPECT_EQ(replaced.readAll(), QByteArray("%PDF-1.7\necho owned"));

    // The folder replaced by a link after the choice: nothing written anywhere.
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("Sub")));
    auto moved = savedAs(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/moved"), dir.filePath(QStringLiteral("Sub/Out.pdf")));
    ASSERT_EQ(moved->response, 0u);
    ASSERT_TRUE(QDir(dir.path()).rename(QStringLiteral("Sub"), QStringLiteral("Sub.old")));
    ASSERT_TRUE(QFile::link(elsewhere.path(), dir.filePath(QStringLiteral("Sub"))));
    auto refused = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/refused"), moved, "%PDF-1.7 elsewhere");
    ASSERT_TRUE(waitFor([&] { return refused->done; }));
    EXPECT_EQ(refused->response, 2u);
    EXPECT_EQ(QDir(elsewhere.path()).entryList(QDir::Files | QDir::Hidden), QStringList{QStringLiteral("bashrc")}) << "nothing through the link";
    EXPECT_TRUE(QDir(dir.filePath(QStringLiteral("Sub.old"))).isEmpty());

    // A folder that is a link when the user chooses it (Documents on another disk): written in the folder it leads to.
    ASSERT_TRUE(QDir(dir.path()).mkdir(QStringLiteral("Disk")));
    ASSERT_TRUE(QFile::link(dir.filePath(QStringLiteral("Disk")), dir.filePath(QStringLiteral("Documents"))));
    auto documents = savedAs(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/documents"), dir.filePath(QStringLiteral("Documents/Mine.pdf")));
    ASSERT_EQ(documents->response, 0u);
    auto mine = printWith(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/mine"), documents, "%PDF-1.7 mine");
    ASSERT_TRUE(waitFor([&] { return mine->done; }));
    EXPECT_EQ(mine->response, 0u);
    EXPECT_TRUE(QFileInfo(dir.filePath(QStringLiteral("Disk/Mine.pdf"))).isFile());

    // An application that makes PostScript only: no Save as PDF answer.
    const qsizetype count = chosen.size();
    auto ps = prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/ps"), {}, {},
                      {{QStringLiteral("supported_output_file_formats"), QStringList{QStringLiteral("ps")}}});
    ASSERT_TRUE(waitFor([&] { return chosen.size() > count; }));
    choices = chosen.last().choices;
    choices.insert(QStringLiteral("outputUri"), QUrl::fromLocalFile(target).toString());
    EXPECT_FALSE(printer->answer(chosen.last().id, 0, choices));
    EXPECT_FALSE(ps->done) << "the sheet stays";
    EXPECT_TRUE(printer->answer(chosen.last().id, 1));
    ASSERT_TRUE(waitFor([&] { return ps->done; }));
    EXPECT_EQ(ps->response, 1u);
}

// Save as PDF… asks the process's own Save panel (the D-4 panel, with the application's memory) over the application's window,
// the name suggested with ".pdf"; the file chosen comes back to the sheet; Cancel there brings the sheet back; a request closed
// meanwhile closes its Save panel.
TEST_F(PrintTest, SaveAsPdfAsksTheSavePanel)
{
    // The sheet is on screen meanwhile (shown: no deadline sends it to x-d-p-gtk); here no window is presented, so the deadline
    // is moved out of the way.
    make([](Print::Options &o) { o.uiDeadlineMs = 60000; });
    QList<QPair<int, QString>> pdf;
    QList<int> back;
    QObject::connect(printer.get(), &Print::pdfChosen, printer.get(), [&pdf](int id, const QString &uri) { pdf.append({id, uri}); });
    QObject::connect(printer.get(), &Print::pdfCancelled, printer.get(), [&back](int id) { back.append(id); });
    auto reply = prepare(kHandle, {{QStringLiteral("output-basename"), QStringLiteral("Quarterly Report")}}, {}, {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }));
    EXPECT_EQ(opened.first().second.value("outputBasename").toString(), QStringLiteral("Quarterly Report"));
    const int id = chosen.first().id;
    printer->savePdf(id, QStringLiteral("Quarterly Report"), QStringLiteral("Save as PDF"));
    ASSERT_TRUE(waitFor([&] { return saveFile->calls.size() == 1; }));
    EXPECT_EQ(saveFile->calls.first(),
              QStringLiteral("SaveFile /org/freedesktop/portal/desktop/request/grassfield org.example.Writer wayland:abc Save as PDF Quarterly Report.pdf"));
    backendBus->send(saveFile->held.createReply(QVariantList{QVariant::fromValue(1u), QVariantMap{}}));
    ASSERT_TRUE(waitFor([&] { return back.size() == 1; })) << "Cancel in the Save panel: the sheet comes back";
    EXPECT_TRUE(pdf.isEmpty());

    printer->savePdf(id, QStringLiteral("a/b"), QStringLiteral("Save as PDF"));
    ASSERT_TRUE(waitFor([&] { return saveFile->calls.size() == 2; }));
    EXPECT_TRUE(saveFile->calls.last().endsWith(QStringLiteral(" Document.pdf"))) << "never a folder in the name";
    const QString target = QUrl::fromLocalFile(dir.filePath(QStringLiteral("Quarterly Report.pdf"))).toString();
    backendBus->send(saveFile->held.createReply(
        QVariantList{QVariant::fromValue(0u), QVariantMap{{QStringLiteral("uris"), QStringList{target}}}}));
    ASSERT_TRUE(waitFor([&] { return pdf.size() == 1; }));
    EXPECT_EQ(pdf.first(), qMakePair(id, target));
    QVariantMap choices = chosen.first().choices;
    choices.insert(QStringLiteral("outputUri"), target);
    ASSERT_TRUE(printer->answer(id, 0, choices));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(mapOf(reply->results.value("settings")).value("output-uri").toString(), QStringLiteral("file:///dev/null"));

    // A Save panel open when the application closes the request goes with it.
    auto second = prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/second"), {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return chosen.size() == 2; }));
    printer->savePdf(chosen.last().id, QString(), QStringLiteral("Save as PDF"));
    ASSERT_TRUE(waitFor([&] { return saveFile->calls.size() == 3; }));
    const QString saveHandle = saveFile->held.arguments().at(0).value<QDBusObjectPath>().path();
    QDBusMessage close = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/second"),
                                                        QStringLiteral("org.freedesktop.impl.portal.Request"), QStringLiteral("Close"));
    frontendBus->asyncCall(close);
    ASSERT_TRUE(waitFor([&] { return second->done; }));
    ASSERT_TRUE(waitFor([&] { return saveFile->closes.contains(saveHandle); })) << "its Save panel was closed";
    // The Save panel's late answer is no answer of the sheet's.
    backendBus->send(saveFile->held.createReply(QVariantList{QVariant::fromValue(0u), QVariantMap{{QStringLiteral("uris"), QStringList{target}}}}));
    QTest::qWait(50);
    EXPECT_EQ(pdf.size(), 1);
}

// Cancel is response 1; a job the printer refuses is response 2 (GTK tells the application); answers for a request that is gone
// are ignored.
TEST_F(PrintTest, CancelAndARefusedJob)
{
    auto reply = prepare(kHandle, {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }));
    EXPECT_TRUE(printer->answer(chosen.first().id, 1));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 1u);
    EXPECT_TRUE(reply->results.isEmpty());
    EXPECT_TRUE(printer->answer(chosen.first().id, 0, chosen.first().choices)) << "gone: ignored";

    system.refuse = QStringLiteral("the printer is out of paper");
    auto prepared = preparedAnswer(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/refused"), {});
    auto job = printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/job"), "%PDF-1.4",
                             {{QStringLiteral("token"), QVariant::fromValue(prepared->results.value("token").toUInt())}});
    ASSERT_TRUE(waitFor([&] { return job->done; }));
    EXPECT_EQ(job->response, 2u);
}

// PR4: no printer: the sheet is told (an empty list, none current) and cannot print, only Save as PDF or Cancel; a printer
// the sheet did not choose is no answer.
TEST_F(PrintTest, NoPrinter)
{
    system.printers.clear();
    auto reply = prepare(kHandle, {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return !listed.isEmpty(); }));
    EXPECT_TRUE(listed.first().printers.isEmpty());
    EXPECT_EQ(listed.first().current, QString());
    EXPECT_TRUE(listed.first().ok);
    QTest::qWait(50);
    EXPECT_TRUE(chosen.isEmpty());
    const QVariantMap choices = opened.first().second.value("choices").toMap();
    EXPECT_FALSE(printer->answer(opened.first().first, 0, choices)) << "nothing to print on";
    QVariantMap other = choices;
    other.insert(QStringLiteral("printer"), QStringLiteral("Office"));
    EXPECT_FALSE(printer->answer(opened.first().first, 0, other)) << "a printer the sheet never chose";
    other.insert(QStringLiteral("printer"), QString());
    other.insert(QStringLiteral("outputUri"), QUrl::fromLocalFile(dir.filePath(QStringLiteral("a.pdf"))).toString());
    EXPECT_FALSE(printer->answer(opened.first().first, 0, other)) << "no file chosen in the Save panel";
    ASSERT_TRUE(choosePdf(opened.first().first, dir.filePath(QStringLiteral("a.pdf"))));
    EXPECT_TRUE(printer->answer(opened.first().first, 0, other));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 0u);

    // CUPS does not answer: the sheet is told so.
    system.listed = false;
    prepare(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/nocups"), {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return listed.size() == 2; }));
    EXPECT_FALSE(listed.last().ok);
}

// Another printer: its options read, the choices made so far carried over where it takes them (Mono: one side, black and white;
// the copies and pages stay); the answer then prints there.
TEST_F(PrintTest, AnotherPrinterKeepsTheChoicesItTakes)
{
    auto reply = prepare(kHandle, {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }));
    QVariantMap choices = chosen.first().choices;
    choices.insert(QStringLiteral("copies"), 3);
    choices.insert(QStringLiteral("duplex"), QStringLiteral("vertical"));
    choices.insert(QStringLiteral("pages"), QStringLiteral("ranges"));
    choices.insert(QStringLiteral("ranges"), QStringLiteral("2-"));
    choices.insert(QStringLiteral("orientation"), QStringLiteral("landscape"));
    choices.insert(QStringLiteral("scale"), 80);
    const int id = chosen.first().id;
    printer->choosePrinter(id, QStringLiteral("Mono"), choices);
    // Its options are being read: no answer prints on it yet.
    QVariantMap early = choices;
    early.insert(QStringLiteral("printer"), QStringLiteral("Mono"));
    early.insert(QStringLiteral("ranges"), QStringLiteral("2"));
    EXPECT_FALSE(printer->answer(id, 0, early)) << "the options are not read yet";
    ASSERT_TRUE(waitFor([&] { return chosen.size() == 2; }));
    const QVariantMap mono = chosen.last().choices;
    EXPECT_EQ(chosen.last().printer, QStringLiteral("Mono"));
    EXPECT_EQ(mono.value("copies").toInt(), 3);
    EXPECT_EQ(mono.value("duplex").toString(), QStringLiteral("simplex"));
    EXPECT_FALSE(mono.value("color").toBool());
    EXPECT_EQ(mono.value("ranges").toString(), QStringLiteral("2-")) << "pages being typed stay as typed";
    EXPECT_EQ(mono.value("orientation").toString(), QStringLiteral("landscape")) << "the rest carried though the pages do not read yet";
    EXPECT_EQ(mono.value("scale").toInt(), 80);
    EXPECT_EQ(printer->tidyRanges(QStringLiteral("2-")), QString());
    EXPECT_EQ(printer->tidyRanges(QStringLiteral("5, 1-2")), QStringLiteral("1-2, 5"));
    QVariantMap answerChoices = mono;
    EXPECT_FALSE(printer->answer(id, 0, answerChoices)) << "bad pages: the sheet stays";
    answerChoices.insert(QStringLiteral("ranges"), QStringLiteral("2-4"));
    ASSERT_TRUE(printer->answer(id, 0, answerChoices));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(mapOf(reply->results.value("settings")).value("printer").toString(), QStringLiteral("Mono"));
    EXPECT_EQ(mapOf(reply->results.value("settings")).value("page-ranges").toString(), QStringLiteral("1-3"));
}

// FC7 for print: a sheet that cannot be made sends PreparePrint to x-d-p-gtk, and its answer comes back with GTK's types (the
// settings' strings, the page setup's doubles, the token); anything else in it is dropped.
TEST_F(PrintTest, NoSheetGoesToGtkAndItsAnswerIsRelayed)
{
    printer->setUiLoader([] { return false; });
    auto reply = prepare(kHandle, {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 1; }));
    EXPECT_EQ(gtk.calls.first(), QStringLiteral("PreparePrint %1").arg(kHandle));
    const QVariantMap settings{{QStringLiteral("n-copies"), QStringLiteral("1")}, {QStringLiteral("odd"), 7}};
    const QVariantMap pageSetup{{QStringLiteral("Width"), 210.0}, {QStringLiteral("Name"), QStringLiteral("iso_a4_210x297mm")},
                                {QStringLiteral("bad"), QStringList{QStringLiteral("x")}}};
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(0u),
                                                   QVariantMap{{QStringLiteral("settings"), settings},
                                                               {QStringLiteral("page-setup"), pageSetup},
                                                               {QStringLiteral("token"), QVariant::fromValue(77u)},
                                                               {QStringLiteral("extra"), QStringLiteral("x")}}}));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 0u);
    EXPECT_EQ(mapOf(reply->results.value("settings")), (QVariantMap{{QStringLiteral("n-copies"), QStringLiteral("1")}}));
    EXPECT_EQ(mapOf(reply->results.value("page-setup")),
              (QVariantMap{{QStringLiteral("Width"), 210.0}, {QStringLiteral("Name"), QStringLiteral("iso_a4_210x297mm")}}));
    EXPECT_EQ(reply->results.value("token").toUInt(), 77u);
    EXPECT_FALSE(reply->results.contains("extra"));
    // x-d-p-gtk's token is x-d-p-gtk's: Print with it goes there.
    printDocument(QStringLiteral("/org/freedesktop/portal/desktop/request/1_1/gtkjob"), "%PDF-1.4", {{QStringLiteral("token"), QVariant::fromValue(77u)}});
    ASSERT_TRUE(waitFor([&] { return gtk.calls.size() == 2; }));
    EXPECT_TRUE(system.jobs.isEmpty());
}

// Close during the sheet: it goes, and nothing is answered after.
TEST_F(PrintTest, CloseTakesTheSheetAway)
{
    auto reply = prepare(kHandle, {}, {}, {});
    ASSERT_TRUE(waitFor([&] { return !chosen.isEmpty(); }));
    QDBusMessage close = QDBusMessage::createMethodCall(QString::fromLatin1(kService), kHandle, QStringLiteral("org.freedesktop.impl.portal.Request"),
                                                        QStringLiteral("Close"));
    frontendBus->asyncCall(close);
    ASSERT_TRUE(waitFor([&] { return closed.contains(chosen.first().id); }));
    EXPECT_TRUE(printer->answer(chosen.first().id, 0, chosen.first().choices)) << "gone: ignored";
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_NE(reply->response, 0u);
}

// Save as PDF's writer: a PDF read to its end whatever the pieces it comes in, written through a temporary file renamed over the
// name; anything that is not a PDF (fewer than five bytes of "%PDF-" too), a source that stops, a document over the limit, or a
// last step that fails writes nothing, leaves the file there as it was and no temporary file. Never through a link: a link at the
// name is replaced (its target untouched), a link in the folder's path fails (integrator security review of step 6a, MAJOR 1). A
// file there keeps its permissions.
TEST(WritePdf, OnlyAWholePdfIsWrittenAndNeverThroughALink)
{
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString folder = dir.path();
    const QString target = dir.filePath(QStringLiteral("out.pdf"));
    const auto pipeOf = [](const QList<QByteArray> &pieces, bool close) {
        int ends[2];
        EXPECT_EQ(::pipe2(ends, O_CLOEXEC), 0);
        for (const QByteArray &piece : pieces)
            EXPECT_EQ(::write(ends[1], piece.constData(), size_t(piece.size())), piece.size());
        if (close)
            ::close(ends[1]);
        return std::make_pair(ends[0], ends[1]);
    };
    const auto source = [&](const QList<QByteArray> &pieces) { return pipeOf(pieces, true).first; };
    const auto contents = [](const QString &path) {
        QFile f(path);
        return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray("(none)");
    };
    const auto leftovers = [](const QString &path) {
        return QDir(path).entryList({QStringLiteral(".grassfield-print-*")}, QDir::Files | QDir::Hidden);
    };
    // The header in two pieces (fewer than five bytes first): nothing of it lost.
    EXPECT_EQ(writePdf(source({QByteArray("%P"), QByteArray("DF-1.7 body")}), folder, QStringLiteral("out.pdf"), 2000), QString());
    EXPECT_EQ(contents(target), QByteArray("%PDF-1.7 body"));
    // Exactly the five bytes of the header: a PDF; four of them: not one.
    EXPECT_EQ(writePdf(source({QByteArray("%PDF-")}), folder, QStringLiteral("five.pdf"), 2000), QString());
    EXPECT_EQ(contents(dir.filePath(QStringLiteral("five.pdf"))), QByteArray("%PDF-"));
    EXPECT_EQ(writePdf(source({QByteArray("%PDF")}), folder, QStringLiteral("out.pdf"), 2000), QStringLiteral("the document is not a PDF"));
    EXPECT_EQ(writePdf(source({QByteArray("%!PS-Adobe-3.0")}), folder, QStringLiteral("out.pdf"), 2000), QStringLiteral("the document is not a PDF"));
    EXPECT_EQ(writePdf(source({QByteArray("%PD")}), folder, QStringLiteral("out.pdf"), 2000), QStringLiteral("the document is not a PDF"));
    // A source that stops halfway: no half document.
    auto [silent, silentWriter] = pipeOf({QByteArray("%PDF-1.7 half")}, false);
    EXPECT_EQ(writePdf(silent, folder, QStringLiteral("out.pdf"), 200), QStringLiteral("the document stopped coming"));
    ::close(silentWriter);
    // Over the limit: nothing.
    EXPECT_EQ(writePdf(source({QByteArray("%PDF-1.7 "), QByteArray(64, 'x')}), folder, QStringLiteral("out.pdf"), 2000, 32),
              QStringLiteral("the document is too large"));
    EXPECT_EQ(contents(target), QByteArray("%PDF-1.7 body")) << "the file there is untouched";
    // A folder that is not there.
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), dir.filePath(QStringLiteral("missing")), QStringLiteral("out.pdf"), 2000)
                    .startsWith(QStringLiteral("cannot open the folder")));
    // The last step failing (the name is a folder): nothing replaced, no temporary file.
    ASSERT_TRUE(QDir(folder).mkdir(QStringLiteral("taken.pdf")));
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), folder, QStringLiteral("taken.pdf"), 2000).startsWith(QStringLiteral("cannot write")));
    EXPECT_TRUE(QFileInfo(dir.filePath(QStringLiteral("taken.pdf"))).isDir());
    EXPECT_EQ(leftovers(folder), QStringList()) << "no temporary file left";

    // A link at the name: replaced by the file, what it pointed to untouched.
    QTemporaryDir elsewhere;
    ASSERT_TRUE(elsewhere.isValid());
    const QString secret = elsewhere.filePath(QStringLiteral("bashrc"));
    {
        QFile f(secret);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly));
        f.write("keep");
    }
    ASSERT_TRUE(QFile::link(secret, dir.filePath(QStringLiteral("link.pdf"))));
    EXPECT_EQ(writePdf(source({QByteArray("%PDF-1.7\necho owned")}), folder, QStringLiteral("link.pdf"), 2000), QString());
    EXPECT_EQ(contents(secret), QByteArray("keep"));
    EXPECT_FALSE(QFileInfo(dir.filePath(QStringLiteral("link.pdf"))).isSymLink());
    EXPECT_EQ(contents(dir.filePath(QStringLiteral("link.pdf"))), QByteArray("%PDF-1.7\necho owned"));
    // A link in the folder's path (the folder itself, or one above it): refused, nothing written where it leads.
    ASSERT_TRUE(QFile::link(elsewhere.path(), dir.filePath(QStringLiteral("swapped"))));
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), dir.filePath(QStringLiteral("swapped")), QStringLiteral("x.pdf"), 2000)
                    .endsWith(QStringLiteral("changed since it was chosen")));
    ASSERT_TRUE(QDir(elsewhere.path()).mkdir(QStringLiteral("inner")));
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), dir.filePath(QStringLiteral("swapped/inner")), QStringLiteral("x.pdf"), 2000)
                    .endsWith(QStringLiteral("changed since it was chosen")));
    EXPECT_EQ(QDir(elsewhere.path()).entryList(QDir::Files | QDir::Hidden), QStringList{QStringLiteral("bashrc")});
    EXPECT_TRUE(QDir(elsewhere.filePath(QStringLiteral("inner"))).isEmpty());
    // Not a file name.
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), folder, QStringLiteral("a/b.pdf"), 2000).startsWith(QStringLiteral("cannot write")));
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7")}), folder, QStringLiteral(".."), 2000).startsWith(QStringLiteral("cannot write")));

    // Over the limit past the first read (a document longer than one read: the limit holds on every piece).
    QFile big(elsewhere.filePath(QStringLiteral("big.pdf")));
    ASSERT_TRUE(big.open(QIODevice::WriteOnly));
    big.write("%PDF-1.7 ");
    big.write(QByteArray(100000, 'x'));
    big.close();
    const int bigFd = ::open(QFile::encodeName(big.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    ASSERT_GE(bigFd, 0);
    EXPECT_EQ(writePdf(bigFd, folder, QStringLiteral("big.pdf"), 2000, 70000), QStringLiteral("the document is too large"));
    EXPECT_FALSE(QFileInfo::exists(dir.filePath(QStringLiteral("big.pdf"))));
    EXPECT_EQ(leftovers(folder), QStringList());

    // A file there keeps its permissions; one that may not be written stays as it is (as QSaveFile refused it).
    ASSERT_EQ(::chmod(QFile::encodeName(target).constData(), 0600), 0);
    EXPECT_EQ(writePdf(source({QByteArray("%PDF-1.7 again")}), folder, QStringLiteral("out.pdf"), 2000), QString());
    struct stat st;
    ASSERT_EQ(::stat(QFile::encodeName(target).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, 0600u);
    ASSERT_EQ(::chmod(QFile::encodeName(target).constData(), 0400), 0);
    EXPECT_TRUE(writePdf(source({QByteArray("%PDF-1.7 over")}), folder, QStringLiteral("out.pdf"), 2000).startsWith(QStringLiteral("cannot write")));
    EXPECT_EQ(contents(target), QByteArray("%PDF-1.7 again"));
    EXPECT_EQ(leftovers(folder), QStringList());

    // A folder one may write in but not list (a drop box, 0300): written in.
    const QString dropBox = dir.filePath(QStringLiteral("drop"));
    ASSERT_TRUE(QDir(folder).mkdir(QStringLiteral("drop")));
    ASSERT_EQ(::chmod(QFile::encodeName(dropBox).constData(), 0300), 0);
    EXPECT_EQ(writePdf(source({QByteArray("%PDF-1.7 dropped")}), dropBox, QStringLiteral("in.pdf"), 2000), QString());
    ASSERT_EQ(::chmod(QFile::encodeName(dropBox).constData(), 0700), 0);
    EXPECT_EQ(contents(dir.filePath(QStringLiteral("drop/in.pdf"))), QByteArray("%PDF-1.7 dropped"));

    // Stopped (Print going away) while the source is silent: it ends at once, without its temporary file.
    auto [held, heldWriter] = pipeOf({QByteArray("%PDF-1.7 started")}, false);
    QElapsedTimer clock;
    clock.start();
    EXPECT_EQ(writePdf(held, folder, QStringLiteral("stopped.pdf"), 30000, print::kMaxDocumentBytes, [&clock] { return clock.elapsed() > 100; }),
              QStringLiteral("cancelled"));
    EXPECT_LT(clock.elapsed(), 2000) << "not the 30 s of silence";
    ::close(heldWriter);
    EXPECT_FALSE(QFileInfo::exists(dir.filePath(QStringLiteral("stopped.pdf"))));
    EXPECT_EQ(leftovers(folder), QStringList());
}

// The libcups side against a real scheduler (A-PR1): tests/integration/print_cups.sh runs this with a scratch cupsd whose default
// queue GF_TEST_CUPS_PRINTER writes its jobs to a file, its PPD offering A4, US Letter and A5, two sides and colour; skipped
// elsewhere. The printers listed (the default flagged, its name and place), what it supports read off the GUI thread, a job sent
// with its options (the scheduler keeps them on the job), and a printer CUPS does not know refused.
TEST(CupsPrintSystem, ListsReadsAndPrintsThroughTheScheduler)
{
    const QString queue = qEnvironmentVariable("GF_TEST_CUPS_PRINTER");
    if (queue.isEmpty())
        GTEST_SKIP() << "needs tests/integration/print_cups.sh (a scratch cupsd)";
    CupsPrintSystem system;
    QObject context;
    const auto wait = [](const std::function<bool()> &done) {
        QDeadlineTimer deadline(20000);
        while (!done() && !deadline.hasExpired())
            QTest::qWait(20);
        return done();
    };

    bool listed = false, ok = false;
    QList<print::Destination> found;
    system.destinations(&context, [&](const QList<print::Destination> &list, bool answered) {
        found = list;
        ok = answered;
        listed = true;
    });
    ASSERT_TRUE(wait([&] { return listed; }));
    EXPECT_TRUE(ok);
    const auto it = std::find_if(found.cbegin(), found.cend(), [&](const print::Destination &d) { return d.name == queue; });
    ASSERT_NE(it, found.cend()) << "the queue is listed";
    EXPECT_TRUE(it->isDefault);
    EXPECT_EQ(it->displayName, QStringLiteral("Office Printer"));
    EXPECT_EQ(it->location, QStringLiteral("Hall"));

    bool read = false;
    print::Capabilities caps;
    system.capabilities(queue, &context, [&](const print::Capabilities &c) {
        caps = c;
        read = true;
    });
    ASSERT_TRUE(wait([&] { return read; }));
    EXPECT_TRUE(caps.known);
    QStringList names;
    for (const print::Media &m : caps.media)
        names << m.name;
    EXPECT_TRUE(names.contains(QStringLiteral("iso_a4_210x297mm"))) << names.join(QLatin1Char(' ')).toStdString();
    EXPECT_TRUE(names.contains(QStringLiteral("na_letter_8.5x11in")));
    EXPECT_TRUE(names.contains(QStringLiteral("iso_a5_148x210mm")));
    EXPECT_EQ(caps.defaultMedia, QStringLiteral("iso_a4_210x297mm"));
    const print::Media a4 = print::findMedia(caps.media, QStringLiteral("iso_a4_210x297mm"));
    EXPECT_NEAR(a4.widthMm, 210, 0.5);
    EXPECT_NEAR(a4.heightMm, 297, 0.5);
    EXPECT_GT(a4.leftMm, 0) << "the PPD's printable area";
    EXPECT_FALSE(a4.displayName.isEmpty());
    EXPECT_TRUE(caps.twoSided);
    EXPECT_TRUE(caps.color);
    EXPECT_GT(caps.maxCopies, 1);

    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QFile document(dir.filePath(QStringLiteral("doc.pdf")));
    ASSERT_TRUE(document.open(QIODevice::WriteOnly));
    document.write("%PDF-1.4\n1 0 obj << /Type /Catalog >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n");
    document.close();
    const int fd = ::open(QFile::encodeName(document.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    ASSERT_GE(fd, 0);
    bool sent = false;
    QString error = QStringLiteral("not answered");
    const PrintSystem::Options options{{QStringLiteral("copies"), QStringLiteral("2")},
                                       {QStringLiteral("multiple-document-handling"), QStringLiteral("separate-documents-collated-copies")},
                                       {QStringLiteral("media"), QStringLiteral("iso_a5_148x210mm")},
                                       {QStringLiteral("sides"), QStringLiteral("two-sided-long-edge")},
                                       {QStringLiteral("print-color-mode"), QStringLiteral("monochrome")}};
    system.submit(queue, QStringLiteral("Grassfield test page"), options, fd, &context, [&](const QString &why) {
        error = why;
        sent = true;
    });
    ASSERT_TRUE(wait([&] { return sent; }));
    EXPECT_TRUE(error.isEmpty()) << error.toStdString();

    // The job as the scheduler keeps it (its newest on the queue): the name and the options sent.
    cups_job_t *jobs = nullptr;
    const int count = cupsGetJobs2(CUPS_HTTP_DEFAULT, &jobs, queue.toUtf8().constData(), 0, CUPS_WHICHJOBS_ALL);
    ASSERT_GT(count, 0);
    int newest = 0;
    QString title;
    for (int i = 0; i < count; ++i) {
        if (jobs[i].id > newest) {
            newest = jobs[i].id;
            title = QString::fromUtf8(jobs[i].title);
        }
    }
    cupsFreeJobs(count, jobs);
    EXPECT_EQ(title, QStringLiteral("Grassfield test page"));
    char uri[1024];
    httpAssembleURIf(HTTP_URI_CODING_ALL, uri, sizeof uri, "ipp", nullptr, "localhost", 0, "/printers/%s", queue.toUtf8().constData());
    ipp_t *request = ippNewRequest(IPP_OP_GET_JOB_ATTRIBUTES);
    ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nullptr, uri);
    ippAddInteger(request, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "job-id", newest);
    ipp_t *response = cupsDoRequest(CUPS_HTTP_DEFAULT, request, "/");
    ASSERT_NE(response, nullptr) << cupsLastErrorString();
    const auto keyword = [response](const char *name) {
        ipp_attribute_t *a = ippFindAttribute(response, name, IPP_TAG_ZERO);
        return a ? QString::fromUtf8(ippGetString(a, 0, nullptr)) : QString();
    };
    ipp_attribute_t *copies = ippFindAttribute(response, "copies", IPP_TAG_INTEGER);
    EXPECT_EQ(copies ? ippGetInteger(copies, 0) : 0, 2);
    EXPECT_EQ(keyword("sides"), QStringLiteral("two-sided-long-edge"));
    EXPECT_EQ(keyword("print-color-mode"), QStringLiteral("monochrome"));
    EXPECT_EQ(keyword("media"), QStringLiteral("iso_a5_148x210mm"));
    ippDelete(response);

    // Only a PDF or PostScript is sent: a printer language (PJL here) is refused before any job is made.
    QFile raw(dir.filePath(QStringLiteral("raw.prn")));
    ASSERT_TRUE(raw.open(QIODevice::WriteOnly));
    raw.write("\x1b%-12345X@PJL ENTER LANGUAGE=PCL\n");
    raw.close();
    const int rawFd = ::open(QFile::encodeName(raw.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    ASSERT_GE(rawFd, 0);
    sent = false;
    system.submit(queue, QStringLiteral("raw"), {}, rawFd, &context, [&](const QString &why) {
        error = why;
        sent = true;
    });
    ASSERT_TRUE(wait([&] { return sent; }));
    EXPECT_EQ(error, QStringLiteral("the document is not a PDF"));
    const auto jobCount = [&queue] {
        cups_job_t *list = nullptr;
        const int n = cupsGetJobs2(CUPS_HTTP_DEFAULT, &list, queue.toUtf8().constData(), 0, CUPS_WHICHJOBS_ALL);
        cupsFreeJobs(n, list);
        return n;
    };
    EXPECT_EQ(jobCount(), count) << "no job made";
    // PostScript neither (it can program a PostScript printer; GTK always sends a PDF here).
    ASSERT_TRUE(raw.open(QIODevice::WriteOnly | QIODevice::Truncate));
    raw.write("%!PS-Adobe-3.0\nserverdict begin 0 exitserver\n");
    raw.close();
    const int psFd = ::open(QFile::encodeName(raw.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    ASSERT_GE(psFd, 0);
    sent = false;
    system.submit(queue, QStringLiteral("ps"), {}, psFd, &context, [&](const QString &why) {
        error = why;
        sent = true;
    });
    ASSERT_TRUE(wait([&] { return sent; }));
    EXPECT_EQ(error, QStringLiteral("the document is not a PDF"));
    EXPECT_EQ(jobCount(), count) << "no job made";

    // A document over the limit: refused before any job when its first read is already over it, else its job cancelled.
    CupsPrintSystem::Limits small;
    small.maxDocumentBytes = 40;
    CupsPrintSystem limited(small, nullptr);
    for (const qsizetype size : {qsizetype(60), qsizetype(200000)}) {
        QFile over(dir.filePath(QStringLiteral("over.pdf")));
        ASSERT_TRUE(over.open(QIODevice::WriteOnly | QIODevice::Truncate));
        over.write("%PDF-1.4\n");
        over.write(QByteArray(size, ' '));
        over.close();
        const int overFd = ::open(QFile::encodeName(over.fileName()).constData(), O_RDONLY | O_CLOEXEC);
        ASSERT_GE(overFd, 0);
        const int before = jobCount();
        sent = false;
        limited.submit(queue, QStringLiteral("over"), {}, overFd, &context, [&](const QString &why) {
            error = why;
            sent = true;
        });
        ASSERT_TRUE(wait([&] { return sent; }));
        EXPECT_EQ(error, QStringLiteral("the document is too large")) << size;
        if (size < 65536) {
            EXPECT_EQ(jobCount(), before) << "no job made";
        }
    }

    // A printer CUPS does not know: refused, the document closed.
    const int other = ::open(QFile::encodeName(document.fileName()).constData(), O_RDONLY | O_CLOEXEC);
    sent = false;
    system.submit(QStringLiteral("NoSuchPrinter"), QStringLiteral("x"), {}, other, &context, [&](const QString &why) {
        error = why;
        sent = true;
    });
    ASSERT_TRUE(wait([&] { return sent; }));
    EXPECT_FALSE(error.isEmpty());
    EXPECT_EQ(::fcntl(other, F_GETFD), -1) << "the document's descriptor was closed";
    bool none = false;
    print::Capabilities unknown;
    system.capabilities(QStringLiteral("NoSuchPrinter"), &context, [&](const print::Capabilities &c) {
        unknown = c;
        none = true;
    });
    ASSERT_TRUE(wait([&] { return none; }));
    EXPECT_FALSE(unknown.known);
}

#include "tst_print.moc"
