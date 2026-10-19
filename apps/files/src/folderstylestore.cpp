#include "folderstylestore.h"

#include "tagstore.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QStandardPaths>

#include <cerrno>
#include <sys/stat.h>

using FolderStyleLogic::Style;

namespace
{
constexpr qint64 kMaxFileSize = 4 * 1024 * 1024;
constexpr int kMaxEntries = 20000;

bool isRealFolder(const QString &path)
{
    struct stat st;
    return ::lstat(QFile::encodeName(path).constData(), &st) == 0 && S_ISDIR(st.st_mode);
}

qint64 stampOf(const QString &file)
{
    const QFileInfo info(file);
    if (!info.exists())
        return 0;
    return info.lastModified().toMSecsSinceEpoch() * 31 + info.size() + 1;
}
} // namespace

FolderStyleStore::FolderStyleStore(const QString &fallbackFile)
    : m_file(fallbackFile.isEmpty() ? defaultFallbackFile() : fallbackFile)
{
}

QString FolderStyleStore::defaultFallbackFile()
{
    const QString dev = qEnvironmentVariable("GRASSFIELD_CONFIG_HOME");
    if (!dev.isEmpty())
        return dev + QStringLiteral("/folder-styles.json");
    const QString xdg = qEnvironmentVariable("XDG_CONFIG_HOME");
    return (xdg.isEmpty() ? QDir::homePath() + QStringLiteral("/.config") : xdg) + QStringLiteral("/grassfield/folder-styles.json");
}

void FolderStyleStore::setFallbackFile(const QString &file)
{
    m_file = file;
    m_loaded = false;
}

QString FolderStyleStore::keyFor(const QString &path)
{
    return QDir::cleanPath(path);
}

bool FolderStyleStore::loadFile() const
{
    m_entries.clear();
    m_broken = false;
    m_serial = 0;
    m_stamp = stampOf(m_file);
    QFile f(m_file);
    if (!f.exists())
        return true;
    if (!f.open(QIODevice::ReadOnly) || f.size() > kMaxFileSize) {
        m_broken = true;
        return false;
    }
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject() || doc.object().value(QStringLiteral("version")).toInt() != 1) {
        m_broken = true;
        return false;
    }
    const QJsonObject root = doc.object();
    m_serial = qint64(root.value(QStringLiteral("serial")).toDouble());
    const QJsonObject folders = root.value(QStringLiteral("folders")).toObject();
    for (auto it = folders.begin(); it != folders.end() && m_entries.size() < kMaxEntries; ++it) {
        const QJsonObject o = it.value().toObject();
        Style style;
        style.color = FolderStyleLogic::normalizeColor(o.value(QStringLiteral("color")).toString());
        style.glyph = FolderStyleLogic::normalizeGlyph(o.value(QStringLiteral("glyph")).toString());
        if (!style.isEmpty() && it.key().startsWith(QLatin1Char('/')))
            m_entries.insert(it.key(), style);
    }
    return true;
}

void FolderStyleStore::ensureLoaded() const
{
    if (m_loaded)
        return;
    m_loaded = true;
    loadFile();
}

bool FolderStyleStore::reload()
{
    if (m_loaded && stampOf(m_file) == m_stamp)
        return false;
    const QHash<QString, Style> before = m_entries;
    const qint64 serial = m_serial;
    const bool brokenBefore = m_broken;
    m_loaded = true;
    loadFile();
    return before != m_entries || serial != m_serial || brokenBefore != m_broken;
}

int FolderStyleStore::fallbackCount() const
{
    ensureLoaded();
    return int(m_entries.size());
}

bool FolderStyleStore::fallbackBroken() const
{
    ensureLoaded();
    return m_broken;
}

Style FolderStyleStore::read(const QString &path) const
{
    ensureLoaded();
    if (!m_entries.isEmpty()) {
        const auto it = m_entries.constFind(keyFor(path));
        if (it != m_entries.cend())
            return *it;
    }
    QByteArray raw;
    if (TagStore::quickReadAttr(path, FolderStyleLogic::attributeName(), &raw) != TagStore::ReadResult::Ok)
        return {};
    return FolderStyleLogic::parse(raw);
}

