// What the Settings portal backend publishes for the Grassfield settings (ADR-0035 D-8, step 2b). Pure: no bus, no file, no
// clock; unit-tested (tests/unit/portal-settings/tst_portalvalues.cpp).
//
// org.freedesktop.appearance (the portal's own namespace, read by GTK 4, libadwaita, Chromium, Electron, Firefox, Qt):
//   color-scheme   u  1 dark, 2 light (the `appearance` setting; "auto" by the schedule of apps/autoappearance.h)
//   accent-color   (ddd) the accent of `accent.color` in this appearance, sRGB 0..1 (PaletteTokens.hpp, from tokens.json)
//   contrast       u  1 with Increase Contrast, else 0
//   reduced-motion u  1 with Reduce Motion, else 0
// org.gnome.desktop.interface (what GTK 3 reads through the portal when GTK_USE_PORTAL=1):
//   gtk-theme         s  Grassfield-<accent>[-hc][-dark]: the generated theme of the accent, Increase Contrast (-hc) and the
//                        appearance (-dark) (ui/tools/gen-gtk-themes.py)
//   color-scheme      s  prefer-dark or prefer-light
//   enable-animations b  not Reduce Motion
// Every other key falls through to the next backend (x-d-p-gtk): fonts, icons and cursors come from the session's dconf.
#pragma once

#include "PaletteTokens.hpp"
#include "autoappearance.h"

#include <QJsonObject>
#include <QString>
#include <QTime>

#include <cstdint>

namespace grassfield::portal {

// The settings that the portal values depend on, as grassfield.json holds them (config/schema/grassfield.schema.json).
struct Input {
    QString appearance = QStringLiteral("dark");   // dark, light, auto (schema default: dark)
    QString accent = QStringLiteral("multicolor"); // Accent.js NAMES (schema default: multicolor)
    bool increaseContrast = false;                 // accessibility.increaseContrast
    bool reduceMotion = false;                     // accessibility.reduceMotion
};

struct Values {
    bool dark = true;
    uint32_t accentRgb = 0;  // 0xRRGGBB
    QString accentName;      // the accent the theme name uses (an unknown name reads as multicolor)
    bool increaseContrast = false;
    bool reduceMotion = false;

    uint colorScheme() const { return dark ? 1u : 2u; }
    double red() const { return ((accentRgb >> 16u) & 0xFFu) / 255.0; }
    double green() const { return ((accentRgb >> 8u) & 0xFFu) / 255.0; }
    double blue() const { return (accentRgb & 0xFFu) / 255.0; }
    QString gtkTheme() const
    {
        return QStringLiteral("Grassfield-") + accentName + (increaseContrast ? QStringLiteral("-hc") : QString())
            + (dark ? QStringLiteral("-dark") : QString());
    }
    QString gnomeColorScheme() const { return dark ? QStringLiteral("prefer-dark") : QStringLiteral("prefer-light"); }
    bool operator==(const Values &other) const
    {
        return dark == other.dark && accentRgb == other.accentRgb && accentName == other.accentName
            && increaseContrast == other.increaseContrast && reduceMotion == other.reduceMotion;
    }
};

// The settings file's values; a missing or wrong-typed key keeps the schema default, as the shell reads it.
inline Input readInput(const QJsonObject &root)
{
    Input in;
    if (root.value(QStringLiteral("appearance")).isString())
        in.appearance = root.value(QStringLiteral("appearance")).toString();
    const QJsonObject accent = root.value(QStringLiteral("accent")).toObject();
    if (accent.value(QStringLiteral("color")).isString())
        in.accent = accent.value(QStringLiteral("color")).toString();
    const QJsonObject accessibility = root.value(QStringLiteral("accessibility")).toObject();
    if (accessibility.value(QStringLiteral("increaseContrast")).isBool())
        in.increaseContrast = accessibility.value(QStringLiteral("increaseContrast")).toBool();
    if (accessibility.value(QStringLiteral("reduceMotion")).isBool())
        in.reduceMotion = accessibility.value(QStringLiteral("reduceMotion")).toBool();
    return in;
}

inline Values values(const Input &in, const QTime &now)
{
    Values v;
    v.dark = grassfield::apps::isDarkAppearance(in.appearance, now);
    const tokens::Accent *found = &tokens::kAccents[0]; // multicolor: also what an unknown name reads as (Accent.js normalize)
    for (const tokens::Accent &accent : tokens::kAccents) {
        if (in.accent == QLatin1String(accent.name))
            found = &accent;
    }
    v.accentName = QLatin1String(found->name);
    v.accentRgb = v.dark ? found->dark : found->light;
    v.increaseContrast = in.increaseContrast;
    v.reduceMotion = in.reduceMotion;
    return v;
}

// ReadAll's namespace filter: an empty list, or an empty string in it, matches everything; "org.example.*" matches by prefix
// (trailing globbing only, the interface's rule).
inline bool namespaceMatches(const QStringList &patterns, const QString &ns)
{
    if (patterns.isEmpty())
        return true;
    for (const QString &pattern : patterns) {
        if (pattern.isEmpty() || pattern == ns)
            return true;
        if (pattern.endsWith(QLatin1Char('*')) && ns.startsWith(pattern.chopped(1)))
            return true;
    }
    return false;
}

} // namespace grassfield::portal
