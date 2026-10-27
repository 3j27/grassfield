#include "settingsbackend.h"

#include <QDBusMetaType>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>

#include <utility>

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

// The file's settings; a missing or unreadable file, or one that is not a JSON object, reads as the defaults (the schema's).
Input readFile(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    const QJsonDocument document = QJsonDocument::fromJson(file.readAll());
    return document.isObject() ? readInput(document.object()) : Input();
}

} // namespace

SettingsBackend::SettingsBackend(Options options, QObject *parent)
    : QObject(parent)
    , m_options(std::move(options))
{
    qDBusRegisterMetaType<AccentColor>();
    qDBusRegisterMetaType<SettingsMap>();
    // A write is often a rename over the file (QSaveFile): the directory changes, then the new file is watched again.
    m_debounce.setSingleShot(true);
    m_debounce.setInterval(50);
    connect(&m_debounce, &QTimer::timeout, this, &SettingsBackend::reread);
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, &m_debounce, qOverload<>(&QTimer::start));
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, &m_debounce, qOverload<>(&QTimer::start));
    // The "auto" schedule: the clock is read again each recheck interval; nothing is signalled unless a value changed.
    m_recheck.setInterval(m_options.recheckMs);
    connect(&m_recheck, &QTimer::timeout, this, &SettingsBackend::reread);
    m_recheck.start();
    watch();
    m_values = values(readFile(m_options.configFile), m_options.clock());
    m_map = toMap(m_values);
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

void SettingsBackend::watch()
{
    // Never create the directory: the backend only reads the file (defaults apply until it exists).
    const QString dir = QFileInfo(m_options.configFile).absolutePath();
    if (QFileInfo(dir).isDir() && !m_watcher.directories().contains(dir))
        m_watcher.addPath(dir);
    if (QFileInfo::exists(m_options.configFile) && !m_watcher.files().contains(m_options.configFile))
        m_watcher.addPath(m_options.configFile);
}

void SettingsBackend::reread()
{
    watch();
    const Values next = values(readFile(m_options.configFile), m_options.clock());
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
