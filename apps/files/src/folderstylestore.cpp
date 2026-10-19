#include "folderstylestore.h"

#include "tagstore.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QSaveFile>
#include <QStandardPaths>

#include <algorithm>
#include <cerrno>
#include <sys/stat.h>

using FolderStyleLogic::Style;

namespace
{
constexpr qint64 kMaxFileSize = 4 * 1024 * 1024;

bool isRealFolder(const QString &path)
{
    struct stat st;
    return ::lstat(QFile::encodeName(path).constData(), &st) == 0 && S_ISDIR(st.st_mode);
}

// Whether `path` is gone for good: its parent folder exists and it is not a folder (a link or file now counts as gone,
// the look belonged to a folder). A path whose parent is missing too (an unplugged volume, a folder that is not
// mounted) is not gone: the entry waits for the volume.
bool isGone(const QString &path)
{
    struct stat st;
    if (::lstat(QFile::encodeName(path).constData(), &st) == 0)
        return !S_ISDIR(st.st_mode);
    const QString parent = QFileInfo(path).absolutePath();
    return ::lstat(QFile::encodeName(parent).constData(), &st) == 0 && S_ISDIR(st.st_mode);
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
    // Every entry is kept (the file is at most kMaxFileSize): a store over the cap is never cut when it is written back.
    for (auto it = folders.begin(); it != folders.end(); ++it) {
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

// Entries of folders that no longer exist (deleted, renamed or moved outside Files, replaced by a file): a new folder at
// an old path must not inherit a look. One lstat per entry, only when the store is written.
void FolderStyleStore::pruneGone()
{
    QStringList gone;
    for (auto it = m_entries.begin(); it != m_entries.end();) {
        if (isGone(it.key())) {
            gone.append(it.key() + QLatin1Char('/'));
            it = m_entries.erase(it);
        } else {
            ++it;
        }
    }
    // The folders under a vanished one went with it (their own parent is missing too, which alone does not tell an
    // unplugged volume from a deleted tree).
    if (gone.isEmpty())
        return;
    for (auto it = m_entries.begin(); it != m_entries.end();) {
        const QString key = it.key();
        const bool under = std::any_of(gone.cbegin(), gone.cend(), [&key](const QString &g) { return key.startsWith(g); });
        if (under)
            it = m_entries.erase(it);
        else
            ++it;
    }
}

bool FolderStyleStore::moveEntries(const QString &from, const QString &to)
{
    const QString a = keyFor(from);
    const QString b = keyFor(to);
    if (a == b || a.isEmpty() || b.isEmpty())
        return false;
    m_loaded = true;
    loadFile();
    if (m_broken)
        return false;
    const QString prefix = a.endsWith(QLatin1Char('/')) ? a : a + QLatin1Char('/');
    QHash<QString, Style> moved;
    for (auto it = m_entries.begin(); it != m_entries.end();) {
        if (it.key() == a || it.key().startsWith(prefix)) {
            moved.insert(b + it.key().mid(a.size()), *it);
            it = m_entries.erase(it);
        } else {
            ++it;
        }
    }
    if (moved.isEmpty())
        return false;
    // Whatever was at the destination is replaced: it belonged to a folder that is gone.
    for (auto it = moved.cbegin(); it != moved.cend(); ++it)
        m_entries.insert(it.key(), *it);
    ++m_serial;
    QString error;
    if (!saveFile(&error)) {
        loadFile();
        return false;
    }
    return true;
}

bool FolderStyleStore::dropEntry(const QString &path)
{
    m_loaded = true;
    loadFile();
    if (m_broken || m_entries.remove(keyFor(path)) == 0)
        return false;
    ++m_serial;
    QString error;
    if (!saveFile(&error)) {
        loadFile();
        return false;
    }
    return true;
}

bool FolderStyleStore::saveFile(QString *error)
{
    if (m_broken) {
        *error = QCoreApplication::translate("FolderStyleStore", "the per-user folder style store (%1) can’t be read; it is left as it is").arg(m_file);
        return false;
    }
    pruneGone();
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
        result.error = QCoreApplication::translate("FolderStyleStore", "not a folder on this computer");
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
        if (FolderStyleLogic::tooLargeToEdit(stored)) {
            // Editing would replace a value this version can't read: it could hold a newer version's keys.
            result.error = QCoreApplication::translate("FolderStyleStore", "the look stored on the folder is too large to edit safely; it is left as it is");
            return result;
        }
        break;
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
            // A reset needs the attribute removed: the store can't hide it, so the reset fails with the reason. The
            // entry saved for this account is dropped anyway (the user asked to reset it, it can be removed), and
            // the message says what is left.
            if (m_entries.remove(key) > 0) {
                ++m_serial;
                QString ignored;
                if (saveFile(&ignored)) {
                    result.changed = true;
                    reason = QCoreApplication::translate("FolderStyleStore", "%1 (the look saved for your account only was removed; the look stored on the folder stays)").arg(reason);
                } else {
                    loadFile();
                }
            }
            result.error = reason;
            return result;
        }
        useFallback = true;
    }

    // Fallback store.
    if (style.isEmpty()) {
        m_entries.remove(key);
    } else {
        if (!m_entries.contains(key) && m_entries.size() >= kMaxFallbackEntries) {
            pruneGone();
            if (m_entries.size() >= kMaxFallbackEntries) {
                // Nothing is evicted behind the user's back: a full store refuses a new entry and says why.
                result.error = QCoreApplication::translate("FolderStyleStore", "the list of folders customized for your account only is full (%1 folders); reset some of them first").arg(kMaxFallbackEntries);
                return result;
            }
        }
        m_entries.insert(key, style);
    }
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
