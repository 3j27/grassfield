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
#include <QThread>
#include <QRegularExpression>

#include <mutex>

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

std::mutex g_observerMutex;
std::function<void(const QString &)> g_statObserver;

void observeStat(const QString &path)
{
    std::function<void(const QString &)> o;
    {
        std::lock_guard<std::mutex> lock(g_observerMutex);
        o = g_statObserver;
    }
    if (o)
        o(path);
}

// Whether `path` is gone for good: its parent folder exists and it is not a folder (a link or file now counts as gone,
// the look belonged to a folder). A path whose parent is missing too (a folder that is not mounted) is not gone.
// Only ever called for a path on a mounted local filesystem, and not on the GUI thread.
bool isGone(const QString &path)
{
    observeStat(path);
    struct stat st;
    if (::lstat(QFile::encodeName(path).constData(), &st) == 0)
        return !S_ISDIR(st.st_mode);
    const QString parent = QFileInfo(path).absolutePath();
    return ::lstat(QFile::encodeName(parent).constData(), &st) == 0 && S_ISDIR(st.st_mode);
}

QString unescapeMount(const QString &s)
{
    QString out;
    for (int i = 0; i < s.size(); ++i) {
        if (s.at(i) == QLatin1Char('\\') && i + 3 < s.size() && s.at(i + 1).isDigit()) {
            out.append(QChar(s.mid(i + 1, 3).toInt(nullptr, 8)));
            i += 3;
        } else {
            out.append(s.at(i));
        }
    }
    return out;
}

bool isLocalType(const QString &type)
{
    static const QStringList local = {QStringLiteral("ext2"), QStringLiteral("ext3"), QStringLiteral("ext4"), QStringLiteral("btrfs"),
                                      QStringLiteral("xfs"), QStringLiteral("f2fs"), QStringLiteral("zfs"), QStringLiteral("jfs"),
                                      QStringLiteral("bcachefs"), QStringLiteral("reiserfs"), QStringLiteral("tmpfs"), QStringLiteral("overlay")};
    return local.contains(type);
}

