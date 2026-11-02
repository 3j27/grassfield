.pragma library

// The Grassfield artwork's phase of the day (ADR-0040 IQ-W1 C, section 2 "The time-of-day rule"): Dawn, Day, Evening and
// Night from the system's time zone alone, no location service, no network. Pure functions, no I/O: the shell reads the zone
// and tzdata's tables (shell/services/TimeOfDay.qml) and passes their text here. Ported from the ADR's probe
// (docs/audits/identity-2026-10-29/timeofday-probe.py) and checked against its figures (tests/unit/tst_timeofday.qml).
//
// The zone's reference point, in this order: its row in zone1970.tab; its row in zone.tab (zones tzdata now treats as aliases
// keep one there: Europe/Amsterdam, Africa/Douala, ...); the zone it links to (tzdata.zi "L <target> <name>", up to 8
// links), looked up in those two; none: the fixed hours. Sunrise and sunset: the NOAA approximation (solar zenith 90.833
// degrees) for the local date. A polar day or night uses the fixed hours too. Times are epoch milliseconds throughout;
// local wall times go through a calendar `cal` ({ymd(ms) -> [y, m, d], local(y, m, d, hh, mm) -> ms}), the system's by
// default (localCalendar), so the tests can name another zone's offset.

const PHASES = ["dawn", "day", "evening", "night"];
const MAX_LINKS = 8;
const MINUTE = 60000;
const DAY = 86400000;

// ISO 6709 "+DDMM[SS]+DDDMM[SS]" -> [lat, lon] in degrees, or null.
function coord(s) {
    const m = /^([+-]\d{4}(?:\d{2})?)([+-]\d{5}(?:\d{2})?)$/.exec(String(s || ""));
    if (!m)
        return null;
    const part = (t, degDigits) => {
        const sign = t.charAt(0) === "-" ? -1 : 1;
        const body = t.substring(1);
        const d = parseInt(body.substring(0, degDigits), 10);
        const mm = parseInt(body.substring(degDigits, degDigits + 2), 10);
        const ss = body.length > degDigits + 2 ? parseInt(body.substring(degDigits + 2, degDigits + 4), 10) : 0;
        return sign * (d + mm / 60 + ss / 3600);
    };
    return [part(m[1], 2), part(m[2], 3)];
}

// zone1970.tab or zone.tab text -> {zone: [lat, lon]}. Comment and malformed lines are skipped.
function parseTable(text) {
    const out = {};
    for (const line of String(text || "").split("\n")) {
        if (line === "" || line.charAt(0) === "#")
            continue;
        const f = line.split("\t");
        if (f.length < 3)
            continue;
        const c = coord(f[1]);
        if (c !== null && /^[A-Za-z0-9_+\/-]+$/.test(f[2]))
            out[f[2]] = c;
    }
    return out;
}

// tzdata.zi text -> {alias: target} from its "L <target> <alias>" lines.
function parseLinks(text) {
    const out = {};
    for (const line of String(text || "").split("\n")) {
        if (line.substring(0, 2) !== "L ")
            continue;
        const f = line.trim().split(/\s+/);
        if (f.length === 3)
            out[f[2]] = f[1];
    }
    return out;
}

// The zone's reference point: {lat, lon, source} or null (no point: the fixed hours).
function reference(zone, z1970, ztab, links) {
    let name = typeof zone === "string" ? zone : "";
    for (let hop = 0; name !== "" && hop < MAX_LINKS; hop++) {
        for (const [rows, source] of [[z1970 || {}, "zone1970.tab"], [ztab || {}, "zone.tab"]]) {
            if (Object.prototype.hasOwnProperty.call(rows, name))
                return {lat: rows[name][0], lon: rows[name][1], source: hop === 0 ? source : source + " via link"};
        }
        name = links && Object.prototype.hasOwnProperty.call(links, name) ? links[name] : "";
    }
    return null;
}

// Sunrise and sunset of the calendar date (y, m 1..12, d) at (lat, lon): {rise, set} in epoch ms, or null for a polar day or
// night. The NOAA approximation, as the probe computes it.
function sun(y, m, d, lat, lon) {
    const base = Date.UTC(y, m - 1, d);
    const n = Math.round((base - Date.UTC(y, 0, 1)) / DAY) + 1;
    const g = 2 * Math.PI / 365 * (n - 1);
    const eqt = 229.18 * (0.000075 + 0.001868 * Math.cos(g) - 0.032077 * Math.sin(g) - 0.014615 * Math.cos(2 * g) - 0.040849 * Math.sin(2 * g));
    const decl = 0.006918 - 0.399912 * Math.cos(g) + 0.070257 * Math.sin(g) - 0.006758 * Math.cos(2 * g) + 0.000907 * Math.sin(2 * g) - 0.002697 * Math.cos(3 * g) + 0.00148 * Math.sin(3 * g);
    const la = lat * Math.PI / 180;
    const c = Math.cos(90.833 * Math.PI / 180) / (Math.cos(la) * Math.cos(decl)) - Math.tan(la) * Math.tan(decl);
    if (!isFinite(c) || Math.abs(c) > 1)
        return null;
    const ha = Math.acos(c) * 180 / Math.PI;
    return {rise: base + (720 - 4 * (lon + ha) - eqt) * MINUTE, set: base + (720 - 4 * (lon - ha) - eqt) * MINUTE};
}

