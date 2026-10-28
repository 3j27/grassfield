// Every request of the Store (ADR-0037 c "What is fetched"): https only, redirects included (at most 5, each checked);
// file:// only through dev plumbing; no cookie, no Referer, the User-Agent Grassfield-Store/1, no HTTP cache; a transfer
// timeout and a size cap (a body over the cap is dropped, never truncated and used). Blocking: the app runs it on a worker
// thread (each call has its own QNetworkAccessManager and event loop).
#pragma once

#include <QByteArray>
#include <QNetworkRequest>
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

// The request every fetch sends: no cookie loaded or saved, no Referer, the User-Agent Grassfield-Store/1, no HTTP cache,
// redirects only as fetch verifies them (requestAllowed, at most 5), the transfer timeout, If-None-Match when given.
QNetworkRequest storeRequest(const QUrl &url, const FetchLimits &limits, const QByteArray &etag = {});

// devPlumbing: the URL came from GRASSFIELD_STORE_CATALOG_URL in a dev session (file:// allowed then).
FetchResult fetch(const QUrl &url, const FetchLimits &limits, const QByteArray &etag = {}, bool devPlumbing = false);

// A HEAD request (the first package of a plan, ADR-0037 e.4 and S5): the HTTP status after the redirects fetch allows, 0
// when no answer came, -1 when the URL is not one the Store requests (not https). Through dev plumbing a file:// URL
// answers 200 when the file exists, else 404.
int headStatus(const QUrl &url, int timeoutMs, bool devPlumbing = false);

// The same request saved to `file`, written whole and then renamed into place; on any failure nothing is left there (the
// AppStream package file and its signature, appstreamsource.h).
bool downloadTo(const QUrl &url, const QString &file, const FetchLimits &limits, bool devPlumbing = false);

} // namespace grassfield::store