bool FolderStyleStore::saveFile(QString *error)
{
    if (m_broken) {
        *error = QStringLiteral("the per-user folder style store (%1) can’t be read; it is left as it is").arg(m_file);
        return false;
    }
    QJsonObject folders;
    for (auto it = m_entries.cbegin(); it != m_entries.cend(); ++it) {
        QJsonObject o;
        if (!it->color.isEmpty())
            o.insert(QStringLiteral("color"), it->color);
        if (!it->glyph.isEmpty())
            o.insert(QStringLiteral("glyph"), it->glyph);
        folders.insert(it.key(), o);
    }
    QJsonObject root;
    root.insert(QStringLiteral("version"), 1);
    root.insert(QStringLiteral("serial"), double(m_serial));
    root.insert(QStringLiteral("folders"), folders);
    QDir().mkpath(QFileInfo(m_file).absolutePath());
    QSaveFile f(m_file);
    if (!f.open(QIODevice::WriteOnly)) {
        *error = f.errorString();
        return false;
    }
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    f.write(QJsonDocument(root).toJson(QJsonDocument::Compact));
    if (!f.commit()) {
        *error = f.errorString();
        return false;
    }
    m_stamp = stampOf(m_file);
    return true;
}

FolderStyleStore::Result FolderStyleStore::write(const QString &path, const Style &wanted)
{
    Result result;
    const QString key = keyFor(path);
    Style style;
    style.color = FolderStyleLogic::normalizeColor(wanted.color);
    style.glyph = FolderStyleLogic::normalizeGlyph(wanted.glyph);
    if (!isRealFolder(path)) {
        result.error = QStringLiteral("not a folder on this computer");
        return result;
    }
    // Another process may have changed the store: decide from the file as it is now.
    m_loaded = true;
    loadFile();

    bool useFallback = false;
    QString reason;
    QByteArray stored;
    switch (TagStore::readAttr(path, FolderStyleLogic::attributeName(), &stored, &reason)) {
    case TagStore::ReadResult::Failed:
        // A failed read must not become "nothing stored": the write would replace what is there.
        result.error = reason;
        return result;
    case TagStore::ReadResult::Unsupported:
        useFallback = true;
        break;
    case TagStore::ReadResult::Ok:
    case TagStore::ReadResult::NoData:
        break;
    }

    if (!useFallback) {
        const QByteArray next = FolderStyleLogic::apply(stored, style);
        int err = 0;
        bool wrote = true;
        if (next != stored)
            wrote = TagStore::writeAttr(path, FolderStyleLogic::attributeName(), next, &reason, &err);
        if (wrote) {
            result.ok = true;
            result.changed = next != stored;
            // The attribute is the truth again: an old fallback entry for this folder would hide it.
            const bool hadEntry = m_entries.remove(key) > 0;
            if (hadEntry || result.changed) {
                ++m_serial;
                QString ignored;
                if (!saveFile(&ignored) && hadEntry) {
                    // The entry could not be dropped: it keeps winning. Say so rather than pretend.
                    result.ok = false;
                    result.error = ignored;
                }
            }
            return result;
        }
        // A folder that can't be written (read-only, immutable, a filesystem without attributes) keeps the user's
        // choice in the per-user store; any other failure is reported as it is.
        if (err != ENOTSUP && err != EOPNOTSUPP && err != EPERM && err != EACCES && err != EROFS) {
            result.error = reason;
            return result;
        }
        if (style.isEmpty()) {
            // A reset needs the attribute removed: the store can't hide it.
            result.error = reason;
            return result;
        }
        useFallback = true;
    }

    // Fallback store.
    if (style.isEmpty())
        m_entries.remove(key);
    else
        m_entries.insert(key, style);
    ++m_serial;
    QString error;
    if (!saveFile(&error)) {
        loadFile();
        result.error = error;
        return result;
    }
    result.ok = true;
    result.fellBack = true;
    result.changed = true;
    return result;
}
