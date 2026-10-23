// Appearance of the Grassfield apps for the stored `appearance` setting (shared by Files and Preview; the shell and Settings use
// ui/Grassfield/Ui/AutoAppearance.js, the same rule). "light" is light, "auto" follows the macOS fallback schedule (no location
// service: dark at night by the local clock), anything else is dark. The hours are the tokens `autoAppearance.darkFromHour` and
// `darkToHour` of ui/tokens/tokens.json (tests/shell/auto_appearance_tokens.sh keeps this copy equal to them).
#pragma once

#include <QString>
#include <QTime>

namespace grassfield::apps {

inline constexpr int kAutoDarkFromHour = 19;
inline constexpr int kAutoDarkToHour = 7;
// How often an app with "auto" re-evaluates the schedule (minute resolution, `autoAppearance.recheckInterval`).
inline constexpr int kAutoRecheckMs = 60000;

inline bool nightAt(const QTime &time, int darkFrom = kAutoDarkFromHour, int darkTo = kAutoDarkToHour)
{
    if (darkFrom == darkTo)
        return false;
    const double h = time.hour() + time.minute() / 60.0;
    return darkFrom < darkTo ? (h >= darkFrom && h < darkTo) : (h >= darkFrom || h < darkTo);
}

inline bool isDarkAppearance(const QString &setting, const QTime &now)
{
    if (setting == QLatin1String("light"))
        return false;
    if (setting == QLatin1String("auto"))
        return nightAt(now);
    return true;
}

} // namespace grassfield::apps
