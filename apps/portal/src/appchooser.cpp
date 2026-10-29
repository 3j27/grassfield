#include "appchooser.h"

#include "chooserlogic.h"

#include <QDBusConnection>
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

AppChooser::AppChooser(const QDBusConnection &bus, const Options &options, QObject *parent)
    : RequestHost(bus, QStringLiteral("org.freedesktop.impl.portal.AppChooser"),
                  Limits{options.gtkService, options.uiDeadlineMs, options.idleQuitMs, options.maxPending, false}, parent)
    , m_gtkService(options.gtkService)
{
}

bool AppChooser::isDesktopId(const QString &id)
{
    // A desktop file id without ".desktop" (the frontend's get_app_id): the characters of a D-Bus name plus '-', as the
    // Applications location makes them from a file's path (ApplicationsLogic, '/' written '-').
    static const QRegularExpression valid(QStringLiteral("^[A-Za-z0-9_][A-Za-z0-9._-]{0,254}$"));
    return valid.match(id).hasMatch() && !id.endsWith(QLatin1String(".desktop"));
}

QStringList AppChooser::desktopIds(const QStringList &ids)
{
    QStringList out;
    QSet<QString> seen;
    for (const QString &id : ids) {
        if (out.size() >= kMaxApplications)
            break;
        if (isDesktopId(id) && !seen.contains(id)) {
            seen.insert(id);
            out.append(id);
        }
    }
    return out;
}

QVariantMap AppChooser::toQml(const QString &appId, const QString &parentWindow, const QStringList &choices, const QVariantMap &options)
{
    static const QRegularExpression mimeType(QStringLiteral("^[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}/[A-Za-z0-9][A-Za-z0-9!#$&^_.+-]{0,126}$"));
    QString contentType = stringOption(options, QStringLiteral("content_type"));
    if (!mimeType.match(contentType).hasMatch())
        contentType.clear();
    // The document's name as the panel's message names it: a plain name, never a path.
    QString filename = chooser::oneLine(stringOption(options, QStringLiteral("filename")));
    if (filename.contains(QLatin1Char('/')) || filename == QLatin1String(".") || filename == QLatin1String(".."))
        filename.clear();
    const QString last = stringOption(options, QStringLiteral("last_choice"));
    return {
        {QStringLiteral("kind"), QStringLiteral("application")},
        {QStringLiteral("appId"), appId},
        // The panel's own title and button (Choose Application, Open).
        {QStringLiteral("title"), QString()},
        {QStringLiteral("acceptLabel"), QString()},
        {QStringLiteral("modal"), boolOption(options, QStringLiteral("modal"), true)},
        {QStringLiteral("parented"), parentWindow.startsWith(QLatin1String("wayland:")) && parentWindow.size() > 8},
        {QStringLiteral("multiple"), false},
        {QStringLiteral("directory"), false},
        // The Enable pop-up's two entries are the panel's own (FilePanel.qml); none of the Open panel's.
        {QStringLiteral("filters"), QVariantList()},
        {QStringLiteral("currentFilter"), -1},
        {QStringLiteral("choices"), QVariantList()},
        {QStringLiteral("currentName"), QString()},
        {QStringLiteral("files"), QVariantList()},
        {QStringLiteral("currentFolder"), QString()},
        {QStringLiteral("applications"), desktopIds(choices)},
        {QStringLiteral("lastChoice"), isDesktopId(last) ? last : QString()},
        {QStringLiteral("contentType"), contentType},
        {QStringLiteral("filename"), filename},
        {QStringLiteral("uri"), chooser::oneLine(stringOption(options, QStringLiteral("uri")))},
    };
}

void AppChooser::handle(const QDBusObjectPath &handle, const QString &appId, const QString &parentWindow, const QStringList &choices,
                        const QVariantMap &options, const QDBusMessage &message)
{
    message.setDelayedReply(true);
    const int id = begin(handle, message, appId, parentWindow);
    if (id == 0)
        return;
    const QString token = stringOption(options, QStringLiteral("activation_token"));
    if (!token.isEmpty() && token.size() <= 1024)
        m_tokens.insert(id, token);
    if (!startUi(id))
        return;
    emit opened(id, toQml(appId, parentWindow, choices, options));
}

void AppChooser::updateChoices(const QDBusObjectPath &handle, const QStringList &choices)
{
    const int id = requestId(handle.path());
    if (id == 0)
        return;
    if (isOpen(id)) {
        emit applicationsChanged(id, desktopIds(choices));
        return;
    }
    // Forwarded: x-d-p-gtk's dialog shows the frontend's new candidates.
    QDBusMessage call = QDBusMessage::createMethodCall(m_gtkService, QStringLiteral("/org/freedesktop/portal/desktop"),
                                                       QStringLiteral("org.freedesktop.impl.portal.AppChooser"),
                                                       QStringLiteral("UpdateChoices"));
    call.setArguments({QVariant::fromValue(handle), choices});
    m_bus.call(call, QDBus::NoBlock);
}

void AppChooser::answer(int id, int response, const QVariantMap &answer)
{
    if (!isOpen(id))
        return;
    if (response != 0) {
        finish(id, 1, {});
        return;
    }
    const QVariant choice = answer.value(QStringLiteral("choice"));
    if (choice.metaType() != QMetaType::fromType<QString>() || !isDesktopId(choice.toString())) {
        qWarning("grassfield-portal: the panel chose no application; the request ends");
        finish(id, 2, {});
        return;
    }
    QVariantMap results{{QStringLiteral("choice"), choice.toString()}};
    // The token the request came with: the frontend starts the chosen application with it (the interface allows the same one
    // back; Hyprland gives a new window the keyboard either way).
    const QString token = m_tokens.value(id);
    if (!token.isEmpty())
        results.insert(QStringLiteral("activation_token"), token);
    finish(id, 0, results);
}

QVariantMap AppChooser::relayed(const QVariantMap &gtkResults) const
{
    // The interface's results: the choice and the activation token (strings).
    QVariantMap out;
    for (const QString &key : {QStringLiteral("choice"), QStringLiteral("activation_token")}) {
        const QVariant value = gtkResults.value(key);
        if (value.metaType() == QMetaType::fromType<QString>())
            out.insert(key, value.toString());
    }
    return out;
}

AppChooserAdaptor::AppChooserAdaptor(QObject *exported, AppChooser *chooser)
    : QDBusAbstractAdaptor(exported)
    , m_chooser(chooser)
{
}

uint AppChooserAdaptor::ChooseApplication(const QDBusObjectPath &handle, const QString &app_id, const QString &parent_window,
                                          const QStringList &choices, const QVariantMap &options, const QDBusMessage &message,
                                          QVariantMap &results)
{
    Q_UNUSED(results)
    m_chooser->handle(handle, app_id, parent_window, choices, options, message);
    return 2;
}

void AppChooserAdaptor::UpdateChoices(const QDBusObjectPath &handle, const QStringList &choices)
{
    m_chooser->updateChoices(handle, choices);
}

} // namespace grassfield::portal
