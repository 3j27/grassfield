// Shared by the three Grassfield apps (R5: one copy). ADR-0015 Q4(b): minimize needs the compositor plugin (Hyprland has no
// native path for xdg_toplevel.set_minimized), so an app greys its minimize light when the plugin is absent, as macOS greys an
// action that is unavailable. The shell writes what it learned from the plugin's capabilities event to one small file:
//
//   $GRASSFIELD_STATE_HOME/capabilities.json (a dev session) or $XDG_RUNTIME_DIR/grassfield-capabilities.json
//   {"v":1,"pluginPresent":true,"features":["decorations","minimize",...]}
//
// The shell writes it once the plugin has answered or the hello timed out, and again on every change (shell/platform/
// Capabilities.qml, ui-independent rule in shell/platform/CapabilitiesFile.js). A missing, unreadable or malformed file means
// "not known": the light stays enabled (the shell may not run yet, or be an older one). The same rule in QML is
// ui/Grassfield/Ui/WindowActions.js minimizeAvailable(), for Settings, which reads the file through its backend.
#pragma once

#include <QByteArray>
#include <QDir>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QString>

#include <QFile>

namespace grassfield::apps {

inline QString capabilitiesFile()
{
    const QString dev = qEnvironmentVariable("GRASSFIELD_STATE_HOME");
    if (!dev.isEmpty())
        return dev + QStringLiteral("/capabilities.json");
    const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    return runtime.isEmpty() ? QString() : runtime + QStringLiteral("/grassfield-capabilities.json");
}

// Whether the minimize light is enabled for the file's content: false only when the shell says the plugin is absent or
// lacks the "minimize" feature; anything unreadable counts as known-nothing (true).
inline bool minimizeAvailable(const QByteArray &json)
{
    QJsonParseError error;
    const QJsonDocument doc = QJsonDocument::fromJson(json, &error);
    if (error.error != QJsonParseError::NoError || !doc.isObject())
        return true;
    const QJsonObject o = doc.object();
    if (o.value(QStringLiteral("v")).toInt() != 1 || !o.value(QStringLiteral("pluginPresent")).isBool())
        return true;
    if (!o.value(QStringLiteral("pluginPresent")).toBool())
        return false;
    const QJsonValue features = o.value(QStringLiteral("features"));
    if (!features.isArray())
        return true;
    for (const QJsonValue &f : features.toArray()) {
        if (f.toString() == QLatin1String("minimize"))
            return true;
    }
    return false;
}

inline bool minimizeAvailableInFile()
{
    const QString path = capabilitiesFile();
    QFile f(path);
    if (path.isEmpty() || !f.open(QIODevice::ReadOnly))
        return true;
    return minimizeAvailable(f.read(64 * 1024));
}

} // namespace grassfield::apps
