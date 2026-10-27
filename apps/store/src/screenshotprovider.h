// Screenshots of a product page (spec SR10, owner ST6): image://screenshot/<the https URL, percent-encoded>. Each one is
// fetched with the Store's own request (fetch.h: https only, no cookie, no Referer, at most 8 MiB in 15 s), decoded off the
// GUI thread with Qt's decoders under the app's allocation limit, and scaled to the size asked for. Never cached on disk.
// The window asks for one only through StoreBackend::screenshotSource, which is "" while screenshots are off or offline.
#pragma once

#include <QQuickAsyncImageProvider>
#include <QThreadPool>

namespace grassfield::store {

class ScreenshotProvider : public QQuickAsyncImageProvider
{
public:
    ScreenshotProvider();
    QQuickImageResponse *requestImageResponse(const QString &id, const QSize &requestedSize) override;

private:
    QThreadPool m_pool;
};

} // namespace grassfield::store
