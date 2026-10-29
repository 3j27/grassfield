// grassfield-portal (ADR-0035 D-4, D-5; steps 4b and 5a): the Open and Save panels and the permission alerts of the Grassfield
// session, served to xdg-desktop-portal as org.freedesktop.impl.portal.FileChooser and org.freedesktop.impl.portal.Access
// under org.freedesktop.impl.portal.desktop.grassfield. Started by D-Bus activation (grassfield-portal.service), it quits 60 s
// after its last request. The panels are the Files browser: this binary links the Files library (apps/files/files-core.cmake)
// and loads Files' QML (FilePanels.qml), so a panel has the sidebar, views, path pop-up, search, Quick Look and KIO sheets of
// Grassfield Files; the alerts are AccessAlerts.qml, next to it.
#include "access.h"
#include "appicons.h"
#include "applicationslogic.h"
#include "filechooser.h"
#include "filesapp.h"
#include "imageproviders.h"
#include "panelstate.h"
#include "runmode.h"
#include "testbus.h"
#include "translationloader.h"
#include "windowchrome.h"

#include <QApplication>
#include <QDBusConnection>
#include <QDir>
#include <QQmlApplicationEngine>
#include <QUrl>

#include <wayland-client-core.h>

#include <cstdio>
#include <memory>

#ifndef GRASSFIELD_FILES_QML_DIR
#define GRASSFIELD_FILES_QML_DIR "/usr/share/grassfield/files/qml"
#endif
#ifndef GRASSFIELD_VERSION
#define GRASSFIELD_VERSION "unknown"
#endif

namespace {

// Whether a Qt GUI can start here: a platform named by QT_QPA_PLATFORM (the tests' offscreen), or a Wayland display that
// answers. Without one, QApplication would abort the process; the backend then runs without panels and forwards every call
// to x-d-p-gtk (D-4: the UI that cannot start).
bool guiAvailable()
{
    if (!qEnvironmentVariableIsEmpty("QT_QPA_PLATFORM"))
        return true;
    if (qEnvironmentVariableIsEmpty("WAYLAND_DISPLAY"))
        return false;
    wl_display *display = wl_display_connect(nullptr);
    if (!display)
        return false;
    wl_display_disconnect(display);
    return true;
}

} // namespace

