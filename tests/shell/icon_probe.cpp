// Probe for tests/shell/icon_theme.sh: prints the Qt icon theme name and, per argument, the colour of the centre pixel of
// QIcon::fromTheme(name) (solid-colour fixture icons) or "-" when no icon resolves. An argument "cmp:<name>=<file>" prints
// "<name>=same" when QIcon::fromTheme(name) at 16 and 48 px is pixel for pixel the image of <file>, "<name>=diff" when it is another
// picture, "<name>=-" when nothing resolves (the shadowed device glyphs of the wrapper theme).
// The offscreen platform has no icon search paths of its own (a Wayland or xcb session gets XDG_DATA_DIRS/icons from its
// generic Unix platform theme), so the probe sets them from XDG_DATA_DIRS the same way.
#include <QGuiApplication>
#include <QIcon>
#include <QImage>
#include <cstdio>

int main(int argc, char **argv)
{
    QGuiApplication app(argc, argv);
    QStringList paths;
    const auto dirs = qEnvironmentVariable("XDG_DATA_DIRS").split(u':', Qt::SkipEmptyParts);
    for (const QString &d : dirs)
        paths << d + QStringLiteral("/icons");
    QIcon::setThemeSearchPaths(paths);
    std::printf("theme=%s\n", QIcon::themeName().toUtf8().constData());
    for (int i = 1; i < argc; ++i) {
        const QString arg = QString::fromUtf8(argv[i]);
        if (arg.startsWith(QStringLiteral("cmp:"))) {
            const int eq = arg.indexOf(u'=');
            const QString name = arg.mid(4, eq - 4);
            const QIcon themed = QIcon::fromTheme(name);
            const QIcon file(arg.mid(eq + 1));
            QString verdict = QStringLiteral("-");
            if (!themed.isNull()) {
                verdict = QStringLiteral("same");
                for (const int size : {16, 48}) {
                    if (themed.pixmap(size).toImage() != file.pixmap(size).toImage())
                        verdict = QStringLiteral("diff");
                }
            }
            std::printf("%s=%s\n", name.toUtf8().constData(), verdict.toUtf8().constData());
            continue;
        }
        const QIcon icon = QIcon::fromTheme(arg);
        const QImage image = icon.pixmap(16).toImage();
        const QString colour = image.isNull() ? QStringLiteral("-") : image.pixelColor(8, 8).name();
        std::printf("%s=%s\n", argv[i], colour.toUtf8().constData());
    }
    return 0;
}
