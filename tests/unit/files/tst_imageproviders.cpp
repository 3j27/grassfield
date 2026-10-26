// Unit tests for apps/files/src/imageproviders.h: the threading contract of the two icon providers (round 3 review of the
// Applications location). image://icon (theme names) must be a synchronous Pixmap provider: an asynchronous one is called on
// Qt's image-loader thread for EVERY request and its QIcon use raced with the GUI thread's QIcon::hasThemeIcon (FolderModel,
// PlacesModel) - a segfault in 4 of 4 stress runs. Only image://appicon (absolute paths) may be asynchronous, and it never
// uses QIcon off the GUI thread. Run with QT_QPA_PLATFORM=offscreen (tst_appicons.cpp's environment sets it).
#include <gtest/gtest.h>

#include <QBuffer>
#include <QCoreApplication>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QIcon>
#include <QImage>
#include <QQuickImageProvider>
#include <QEventLoop>
#include <QTimer>
#include <QTemporaryDir>

#include <memory>
#include <sys/stat.h>

#include "imageproviders.h"

namespace
{
QString writePng(const QString &path)
{
    QImage image(16, 16, QImage::Format_ARGB32);
    image.fill(Qt::green);
    image.save(path, "PNG");
    return path;
}

// Records finished() from the moment it is made (the signal must not be missed while other events are processed).
class Spy
{
public:
    explicit Spy(QQuickImageResponse *response)
    {
        QObject::connect(response, &QQuickImageResponse::finished, response, [this] {
            m_done = true;
            m_loop.quit();
        });
    }
    bool wait(int ms = 5000)
    {
        if (!m_done) {
            QTimer::singleShot(ms, &m_loop, &QEventLoop::quit);
            m_loop.exec();
        }
        return m_done;
    }

private:
    bool m_done = false;
    QEventLoop m_loop;
};
} // namespace

TEST(ImageProviders, TheThemeProviderIsSynchronousOnTheGuiThread)
{
    IconProvider theme;
    EXPECT_EQ(theme.imageType(), QQuickImageProvider::Pixmap);
    EXPECT_FALSE(theme.flags().testFlag(QQuickImageProvider::ForceAsynchronousImageLoading));
    AppIconProvider files;
    EXPECT_EQ(files.imageType(), QQuickImageProvider::ImageResponse);
}

TEST(ImageProviders, AnIconFileIsDecodedAndEveryRequestIsFinished)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString root = QFileInfo(tmp.path()).canonicalFilePath();
    const QString good = writePng(root + QStringLiteral("/good.png"));
    const QString fifo = root + QStringLiteral("/icon.fifo");
    ASSERT_EQ(::mkfifo(QFile::encodeName(fifo).constData(), 0600), 0);
    QFile evil(root + QStringLiteral("/evil.svg"));
    ASSERT_TRUE(evil.open(QIODevice::WriteOnly));
    evil.write("<svg xmlns=\"http://www.w3.org/2000/svg\" xmlns:xlink=\"http://www.w3.org/1999/xlink\" width=\"8\" height=\"8\">"
               "<image width=\"8\" height=\"8\" xlink:href=\"#icon.fifo\"/></svg>");
    evil.close();

    AppIconProvider provider;
    std::unique_ptr<QQuickImageResponse> ok(provider.requestImageResponse(good, QSize(32, 32)));
    Spy okSpy(ok.get());
    ASSERT_TRUE(okSpy.wait());
    std::unique_ptr<QQuickTextureFactory> factory(ok->textureFactory());
    ASSERT_TRUE(factory);
    EXPECT_EQ(factory->image().size(), QSize(16, 16));

    // A refused file (a FIFO, an SVG naming one) is still answered, at once, with no blocked worker.
    QElapsedTimer timer;
    timer.start();
    std::unique_ptr<QQuickImageResponse> a(provider.requestImageResponse(fifo, QSize(32, 32)));
    std::unique_ptr<QQuickImageResponse> b(provider.requestImageResponse(evil.fileName(), QSize(32, 32)));
    Spy aSpy(a.get()), bSpy(b.get());
    EXPECT_TRUE(aSpy.wait());
    EXPECT_TRUE(bSpy.wait());
    EXPECT_LT(timer.elapsed(), 3000);

    // A cancelled response is finished too (Qt requires it).
    std::unique_ptr<QQuickImageResponse> c(provider.requestImageResponse(good, QSize(32, 32)));
    Spy cSpy(c.get());
    c->cancel();
    EXPECT_TRUE(cSpy.wait());
}

TEST(ImageProviders, TheGuiThreadsThemeLookupsRunBesideManyIconRequests)
{
    QTemporaryDir tmp;
    ASSERT_TRUE(tmp.isValid());
    const QString root = QFileInfo(tmp.path()).canonicalFilePath();
    const QString good = writePng(root + QStringLiteral("/good.png"));
    AppIconProvider provider;
    std::vector<std::unique_ptr<QQuickImageResponse>> responses;
    std::vector<std::unique_ptr<Spy>> spies; // made before any event is processed: finished() must not be missed
    for (int i = 0; i < 60; ++i) {
        responses.emplace_back(provider.requestImageResponse(i % 3 ? good : root + QStringLiteral("/missing.png"), QSize(32, 32)));
        spies.emplace_back(new Spy(responses.back().get()));
    }
    // What FolderModel and PlacesModel do on the GUI thread while the workers decode.
    for (int i = 0; i < 200; ++i) {
        QIcon::hasThemeIcon(QStringLiteral("text-x-generic"));
        QIcon::hasThemeIcon(QStringLiteral("folder"));
        QCoreApplication::processEvents();
    }
    for (const auto &spy : spies)
        EXPECT_TRUE(spy->wait());
}
