// Loads each SVG named on the command line with Qt's own renderer and fails when it logs anything (qt.svg warnings such as
// "Could not resolve property"), cannot be parsed, or renders nothing. Used by tests/shell/icon_svg_qt.sh over the composed
// icon theme: an icon Qt cannot read renders wrong in the shell and fills the journal on every load.
// Build: g++ -std=c++17 -fPIC $(pkg-config --cflags --libs Qt6Svg Qt6Gui Qt6Core) svgcheck.cpp
#include <QGuiApplication>
#include <QImage>
#include <QPainter>
#include <QString>
#include <QSvgRenderer>
#include <cstdio>

static QString lastWarning;
static void handler(QtMsgType, const QMessageLogContext &, const QString &msg) { lastWarning += msg + QLatin1Char('\n'); }

int main(int argc, char **argv)
{
    qputenv("QT_QPA_PLATFORM", "offscreen");
    QGuiApplication app(argc, argv);
    qInstallMessageHandler(handler);
    int bad = 0;
    for (int i = 1; i < argc; ++i) {
        lastWarning.clear();
        QSvgRenderer r;
        const bool ok = r.load(QString::fromLocal8Bit(argv[i]));
        if (ok) {
            QImage img(64, 64, QImage::Format_ARGB32);
            img.fill(0);
            QPainter p(&img);
            r.render(&p);
        }
        if (!ok || !lastWarning.isEmpty()) {
            ++bad;
            std::printf("BAD %s: %s%s", argv[i], ok ? "" : "does not load ", qPrintable(lastWarning));
            if (lastWarning.isEmpty()) std::printf("\n");
        }
    }
    std::printf("checked %d, bad %d\n", argc - 1, bad);
    return bad ? 1 : 0;
}
