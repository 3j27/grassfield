#include <QDBusConnection>
#include <QDBusMessage>
#include <QDir>
#include <QGuiApplication>
#include <QPointer>
#include <QQmlApplicationEngine>
#include <QUrl>
#include <QWindow>

#include "translationloader.h"
#include "backend.h"
#include "busjobs.h"
#include "globalmenu.h"
#include "iconprovider.h"
#include "settingsinstance.h"
#include "windowchrome.h"

#ifndef GRASSFIELD_SETTINGS_QML_DIR
#define GRASSFIELD_SETTINGS_QML_DIR "/usr/share/grassfield/settings/qml"
#endif
#ifndef GRASSFIELD_VERSION
#define GRASSFIELD_VERSION "unknown" // the real one comes from VERSION (cmake/GrassfieldVersion.cmake, build-direct.sh)
#endif

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    // Before any QML: no global menu item may hold Qt's first shortcut id (globalmenu.h).
    grassfield::apps::reserveFirstShortcutId(app);
    // ADR-0015: windows that draw their own chrome (QML property gfChromeRole) are tagged for the compositor plugin.
    new grassfield::apps::ChromeTagger(&app);
    grassfield::i18n::installForApplication(); // English source; fr via grassfield_fr.qm
    app.setApplicationName(QStringLiteral("Grassfield Settings")); // i18n-ignore: the application name
    app.setApplicationVersion(QStringLiteral(GRASSFIELD_VERSION));
    app.setOrganizationName(QStringLiteral("Grassfield"));
    // Wayland app_id: matches org.grassfield.Settings.desktop.
    app.setDesktopFileName(QStringLiteral("org.grassfield.Settings"));

    // --section=<id> opens that section first (screenshots, tests); unknown ids fall back to Appearance.
    // --about opens the About This Computer window (AboutWindow.qml, ADR-0040 ID-19; the shell's Grassfield menu).
    QString startSection;
    bool about = false;
    for (const QString &arg : app.arguments().mid(1)) {
        if (arg.startsWith(QLatin1String("--section=")))
            startSection = arg.mid(10);
        else if (arg == QLatin1String("--about"))
            about = true;
    }
    // One Settings per user (settingsinstance.h): a second launch hands its request and its activation token to the running
    // one and leaves. Without a session bus, or with no answer from the name's owner (stuck, or gone meanwhile), this one runs.
    using grassfield::settings::SettingsInstance;
    SettingsInstance instance;
    QDBusConnection bus = QDBusConnection::sessionBus();
    if (bus.isConnected()) {
        bus.registerObject(SettingsInstance::objectPath(), &instance, QDBusConnection::ExportScriptableSlots);
        if (!bus.registerService(SettingsInstance::serviceName())) {
            const QString method = about ? QStringLiteral("About") : QStringLiteral("Open"); // i18n-ignore: D-Bus methods
            QDBusMessage call = QDBusMessage::createMethodCall(SettingsInstance::serviceName(), SettingsInstance::objectPath(),
                                                               SettingsInstance::interfaceName(), method);
            if (!about)
                call << startSection;
            call << qEnvironmentVariable("XDG_ACTIVATION_TOKEN");
            const QDBusMessage reply = bus.call(call, QDBus::Block, 2000);
            if (reply.type() == QDBusMessage::ReplyMessage)
                return 0;
        }
    }

    // The backend outlives the engine (declared first, destroyed last): bindings that run while the engine tears the
    // window down still see it.
    Backend backend;

    QQmlApplicationEngine engine;
    // Installed Grassfield.Ui lives in the system QML directory; QML_IMPORT_PATH adds the repo in dev.
    engine.addImportPath(QStringLiteral("/usr/lib/qt6/qml"));
    // addImportPath puts a path before the ones searched so far, so the system directory above would shadow the tree's own
    // Grassfield.Ui in a dev session (a new token or Appearance property would not exist): add QML_IMPORT_PATH after it, in
    // reverse so that its first entry is searched first (same as Preview).
    const QStringList devPaths = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
    for (auto it = devPaths.crbegin(); it != devPaths.crend(); ++it)
        engine.addImportPath(*it);

    // GRASSFIELD_SETTINGS_QML overrides the QML directory (dev); the default is baked in at build time.
    QString qmlDir = qEnvironmentVariable("GRASSFIELD_SETTINGS_QML");
    if (qmlDir.isEmpty())
        qmlDir = QStringLiteral(GRASSFIELD_SETTINGS_QML_DIR);

    // Login Items: the applications' icons (the engine owns the provider).
    engine.addImageProvider(QStringLiteral("icon"), new IconProvider);
    // A window that cannot be made leaves the app only when it has no other.
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app,
        [&engine] {
            if (engine.rootObjects().isEmpty())
                QCoreApplication::exit(1);
        },
        Qt::QueuedConnection);

    // The two windows, each made when first asked for and then kept: closing one hides it, and the app quits when the last
    // shown one closes.
    QPointer<QWindow> settingsWindow;
    QPointer<QWindow> aboutWindow;
    const auto load = [&engine, &qmlDir](const QString &file, const QVariantMap &properties) -> QWindow * {
        engine.setInitialProperties(properties);
        const auto before = engine.rootObjects().size();
        engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(file)));
        return engine.rootObjects().size() > before ? qobject_cast<QWindow *>(engine.rootObjects().constLast()) : nullptr;
    };
    // The Settings window, on `section` when one is given (an unknown one falls back to Appearance).
    const auto showSettings = [&](const QString &section, const QString &token) {
        if (!settingsWindow) {
            // Global menu (T1): the window exports its menus only while the registrar is there (globalmenu.h).
            settingsWindow = load(QStringLiteral("Main.qml"), {{QStringLiteral("backend"), QVariant::fromValue(&backend)},
                                                               {QStringLiteral("globalMenu"), grassfield::apps::globalMenuAvailable()},
                                                               {QStringLiteral("startSection"), section}});
            // The registrar may appear later (an app started before the bridge) or restart: the menus follow it.
            grassfield::apps::followGlobalMenu(settingsWindow, "globalMenu");
            if (settingsWindow && !token.isEmpty())
                grassfield::settings::activateWindow(settingsWindow, token);
            return;
        }
        if (!section.isEmpty())
            QMetaObject::invokeMethod(settingsWindow.data(), "select", Q_ARG(QString, section));
        grassfield::settings::activateWindow(settingsWindow, token);
    };
    // About This Computer: it maps itself once its facts are in (ADR-0040 P-2); asked again meanwhile, it is still coming.
    const auto showAbout = [&](const QString &token) {
        if (!aboutWindow) {
            aboutWindow = load(QStringLiteral("AboutWindow.qml"), {{QStringLiteral("backend"), QVariant::fromValue(&backend)},
                                                                  {QStringLiteral("instance"), QVariant::fromValue(&instance)}});
            return;
        }
        if (aboutWindow->property("ready").toBool())
            grassfield::settings::activateWindow(aboutWindow, token);
    };
    QObject::connect(&instance, &SettingsInstance::settingsRequested, &app, showSettings);
    QObject::connect(&instance, &SettingsInstance::aboutRequested, &app, showAbout);

    if (about)
        showAbout(QString());
    else
        showSettings(startSection, QString());
    if (engine.rootObjects().isEmpty()) {
        grassfield::settings::BusJobs::setExitCode(1); // the same code if a D-Bus job were abandoned on the way out
        return 1;
    }
    const int code = app.exec();
    grassfield::settings::BusJobs::setExitCode(code); // a D-Bus job stuck at exit abandons the process with the app's own code
    return code;
}
