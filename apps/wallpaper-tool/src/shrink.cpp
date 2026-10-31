// grassfield-wallpaper-shrink: build only (packaging/arch/PKGBUILD, ADR-0040 step 2c). Never installed, never run by the shell
// or Settings: the installed helper writes only into its own cache, and this tool writes where the build tells it.
//
//   grassfield-wallpaper-shrink --width W --quality Q --out FILE -- SRC
//
// Writes the downloaded photograph SRC to FILE no wider than W pixels, as a JPEG of quality Q, without the source's metadata
// (wallpaper::shrinkPicture). Exit 0 with "WxH" (the size written) on stdout; otherwise the helper's exit code and the reason
// on stderr, so the build stops.
#include <QCoreApplication>
#include <QTextStream>

#include "wallpaperlogic.h"

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    const QStringList a = app.arguments().mid(1);
    QTextStream err(stderr);
    if (a.size() != 8 || a.at(0) != QLatin1String("--width") || a.at(2) != QLatin1String("--quality") || a.at(4) != QLatin1String("--out")
        || a.at(6) != QLatin1String("--")) {
        err << "usage: grassfield-wallpaper-shrink --width W --quality Q --out FILE -- SRC\n";
        return wallpaper::Usage;
    }
    bool widthOk = false, qualityOk = false;
    const int width = a.at(1).toInt(&widthOk);
    const int quality = a.at(3).toInt(&qualityOk);
    if (!widthOk || !qualityOk) {
        err << "grassfield-wallpaper-shrink: --width and --quality take whole numbers\n";
        return wallpaper::Usage;
    }
    QSize written;
    const wallpaper::ExitCode code = wallpaper::shrinkPicture(a.at(7), a.at(5), width, quality, &written);
    if (code != wallpaper::Ok) {
        err << "grassfield-wallpaper-shrink: " << a.at(7) << ": failed with code " << int(code) << '\n';
        return code;
    }
    QTextStream(stdout) << written.width() << 'x' << written.height() << '\n';
    return wallpaper::Ok;
}
