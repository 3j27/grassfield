.pragma library

// Auto appearance (`appearance` = "auto", docs/specs/ui.md, Settings > Appearance, Quick Settings).
// macOS model: Auto is light by day and dark at night, switching at sunset and sunrise. Grassfield has no location
// service, so the rule is the macOS fallback: a fixed local schedule, dark from `darkFrom` o'clock to `darkTo` o'clock
// (tokens `autoAppearance.darkFromHour` 19 and `darkToHour` 7). Pure functions, no I/O, so a test can pass any date.

// True while the local hour of `date` lies in the dark window. The window may wrap midnight (19 to 7) or not (0 to 6).
function nightAt(date, darkFrom, darkTo) {
    const h = date.getHours() + date.getMinutes() / 60;
    if (darkFrom === darkTo)
        return false;
    return darkFrom < darkTo ? (h >= darkFrom && h < darkTo) : (h >= darkFrom || h < darkTo);
}

// Whether the shell renders dark for a stored setting: "light" never, "dark" always, "auto" by the schedule;
// anything else reads as the default (dark).
function isDark(setting, date, darkFrom, darkTo) {
    if (setting === "light")
        return false;
    if (setting === "auto")
        return nightAt(date, darkFrom, darkTo);
    return true;
}
