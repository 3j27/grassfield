#include "settingsbackend.h"

#include <QDBusMetaType>
#include <QEventLoop>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonParseError>

#include <cerrno>
#include <system_error>
#include <thread>
#include <utility>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

QDBusArgument &operator<<(QDBusArgument &argument, const AccentColor &color)
{
    argument.beginStructure();
    argument << color.red << color.green << color.blue;
    argument.endStructure();
    return argument;
}

const QDBusArgument &operator>>(const QDBusArgument &argument, AccentColor &color)
{
    argument.beginStructure();
    argument >> color.red >> color.green >> color.blue;
    argument.endStructure();
    return argument;
}

namespace grassfield::portal {

namespace {

const QString kAppearance = QStringLiteral("org.freedesktop.appearance");
const QString kInterface = QStringLiteral("org.gnome.desktop.interface");

// A real grassfield.json is a few KiB (ADR-0020 §2).
constexpr off_t kMaxFileBytes = off_t(1024) * 1024;

// What the file says, never read without a bound (ADR-0020 §2): only a regular file is opened, without blocking, and checked
// again on the descriptor, so a FIFO, a device (also through a symlink) or a directory is never read; at most 1 MiB, read
// whole and exactly. A missing file is a fresh start (the schema's defaults); anything else that is not a JSON object, or that
// cannot be opened (chmod 000), is malformed.
FileRead readContent(const QString &path)
{
    const QByteArray native = QFile::encodeName(path);
    // Looked at before it is opened, so that a device is never opened at all; checked again on the descriptor (a swap in
    // between).
    struct stat before {};
    if (::stat(native.constData(), &before) != 0)
        return {errno == ENOENT || errno == ENOTDIR ? FileState::Missing : FileState::Malformed, {}, {}, false};
    if (!S_ISREG(before.st_mode) || before.st_size > kMaxFileBytes)
        return {FileState::Malformed, {}, {}, false};
    const int fd = ::open(native.constData(), O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOCTTY);
    if (fd < 0)
        return {errno == ENOENT || errno == ENOTDIR ? FileState::Missing : FileState::Malformed, {}, {}, false};
    struct stat st {};
    QByteArray text;
    bool whole = ::fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size <= kMaxFileBytes;
    if (whole) {
        text.resize(qsizetype(st.st_size));
        qsizetype done = 0;
        while (done < text.size()) {
            const ssize_t n = ::read(fd, text.data() + done, size_t(text.size() - done));
            if (n < 0 && errno == EINTR)
                continue;
            if (n <= 0)
                break;
            done += n;
        }
        char more = 0;
        whole = done == text.size() && ::read(fd, &more, 1) == 0;
    }
    ::close(fd);
    if (!whole)
        return {FileState::Malformed, {}, {}, false};
    QJsonParseError error {};
    const QJsonDocument document = QJsonDocument::fromJson(text, &error);
    if (error.error != QJsonParseError::NoError || !document.isObject())
        return {FileState::Malformed, {}, {}, false};
    return {FileState::Read, readInput(document.object()), {}, false};
}

} // namespace

FileRead readSettingsFile(const QString &path)
{
    FileRead read = readContent(path);
    // Where to watch, looked at here too, off the event loop (a home that stops answering blocks this thread only). Never
    // created: until the directory exists, its nearest existing parent is watched.
    QString dir = QFileInfo(path).absolutePath();
    while (!QFileInfo(dir).isDir() && dir != QStringLiteral("/"))
        dir = QFileInfo(dir).absolutePath();
    read.watchDir = std::move(dir);
    read.fileExists = QFileInfo::exists(path);
    return read;
}

SettingsBackend::SettingsBackend(Options options, QObject *parent)
    : QObject(parent)
    , m_options(std::move(options))
{
    qDBusRegisterMetaType<AccentColor>();
    qDBusRegisterMetaType<SettingsMap>();
    // A write is often a rename over the file (QSaveFile): the directory changes, then the new file is watched again.
    m_debounce.setSingleShot(true);
    m_debounce.setInterval(50);
    connect(&m_debounce, &QTimer::timeout, this, &SettingsBackend::startRead);
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, &m_debounce, qOverload<>(&QTimer::start));
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, &m_debounce, qOverload<>(&QTimer::start));
    // The "auto" schedule: only the clock is read again each recheck interval, and only while the appearance is "auto";
    // nothing is signalled unless a value changed.
    m_recheck.setInterval(m_options.recheckMs);
    connect(&m_recheck, &QTimer::timeout, this, &SettingsBackend::recompute);
    // ADR-0020 §2: a read that hangs (a home on a network mount that stops answering) is not waited for: the calls keep
    // being answered from memory with the last settings, and the read that answers late is applied then.
    m_cut.setSingleShot(true);
    m_cut.setInterval(m_options.readCutMs);
    connect(&m_cut, &QTimer::timeout, this, [this] {
        if (!m_reading || m_hung)
            return;
        m_hung = true;
        qWarning("grassfield-portal-settings: reading grassfield.json takes more than %d ms; the last settings stay until it answers",
                 m_options.readCutMs);
    });
    m_values = values(m_input, m_options.clock());
    m_map = toMap(m_values);
    // The first read, waited for at most startWaitMs: the frontend's first calls then get the file's values.
    startRead();
    if (m_reading) {
        QEventLoop loop;
        m_startLoop = &loop;
        QTimer::singleShot(m_options.startWaitMs, &loop, &QEventLoop::quit);
        loop.exec();
        m_startLoop = nullptr;
    }
}

