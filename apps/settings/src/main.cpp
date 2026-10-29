#include <QDir>
#include <QGuiApplication>
#include <QLockFile>
#include <QQmlApplicationEngine>
#include <QUrl>
#include <QWindow>

#include "translationloader.h"
#include "backend.h"
#include "busjobs.h"
#include "globalmenu.h"
#include "iconprovider.h"
#include "runmode.h"
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
    // --about opens the About This Computer window alone (AboutWindow.qml, ADR-0040 ID-19; the shell's Grassfield menu).
    QString startSection;
    bool about = false;
    for (const QString &arg : app.arguments().mid(1)) {
        if (arg.startsWith(QLatin1String("--section=")))
            startSection = arg.mid(10);
        else if (arg == QLatin1String("--about"))
            about = true;
    }
    // One About window per user (macOS): a second --about while one is open leaves at once (the shell brings the open one
    // forward). The lock lives in the state directory (a dev session's own, ADR-0019) and goes with the window, so a Settings
    // window that More Info… opened may stay without holding it; a crashed holder's lock is stale and taken over. Declared before
    // the engine, so it outlives the window whose closing releases it.
    QLockFile aboutLock(grassfield::apps::runmode::stateDir() + QStringLiteral("/settings-about.lock"));
    if (about) {
        QDir().mkpath(grassfield::apps::runmode::stateDir());
        if (!aboutLock.tryLock(0)) {
            qInfo("grassfield-settings: About This Computer is open already");
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
    // Global menu (T1): the window exports its menus only while the registrar is there (globalmenu.h). The About window has
    // no section to start on.
    QVariantMap initial{{"backend", QVariant::fromValue(&backend)}, {"globalMenu", grassfield::apps::globalMenuAvailable()}};
    if (!about)
        initial.insert(QStringLiteral("startSection"), startSection);
    engine.setInitialProperties(initial);

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); },
        Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(about ? QStringLiteral("AboutWindow.qml") : QStringLiteral("Main.qml"))));
    if (engine.rootObjects().isEmpty()) {
        grassfield::settings::BusJobs::setExitCode(1); // the same code if a D-Bus job were abandoned on the way out
        return 1;
    }
    if (about) {
        if (auto *window = qobject_cast<QWindow *>(engine.rootObjects().constFirst())) {
            QObject::connect(window, &QWindow::visibleChanged, window, [&aboutLock](bool shown) {
                if (!shown)
                    aboutLock.unlock();
            });
        }
    }
    // The registrar may appear later (an app started before the bridge) or restart: the menus follow it.
    grassfield::apps::followGlobalMenu(engine.rootObjects().constFirst(), "globalMenu");
    const int code = app.exec();
    grassfield::settings::BusJobs::setExitCode(code); // a D-Bus job stuck at exit abandons the process with the app's own code
    return code;
}
