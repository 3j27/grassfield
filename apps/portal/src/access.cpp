#include "access.h"

#include <KService>

#include <QRegularExpression>
#include <QSet>

namespace grassfield::portal {

namespace {

// An option the frontend passes as a string or a boolean: a value of any other type is no value (any process on the session
// bus can call the backend directly, without the frontend's checks).
QString stringOption(const QVariantMap &options, const QString &key)
{
    const QVariant value = options.value(key);
    return value.metaType() == QMetaType::fromType<QString>() ? value.toString() : QString();
}

bool boolOption(const QVariantMap &options, const QString &key, bool fallback)
{
    const QVariant value = options.value(key);
    return value.metaType() == QMetaType::fromType<bool>() ? value.toBool() : fallback;
}

} // namespace

Access::Access(const QDBusConnection &bus, const Options &options, QObject *parent)
    : RequestHost(bus, QStringLiteral("org.freedesktop.impl.portal.Access"),
                  Limits{options.gtkService, options.uiDeadlineMs, options.idleQuitMs, options.maxPending}, parent)
{
    chooser::registerTypes();
}

QVariantMap Access::toQml(const QString &appId, const QString &parentWindow, const QString &title, const QString &subtitle,
                          const QString &body, const QVariantMap &options)
{
    // The frontend's icon names the question (src/camera.c, screenshot.c, location.c, wallpaper.c, background.c of
    // xdg-desktop-portal 1.22.1): a symbolic icon name, nothing else.
    static const QRegularExpression iconName(QStringLiteral("^[A-Za-z0-9_.-]{1,128}$"));
    QString icon = stringOption(options, QStringLiteral("icon"));
    if (!iconName.match(icon).hasMatch())
        icon.clear();
    // macOS asks about the camera, the microphone and screen recording with neither button the default: Return does nothing
    // until a button has the keyboard (AC2).
    static const QSet<QString> noDefault{QStringLiteral("camera-web-symbolic"), QStringLiteral("audio-input-microphone-symbolic"),
                                         QStringLiteral("applets-screenshooter-symbolic")};
    const auto label = [&](const char *key) { return chooser::oneLine(chooser::withoutMnemonic(stringOption(options, QLatin1String(key)))); };
    return {
        {QStringLiteral("appId"), appId},
        {QStringLiteral("title"), chooser::oneLine(title)},
        {QStringLiteral("subtitle"), chooser::oneLine(subtitle)},
        {QStringLiteral("body"), chooser::oneLine(body)},
        {QStringLiteral("denyLabel"), label("deny_label")},
        {QStringLiteral("grantLabel"), label("grant_label")},
        {QStringLiteral("icon"), icon},
        {QStringLiteral("modal"), boolOption(options, QStringLiteral("modal"), true)},
        {QStringLiteral("parented"), parentWindow.startsWith(QLatin1String("wayland:")) && parentWindow.size() > 8},
        {QStringLiteral("noDefault"), noDefault.contains(icon)},
        {QStringLiteral("choices"), chooser::choicesToQml(chooser::parseChoices(options.value(QStringLiteral("choices"))))},
    };
}

void Access::handle(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QString &title,
                    const QString &subtitle, const QString &body, const QVariantMap &options, const QDBusMessage &message)
{
    message.setDelayedReply(true);
    const int id = begin(handle, message, appId, parentWindow);
    if (id == 0)
        return;
    m_choices.insert(id, chooser::parseChoices(options.value(QStringLiteral("choices"))));
    if (!startUi(id))
        return;
    QVariantMap alert = toQml(appId, parentWindow, title, subtitle, body, options);
    alert.insert(QStringLiteral("appName"), appName(appId));
    // The application's icon (its desktop entry's Icon=: a theme name or a file, IconSource.js), "" when the frontend could
    // not name it or it has none.
    const QString desktopId = windowAppId(appId);
    const KService::Ptr service = appId.isEmpty() || desktopId == QLatin1String("org.grassfield.Files") ? KService::Ptr()
                                                                                                       : KService::serviceByDesktopName(desktopId);
    alert.insert(QStringLiteral("appIcon"), service ? service->icon() : QString());
    emit opened(id, alert);
}

void Access::answer(int id, bool grant, const QVariantList &choices)
{
    if (!isOpen(id))
        return;
    QVariantMap results;
    const QList<chooser::Pair> answered = chooser::answerChoices(m_choices.value(id), choices);
    if (!answered.isEmpty())
        results.insert(QStringLiteral("choices"), QVariant::fromValue(answered));
    finish(id, grant ? 0 : 1, results);
}

QVariantMap Access::relayed(const QVariantMap &gtkResults) const
{
    // The interface's one result: the choices (a(ss)), with their D-Bus type.
    const QVariantMap relayed = chooser::relayed(gtkResults);
    QVariantMap out;
    if (relayed.contains(QStringLiteral("choices")))
        out.insert(QStringLiteral("choices"), relayed.value(QStringLiteral("choices")));
    return out;
}

AccessAdaptor::AccessAdaptor(QObject *exported, Access *access)
    : QDBusAbstractAdaptor(exported)
    , m_access(access)
{
}

uint AccessAdaptor::AccessDialog(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window, const QString &title,
                                 const QString &subtitle, const QString &body, const QVariantMap &options, const QDBusMessage &message,
                                 QVariantMap &results)
{
    Q_UNUSED(results)
    m_access->handle(handle, app_id, parent_window, title, subtitle, body, options, message);
    return 2;
}

} // namespace grassfield::portal