SettingsBackend::~SettingsBackend()
{
    const QMutexLocker lock(&m_alive->mutex);
    m_alive->alive = false;
}

SettingsMap SettingsBackend::toMap(const Values &v)
{
    SettingsMap map;
    map[kAppearance] = QVariantMap{
        {QStringLiteral("color-scheme"), QVariant::fromValue(v.colorScheme())},
        {QStringLiteral("accent-color"), QVariant::fromValue(AccentColor{v.red(), v.green(), v.blue()})},
        {QStringLiteral("contrast"), QVariant::fromValue(uint(v.increaseContrast ? 1 : 0))},
        {QStringLiteral("reduced-motion"), QVariant::fromValue(uint(v.reduceMotion ? 1 : 0))},
    };
    map[kInterface] = QVariantMap{
        {QStringLiteral("gtk-theme"), v.gtkTheme()},
        {QStringLiteral("color-scheme"), v.gnomeColorScheme()},
        {QStringLiteral("enable-animations"), !v.reduceMotion},
    };
    return map;
}

SettingsMap SettingsBackend::ReadAll(const QStringList &namespaces)
{
    SettingsMap result;
    for (auto it = m_map.cbegin(); it != m_map.cend(); ++it) {
        if (namespaceMatches(namespaces, it.key()))
            result.insert(it.key(), it.value());
    }
    return result;
}

QDBusVariant SettingsBackend::Read(const QString &ns, const QString &key)
{
    const auto group = m_map.constFind(ns);
    if (group != m_map.cend() && group->contains(key))
        return QDBusVariant(group->value(key));
    if (calledFromDBus())
        sendErrorReply(QStringLiteral("org.freedesktop.portal.Error.NotFound"), QStringLiteral("Requested setting not found"));
    return QDBusVariant(QVariant());
}

void SettingsBackend::announceAll()
{
    for (auto group = m_map.cbegin(); group != m_map.cend(); ++group) {
        for (auto entry = group->cbegin(); entry != group->cend(); ++entry)
            Q_EMIT SettingChanged(group.key(), entry.key(), QDBusVariant(entry.value()));
    }
}

