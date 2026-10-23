#include <QApplication>
#include <QCommandLineParser>
#include <QDir>
#include <QQmlApplicationEngine>
#include <QUrl>

#include "translationloader.h"
#include "filesapp.h"
#include "globalmenu.h"
#include "windowchrome.h"
#include "imageproviders.h"

#ifndef GRASSFIELD_FILES_QML_DIR
#define GRASSFIELD_FILES_QML_DIR "/usr/share/grassfield/files/qml"
#endif
#ifndef GRASSFIELD_FILES_VERSION
#define GRASSFIELD_FILES_VERSION "0.1.0"
#endif

int main(int argc, char *argv[])
{
    // QApplication (not QGuiApplication): KIO's conflict, Open With and undo confirmation dialogs are widgets.
    QApplication app(argc, argv);
    // ADR-0015: windows that draw their own chrome (QML property gfChromeRole) are tagged for the compositor plugin.
    new grassfield::apps::ChromeTagger(&app);
    grassfield::i18n::installForApplication(); // English source; fr via grassfield_fr.qm
    app.setApplicationName(QStringLiteral("grassfield-files"));
    app.setApplicationDisplayName(QObject::tr("Files"));
    app.setApplicationVersion(QStringLiteral(GRASSFIELD_FILES_VERSION));
    app.setOrganizationName(QStringLiteral("Grassfield"));
    // Wayland app_id: matches org.grassfield.Files.desktop.
    app.setDesktopFileName(QStringLiteral("org.grassfield.Files"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QObject::tr("Browse and manage files"));
    parser.addHelpOption();
    parser.addVersionOption();
    parser.addPositionalArgument(QStringLiteral("locations"), QObject::tr("Folders or URLs to open, one window each."), QStringLiteral("[locations...]"));
    // --info: the Get Info window of each location instead of a browser window (the desktop's Get Info, macOS model).
    const QCommandLineOption infoOption(QStringLiteral("info"), QObject::tr("Show the Get Info window of each location."));
    parser.addOption(infoOption);
    parser.process(app);
    // --info shows its window only once the folder listing ended: KIO jobs hold quit locks, and the last one released with
    // no window open yet would quit the app before the window appears. It quits when its last window closes instead.
    if (parser.isSet(infoOption))
        app.setQuitLockEnabled(false);

    QList<QUrl> urls;
    const QStringList args = parser.positionalArguments();
    for (const QString &arg : args) {
        const QUrl url = QUrl::fromUserInput(arg, QDir::currentPath(), QUrl::AssumeLocalFile);
        if (url.isValid())
            urls << url;
    }

    // The backend outlives the engine (declared first, destroyed last): bindings that run while the engine tears the
    // windows down still see it.
    FilesApp files(urls);

    QQmlApplicationEngine engine;
    // Installed Grassfield.Ui lives in the system QML directory; QML_IMPORT_PATH adds the repo in dev.
    engine.addImportPath(QStringLiteral("/usr/lib/qt6/qml"));
    // addImportPath puts a path before the ones searched so far, so the system directory above would shadow the tree's own
    // Grassfield.Ui in a dev session (a new token or Appearance property would not exist): add QML_IMPORT_PATH after it, in
    // reverse so that its first entry is searched first (same as Preview).
    const QStringList devPaths = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
    for (auto it = devPaths.crbegin(); it != devPaths.crend(); ++it)
        engine.addImportPath(*it);
    engine.addImageProvider(QStringLiteral("icon"), new IconProvider);
    engine.addImageProvider(QStringLiteral("thumbnail"), new ThumbnailProvider);

    QString qmlDir = qEnvironmentVariable("GRASSFIELD_FILES_QML");
    if (qmlDir.isEmpty())
        qmlDir = QStringLiteral(GRASSFIELD_FILES_QML_DIR);

    // Global menu (T1): the windows export their menus only while the registrar is there (globalmenu.h).
    engine.setInitialProperties({{QStringLiteral("app"), QVariant::fromValue(&files)},
                                 {QStringLiteral("globalMenu"), grassfield::apps::globalMenuAvailable()},
                                 {QStringLiteral("infoOnly"), parser.isSet(infoOption)}});
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(QStringLiteral("Main.qml"))));
    if (engine.rootObjects().isEmpty())
        return 1;
    // The registrar may appear later (an app started before the bridge) or restart: the menus follow it.
    grassfield::apps::followGlobalMenu(engine.rootObjects().constFirst(), "globalMenu");
    return app.exec();
}
