#include "folderviews.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>

namespace
{
const QStringList kModes = {QStringLiteral("icons"), QStringLiteral("list"), QStringLiteral("columns"), QStringLiteral("gallery")};
}

FolderViews::FolderViews(const QString &file)
    : m_file(file)
{
}

QString FolderViews::keyFor(const QUrl &url)
{
    if (!url.isValid() || url.isEmpty())
        return QString();
    return url.adjusted(QUrl::StripTrailingSlash | QUrl::NormalizePathSegments).toString(QUrl::FullyEncoded);
}

FolderViews::Entry FolderViews::parse(const QJsonObject &object)
{
    Entry e;
    const QString mode = object.value(QStringLiteral("mode")).toString();
    if (kModes.contains(mode))
        e.mode = mode;
    const QJsonValue key = object.value(QStringLiteral("sortKey"));
    if (key.isDouble() && key.toDouble() == double(key.toInt()) && key.toInt() >= 0 && key.toInt() <= 3)
        e.sortKey = key.toInt();
    const QJsonValue descending = object.value(QStringLiteral("descending"));
    if (descending.isBool())
        e.descending = descending.toBool() ? 1 : 0;
    return e;
}

QJsonObject FolderViews::serialize(const QString &key, const Entry &entry)
{
    QJsonObject o;
    o.insert(QStringLiteral("url"), key);
    if (!entry.mode.isEmpty())
        o.insert(QStringLiteral("mode"), entry.mode);
    if (entry.sortKey >= 0)
        o.insert(QStringLiteral("sortKey"), entry.sortKey);
    if (entry.descending >= 0)
        o.insert(QStringLiteral("descending"), entry.descending == 1);
    return o;
}

FolderViews::Entry FolderViews::merged(const Entry &base, const Entry &fields)
{
    Entry e = base;
    if (kModes.contains(fields.mode))
        e.mode = fields.mode;
    if (fields.sortKey >= 0 && fields.sortKey <= 3)
        e.sortKey = fields.sortKey;
    if (fields.descending == 0 || fields.descending == 1)
        e.descending = fields.descending;
    return e;
}

QDateTime FolderViews::stampOnDisk() const
{
    const QFileInfo info(m_file);
    return info.exists() ? info.lastModified() : QDateTime();
}

void FolderViews::load()
{
    m_entries.clear();
    m_order.clear();
    m_readOnly = false;
    m_stamp = stampOnDisk();
    QFile f(m_file);
    if (!f.exists())
        return;
    if (f.size() > kMaxFileSize || !f.open(QIODevice::ReadOnly)) {
        m_readOnly = true;
        return;
    }
    QJsonParseError err{};
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &err);
    const QJsonObject root = doc.object();
    const QJsonValue version = root.value(QStringLiteral("version"));
    // ADR-0020: a missing version reads as 1; a newer one makes the file read-only.
    if (err.error != QJsonParseError::NoError || !doc.isObject() || (!version.isUndefined() && (!version.isDouble() || version.toInt() < 1))) {
        m_readOnly = true;
        return;
    }
    if (version.toInt(1) > kVersion) {
        m_readOnly = true;
        return;
    }
    const QJsonArray folders = root.value(QStringLiteral("folders")).toArray();
    for (const QJsonValue &value : folders) {
        const QJsonObject o = value.toObject();
        const QString key = o.value(QStringLiteral("url")).toString();
        const Entry e = parse(o);
        if (key.isEmpty() || e.isEmpty())
            continue;
        // A key listed twice keeps its last (most recent) place.
        m_order.removeAll(key);
        m_order.append(key);
        m_entries.insert(key, e);
    }
    while (m_order.size() > kMaxEntries)
        m_entries.remove(m_order.takeFirst());
}

bool FolderViews::set(const QString &key, const Entry &fields, QString *error)
{
    if (key.isEmpty())
        return false;
    if (stampOnDisk() != m_stamp)
        load();
    if (m_readOnly) {
        if (error)
            *error = QCoreApplication::translate("FolderViews", "the view settings file can't be read, so it is left as it is");
        return false;
    }
    const Entry next = merged(m_entries.value(key), fields);
    if (next.isEmpty())
        return true;
    m_entries.insert(key, next);
    m_order.removeAll(key);
    m_order.append(key);
    while (m_order.size() > kMaxEntries)
        m_entries.remove(m_order.takeFirst());
    return save(error);
}

bool FolderViews::save(QString *error)
{
    QJsonArray folders;
    for (const QString &key : std::as_const(m_order))
        folders.append(serialize(key, m_entries.value(key)));
    QJsonObject root;
    root.insert(QStringLiteral("version"), kVersion);
    root.insert(QStringLiteral("folders"), folders);
    const QByteArray bytes = QJsonDocument(root).toJson(QJsonDocument::Compact);
    if (bytes.size() > kMaxFileSize) {
        if (error)
            *error = QCoreApplication::translate("FolderViews", "the view settings file would be too large");
        return false;
    }
    QDir().mkpath(QFileInfo(m_file).absolutePath());
    QSaveFile f(m_file);
    if (!f.open(QIODevice::WriteOnly)) {
        if (error)
            *error = f.errorString();
        return false;
    }
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    f.write(bytes);
    if (!f.commit()) {
        if (error)
            *error = f.errorString();
        return false;
    }
    m_stamp = stampOnDisk();
    return true;
}
