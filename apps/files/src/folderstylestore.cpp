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
#include <QRegularExpression>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>

#include <algorithm>
#include <cerrno>
#include <sys/stat.h>
#include <unistd.h>

using FolderStyleLogic::Style;

namespace
{
constexpr qint64 kMaxFileSize = 4 * 1024 * 1024;

bool isRealFolder(const QString &path)
{
    struct stat st;
    return ::lstat(QFile::encodeName(path).constData(), &st) == 0 && S_ISDIR(st.st_mode);
}

// Never destroyed: a worker abandoned at exit (a blocked stat) may still read them after static destruction began.
std::mutex &observerMutex()
{
    static std::mutex *m = new std::mutex;
    return *m;
}

std::function<void(const QString &)> &statObserver()
{
    static auto *o = new std::function<void(const QString &)>;
    return *o;
}

void observeStat(const QString &path)
{
    std::function<void(const QString &)> o;
    {
        std::lock_guard<std::mutex> lock(observerMutex());
        o = statObserver();
    }
    if (o)
        o(path);
}

// The file system as the pruner sees it (real by default; tests inject a fake one with symlinks and dead shares).
FolderStyleStore::Fs realFs()
{
    FolderStyleStore::Fs fs;
    fs.kindOf = [](const QString &path) {
        struct stat st;
        if (::lstat(QFile::encodeName(path).constData(), &st) != 0)
            return (errno == ENOENT || errno == ENOTDIR) ? FolderStyleStore::Fs::Missing : FolderStyleStore::Fs::Error;
        if (S_ISDIR(st.st_mode))
            return FolderStyleStore::Fs::Dir;
        return S_ISLNK(st.st_mode) ? FolderStyleStore::Fs::Link : FolderStyleStore::Fs::Other;
    };
    fs.readLink = [](const QString &path) {
        char buffer[4096];
        const ssize_t n = ::readlink(QFile::encodeName(path).constData(), buffer, sizeof buffer - 1);
        return n > 0 ? QFile::decodeName(QByteArray(buffer, int(n))) : QString();
    };
    return fs;
}

enum class Judgement { Present, Gone, Missing, Unknown };

// Where `key` really is, without ever touching a filesystem that is not a mounted local disk: the path is walked one
// component at a time from the root, a symbolic link met on the way is followed (its text is read from a local
// directory) and every step is checked against the mount table by its canonical path BEFORE it is looked at. A step on a
// network, FUSE, removable or unknown mount, or one that cannot be told (any error but "does not exist"), ends the walk
// as Unknown: the entry is kept and nothing was statted there.
//   Gone    the last component is absent from an existing local folder, or is no folder any more (a link or a file)
//   Missing a folder on the way is absent (the entry is not judged alone; under a Gone folder it goes with it)
//   Present the folder is there
// Not on the GUI thread.
Judgement judge(const QString &key, const FolderStyleStore::Mounts &mounts, const FolderStyleStore::Fs &fs, const std::atomic<bool> *cancel)
{
    const auto cancelled = [cancel] { return cancel && cancel->load(); };
    QStringList pending = key.split(QLatin1Char('/'), Qt::SkipEmptyParts);
    QString cur = QStringLiteral("/");
    int links = 0;
    while (!pending.isEmpty()) {
        if (cancelled())
            return Judgement::Unknown;
        const QString part = pending.takeFirst();
        if (part == QLatin1String("."))
            continue;
        if (part == QLatin1String("..")) {
            cur = QDir::cleanPath(cur + QLatin1String("/.."));
            continue;
        }
        const QString next = cur == QLatin1String("/") ? cur + part : cur + QLatin1Char('/') + part;
        if (!mounts.isLocalAndMounted(cur) || !mounts.isLocalAndMounted(next))
            return Judgement::Unknown;
        const bool last = pending.isEmpty();
        observeStat(next);
        if (cancelled())
            return Judgement::Unknown;
        switch (fs.kindOf(next)) {
        case FolderStyleStore::Fs::Dir:
            cur = next;
            break;
        case FolderStyleStore::Fs::Missing:
        case FolderStyleStore::Fs::Other:
            return last ? Judgement::Gone : Judgement::Missing;
        case FolderStyleStore::Fs::Link: {
            if (last)
                return Judgement::Gone; // the look belonged to a folder
            const QString target = fs.readLink(next);
            if (target.isEmpty() || ++links > 40 || cancelled())
                return Judgement::Unknown;
            pending = (target.startsWith(QLatin1Char('/')) ? target : cur + QLatin1Char('/') + target).split(QLatin1Char('/'), Qt::SkipEmptyParts) + pending;
            cur = QStringLiteral("/");
            break;
        }
        case FolderStyleStore::Fs::Error:
            return Judgement::Unknown;
        }
    }
    return Judgement::Present;
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
        m.mounted.append({QDir::cleanPath(unescapeMount(pre.at(4))), post.at(0)});
    }
    for (const QByteArray &raw : fstab.split('\n')) {
        const QString line = QString::fromUtf8(raw).trimmed();
        if (line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        const QStringList f = line.split(QRegularExpression(QStringLiteral("\\s+")), Qt::SkipEmptyParts);
        if (f.size() >= 2 && f.at(1).startsWith(QLatin1Char('/')) && QDir::cleanPath(unescapeMount(f.at(1))) != QLatin1String("/"))
            m.declared.append(QDir::cleanPath(unescapeMount(f.at(1))));
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

FolderStyleStore::Fs FolderStyleStore::Fs::real()
{
    return realFs();
}

QStringList FolderStyleStore::goneEntries(const QStringList &keys, const Mounts &mounts)
{
    return goneEntries(keys, mounts, Fs::real(), nullptr);
}

QStringList FolderStyleStore::goneEntries(const QStringList &keys, const Mounts &mounts, const Fs &fs, const std::atomic<bool> *cancel)
{
    QStringList gone, judged, prefixes;
    QList<Judgement> states;
    for (const QString &key : keys) {
        if (cancel && cancel->load())
            return {};
        const Judgement j = judge(key, mounts, fs, cancel);
        if (j == Judgement::Unknown)
            continue;
        judged.append(key);
        states.append(j);
        if (j == Judgement::Gone) {
            gone.append(key);
            prefixes.append(key + QLatin1Char('/'));
        }
    }
    // The folders under a vanished one went with it (judged on a local disk, and not found there themselves: a folder
    // that is present, reached through a link that replaced the vanished one, is a different folder and stays).
    if (!prefixes.isEmpty()) {
        for (int i = 0; i < judged.size(); ++i) {
            const QString &key = judged.at(i);
            if (states.at(i) != Judgement::Present && !gone.contains(key)
                && std::any_of(prefixes.cbegin(), prefixes.cend(), [&key](const QString &g) { return key.startsWith(g); }))
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

void FolderStyleStore::setFsForTests(const Fs &fs)
{
    m_fs = fs;
    m_haveFs = true;
}

void FolderStyleStore::setStatObserverForTests(std::function<void(const QString &)> observer)
{
    std::lock_guard<std::mutex> lock(observerMutex());
    statObserver() = std::move(observer);
}

// The worker owns this (a shared copy of everything it reads) and holds no pointer to the store: the store may go away
// while it is blocked in a stat of a dead mount. `cancel` makes it stop at its next step.
struct FolderStyleStore::PruneJob {
    QStringList keys;
    QHash<QString, Style> snapshot;
    Mounts mounts;
    Fs fs;
    QStringList gone;
    std::atomic<bool> cancel{false};
    std::atomic<bool> done{false};
    std::mutex mutex;
    std::condition_variable finished;

    bool wait(int milliseconds)
    {
        std::unique_lock<std::mutex> lock(mutex);
        return finished.wait_for(lock, std::chrono::milliseconds(milliseconds), [this] { return done.load(); });
    }
};

FolderStyleStore::~FolderStyleStore()
{
    // Never wait for a worker that may be stuck in a stat of a dead hard mount: cancel it, give a healthy one a moment to
    // leave, then abandon it (it owns copies, touches nothing of the store and ends at its next step).
    if (m_job && !m_job->done.load()) {
        m_job->cancel = true;
        m_job->wait(kExitGraceMs);
    }
}

void FolderStyleStore::startPrune(bool force)
{
    if (m_job) {
        // One runs, or a finished one waits to be collected. A forced request is not dropped: its snapshot must include
        // what changed since this job started, so it runs once this one has been collected.
        if (force)
            m_pruneAgain = true;
        return;
    }
    if (m_entries.isEmpty())
        return;
    if (!force && m_lastPrune.isValid() && m_lastPrune.elapsed() < 60000)
        return;
    m_lastPrune.start();
    auto job = std::make_shared<PruneJob>();
    job->keys = m_entries.keys();
    job->snapshot = m_entries;
    job->mounts = m_haveMounts ? m_mounts : Mounts::system();
    job->fs = m_haveFs ? m_fs : Fs::real();
    m_touched.clear();
    m_job = job;
    std::thread([job] {
        job->gone = goneEntries(job->keys, job->mounts, job->fs, &job->cancel);
        {
            std::lock_guard<std::mutex> lock(job->mutex);
            job->done = true;
        }
        job->finished.notify_all();
    }).detach();
}

bool FolderStyleStore::collectPruned()
{
    if (!m_job || !m_job->done.load())
        return false;
    const std::shared_ptr<PruneJob> job = m_job;
    m_job.reset();
    // A forced prune asked for while this job ran starts after the entries of this one are applied (every way out below).
    struct Again {
        FolderStyleStore *store;
        ~Again()
        {
            if (store->m_pruneAgain) {
                store->m_pruneAgain = false;
                store->startPrune(true);
            }
        }
    } again{this};
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
    // Also the job a forced request queued behind the one that was running.
    for (int round = 0; m_job && round < 4; ++round) {
        m_job->wait(60000);
        collectPruned();
    }
}
