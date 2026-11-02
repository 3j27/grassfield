#include "savedsearches.h"

#include "filelogic.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QSaveFile>
#include <QStandardPaths>

#include <algorithm>

namespace
{
// Reads every saved search of `folder`, sorted by name (collation of the locale).
QList<SavedSearches::Entry> readFolder(const QString &folder)
{
    QList<SavedSearches::Entry> out;
    const QFileInfoList files = QDir(folder).entryInfoList({QStringLiteral("*.json")}, QDir::Files | QDir::NoSymLinks | QDir::Readable, QDir::Name);
    for (const QFileInfo &info : files) {
        if (out.size() >= SavedSearches::kMaxSearches)
            break;
        if (info.size() > SavedSearches::kMaxFileSize)
            continue;
        QFile f(info.filePath());
        if (!f.open(QIODevice::ReadOnly))
            continue;
        const QJsonDocument doc = QJsonDocument::fromJson(f.read(SavedSearches::kMaxFileSize + 1));
        if (!doc.isObject())
            continue;
        const auto saved = SearchLogic::fromJson(doc.object());
        if (saved)
            out.append({*saved, info.fileName()});
    }
    std::sort(out.begin(), out.end(), [](const SavedSearches::Entry &a, const SavedSearches::Entry &b) {
        return QString::localeAwareCompare(a.saved.name, b.saved.name) < 0;
    });
    return out;
}

QString writeFile(const QString &path, const SearchLogic::Saved &saved)
{
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return f.errorString();
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    f.write(QJsonDocument(SearchLogic::toJson(saved)).toJson(QJsonDocument::Indented));
    return f.commit() ? QString() : f.errorString();
}
} // namespace

SavedSearches::SavedSearches(const QString &folder, QObject *parent)
    : QObject(parent)
    , m_folder(folder.isEmpty() ? defaultFolder() : folder)
{
    // A burst of changes (a write is a rename) is read once.
    m_reloadTimer.setSingleShot(true);
    m_reloadTimer.setInterval(200);
    connect(&m_reloadTimer, &QTimer::timeout, this, &SavedSearches::reload);
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, &m_reloadTimer, qOverload<>(&QTimer::start));
    reload();
}

QString SavedSearches::defaultFolder()
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation) + QStringLiteral("/grassfield/saved-searches");
}

void SavedSearches::reload()
{
    if (QFileInfo(m_folder).isDir() && !m_watcher.directories().contains(m_folder))
        m_watcher.addPath(m_folder);
    QList<Entry> entries = readFolder(m_folder);
    const bool same = entries.size() == m_entries.size()
                      && std::equal(entries.cbegin(), entries.cend(), m_entries.cbegin(), [](const Entry &a, const Entry &b) {
                             return a.file == b.file && a.saved.name == b.saved.name && a.saved.query == b.saved.query && a.saved.sidebar == b.saved.sidebar;
                         });
    if (same)
        return;
    m_entries = entries;
    emit changed();
}

QString SavedSearches::save(const SearchLogic::Saved &saved)
{
    if (saved.name.trimmed().isEmpty())
        return tr("A saved search needs a name.");
    if (!QDir().mkpath(m_folder))
        return tr("The saved searches folder can’t be created.");
    QFile::setPermissions(m_folder, QFileDevice::ReadOwner | QFileDevice::WriteOwner | QFileDevice::ExeOwner);
    // A search of the same name is replaced (the Finder asks first: the window does).
    QString file;
    for (const Entry &e : std::as_const(m_entries)) {
        if (FileLogic::sameName(e.saved.name, saved.name.trimmed()))
            file = e.file;
    }
    if (file.isEmpty()) {
        const QString base = SearchLogic::savedFileName(saved.name);
        const QString stem = base.chopped(5);
        file = FileLogic::uniqueName(stem, [this](const QString &candidate) {
                   return QFileInfo::exists(m_folder + QLatin1Char('/') + candidate + QStringLiteral(".json"));
               })
               + QStringLiteral(".json");
    }
    SearchLogic::Saved clean = saved;
    clean.name = saved.name.trimmed();
    const QString error = writeFile(m_folder + QLatin1Char('/') + file, clean);
    if (!error.isEmpty())
        return error;
    reload();
    return QString();
}

bool SavedSearches::remove(const QString &file)
{
    // Only a file this store listed, by its own name (never a path).
    for (const Entry &e : std::as_const(m_entries)) {
        if (e.file == file && !file.contains(QLatin1Char('/'))) {
            // To the Trash, as the Finder does for a smart folder (Put Back brings it back); never deleted outright.
            const bool ok = QFile::moveToTrash(m_folder + QLatin1Char('/') + file);
            reload();
            return ok;
        }
    }
    return false;
}

bool SavedSearches::setSidebar(const QString &file, bool on)
{
    for (const Entry &e : std::as_const(m_entries)) {
        if (e.file != file)
            continue;
        SearchLogic::Saved saved = e.saved;
        saved.sidebar = on;
        const bool ok = writeFile(m_folder + QLatin1Char('/') + file, saved).isEmpty();
        reload();
        return ok;
    }
    return false;
}
