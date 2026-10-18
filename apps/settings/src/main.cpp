#include <QDir>
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QUrl>

#include "translationloader.h"
#include "backend.h"
#include "globalmenu.h"

#ifndef GRASSFIELD_SETTINGS_QML_DIR
#define GRASSFIELD_SETTINGS_QML_DIR "/usr/share/grassfield/settings/qml"
#endif
#ifndef GRASSFIELD_SETTINGS_VERSION
#define GRASSFIELD_SETTINGS_VERSION "0.1.0"
#endif

int main(int argc, char *argv[])
{
    QGuiApplication app(argc, argv);
    grassfield::i18n::installForApplication(); // English source; fr via grassfield_fr.qm
    app.setApplicationName(QStringLiteral("Grassfield Settings"));
    app.setApplicationVersion(QStringLiteral(GRASSFIELD_SETTINGS_VERSION));
    app.setOrganizationName(QStringLiteral("Grassfield"));
    // Wayland app_id: matches org.grassfield.Settings.desktop.
    app.setDesktopFileName(QStringLiteral("org.grassfield.Settings"));

    // The backend outlives the engine (declared first, destroyed last): bindings that run while the engine tears the
    // window down still see it.
    Backend backend;

    QQmlApplicationEngine engine;
    // Installed Grassfield.Ui lives in the system QML directory; QML_IMPORT_PATH adds the repo in dev.
    engine.addImportPath(QStringLiteral("/usr/lib/qt6/qml"));

    // GRASSFIELD_SETTINGS_QML overrides the QML directory (dev); the default is baked in at build time.
    QString qmlDir = qEnvironmentVariable("GRASSFIELD_SETTINGS_QML");
    if (qmlDir.isEmpty())
        qmlDir = QStringLiteral(GRASSFIELD_SETTINGS_QML_DIR);

    // Global menu (T1): the window exports its menus only when the registrar is there (globalmenu.h).
    engine.setInitialProperties({{"backend", QVariant::fromValue(&backend)}, {"globalMenu", grassfield::apps::globalMenuAvailable()}});

    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); },
        Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(QStringLiteral("Main.qml"))));
    if (engine.rootObjects().isEmpty())
        return 1;
    return app.exec();
}