int main(int argc, char *argv[])
{
    namespace runmode = grassfield::apps::runmode;
    // The icon decoder child (AppIcons::loadIsolated runs this binary, as in Files): decode stdin to a PNG on stdout and
    // nothing else, never a second backend.
    if (AppIcons::isDecodeChildInvocation(argc, argv))
        return AppIcons::decodeChildMain(argc, argv);
    // D-4's start-up loop: a platform theme that reads the portal (gtk3 with GTK_USE_PORTAL=1) could wait on the frontend that
    // waits on this process. The panels draw with Grassfield.Ui and need none (the unit clears it too).
    qunsetenv("QT_QPA_PLATFORMTHEME");
    const bool gui = guiAvailable();
    // QApplication (not QGuiApplication): KIO's widgets library (KDirLister, its job delegate class) expects one; its
    // dialogs are not used (Grassfield's sheets, ADR-0035 D-12 a).
    std::unique_ptr<QCoreApplication> app(gui ? new QApplication(argc, argv) : new QCoreApplication(argc, argv));
    // It quits when idle (FileChooser::idle), never because its last panel closed or KIO's last job released its quit lock.
    QCoreApplication::setQuitLockEnabled(false);
    if (gui)
        QGuiApplication::setQuitOnLastWindowClosed(false);
    QCoreApplication::setApplicationName(QStringLiteral("grassfield-portal"));
    QCoreApplication::setOrganizationName(QStringLiteral("Grassfield"));
    QCoreApplication::setApplicationVersion(QStringLiteral(GRASSFIELD_VERSION));
    if (!runmode::session() && !runmode::dev()) {
        std::fputs("grassfield-portal: refused: not a Grassfield session\n", stderr);
        return 2;
    }
    // A dev run (the tests) never serves the user's own bus, where it could take the name from the real backend.
    if (runmode::dev()
        && (qgetenv("GF_TEST_BUS") != "1"
            || !grassfield::apps::isPrivateTestBus(qEnvironmentVariable("DBUS_SESSION_BUS_ADDRESS"), qEnvironmentVariable("GF_TEST_BUS_DIR")))) {
        std::fputs("grassfield-portal: refused: a dev session runs it only on a private test bus (GF_TEST_BUS=1, GF_TEST_BUS_DIR)\n", stderr);
        return 2;
    }

    QDBusConnection bus = QDBusConnection::sessionBus();
    if (!bus.isConnected()) {
        std::fputs("grassfield-portal: no session bus\n", stderr);
        return 1;
    }

    grassfield::portal::PanelState state(runmode::stateDir() + QStringLiteral("/portal-filechooser.json"));
    grassfield::portal::FileChooser::Options options;
    options.state = &state;
    // Dev plumbing (ADR-0019), honoured only in a dev session: the tests shorten the waits.
    if (const int ms = runmode::devValue("PORTAL_UI_DEADLINE_MS").toInt(); ms > 0)
        options.uiDeadlineMs = ms;
    if (const int ms = runmode::devValue("PORTAL_IDLE_MS").toInt(); ms > 0)
        options.idleQuitMs = ms;
    grassfield::portal::Access::Options accessOptions;
    accessOptions.uiDeadlineMs = options.uiDeadlineMs;
    accessOptions.idleQuitMs = options.idleQuitMs;
    const QString serviceName = QStringLiteral("org.freedesktop.impl.portal.desktop.grassfield");
    // Access first: it outlives FileChooser and the Access adaptor FileChooser's object owns.
    grassfield::portal::Access access(bus, accessOptions);
    grassfield::portal::FileChooser chooser(bus, options);
    new grassfield::portal::FileChooserAdaptor(&chooser);
    // Both interfaces live on the one exported object (FileChooser's).
    new grassfield::portal::AccessAdaptor(&chooser, &access);
    // Idle once both interfaces have had no request for the idle time (each one's idle() asks): the name goes first, so a
    // call on its way starts a new instance (D-Bus activation) instead of reaching one that is quitting; a call that reached
    // this one before (it comes ahead of ReleaseName's reply) is served, the name taken back. Under systemd the unit
    // (Type=dbus) stops once the name goes, which takes such a call with it: response 2, the window a few microseconds every
    // idle period (review of step 4b, MINOR 6).
    const QList<const grassfield::portal::RequestHost *> hosts{&chooser, &access};
    const auto quietLongEnough = [&]() { return grassfield::portal::RequestHost::quiet(hosts, options.idleQuitMs); };
    const auto quitWhenIdle = [&]() {
        if (!quietLongEnough())
            return;
        bus.unregisterService(serviceName);
        QMetaObject::invokeMethod(app.get(), [&]() {
            if (quietLongEnough())
                QCoreApplication::quit();
            else
                bus.registerService(serviceName);
        }, Qt::QueuedConnection);
    };
    QObject::connect(&chooser, &grassfield::portal::FileChooser::idle, app.get(), quitWhenIdle);
    QObject::connect(&access, &grassfield::portal::Access::idle, app.get(), quitWhenIdle);

    // Each interface's UI is made at its first request (the frontend starts every backend when it starts; an idle start costs
    // no QML): one engine, made with the first of them; the panels' root (with the Files backend) and the alerts' root are
    // loaded apart, so that one that fails never sends the other's calls to x-d-p-gtk. The Files backend outlives the engine:
    // bindings that run while the engine tears the windows down still see it.
    std::unique_ptr<FilesApp> files;
    std::unique_ptr<QQmlApplicationEngine> engine;
    QString qmlDir;
    QString testAnswer;
    const auto makeEngine = [&]() {
        if (engine)
            return;
        grassfield::i18n::installForApplication();
        // Windows that draw their own chrome are tagged for the compositor plugin (ADR-0015): the panels draw a sheet's, the
        // alerts an alert's.
        new grassfield::apps::ChromeTagger(app.get());
        engine = std::make_unique<QQmlApplicationEngine>();
        engine->addImportPath(QStringLiteral("/usr/lib/qt6/qml"));
        const QStringList devPaths = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
        for (auto it = devPaths.crbegin(); it != devPaths.crend(); ++it)
            engine->addImportPath(*it);
        engine->addImageProvider(QStringLiteral("icon"), new IconProvider);
        engine->addImageProvider(QStringLiteral("appicon"), new AppIconProvider);
        // As in Files: the icon decoders and the walks of the applications end before Qt's shutdown.
        QObject::connect(app.get(), &QCoreApplication::aboutToQuit, app.get(), [] {
            AppIconProvider::shutdown();
            ApplicationsLogic::waitForListings(3500);
        });
        engine->addImageProvider(QStringLiteral("thumbnail"), new ThumbnailProvider);
        qmlDir = runmode::devValue("FILES_QML");
        if (qmlDir.isEmpty())
            qmlDir = QStringLiteral(GRASSFIELD_FILES_QML_DIR);
        testAnswer = runmode::devValue("PORTAL_TEST_ANSWER");
    };
    // Loads one root; whether it loaded.
    const auto loadRoot = [&](const QString &file, const QVariantMap &properties) -> bool {
        const qsizetype before = engine->rootObjects().size();
        engine->setInitialProperties(properties);
        engine->load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(file)));
        if (engine->rootObjects().size() == before) {
            qWarning("grassfield-portal: %s did not load; its requests go to x-d-p-gtk", qPrintable(file));
            return false;
        }
        return true;
    };
    if (gui) {
        chooser.setUiLoader([&]() -> bool {
            makeEngine();
            files = std::make_unique<FilesApp>(QList<QUrl>());
            return loadRoot(QStringLiteral("FilePanels.qml"), {{QStringLiteral("app"), QVariant::fromValue(files.get())},
                                                               {QStringLiteral("host"), QVariant::fromValue(&chooser)},
                                                               {QStringLiteral("testAnswer"), testAnswer}});
        });
        access.setUiLoader([&]() -> bool {
            makeEngine();
            return loadRoot(QStringLiteral("AccessAlerts.qml"), {{QStringLiteral("host"), QVariant::fromValue(&access)},
                                                                 {QStringLiteral("testAnswer"), testAnswer}});
        });
    } else {
        qWarning("grassfield-portal: no display; every request goes to x-d-p-gtk");
    }

    // The object first, then the name: a caller that sees the name always finds the object.
    if (!bus.registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), &chooser, QDBusConnection::ExportAdaptors)) {
        std::fputs("grassfield-portal: cannot export the FileChooser object\n", stderr);
        return 1;
    }
    if (!bus.registerService(serviceName)) {
        std::fputs("grassfield-portal: the bus name is taken\n", stderr);
        return 1;
    }
    const int code = app->exec();
    // The windows go, then the Files backend the panels used; requests still open end with an error after them, at the return,
    // when RequestHost's destructor answers them.
    engine.reset();
    files.reset();
    return code;
}
