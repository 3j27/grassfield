.pragma library

// Month grid math for the Calendar widget (pure).

// Number of days in `month` (0-11) of `year`.
function daysInMonth(year, month) {
    // UTC date math: local midnight may not exist (DST at 00:00 in some zones).
    return new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
}

// Weekday indexes (0 = Sunday ... 6 = Saturday) of the seven columns, starting at firstDay.
function weekdayOrder(firstDay) {
    const out = [];
    for (let i = 0; i < 7; i++)
        out.push((firstDay + i) % 7);
    return out;
}

// Weeks of the month: arrays of 7 cells {day, inMonth}, padded with the neighbouring months'
// days. `firstDay` is the first column's weekday (0 = Sunday); the result has 4-6 rows.
function monthGrid(year, month, firstDay) {
    const lead = (new Date(Date.UTC(year, month, 1)).getUTCDay() - firstDay + 7) % 7;
    const count = daysInMonth(year, month);
    const prevCount = daysInMonth(month === 0 ? year - 1 : year, month === 0 ? 11 : month - 1);
    const weeks = [];
    const total = Math.ceil((lead + count) / 7) * 7;
    for (let i = 0; i < total; i++) {
        const day = i - lead + 1;
        let cell;
        if (day < 1)
            cell = {day: prevCount + day, inMonth: false};
        else if (day > count)
            cell = {day: day - count, inMonth: false};
        else
            cell = {day: day, inMonth: true};
        if (i % 7 === 0)
            weeks.push([]);
        weeks[weeks.length - 1].push(cell);
    }
    return weeks;
}
