// Every request of the Store (ADR-0037 c "What is fetched"): https only, redirects included (at most 5, each checked);
// file:// only through dev plumbing; no cookie, no Referer, the User-Agent Grassfield-Store/1, no HTTP cache; a transfer
// timeout and a size cap (a body over the cap is dropped, never truncated and used). Blocking: the app runs it on a worker
// thread (each call has its own QNetworkAccessManager and event loop).
#pragma once

#include <QByteArray>
#include <QString>
#include <QUrl>

namespace grassfield::store {

struct FetchLimits {
    qint64 maxBytes = 1024 * 1024;
    int timeoutMs = 15000;
};

struct FetchResult {
    enum class Status { Ok, NotModified, Refused, TooLarge, Failed };
    Status status = Status::Failed;
    QByteArray body;
    QByteArray etag;
    QString error;
};

// devPlumbing: the URL came from GRASSFIELD_STORE_CATALOG_URL in a dev session (file:// allowed then).
FetchResult fetch(const QUrl &url, const FetchLimits &limits, const QByteArray &etag = {}, bool devPlumbing = false);

// The same request saved to `file`, written whole and then renamed into place; on any failure nothing is left there (the
// AppStream package file and its signature, appstreamsource.h).
bool downloadTo(const QUrl &url, const QString &file, const FetchLimits &limits, bool devPlumbing = false);

} // namespace grassfield::store
