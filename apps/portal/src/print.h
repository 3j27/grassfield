// org.freedesktop.impl.portal.Print for the Grassfield session (ADR-0035 D-7, step 6a; docs/specs/system-dialogs.md section 7,
// PR1-PR5): an application's Print… becomes Grassfield's print sheet (apps/files/qml/PrintSheet.qml) on its window.
//
// GTK's flow (gtk/print/gtkprintoperation-portal.c): PreparePrint shows the sheet and answers GTK's settings, page setup and a
// token; GTK renders the document with them and sends it to Print with the token, which prints it with no sheet: the job goes
// to the CUPS printer chosen (PrintSystem), or Save as PDF writes it to the file chosen in the Save panel. A token is good once,
// for the application that got it, for five minutes (x-d-p-gtk's rule, src/print.c). A Print with no token, or one this backend
// did not give (x-d-p-gtk's, after a PreparePrint it served), goes to x-d-p-gtk: its dialog with a preview of the document
// (step 6b brings Grassfield's).
//
// The request lifecycle is RequestHost's (a Request object at the frontend's handle, Close, the 3-s forward to x-d-p-gtk when
// the sheet cannot show, the idle quit).
#pragma once

#include "printlogic.h"
#include "requesthost.h"

#include <QDBusAbstractAdaptor>
#include <QDBusUnixFileDescriptor>
#include <QElapsedTimer>
#include <QHash>
#include <QVariantMap>

#include <atomic>
#include <memory>

namespace grassfield::portal {

class PrintSystem;

class Print : public RequestHost
{
    Q_OBJECT

public:
    struct Options {
        // The backend x-d-p-gtk serves Print under (the forward of FC7, and Print without a token of ours).
        QString gtkService = QStringLiteral("org.freedesktop.impl.portal.desktop.gtk");
        int uiDeadlineMs = 3000;
        int idleQuitMs = 60000;
        int maxPending = 16;
        int tokenLifetimeMs = 300000;
        // Save as PDF: a document that stops coming for this long is not written.
        int fileIdleMs = 30000;
        // How Settings > Printers opens (Add Printer…): the program and its arguments.
        QStringList addPrinterCommand{QStringLiteral("grassfield-settings"), QStringLiteral("--section=printers")};
    };

    Print(const QDBusConnection &bus, PrintSystem *system, const Options &options, QObject *parent = nullptr);
    // Waits a short while for the Save as PDF writes still running (a file the frontend handed is read to its end at once).
    ~Print() override;

    // The connection Save as PDF calls this process's FileChooser on: a second one to the same bus (QtDBus answers a call on
    // the connection the service is on in place, without the delayed reply the panel needs). None: no Save as PDF.
    void setPanelBus(const QDBusConnection &bus) { m_panelBus = std::make_unique<QDBusConnection>(bus); }

    // The D-Bus methods (PrintAdaptor). handle*: a delayed reply, sent when the request ends.
    void handlePrepare(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                       const QVariantMap &settings, const QVariantMap &pageSetup, const QVariantMap &options, const QDBusMessage &message);
    void handlePrint(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                     const QDBusUnixFileDescriptor &fd, const QVariantMap &options, const QDBusMessage &message);

    // For the sheet. The printers, again (printersListed answers).
    Q_INVOKABLE void listPrinters(int id);
    // What `printer` supports, and the sheet's choices carried over to it (`choices`: the sheet's current ones, toQml's form):
    // printerChosen answers.
    Q_INVOKABLE void choosePrinter(int id, const QString &printer, const QVariantMap &choices);
    // Whether `ranges` (as typed, 1-based) are pages the sheet can print, and their tidy form ("" when not).
    Q_INVOKABLE QString tidyRanges(const QString &ranges) const;
    // The sheet's answer: response 0 with its choices (to print, or Save as PDF when outputUri is set), or 1 (Cancel). False
    // (and the sheet stays) when the choices cannot be printed; an answer for a request that is gone is ignored (true).
    Q_INVOKABLE bool answer(int id, int response, const QVariantMap &choices = {});
    // Add Printer…: Settings > Printers.
    Q_INVOKABLE void addPrinter();
    // Not quiet while a token waits for its Print (GTK may take a while to render the document): the process quitting would
    // lose it, and the Print would end in x-d-p-gtk's dialog (review of step 6a, MINOR 2).
    qint64 quietFor() const override;
    // Save as PDF…: grassfield-portal's own Save panel (FileChooser's SaveFile, called on this process's bus connection, so it
    // is the panel of D-4 with the application's remembered folder), over the application's window, suggesting `name`
    // (".pdf" added) under `title`; pdfChosen or pdfCancelled answers. The sheet then answers with outputUri, or comes back.
    Q_INVOKABLE void savePdf(int id, const QString &name, const QString &title);

