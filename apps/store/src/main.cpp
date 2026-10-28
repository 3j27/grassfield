#include <QCommandLineParser>
#include <QDir>
#include <QFileInfo>
#include <QGuiApplication>
#include <QImageReader>
#include <QLibraryInfo>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <QUrl>

#include <memory>

#include "globalmenu.h"
#include "screenshotprovider.h"
#include "storebackend.h"
#include "translationloader.h"
#include "windowchrome.h"

#ifndef GRASSFIELD_STORE_QML_DIR
#define GRASSFIELD_STORE_QML_DIR "/usr/share/grassfield/store/qml"
#endif
#ifndef GRASSFIELD_VERSION
#define GRASSFIELD_VERSION "unknown" // the real one comes from VERSION (cmake/GrassfieldVersion.cmake, build-direct.sh)
#endif

int main(int argc, char *argv[])
{
    // The Grassfield controls style for this app only when it is installed, the Basic style otherwise (as Preview, GF-085).
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE")) {
        QStringList roots = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
        roots += qEnvironmentVariable("QML2_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
        roots << QLibraryInfo::path(QLibraryInfo::QmlImportsPath);
        bool installed = false;
        for (const QString &root : std::as_const(roots))
            installed = installed || QFileInfo::exists(root + QStringLiteral("/Grassfield/qmldir"));
        qputenv("QT_QUICK_CONTROLS_STYLE", installed ? "Grassfield" : "Basic");
        if (installed && qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_FALLBACK_STYLE"))
            qputenv("QT_QUICK_CONTROLS_FALLBACK_STYLE", "Basic");
    }
    // Icons and screenshots come from third parties: every decoder (QML Image included) is bounded to this much memory.
    QImageReader::setAllocationLimit(128);

    QGuiApplication app(argc, argv);
    // Before any QML: no global menu item may hold Qt's first shortcut id (globalmenu.h).
    grassfield::apps::reserveFirstShortcutId(app);
    // ADR-0015: the window draws its own chrome (QML property gfChromeRole), tagged for the compositor plugin.
    new grassfield::apps::ChromeTagger(&app);
    grassfield::i18n::installForApplication(); // English source; fr via grassfield_fr.qm
    app.setApplicationName(QStringLiteral("grassfield-store"));
    app.setApplicationVersion(QStringLiteral(GRASSFIELD_VERSION));
    app.setOrganizationName(QStringLiteral("Grassfield"));
    app.setDesktopFileName(QStringLiteral("org.grassfield.Store")); // Wayland app_id: org.grassfield.Store.desktop

    QCommandLineParser parser;
    parser.setApplicationDescription(QObject::tr("Find, read about and open apps for Grassfield."));
    parser.addHelpOption();
    parser.addVersionOption();
    const QCommandLineOption pageOption(QStringLiteral("page"),
                                        QObject::tr("Open this page first: discover, section:<id>, categories, category:<id>, app:<id>, "
                                                    "search:<words>, installed or updates."),
                                        QStringLiteral("page"));
    parser.addOption(pageOption);
    parser.process(app);

    // The backend outlives the engine (declared first, destroyed last): bindings that run while the engine tears the
    // window down still see it.
    grassfield::store::StoreBackend backend;

    QQmlApplicationEngine engine;
    // Installed Grassfield.Ui lives in the system QML directory; QML_IMPORT_PATH (the tree's ui/ in a dev session) is
    // added after it in reverse, so that its first entry is searched first (as Preview).
    engine.addImportPath(QStringLiteral("/usr/lib/qt6/qml"));
    const QStringList devPaths = qEnvironmentVariable("QML_IMPORT_PATH").split(QDir::listSeparator(), Qt::SkipEmptyParts);
    for (auto it = devPaths.crbegin(); it != devPaths.crend(); ++it)
        engine.addImportPath(*it);
    engine.addImageProvider(QStringLiteral("screenshot"), new grassfield::store::ScreenshotProvider(backend.screenshotGate()));

    QString qmlDir = qEnvironmentVariable("GRASSFIELD_STORE_QML");
    if (qmlDir.isEmpty())
        qmlDir = QStringLiteral(GRASSFIELD_STORE_QML_DIR);
    engine.setInitialProperties({{QStringLiteral("backend"), QVariant::fromValue(&backend)},
                                 {QStringLiteral("globalMenu"), grassfield::apps::globalMenuAvailable()},
                                 {QStringLiteral("startPage"), parser.value(pageOption)}});
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(QStringLiteral("Main.qml"))));
    if (engine.rootObjects().isEmpty())
        return 1;
    grassfield::apps::followGlobalMenu(engine.rootObjects().constFirst(), "globalMenu");
    // The last window closed while an operation runs: the Store stays until it ends (ADR-0037 f; it holds Omarchy's update
    // lock and keeps the result), then quits.
    app.setQuitOnLastWindowClosed(false);
    QObject::connect(&app, &QGuiApplication::lastWindowClosed, &backend, &grassfield::store::StoreBackend::quitWhenIdle);
    // The first load starts once the window has its first frame: the window never waits for pacman or AppStream.
    auto *window = qobject_cast<QQuickWindow *>(engine.rootObjects().constFirst());
    if (window) {
        auto started = std::make_shared<bool>(false);
        QObject::connect(window, &QQuickWindow::frameSwapped, &backend, [&backend, started] {
            if (*started)
                return;
            *started = true;
            backend.start();
        });
    } else {
        backend.start();
    }
    return app.exec();
}
