#include "fetch.h"

#include "channel.h"

#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QSaveFile>
#include <QTimer>

namespace grassfield::store {

QNetworkRequest storeRequest(const QUrl &url, const FetchLimits &limits, const QByteArray &etag)
{
    QNetworkRequest request(url);
    request.setRawHeader("User-Agent", "Grassfield-Store/1");
    request.setAttribute(QNetworkRequest::CookieLoadControlAttribute, QNetworkRequest::Manual);
    request.setAttribute(QNetworkRequest::CookieSaveControlAttribute, QNetworkRequest::Manual);
    request.setAttribute(QNetworkRequest::CacheLoadControlAttribute, QNetworkRequest::AlwaysNetwork);
    request.setAttribute(QNetworkRequest::CacheSaveControlAttribute, false);
    request.setAttribute(QNetworkRequest::RedirectPolicyAttribute, QNetworkRequest::UserVerifiedRedirectPolicy);
    request.setMaximumRedirectsAllowed(5);
    request.setTransferTimeout(limits.timeoutMs);
    if (!etag.isEmpty())
        request.setRawHeader("If-None-Match", etag);
    return request;
}

FetchResult fetch(const QUrl &url, const FetchLimits &limits, const QByteArray &etag, bool devPlumbing)
{
    FetchResult result;
    if (!requestAllowed(url, devPlumbing)) {
        result.status = FetchResult::Status::Refused;
        result.error = QStringLiteral("not an https URL");
        return result;
    }
    QNetworkAccessManager manager;
    manager.setCookieJar(nullptr); // QNetworkAccessManager then keeps no cookie at all
    manager.setRedirectPolicy(QNetworkRequest::UserVerifiedRedirectPolicy);
    QNetworkReply *reply = manager.get(storeRequest(url, limits, etag));
    QEventLoop loop;
    QByteArray body;
    bool tooLarge = false, refused = false;
    QObject::connect(reply, &QNetworkReply::redirected, reply, [&](const QUrl &to) {
        if (requestAllowed(to, false)) {
            emit reply->redirectAllowed();
        } else {
            refused = true;
            reply->abort();
        }
    });
    QObject::connect(reply, &QNetworkReply::metaDataChanged, reply, [&] {
        const QVariant length = reply->header(QNetworkRequest::ContentLengthHeader);
        if (length.isValid() && length.toLongLong() > limits.maxBytes) {
            tooLarge = true;
            reply->abort();
        }
    });
    QObject::connect(reply, &QNetworkReply::readyRead, reply, [&] {
        body += reply->read(limits.maxBytes + 1 - body.size());
        if (body.size() > limits.maxBytes) {
            tooLarge = true;
            reply->abort();
        }
    });
    QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
    // A guard beside the transfer timeout: the whole exchange never outlives twice its limit. A timer of this call's own,
    // gone with it: a pending QTimer::singleShot outlived the call in a thread whose loop never ran again (LSan).
    QTimer guard;
    guard.setSingleShot(true);
    QObject::connect(&guard, &QTimer::timeout, reply, [reply] { reply->abort(); });
    guard.start(2 * limits.timeoutMs);
    if (!reply->isFinished())
        loop.exec();
    if (!tooLarge && !refused)
        body += reply->read(limits.maxBytes + 1 - body.size());
    if (body.size() > limits.maxBytes)
        tooLarge = true;

    const int code = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    if (refused) {
        result.status = FetchResult::Status::Refused;
        result.error = QStringLiteral("redirected to a URL that is not https");
    } else if (tooLarge) {
        result.status = FetchResult::Status::TooLarge;
        result.error = QStringLiteral("larger than %1 bytes").arg(limits.maxBytes);
    } else if (code == 304) {
        result.status = FetchResult::Status::NotModified;
    } else if (reply->error() != QNetworkReply::NoError || (url.scheme() == QLatin1String("https") && code != 200)) {
        result.status = FetchResult::Status::Failed;
        result.error = code ? QStringLiteral("HTTP %1").arg(code) : reply->errorString();
    } else {
        result.status = FetchResult::Status::Ok;
        result.body = body;
        result.etag = reply->rawHeader("ETag").left(512);
    }
    reply->deleteLater();
    return result;
}

int headStatus(const QUrl &url, int timeoutMs, bool devPlumbing)
{
    if (!requestAllowed(url, devPlumbing))
        return -1;
    if (url.isLocalFile())
        return QFileInfo(url.toLocalFile()).isFile() ? 200 : 404;
    QNetworkAccessManager manager;
    manager.setCookieJar(nullptr);
    manager.setRedirectPolicy(QNetworkRequest::UserVerifiedRedirectPolicy);
    QNetworkReply *reply = manager.head(storeRequest(url, FetchLimits{0, timeoutMs}));
    QEventLoop loop;
    bool refused = false;
    QObject::connect(reply, &QNetworkReply::redirected, reply, [&](const QUrl &to) {
        if (requestAllowed(to, false)) {
            emit reply->redirectAllowed();
        } else {
            refused = true;
            reply->abort();
        }
    });
    QObject::connect(reply, &QNetworkReply::finished, &loop, &QEventLoop::quit);
    QTimer guard; // as fetch()'s
    guard.setSingleShot(true);
    QObject::connect(&guard, &QTimer::timeout, reply, [reply] { reply->abort(); });
    guard.start(2 * timeoutMs);
    if (!reply->isFinished())
        loop.exec();
    const int code = refused ? -1 : reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
    reply->deleteLater();
    return code;
}

bool downloadTo(const QUrl &url, const QString &file, const FetchLimits &limits, bool devPlumbing)
{
    QFile::remove(file);
    const FetchResult r = fetch(url, limits, {}, devPlumbing);
    if (r.status != FetchResult::Status::Ok)
        return false;
    QSaveFile out(file);
    return out.open(QIODevice::WriteOnly) && out.write(r.body) == r.body.size() && out.commit();
}

} // namespace grassfield::store
