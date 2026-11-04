.pragma library

// The Weather widget's rules (ADR-0045 OC-14, docs/specs/widgets.md), pure for the tests (tests/unit/tst_weather.qml, over
// tests/unit/fixtures/weather-j1.json): Omarchy's saved location, the wttr.in request and the curl argument vector, the j1
// report reduced to what the widget shows, a WWO weather code's condition (a key the widget translates, a symbol of
// branding/icons/symbolic), the temperature unit of the formats, and when to fetch again. WeatherSampler.qml runs them.
//
// Derived from Omarchy v4.0.6, Copyright (c) David Heinemeier Hansson, MIT License (upstream LICENSE, basecamp/omarchy@237f1b4;
// notice shipped as packaging/licenses/omarchy-MIT.txt): the location file's format and its reading follow
// bin/omarchy-weather-location and shell/plugins/panels/weather/Model.js (parseLocationFile, wttrLocationQuery,
// localeUsesImperial); the request is the one of that panel, shell/plugins/panels/weather/Panel.qml
// (`curl ... https://wttr.in/<query>?format=j1`). Nothing else of it is used: the panel's Open-Meteo forecast and geocoding
// are not (OC-14 names wttr.in only).

const BASE_URL = "https://wttr.in";
const LOCATION_COMMAND = "omarchy-weather-location";
// The longest place or area name kept from a file or an answer (longer ones are cut).
const NAME_MAX = 100;

// Trimmed text without control characters (a name from a file or from the network is shown as plain text, never parsed).
function cleanName(value) {
    if (typeof value !== "string")
        return "";
    return value.replace(/[\u0000-\u001f\u007f-\u009f\u2028\u2029]/g, " ").replace(/^\s+|\s+$/g, "").substring(0, NAME_MAX);
}

// Omarchy's weather.json ({"name": ..., "latitude": ..., "longitude": ...}, owned by omarchy-weather-location): missing,
// blank, unparsable or not an object means unset (wttr.in then finds the place from the IP address). Coordinates count only
// as a pair in range.
function parseLocationFile(text) {
    const unset = {name: "", latitude: null, longitude: null};
    let data = null;
    try {
        data = JSON.parse(String(text || ""));
    } catch (e) {
        return unset;
    }
    if (data === null || typeof data !== "object" || Array.isArray(data))
        return unset;
    const lat = parseFloat(data.latitude);
    const lon = parseFloat(data.longitude);
    const pair = isFinite(lat) && isFinite(lon) && Math.abs(lat) <= 90 && Math.abs(lon) <= 180;
    return {name: cleanName(data.name), latitude: pair ? lat : null, longitude: pair ? lon : null};
}

// The wttr.in path segment: the coordinates when there are, else the URL-encoded name, else "" (the IP address's place).
function locationQuery(loc) {
    if (!loc)
        return "";
    if (loc.latitude !== null && loc.longitude !== null && isFinite(loc.latitude) && isFinite(loc.longitude))
        return String(loc.latitude) + "," + String(loc.longitude);
    return loc.name ? encodeURIComponent(loc.name) : "";
}

// The loopback origin of a dev session's test server (GRASSFIELD_WEATHER_BASE_URL, http://127.0.0.1:<port>), "" otherwise.
function devBaseUrl(value) {
    const v = String(value || "");
    return /^http:\/\/127\.0\.0\.1:\d{1,5}$/.test(v) ? v : "";
}

// The j1 report's URL for a query; "" for a base that is neither wttr.in nor a loopback test server.
function reportUrl(base, query) {
    if (base !== BASE_URL && devBaseUrl(base) === "")
        return "";
    return base + "/" + String(query || "") + "?format=j1";
}