bool underOrSame(const QString &path, const QString &point)
{
    if (point == QLatin1String("/"))
        return true;
    return path == point || path.startsWith(point + QLatin1Char('/'));
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

bool FolderStyleStore::moveEntries(const QString &from, const QString &to)
{
    const QString a = keyFor(from);
    const QString b = keyFor(to);
    if (a == b || a.isEmpty() || b.isEmpty())
        return false;
    collectPruned();
    if (m_job) {
        m_touched.append(a);
        m_touched.append(b);
    }
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
    collectPruned();
    if (m_job)
        m_touched.append(keyFor(path));
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
    const QByteArray bytes = QJsonDocument(root).toJson(QJsonDocument::Compact);
    // The reader refuses a file over the limit as broken: a file it would not read back is never written.
    if (bytes.size() > kMaxFileSize) {
        *error = QCoreApplication::translate("FolderStyleStore", "the list of folders customized for your account only would be too large (over %1 MiB, long folder paths); reset some of them first").arg(kMaxFileSize / (1024 * 1024));
        return false;
    }
    QDir().mkpath(QFileInfo(m_file).absolutePath());
    QSaveFile f(m_file);
    if (!f.open(QIODevice::WriteOnly)) {
        *error = f.errorString();
        return false;
    }
    f.setPermissions(QFileDevice::ReadOwner | QFileDevice::WriteOwner);
    f.write(bytes);
    if (!f.commit()) {
        *error = f.errorString();
        return false;
    }
    m_stamp = stampOf(m_file);
    startPrune(false);
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
    collectPruned();
    if (m_job)
        m_touched.append(key);
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
            // Nothing is evicted behind the user's back: a full store refuses a new entry and says why. Entries of
            // vanished folders are looked for in the background, so a later try may find room.
            startPrune(true);
            result.error = QCoreApplication::translate("FolderStyleStore", "the list of folders customized for your account only is full (%1 folders); reset some of them first").arg(kMaxFallbackEntries);
            return result;
        }
        m_entries.insert(key, style);
        if (m_job)
            m_touched.append(key);
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

// ---- Mounts and the background pruning ----

FolderStyleStore::Mounts FolderStyleStore::Mounts::parse(const QByteArray &mountinfo, const QByteArray &fstab)
{
    Mounts m;
    for (const QByteArray &raw : mountinfo.split('\n')) {
        const QString line = QString::fromUtf8(raw);
        const int dash = line.indexOf(QLatin1String(" - "));
        if (dash < 0)
            continue;
        const QStringList pre = line.left(dash).split(QLatin1Char(' '), Qt::SkipEmptyParts);
        const QStringList post = line.mid(dash + 3).split(QLatin1Char(' '), Qt::SkipEmptyParts);
        if (pre.size() < 5 || post.isEmpty())
            continue;
        m.mounted.append({unescapeMount(pre.at(4)), post.at(0)});
    }
    for (const QByteArray &raw : fstab.split('\n')) {
        const QString line = QString::fromUtf8(raw).trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        const QStringList f = line.split(QRegularExpression(QStringLiteral("\\s+")), Qt::SkipEmptyParts);
        if (f.size() >= 2 && f.at(1).startsWith(QLatin1Char('/')) && f.at(1) != QLatin1String("/"))
            m.declared.append(unescapeMount(f.at(1)));
    }
    return m;
}

FolderStyleStore::Mounts FolderStyleStore::Mounts::system()
{
    // Plain files: reading them never touches a mount.
    QFile a(QStringLiteral("/proc/self/mountinfo"));
    QFile b(QStringLiteral("/etc/fstab"));
    const QByteArray mountinfo = a.open(QIODevice::ReadOnly) ? a.readAll() : QByteArray();
    const QByteArray fstab = b.open(QIODevice::ReadOnly) ? b.readAll() : QByteArray();
    return parse(mountinfo, fstab);
}

bool FolderStyleStore::Mounts::isLocalAndMounted(const QString &path) const
{
    const Mount *covering = nullptr;
    for (const Mount &m : mounted) {
        if (underOrSame(path, m.point) && (!covering || m.point.size() >= covering->point.size()))
            covering = &m;
    }
    if (!covering || !isLocalType(covering->type))
        return false;
    const auto isMounted = [this](const QString &point) {
        return std::any_of(mounted.cbegin(), mounted.cend(), [&point](const Mount &m) { return m.point == point; });
    };
    // A mount point that is not mounted now (unplugged stick, fixed mount of an absent disk) leaves its folder on the
    // parent filesystem: the entries under it wait for the volume.
    for (const QString &d : declared) {
        if (underOrSame(path, d) && !isMounted(d))
            return false;
    }
    static const QRegularExpression removable(QStringLiteral("^(/run/media/[^/]+/[^/]+|/media/[^/]+|/mnt/[^/]+)(/|$)"));
    const QRegularExpressionMatch match = removable.match(path);
    if (match.hasMatch() && !isMounted(match.captured(1)))
        return false;
    return true;
}

QStringList FolderStyleStore::goneEntries(const QStringList &keys, const Mounts &mounts)
{
    QStringList gone, local, prefixes;
    for (const QString &key : keys) {
        if (!mounts.isLocalAndMounted(key))
            continue;
        local.append(key);
        if (isGone(key)) {
            gone.append(key);
            prefixes.append(key + QLatin1Char('/'));
        }
    }
    // The folders under a vanished one went with it (only those on local disks: judged by their path alone).
    if (!prefixes.isEmpty()) {
        for (const QString &key : local) {
            if (!gone.contains(key) && std::any_of(prefixes.cbegin(), prefixes.cend(), [&key](const QString &g) { return key.startsWith(g); }))
                gone.append(key);
        }
    }
    return gone;
}

void FolderStyleStore::setMountsForTests(const Mounts &mounts)
{
    m_mounts = mounts;
    m_haveMounts = true;
}

void FolderStyleStore::setStatObserverForTests(std::function<void(const QString &)> observer)
{
    std::lock_guard<std::mutex> lock(g_observerMutex);
    g_statObserver = std::move(observer);
}

struct FolderStyleStore::PruneJob {
    QStringList keys;
    QHash<QString, Style> snapshot;
    Mounts mounts;
    QStringList gone;
};

FolderStyleStore::~FolderStyleStore()
{
    if (m_thread)
        m_thread->wait();
}

void FolderStyleStore::startPrune(bool force)
{
    if (m_job)
        return; // one runs, or a finished one waits to be collected
    if (m_entries.isEmpty())
        return;
    if (!force && m_lastPrune.isValid() && m_lastPrune.elapsed() < 60000)
        return;
    m_lastPrune.start();
    auto job = std::make_shared<PruneJob>();
    job->keys = m_entries.keys();
    job->snapshot = m_entries;
    job->mounts = m_haveMounts ? m_mounts : Mounts::system();
    m_touched.clear();
    m_job = job;
    m_thread.reset(QThread::create([job] { job->gone = goneEntries(job->keys, job->mounts); }));
    m_thread->start();
}

bool FolderStyleStore::collectPruned()
{
    if (!m_job || !m_thread || !m_thread->isFinished())
        return false;
    const std::shared_ptr<PruneJob> job = m_job;
    m_job.reset();
    m_thread.reset();
    const QStringList touched = m_touched;
    m_touched.clear();
    // Decide from the file as it is now; an entry changed since the snapshot (or touched meanwhile) stays.
    m_loaded = true;
    loadFile();
    if (m_broken)
        return false;
    bool removed = false;
    for (const QString &key : job->gone) {
        const auto it = m_entries.constFind(key);
        if (it == m_entries.cend() || *it != job->snapshot.value(key) || touched.contains(key))
            continue;
        m_entries.remove(key);
        removed = true;
    }
    if (!removed)
        return false;
    ++m_serial;
    QString error;
    if (!saveFile(&error)) {
        loadFile();
        return false;
    }
    return true;
}

void FolderStyleStore::waitForPrune()
{
    if (m_thread)
        m_thread->wait();
    collectPruned();
}
