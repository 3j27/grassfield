#include <QCommandLineParser>
#include <QDir>
#include <QGuiApplication>
#include <QImageReader>
#include <QQmlApplicationEngine>
#include <QTextStream>
#include <QUrl>

#include "translationloader.h"
#include "globalmenu.h"
#include "previewapp.h"
#include "previewlogic.h"

#ifndef GRASSFIELD_PREVIEW_QML_DIR
#define GRASSFIELD_PREVIEW_QML_DIR "/usr/share/grassfield/preview/qml"
#endif
#ifndef GRASSFIELD_PREVIEW_VERSION
#define GRASSFIELD_PREVIEW_VERSION "0.1.0"
#endif

int main(int argc, char *argv[])
{
    // QtPdf's views are Qt Quick Controls; the Basic style draws nothing of its own that we do not restyle.
    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE"))
        qputenv("QT_QUICK_CONTROLS_STYLE", "Basic");
    // Untrusted images: bound every decoder (also QML Image and AnimatedImage) to this much memory.
    QImageReader::setAllocationLimit(preview::kAllocationLimitMb);

    QGuiApplication app(argc, argv);
    grassfield::i18n::installForApplication(); // English source; fr via grassfield_fr.qm
    app.setApplicationName(QStringLiteral("grassfield-preview"));
    app.setApplicationVersion(QStringLiteral(GRASSFIELD_PREVIEW_VERSION));
    app.setOrganizationName(QStringLiteral("Grassfield"));

    QCommandLineParser parser;
    parser.setApplicationDescription(QObject::tr("View images, PDF documents, text, audio and video (read only)"));
    parser.addHelpOption();
    parser.addVersionOption();
    const QCommandLineOption glanceOption(QStringLiteral("glance"), QObject::tr("Show a quick, floating look at the files (Space or Esc closes it)."));
    parser.addOption(glanceOption);
    parser.addPositionalArgument(QStringLiteral("files"), QObject::tr("Local files or file: URLs."), QStringLiteral("[files...]"));
    parser.process(app);

    const bool glance = parser.isSet(glanceOption);
    // Wayland app_id: matches org.grassfield.Preview.desktop; Glance has its own (window rule).
    app.setDesktopFileName(glance ? QStringLiteral("org.grassfield.Preview.Glance") : QStringLiteral("org.grassfield.Preview"));

    const preview::Arguments args = preview::resolveArguments(parser.positionalArguments(), QDir::currentPath());
    QTextStream err(stderr);
    for (const QString &message : args.errors)
        err << "grassfield-preview: " << message << Qt::endl;

    // The backend outlives the engine (declared first, destroyed last): bindings that run while the engine tears the
    // windows down still see it (no TypeError on close).
    PreviewApp backend(args.paths, args.errors, glance);

    QQmlApplicationEngine engine;
    // Installed Grassfield.Ui lives in the system QML directory; QML_IMPORT_PATH adds the repo in dev.
    engine.addImportPath(QStringLiteral("/usr/lib/qt6/qml"));
    engine.addImageProvider(QStringLiteral("preview"), new PreviewImageProvider(&backend));

    QString qmlDir = qEnvironmentVariable("GRASSFIELD_PREVIEW_QML");
    if (qmlDir.isEmpty())
        qmlDir = QStringLiteral(GRASSFIELD_PREVIEW_QML_DIR);

    QVariantMap initial{{QStringLiteral("backend"), QVariant::fromValue(&backend)}};
    // Global menu (T1): the viewer exports its menus only when the registrar is there (globalmenu.h). A Glance is a
    // panel without menus of its own.
    if (!glance)
        initial.insert(QStringLiteral("globalMenu"), grassfield::apps::globalMenuAvailable());
    engine.setInitialProperties(initial);
    QObject::connect(
        &engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] { QCoreApplication::exit(1); }, Qt::QueuedConnection);
    engine.load(QUrl::fromLocalFile(QDir(qmlDir).absoluteFilePath(glance ? QStringLiteral("Glance.qml") : QStringLiteral("Viewer.qml"))));
    if (engine.rootObjects().isEmpty())
        return 1;
    return app.exec();
}
