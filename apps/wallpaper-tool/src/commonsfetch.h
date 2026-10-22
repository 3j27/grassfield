#pragma once

#include <QJsonObject>
#include <QString>
#include <QStringList>
#include <QUrl>

#include "wallpaperlogic.h"

// `grassfield-wallpaper fetch commons` (ADR-0016 step 2, slice O1): the Wikimedia Commons Picture of the Day, downloaded by
// curl (an argument vector; the helper links no network library) and treated as untrusted from the first byte. Everything
// pure (text clean-up, licence and host rules, response parsing, the curl vector) is a free function so that the unit tests
// run it without a network; fetchCommons() is the only function that starts a process.
namespace wallpaper::commons {

constexpr qint64 kMaxJsonBytes = 256 * 1024;
constexpr qint64 kMaxImageBytes = qint64(40) * 1024 * 1024;
constexpr int kMaxTitleChars = 200;
constexpr int kMaxCreditChars = 300;
constexpr int kMaxCaptionChars = 500;
constexpr int kMaxRedirects = 3;
constexpr int kDefaultWidth = 3840;
constexpr int kKeepDays = 14;
constexpr qint64 kKeepBytes = qint64(200) * 1024 * 1024;

struct Options {
    QString date;            // YYYY-MM-DD, UTC (the POTD dates are UTC)
    QString out;             // <...>/wallpapers/online/commons
    int width = kDefaultWidth;
    QString lang = QStringLiteral("en");
    QString baseUrl;         // "" = https://commons.wikimedia.org; http://127.0.0.1:<port> only with dev = true
    bool dev = false;        // GRASSFIELD_DEV=1
    QString curl = QStringLiteral("curl");
};

// ---- pure rules ----

// The User-Agent: product and major version, and the project contact (no machine or user identifier).
QString userAgent();

bool validDate(const QString &date);
// "http://127.0.0.1:<port>" exactly (no path, query, user info), accepted only when `dev`.
bool baseUrlAllowed(const QString &base, bool dev);
// The URL a request may go to: https on commons.wikimedia.org, thumb.wikimedia.org or upload.wikimedia.org (no user info,
// default port), or, with a base URL, exactly that origin.
bool hostAllowed(const QUrl &url, const QString &baseUrl);
// The same URL without its query string and fragment (the utm_* parameters).
QUrl withoutQuery(const QUrl &url);

// The machine key of extmetadata "License": public-domain marks, cc0, cc-by-*, cc-by-sa-*.
bool licenseAllowed(const QString &key);

// Plain text for display from HTML or wikitext: tags, links, templates and quote marks removed, entities decoded, control,
// bidi and zero-width characters removed, white space collapsed, at most `maxChars` characters (code points).
QString plainText(const QString &raw, int maxChars);

// The picture's file name from the `expandtemplates` wikitext, or "" when it is not a plain image name.
QString fileNameFromWikitext(const QString &wikitext);

// The Content-Type is jpeg, png or webp (parameters ignored) and the first bytes are that format's signature.
bool imageSignatureOk(const QString &contentType, const QByteArray &head);

// <...>/grassfield/wallpapers/online/commons or <...>/cache/wallpapers/online/commons, absolute, no "." or ".." component.
bool outDirAllowed(const QString &out);

// "YYYY-MM-DD.jpg" or ".json" (the online cache's own names; the folder is pruned by these names only).
bool isOnlineCacheName(const QString &name);

struct Parsed {
    QString fileName;
    QUrl thumbUrl;
    QString title, author, credit, licenseShort, licenseUrl, sourceUrl;
};
// `expandtemplates` answer to the file name ("" on failure).
QString parseFileName(const QByteArray &json);
// `expandtemplates` answer to the plain caption ("" when there is none).
QString parseCaption(const QByteArray &json);
// `imageinfo` answer to what is shown and fetched. Returns Ok, Skipped (licence not allowed, not a picture, no such file)
// or BadResponse (malformed, host not allowed, missing fields). `reason` is a short English note for the journal.
ExitCode parseImageInfo(const QByteArray &json, const QString &fileName, const QString &baseUrl, Parsed *out, QString *reason);

// The sanitized sidecar the shell reads (through `latest`).
QJsonObject sidecarOf(const Parsed &p, const QString &caption, const QString &date, const QString &fetchedAtIso, int width, int height);

// The curl argument vector for one request (the program name is not part of it). `maxBytes` is --max-filesize.
QStringList curlArgs(const QUrl &url, const QString &outFile, qint64 maxBytes, const QString &baseUrl);

// The URL of an API request on the Commons site (or the base URL).
QUrl apiUrl(const QString &baseUrl, const QList<QPair<QString, QString>> &query);

// Removes the files of dates older than `keepDays` before `newest` and then the oldest dates until the folder holds at most
// `maxBytes`; the pair of `newest` is never removed.
void pruneOnline(const QString &dir, const QString &newest, int keepDays, qint64 maxBytes);

// ---- the network part ----

// Runs the whole fetch. On success `result` holds the sidecar fields plus date and file; otherwise the exit code and `reason`.
ExitCode fetchCommons(const Options &opts, QJsonObject *result, QString *reason);

// The newest cached picture ({found, date, file, ...sidecar}), or that of `onlyDate`; never touches the network.
QJsonObject latestCached(const QString &dir, const QString &onlyDate = QString());

} // namespace wallpaper::commons
