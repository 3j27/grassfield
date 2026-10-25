.pragma library

// Menu bar clock text (macOS Clock options: show the date, the day of the week, a 24-hour time, seconds). Pure; the
// QML side formats with the locale (Qt.locale().toString / Qt.formatTime) from the patterns chosen here.

const HOURS = ["auto", "12", "24"];

function normalizeHours(mode) {
    return HOURS.indexOf(mode) >= 0 ? mode : "auto";
}

// Qt time pattern. `localeShort` is the locale's short time format (Locale.ShortFormat); "auto" keeps it, "24" and "12"
// replace it. Seconds are added after the minutes ("HH:mm" -> "HH:mm:ss"), or appended when the pattern has no minutes.
function timePattern(localeShort, hours, seconds, showAmPm) {
    const mode = normalizeHours(hours);
    let p = mode === "24" ? "HH:mm" : mode === "12" ? "h:mm AP" : String(localeShort || "HH:mm");
    if (seconds) {
        // Only an unquoted run of m is the minutes ('min' inside quotes is text).
        const parts = p.split("'");
        let done = false;
        for (let i = 0; i < parts.length && !done; i += 2) {
            const at = parts[i].search(/m+/);
            if (at >= 0) {
                parts[i] = parts[i].replace(/m+/, "mm:ss");
                done = true;
            }
        }
        p = done ? parts.join("'") : p + ":ss";
    }
    // 12-hour clock without AM/PM: the AP / A marker and the space before it go.
    if (showAmPm === false)
        p = p.replace(/\s*(AP|ap|A|a)(?=[^']*$)/, "").replace(/\s+$/, "");
    return p;
}

// Flashing separators: on the "off" beat the colons of the time are blanks of the same kind (the digits do not move
// in a monospaced-figure font; the width may change by a hair, which macOS accepts too).
function flash(timeText, off) {
    return off ? String(timeText).replace(/:/g, " ") : String(timeText);
}

// Which date pattern the clock uses: "both" (day of the week and date), "day", "date" or "none". `showDate` is the
// resolved date setting: true to show the day and month (the setting "always", or "auto" when there is room).
function dateKind(showDate, showDay) {
    if (showDate && showDay)
        return "both";
    if (showDay)
        return "day";
    return showDate ? "date" : "none";
}

// The gap between the date and the time: an en space and a space (macOS: 9.5 pt between them against 6 for a word gap).
const DATE_TIME_GAP = "\u2002 ";

// Date part and time part joined by the gap; an empty date part leaves the time alone.
function join(dateText, timeText) {
    return dateText !== "" ? dateText + DATE_TIME_GAP + timeText : timeText;
}

// "When Space Allows": the date is shown when the whole status area fits with it. `fullHidden` = the optional items
// hidden with the long clock (StatusLogic.hiddenItems) as a map, `total` the width of every item with it, `available`
// the room: any hidden item, or a total that does not fit, means no room.
function dateFits(mode, fullHidden, total, available) {
    if (mode === "always")
        return true;
    if (mode === "never")
        return false;
    return Object.keys(fullHidden || {}).length === 0 && total <= available;
}