// curl's argument vector for a report URL (one run, no shell): failures as an exit code (-f), quiet but for errors, only the
// URL's own protocol (https; http for the loopback test server) for the request and any redirect, at most `seconds` and
// `maxBytes`. null for any other URL.
function fetchArgs(url, seconds, maxBytes) {
    const u = String(url || "");
    let proto = "";
    if (u.startsWith(BASE_URL + "/"))
        proto = "=https";
    else if (/^http:\/\/127\.0\.0\.1:\d{1,5}\//.test(u))
        proto = "=http";
    else
        return null;
    return ["curl", "-fsS", "--proto", proto, "--proto-redir", proto, "--max-redirs", "3", "--max-time", String(seconds),
            "--max-filesize", String(maxBytes), "-H", "Accept: application/json", "--", u];
}

// Edit Location…'s command (Omarchy's own, argument vector): `--set <name>`, or `--clear` (back to the IP address's place)
// for an empty name; null for a name that is too long.
function locationArgs(name, maxChars) {
    const n = cleanName(name);
    if (String(name || "").replace(/^\s+|\s+$/g, "").length > maxChars)
        return null;
    return n === "" ? [LOCATION_COMMAND, "--clear"] : [LOCATION_COMMAND, "--set", n];
}

function num(v) {
    if (v === null || v === undefined || v === "")
        return null;
    const n = parseFloat(v);
    return isFinite(n) ? n : null;
}

function first(list) {
    return Array.isArray(list) && list.length > 0 && list[0] !== null && typeof list[0] === "object" ? list[0] : null;
}

function valueOf(list) {
    const o = first(list);
    return o ? cleanName(o.value) : "";
}

// "07:58 AM" -> 478; null for anything else ("No sunrise" in polar days and nights).
function clockMinutes(text) {
    const m = /^(\d{1,2}):(\d{2})\s*(AM|PM)$/i.exec(String(text || "").replace(/^\s+|\s+$/g, ""));
    if (!m)
        return null;
    const h = parseInt(m[1], 10);
    const min = parseInt(m[2], 10);
    if (h < 1 || h > 12 || min > 59)
        return null;
    return (h % 12 + (m[3].toUpperCase() === "PM" ? 12 : 0)) * 60 + min;
}

// The place's local date and time of the observation: "2026-11-04 04:15 PM" -> {date: "2026-11-04", minutes: 975}.
function observed(text) {
    const m = /^(\d{4}-\d{2}-\d{2})\s+(.+)$/.exec(String(text || "").replace(/^\s+|\s+$/g, ""));
    if (!m)
        return null;
    const minutes = clockMinutes(m[2]);
    return minutes === null ? null : {date: m[1], minutes: minutes};
}

// Sunrise and sunset of a j1 day, in the place's minutes; null when either is missing (polar day or night: the day symbols).
function sunOf(day) {
    const a = day ? first(day.astronomy) : null;
    if (!a)
        return null;
    const rise = clockMinutes(a.sunrise);
    const set = clockMinutes(a.sunset);
    return rise === null || set === null || rise >= set ? null : {rise: rise, set: set};
}

function isNight(minutes, sun) {
    return minutes !== null && sun !== null && (minutes < sun.rise || minutes >= sun.set);
}

// "1500" -> 900 (j1's hourly "time" is hhmm without padding: "0", "300", ... "2100").
function slotMinutes(time) {
    const t = parseInt(String(time), 10);
    if (!isFinite(t) || t < 0 || t > 2359 || t % 100 > 59)
        return null;
    return Math.floor(t / 100) * 60 + t % 100;
}

// A wttr.in j1 answer reduced to what the widget shows, or null when it is not one (not JSON, larger than maxBytes, no
// current temperature or code):
//   {area, observed: {date, minutes} | null, current: {tempC, tempF, code, night, windKmph, windMph},
//    high: {c, f} | null, low: {c, f} | null, hours: [{date, minutes, tempC, tempF, code, night}, ...]}
// `hours` are the forecast slots after the observation, in order (j1 has one every three hours, for three days), at most
// `maxHours`. Times are the place's own, as wttr.in gives them.
function parseReport(text, maxBytes, maxHours) {
    if (typeof text !== "string" || text.length === 0 || text.length > maxBytes)
        return null;
    let data = null;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (data === null || typeof data !== "object" || Array.isArray(data))
        return null;
    const cur = first(data.current_condition);
    if (!cur)
        return null;
    const tempC = num(cur.temp_C);
    const tempF = num(cur.temp_F);
    const code = parseInt(cur.weatherCode, 10);
    if (tempC === null || tempF === null || !isFinite(code))
        return null;
    const obs = observed(cur.localObsDateTime);
    const days = (Array.isArray(data.weather) ? data.weather : []).filter(d => d !== null && typeof d === "object" && typeof d.date === "string");
    const today = (obs ? days.find(d => d.date === obs.date) : null) || days[0] || null;
    const hiC = today ? num(today.maxtempC) : null;
    const hiF = today ? num(today.maxtempF) : null;
    const loC = today ? num(today.mintempC) : null;
    const loF = today ? num(today.mintempF) : null;
    const hours = [];
    for (let i = 0; i < days.length && hours.length < maxHours; i++) {
        const d = days[i];
        if (obs && d.date < obs.date)
            continue;
        const sun = sunOf(d);
        const slots = (Array.isArray(d.hourly) ? d.hourly : []).map(h => ({h: h, minutes: h && typeof h === "object" ? slotMinutes(h.time) : null}))
            .filter(s => s.minutes !== null).sort((a, b) => a.minutes - b.minutes);
        for (let j = 0; j < slots.length && hours.length < maxHours; j++) {
            const s = slots[j];
            if (obs && d.date === obs.date && s.minutes <= obs.minutes)
                continue;
            const c = num(s.h.tempC);
            const f = num(s.h.tempF);
            const k = parseInt(s.h.weatherCode, 10);
            if (c === null || f === null || !isFinite(k))
                continue;
            hours.push({date: d.date, minutes: s.minutes, tempC: c, tempF: f, code: k, night: isNight(s.minutes, sun)});
        }
    }
    const area = first(data.nearest_area);
    return {
        area: area ? valueOf(area.areaName) : "",
        observed: obs,
        current: {
            tempC: tempC,
            tempF: tempF,
            code: code,
            night: isNight(obs ? obs.minutes : null, sunOf(today)),
            windKmph: num(cur.windspeedKmph),
            windMph: num(cur.windspeedMiles)
        },
        high: hiC !== null && hiF !== null ? {c: hiC, f: hiF} : null,
        low: loC !== null && loF !== null ? {c: loC, f: loF} : null,
        hours: hours
    };
}

// WWO weather codes (wttr.in's weatherCode) -> the condition the widget names and its symbol. Clear and partly cloudy have
// a night symbol; everything else is drawn the same by day and by night.
const CONDITIONS = [
    {key: "clear", codes: [113], day: "sun", night: "moon"},
    {key: "partlyCloudy", codes: [116], day: "cloud-sun", night: "cloud-moon"},
    {key: "cloudy", codes: [119, 122], day: "cloud", night: "cloud"},
    {key: "fog", codes: [143, 248, 260], day: "cloud-fog", night: "cloud-fog"},
    {key: "drizzle", codes: [263, 266], day: "cloud-drizzle", night: "cloud-drizzle"},
    {key: "freezingDrizzle", codes: [185, 281, 284], day: "cloud-sleet", night: "cloud-sleet"},
    {key: "rain", codes: [176, 293, 296, 299, 302, 353, 356], day: "cloud-rain", night: "cloud-rain"},
    {key: "heavyRain", codes: [305, 308, 359], day: "cloud-rain", night: "cloud-rain"},
    {key: "freezingRain", codes: [311, 314], day: "cloud-sleet", night: "cloud-sleet"},
    {key: "sleet", codes: [182, 317, 320, 350, 362, 365, 374, 377], day: "cloud-sleet", night: "cloud-sleet"},
    {key: "snow", codes: [179, 323, 326, 329, 332, 368], day: "cloud-snow", night: "cloud-snow"},
    {key: "heavySnow", codes: [335, 338, 371], day: "cloud-snow", night: "cloud-snow"},
    {key: "blowingSnow", codes: [227], day: "cloud-snow", night: "cloud-snow"},
    {key: "blizzard", codes: [230], day: "cloud-snow", night: "cloud-snow"},
    {key: "thunderstorms", codes: [200, 386, 389, 392, 395], day: "cloud-bolt", night: "cloud-bolt"}
];

// {key, symbol}; an unknown code is "unknown" with the plain cloud.
function condition(code, night) {
    const c = parseInt(code, 10);
    for (let i = 0; i < CONDITIONS.length; i++) {
        if (CONDITIONS[i].codes.indexOf(c) >= 0)
            return {key: CONDITIONS[i].key, symbol: night ? CONDITIONS[i].night : CONDITIONS[i].day};
    }
    return {key: "unknown", symbol: "cloud"};
}

// °F for the formats of the United States, Liberia and Myanmar (Omarchy's localeUsesImperial), °C everywhere else.
function useFahrenheit(localeName) {
    const name = String(localeName || "").replace(".", "_");
    return /^en[_-]US($|[_.@-])/.test(name) || /^en[_-]LR($|[_.@-])/.test(name) || /^my($|[_.@-])/.test(name);
}

// A temperature as the widget writes it: whole degrees and the degree sign ("12°", "-3°"); "--" when unknown.
function tempText(value) {
    if (value === null || value === undefined || !isFinite(value))
        return "--";
    return String(Math.round(value) || 0) + "°";
}

// A {c, f} pair or a {tempC, tempF} slot in the unit chosen.
function pick(pair, fahrenheit) {
    if (!pair)
        return null;
    if ("tempC" in pair)
        return fahrenheit ? pair.tempF : pair.tempC;
    return fahrenheit ? pair.f : pair.c;
}

// The place shown: Omarchy's saved name, else the area wttr.in answered for.
function placeName(loc, report) {
    if (loc && loc.name)
        return loc.name;
    return report ? report.area : "";
}

// The hour of a slot for the row of hours: {hour (0..23), twelve} -> a 12-hour clock writes "5PM" (macOS), a 24-hour one
// the hour alone. `format` is the locale's short time format (Qt: "h:mm AP" or "HH:mm").
function usesTwelveHours(format) {
    return /a/i.test(String(format || "").replace(/'[^']*'/g, ""));
}

// The fetch schedule. State {lastOkAt, lastTryAt, failures} (ms since the epoch, 0 = never). The first fetch is at once;
// after a success the next is refreshMs later; after a failure retryMs later, doubled with each further failure up to
// refreshMs. Returns the ms to wait (0: due now).
function nextDelay(state, now, refreshMs, retryMs) {
    const s = state || {};
    if (!s.lastTryAt)
        return 0;
    let due = 0;
    if (s.failures > 0)
        due = s.lastTryAt + Math.min(refreshMs, retryMs * Math.pow(2, Math.min(s.failures - 1, 20)));
    else
        due = (s.lastOkAt || s.lastTryAt) + refreshMs;
    return Math.max(0, due - now);
}

function afterFetch(state, now, ok) {
    const s = state || {};
    return ok ? {lastOkAt: now, lastTryAt: now, failures: 0} : {lastOkAt: s.lastOkAt || 0, lastTryAt: now, failures: (s.failures || 0) + 1};
}

function emptyState() {
    return {lastOkAt: 0, lastTryAt: 0, failures: 0};
}

// What the widget says: "loading" before the first answer, "ok" after a fetch that worked, "unavailable" after one that
// failed (the last good values, if any, stay and are greyed).
function status(state, report) {
    const s = state || {};
    if (s.failures > 0)
        return "unavailable";
    return report ? "ok" : "loading";
}