// The offsets and fixed hours from the tokens (Tokens.wallpaperPhase*).
function rules(tokens) {
    return {
        dawn: -tokens.wallpaperPhaseDawnBeforeSunriseMin,
        day: tokens.wallpaperPhaseDayAfterSunriseMin,
        evening: -tokens.wallpaperPhaseEveningBeforeSunsetMin,
        night: tokens.wallpaperPhaseNightAfterSunsetMin,
        fixed: {dawn: tokens.wallpaperPhaseFixedDawn, day: tokens.wallpaperPhaseFixedDay, evening: tokens.wallpaperPhaseFixedEvening, night: tokens.wallpaperPhaseFixedNight}
    };
}

// The system's calendar (the shell's time zone, as Qt's Date sees it).
const localCalendar = {
    ymd: ms => {
        const t = new Date(ms);
        return [t.getFullYear(), t.getMonth() + 1, t.getDate()];
    },
    local: (y, m, d, hh, mm) => new Date(y, m - 1, d, hh, mm).getTime()
};

// The day after (y, m, d).
function nextDate(y, m, d) {
    const t = new Date(Date.UTC(y, m - 1, d) + DAY);
    return [t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate()];
}

function previousDate(y, m, d) {
    const t = new Date(Date.UTC(y, m - 1, d) - DAY);
    return [t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate()];
}

// The phase boundaries of one local date: [{phase, at}] in time order, an absent phase left out; `how` says which rule
// applied ("sun", "fixed: no point", "fixed: polar").
function boundaries(y, m, d, point, r, cal) {
    const c = cal || localCalendar;
    const fixed = why => ({how: why, list: PHASES.map(p => {
                const hm = String(r.fixed[p]).split(":");
                return {phase: p, at: c.local(y, m, d, parseInt(hm[0], 10), parseInt(hm[1], 10))};
            })});
    if (!point)
        return fixed("fixed: no point");
    const s = sun(y, m, d, point.lat, point.lon);
    if (s === null)
        return fixed("fixed: polar");
    const at = {dawn: s.rise + r.dawn * MINUTE, day: s.rise + r.day * MINUTE, evening: s.set + r.evening * MINUTE, night: s.set + r.night * MINUTE};
    const list = [];
    if (at.day >= at.evening) {
        // Daylight under (day - evening offsets): no Day; Dawn runs to the middle of the daylight, then Evening.
        list.push({phase: "dawn", at: at.dawn}, {phase: "evening", at: s.rise + (s.set - s.rise) / 2});
    } else {
        list.push({phase: "dawn", at: at.dawn}, {phase: "day", at: at.day}, {phase: "evening", at: at.evening});
    }
    const nd = nextDate(y, m, d);
    const next = sun(nd[0], nd[1], nd[2], point.lat, point.lon);
    // A night under (night - dawn offsets): no Night; Evening runs on to the next Dawn.
    if (!(next !== null && at.night >= next.rise + r.dawn * MINUTE))
        list.push({phase: "night", at: at.night});
    return {how: "sun", rise: s.rise, set: s.set, list: list};
}

// {phase, next, how}: the phase at `now` (ms) and the time of the next boundary, from yesterday's, today's and tomorrow's
// boundaries of the local calendar. `point`: reference() or null.
function at(now, point, r, cal) {
    const c = cal || localCalendar;
    const today = c.ymd(now);
    const days = [previousDate(today[0], today[1], today[2]), today, nextDate(today[0], today[1], today[2])];
    let all = [];
    let how = "";
    for (const dd of days) {
        const b = boundaries(dd[0], dd[1], dd[2], point, r, c);
        if (dd === today)
            how = b.how;
        all = all.concat(b.list);
    }
    all.sort((a, b) => a.at - b.at);
    let phase = "night";
    let next = now + DAY;
    for (const e of all) {
        if (e.at <= now)
            phase = e.phase;
        else {
            next = e.at;
            break;
        }
    }
    return {phase: phase, next: next, how: how};
}