    // What the sheet is given first (pure; the tests read it): {appId, title (one line), modal, parented, acceptLabel,
    // hasCurrentPage, hasSelection, canSavePdf (the application can make a PDF), outputBasename (the name the application
    // gives a file it prints to, a plain name or ""), choices (print::toQml, the printer not known yet)}.
    static QVariantMap toQml(const QString &appId, const QString &parentWindow, const QString &title, const QVariantMap &settings,
                             const QVariantMap &pageSetup, const QVariantMap &options);

signals:
    // A sheet to make for request `id` (toQml).
    void opened(int id, const QVariantMap &sheet);
    // The printers for request `id`'s sheet ([print::toQml(Destination)], the default first), and the one to show first
    // ("" when none); `ok` false when CUPS did not answer.
    void printersListed(int id, const QVariantList &printers, const QString &current, bool ok);
    // What `printer` supports (print::toQml(Capabilities)) and the sheet's choices for it.
    void printerChosen(int id, const QString &printer, const QVariantMap &capabilities, const QVariantMap &choices);
    // Save as PDF's answer: the file chosen (a local file:// URI), or none.
    void pdfChosen(int id, const QString &uri);
    void pdfCancelled(int id);

protected:
    QVariantMap relayed(const QVariantMap &gtkResults) const override;
    void ended(int id) override;

private:
    struct Pending {
        QString appId;
        QString parentWindow;
        QString title;
        QVariantMap settings;
        QVariantMap pageSetup;
        bool hasCurrentPage = false;
        bool hasSelection = false;
        bool canSavePdf = false;
        QString printer;
        // The printer's options are being read: no answer prints on it meanwhile (review of step 6a, MINOR 4).
        bool reading = false;
        print::Capabilities capabilities;
        print::Choices choices;
        // The file the Save panel last answered: its URI as given, its folder with the links resolved then, its name. Save as
        // PDF writes only there (integrator security review of step 6a, NIT).
        QString pdfUri;
        QString pdfFolder;
        QString pdfName;
        // The Save panel last opened (its handle): only its answer is the sheet's.
        QString saveHandle;
    };
    struct Ticket {
        QString appId;
        QString printer;
        print::Capabilities capabilities;
        print::Choices choices;
        // Save as PDF's file (Pending's), empty to print.
        QString pdfFolder;
        QString pdfName;
        QElapsedTimer age;
    };
    // A new token for `ticket`: random, not 0, not one in use.
    uint issue(const Ticket &ticket);
    // Drops the expired tokens; true when it dropped one.
    bool dropExpired();
    void printWithTicket(int id, const Ticket &ticket, const QString &title, int fd);

    PrintSystem *m_system;
    Options m_options;
    QHash<int, Pending> m_pending;
    QHash<uint, Ticket> m_tickets;
    // The Save panel each sheet opened (its handle), closed if the sheet's request ends first.
    QHash<int, QString> m_saving;
    // Set when Print goes: the writes still running stop and remove their temporary files.
    std::shared_ptr<std::atomic<bool>> m_stopWriting = std::make_shared<std::atomic<bool>>(false);
    int m_saves = 0;
    std::unique_ptr<QDBusConnection> m_panelBus;
};

// The interface on /org/freedesktop/portal/desktop (the object FileChooser is exported as; this adaptor is its child and
// calls into Print).
class PrintAdaptor : public QDBusAbstractAdaptor
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.Print")

public:
    PrintAdaptor(QObject *exported, Print *print);

public Q_SLOTS:
    uint PreparePrint(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                      const QVariantMap &settings, const QVariantMap &page_setup, const QVariantMap &options, const QDBusMessage &message,
                      QVariantMap &results);
    uint Print(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
               const QDBusUnixFileDescriptor &fd, const QVariantMap &options, const QDBusMessage &message, QVariantMap &results);

private:
    grassfield::portal::Print *m_print;
};

} // namespace grassfield::portal