void SettingsBackend::answerOtherBackends(const QDBusConnection &bus)
{
    // Only the backend the session's routing lists after this one (x-d-p-gtk), by its name: Qt delivers only what that name's
    // owner sends, so no other client can make this backend signal, and x-d-p-gtk never answers back (no loop).
    QDBusConnection(bus).connect(QStringLiteral("org.freedesktop.impl.portal.desktop.gtk"), QStringLiteral("/org/freedesktop/portal/desktop"),
                                 QStringLiteral("org.freedesktop.impl.portal.Settings"), QStringLiteral("SettingChanged"), this,
                                 SLOT(otherBackendChanged(QString, QString, QDBusVariant)));
}

void SettingsBackend::otherBackendChanged(const QString &ns, const QString &key, const QDBusVariant &value)
{
    const auto group = m_map.constFind(ns);
    if (group == m_map.cend() || !group->contains(key))
        return;
    // The same value as Grassfield's: the apps already end with it.
    const QVariant own = group->value(key);
    if (value.variant() == own)
        return;
    Q_EMIT SettingChanged(ns, key, QDBusVariant(own));
}

void SettingsBackend::startRead()
{
    if (m_reading) {
        m_readAgain = true;
        return;
    }
    m_reading = true;
    m_cut.start();
    try {
        std::thread([alive = m_alive, reader = m_options.reader, path = m_options.configFile, self = this] {
            const FileRead read = reader(path);
            const QMutexLocker lock(&alive->mutex);
            if (alive->alive)
                QMetaObject::invokeMethod(self, [self, read] { self->readDone(read); }, Qt::QueuedConnection);
        }).detach();
    } catch (const std::system_error &) {
        // No thread to read with (the unit's task limit): the last settings stay, the next change tries again.
        m_reading = false;
        m_cut.stop();
        qWarning("grassfield-portal-settings: no thread to read grassfield.json with; the last settings stay");
    }
}

void SettingsBackend::readDone(const FileRead &read)
{
    m_reading = false;
    m_cut.stop();
    if (m_hung) {
        m_hung = false;
        qInfo("grassfield-portal-settings: grassfield.json answered again");
    }
    watch(read);
    // A malformed or unreadable file keeps the last good settings (a hand edit with a typo, a writer caught between truncate
    // and write); a missing one is a fresh start (ADR-0020 §2).
    if (read.state != FileState::Malformed)
        m_input = read.input;
    recompute();
    if (m_startLoop)
        m_startLoop->quit();
    if (m_readAgain) {
        m_readAgain = false;
        startRead();
    }
}

void SettingsBackend::watch(const FileRead &read)
{
    for (const QString &stale : m_watcher.directories()) {
        if (stale != read.watchDir)
            m_watcher.removePath(stale);
    }
    if (!read.watchDir.isEmpty() && !m_watcher.directories().contains(read.watchDir))
        m_watcher.addPath(read.watchDir);
    if (read.fileExists && !m_watcher.files().contains(m_options.configFile))
        m_watcher.addPath(m_options.configFile);
}

void SettingsBackend::recompute()
{
    // Only "auto" depends on the clock; any other appearance needs no timer at all.
    if (m_input.appearance != QLatin1String("auto"))
        m_recheck.stop();
    else if (!m_recheck.isActive())
        m_recheck.start();
    const Values next = values(m_input, m_options.clock());
    if (next == m_values)
        return;
    const SettingsMap map = toMap(next);
    m_values = next;
    const SettingsMap previous = std::exchange(m_map, map);
    for (auto group = map.cbegin(); group != map.cend(); ++group) {
        for (auto entry = group->cbegin(); entry != group->cend(); ++entry) {
            // QVariant compares AccentColor with its operator== (Qt 6's QMetaType equality).
            if (previous.value(group.key()).value(entry.key()) != entry.value())
                Q_EMIT SettingChanged(group.key(), entry.key(), QDBusVariant(entry.value()));
        }
    }
}

} // namespace grassfield::portal
