import QtQuick
import QtTest
import "../../shell/widgets/Weather.js" as Weather
import "../../shell/widgets/Registry.js" as Registry

// The Weather widget's rules (shell/widgets/Weather.js; ADR-0045 OC-14, docs/specs/widgets.md), offline: a j1 report written
// for the test (tests/unit/fixtures/weather-j1.json, Paris at 4:15 PM on 2026-11-04; no network), Omarchy's location file,
// the wttr.in request and curl's vector, Edit Location…'s command, the condition of every WWO code, the unit of the formats
// and the fetch schedule.
TestCase {
    name: "Weather"

    readonly property int maxBytes: 1048576

    function fixture() {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("fixtures/weather-j1.json"), false);
        xhr.send();
        return xhr.responseText;
    }

    function fixtureWith(change) {
        const data = JSON.parse(fixture());
        change(data);
        return JSON.stringify(data);
    }

    // ---- the location -------------------------------------------------------------------------

    function test_locationFile() {
        compare(Weather.parseLocationFile('{"name": "Malibu"}'), {name: "Malibu", latitude: null, longitude: null}, "a name alone");
        compare(Weather.parseLocationFile('{"name": " Lyon ", "latitude": 45.76, "longitude": 4.84}'), {name: "Lyon", latitude: 45.76, longitude: 4.84});
        compare(Weather.parseLocationFile('{"name": "X", "latitude": "45.5", "longitude": "4.5"}').latitude, 45.5, "coordinates as text");
        compare(Weather.parseLocationFile('{"name": "X", "latitude": 95, "longitude": 4}').latitude, null, "a latitude out of range");
        compare(Weather.parseLocationFile('{"name": "X", "latitude": 45}').latitude, null, "half a pair");
        const unset = {name: "", latitude: null, longitude: null};
        for (const text of ["", "   ", "{", "null", "[]", "42", '"Paris"', '{"name": 42}'])
            compare(Weather.parseLocationFile(text), unset, JSON.stringify(text));
        compare(Weather.parseLocationFile('{"name": "a\\nb\\u0007c"}').name, "a b c", "control characters");
        compare(Weather.parseLocationFile(JSON.stringify({name: "x".repeat(500)})).name.length, Weather.NAME_MAX, "a long name is cut");
    }

    function test_locationQueryAndUrl() {
        compare(Weather.locationQuery({name: "", latitude: null, longitude: null}), "", "unset: the IP address's place");
        compare(Weather.locationQuery({name: "Saint-Étienne", latitude: null, longitude: null}), "Saint-%C3%89tienne");
        compare(Weather.locationQuery({name: "a/b?c#d e", latitude: null, longitude: null}), "a%2Fb%3Fc%23d%20e", "no path, query or fragment");
        compare(Weather.locationQuery({name: "Lyon", latitude: 45.76, longitude: 4.84}), "45.76,4.84", "coordinates first");
        compare(Weather.reportUrl(Weather.BASE_URL, ""), "https://wttr.in/?format=j1");
        compare(Weather.reportUrl(Weather.BASE_URL, "Lyon"), "https://wttr.in/Lyon?format=j1");
        compare(Weather.reportUrl("http://127.0.0.1:8123", "Lyon"), "http://127.0.0.1:8123/Lyon?format=j1", "a dev session's test server");
        compare(Weather.reportUrl("https://example.com", "Lyon"), "", "no other host");
        compare(Weather.reportUrl("http://127.0.0.1:8123/x", "Lyon"), "", "a loopback origin only");
        compare(Weather.devBaseUrl("http://127.0.0.1:8123"), "http://127.0.0.1:8123");
        for (const bad of ["", "http://localhost:8123", "https://127.0.0.1:8123", "http://127.0.0.1", "http://10.0.0.1:80", "http://127.0.0.1:8123/"])
            compare(Weather.devBaseUrl(bad), "", bad);
    }

    function test_fetchArgs() {
        const args = Weather.fetchArgs("https://wttr.in/Lyon?format=j1", 10, maxBytes);
        compare(args[0], "curl");
        compare(args[args.length - 1], "https://wttr.in/Lyon?format=j1", "the URL last");
        compare(args[args.length - 2], "--", "after --");
        verify(args.indexOf("-fsS") > 0, "fail on HTTP errors, quiet");
        compare(args[args.indexOf("--proto") + 1], "=https", "https only");
        compare(args[args.indexOf("--proto-redir") + 1], "=https", "redirects too");
        compare(args[args.indexOf("--max-time") + 1], "10");
        compare(args[args.indexOf("--max-filesize") + 1], String(maxBytes));
        compare(Weather.fetchArgs("http://127.0.0.1:8123/Lyon?format=j1", 10, maxBytes)[3], "=http", "the loopback test server");
        for (const bad of ["", "http://wttr.in/Lyon", "https://wttr.in.example.com/x", "https://evil.example/https://wttr.in/", "file:///etc/passwd"])
            compare(Weather.fetchArgs(bad, 10, maxBytes), null, bad);
    }

    function test_locationArgs() {
        compare(Weather.locationArgs("Lyon", 100), ["omarchy-weather-location", "--set", "Lyon"]);
        compare(Weather.locationArgs("  New York ", 100), ["omarchy-weather-location", "--set", "New York"], "trimmed");
        compare(Weather.locationArgs("--clear", 100), ["omarchy-weather-location", "--set", "--clear"], "a name is the argument after --set, whatever it says");
        compare(Weather.locationArgs("", 100), ["omarchy-weather-location", "--clear"], "empty: back to the IP address's place");
        compare(Weather.locationArgs("   ", 100), ["omarchy-weather-location", "--clear"]);
        compare(Weather.locationArgs("x".repeat(101), 100), null, "too long");
    }

    // ---- the report ---------------------------------------------------------------------------

    function test_parseReport() {
        const r = Weather.parseReport(fixture(), maxBytes, 5);
        verify(r !== null);
        compare(r.area, "Paris");
        compare(r.observed, {date: "2026-11-04", minutes: 16 * 60 + 15});
        compare(r.current.tempC, 12);
        compare(r.current.tempF, 54);
        compare(r.current.code, 116);
        compare(r.current.night, false, "4:15 PM is before the 5:16 PM sunset");
        compare(r.current.windKmph, 15);
        compare(r.high, {c: 14, f: 57});
        compare(r.low, {c: 7, f: 44});
        // The slots after 4:15 PM: 6 PM and 9 PM today, then midnight, 3 AM, 6 AM tomorrow.
        compare(r.hours.map(h => h.date + " " + h.minutes), ["2026-11-04 1080", "2026-11-04 1260", "2026-11-05 0", "2026-11-05 180", "2026-11-05 360"]);
        compare(r.hours.map(h => h.code), [266, 113, 113, 143, 248]);
        compare(r.hours.map(h => h.night), [true, true, true, true, true], "all after sunset and before sunrise");
        compare(r.hours.map(h => h.tempC), [11, 9, 7, 5, 3]);
        compare(Weather.parseReport(fixture(), maxBytes, 9).hours[5].night, false, "9 AM tomorrow is day");
        compare(Weather.parseReport(fixture(), maxBytes, 100).hours.length, 18, "every slot left of the three days, the unknown code too");
    }

    function test_parseReportNight() {
        const text = fixtureWith(d => d.current_condition[0].localObsDateTime = "2026-11-04 10:40 PM");
        const r = Weather.parseReport(text, maxBytes, 3);
        verify(r.current.night, "after sunset");
        compare(r.hours[0].date + " " + r.hours[0].minutes, "2026-11-05 0", "the next slot is tomorrow's");
        compare(Weather.condition(r.current.code, r.current.night).symbol, "cloud-moon");
    }

    function test_parseReportRefusals() {
        compare(Weather.parseReport("", maxBytes, 5), null, "empty");
        compare(Weather.parseReport("<html>wttr.in is down</html>", maxBytes, 5), null, "not JSON");
        compare(Weather.parseReport(fixture(), 100, 5), null, "larger than the cap");
        compare(Weather.parseReport("[]", maxBytes, 5), null, "not an object");
        compare(Weather.parseReport('{"current_condition": []}', maxBytes, 5), null, "no current condition");
        compare(Weather.parseReport(fixtureWith(d => d.current_condition[0].temp_C = "n/a"), maxBytes, 5), null, "no temperature");
        compare(Weather.parseReport(fixtureWith(d => delete d.current_condition[0].weatherCode), maxBytes, 5), null, "no code");
    }

    function test_parseReportDegrades() {
        const noWeather = Weather.parseReport(fixtureWith(d => d.weather = "x"), maxBytes, 5);
        compare(noWeather.high, null, "no forecast: no high and low");
        compare(noWeather.hours, []);
        compare(noWeather.current.tempC, 12, "the current values still");
        const polar = Weather.parseReport(fixtureWith(d => d.weather[0].astronomy[0].sunset = "No sunset"), maxBytes, 5);
        compare(polar.current.night, false, "no sunset: day symbols");
        const noTime = Weather.parseReport(fixtureWith(d => d.current_condition[0].localObsDateTime = "later"), maxBytes, 2);
        compare(noTime.observed, null);
        compare(noTime.hours.map(h => h.minutes), [0, 180], "no observation time: the first day's slots from midnight");
        const noArea = Weather.parseReport(fixtureWith(d => d.nearest_area = null), maxBytes, 5);
        compare(noArea.area, "");
        const badSlot = Weather.parseReport(fixtureWith(d => d.weather[0].hourly[6].tempC = ""), maxBytes, 1);
        compare(badSlot.hours[0].minutes, 1260, "a slot without a temperature is skipped");
        const shuffled = Weather.parseReport(fixtureWith(d => d.weather[0].hourly.reverse()), maxBytes, 2);
        compare(shuffled.hours.map(h => h.minutes), [1080, 1260], "slots in time order");
        const area = Weather.parseReport(fixtureWith(d => d.nearest_area[0].areaName[0].value = "Pa\u0000ris\n"), maxBytes, 1);
        compare(area.area, "Pa ris", "an answer's name is cleaned");
    }

    // ---- conditions, units, text ----------------------------------------------------------------

    function test_conditions() {
        const expected = {
            113: ["clear", "sun", "moon"], 116: ["partlyCloudy", "cloud-sun", "cloud-moon"], 119: ["cloudy", "cloud", "cloud"],
            122: ["cloudy", "cloud", "cloud"], 143: ["fog", "cloud-fog", "cloud-fog"], 248: ["fog", "cloud-fog", "cloud-fog"],
            260: ["fog", "cloud-fog", "cloud-fog"], 176: ["rain", "cloud-rain", "cloud-rain"], 263: ["drizzle", "cloud-drizzle", "cloud-drizzle"],
            266: ["drizzle", "cloud-drizzle", "cloud-drizzle"], 293: ["rain", "cloud-rain", "cloud-rain"], 308: ["heavyRain", "cloud-rain", "cloud-rain"],
            185: ["freezingDrizzle", "cloud-sleet", "cloud-sleet"], 314: ["freezingRain", "cloud-sleet", "cloud-sleet"],
            320: ["sleet", "cloud-sleet", "cloud-sleet"], 326: ["snow", "cloud-snow", "cloud-snow"], 338: ["heavySnow", "cloud-snow", "cloud-snow"],
            227: ["blowingSnow", "cloud-snow", "cloud-snow"], 230: ["blizzard", "cloud-snow", "cloud-snow"],
            200: ["thunderstorms", "cloud-bolt", "cloud-bolt"], 395: ["thunderstorms", "cloud-bolt", "cloud-bolt"]
        };
        for (const code in expected) {
            const e = expected[code];
            compare(Weather.condition(code, false), {key: e[0], symbol: e[1]}, code + " by day");
            compare(Weather.condition(Number(code), true), {key: e[0], symbol: e[2]}, code + " by night");
        }
        compare(Weather.condition(999, false), {key: "unknown", symbol: "cloud"});
        compare(Weather.condition("n/a", true), {key: "unknown", symbol: "cloud"});
        // Every code WWO documents has a condition (wttr.in's constants), none twice.
        const all = [113, 116, 119, 122, 143, 176, 179, 182, 185, 200, 227, 230, 248, 260, 263, 266, 281, 284, 293, 296, 299, 302, 305, 308, 311,
                     314, 317, 320, 323, 326, 329, 332, 335, 338, 350, 353, 356, 359, 362, 365, 368, 371, 374, 377, 386, 389, 392, 395];
        const seen = {};
        for (const c of Weather.CONDITIONS) {
            for (const k of c.codes) {
                verify(!(k in seen), "code " + k + " once");
                seen[k] = true;
            }
        }
        for (const k of all)
            verify(Weather.condition(k, false).key !== "unknown", "code " + k);
    }

    function test_symbolsExist() {
        const symbols = {};
        for (const c of Weather.CONDITIONS) {
            symbols[c.day] = true;
            symbols[c.night] = true;
        }
        symbols["location"] = true;
        for (const s in symbols) {
            const xhr = new XMLHttpRequest();
            xhr.open("GET", Qt.resolvedUrl("../../branding/icons/symbolic/" + s + ".svg"), false);
            xhr.send();
            verify(xhr.responseText.indexOf("<svg") === 0, s + ".svg in the symbolic set");
        }
    }

    function test_units() {
        verify(Weather.useFahrenheit("en_US"));
        verify(Weather.useFahrenheit("en_US.UTF-8"));
        verify(Weather.useFahrenheit("en-US"));
        verify(Weather.useFahrenheit("en_LR"));
        verify(Weather.useFahrenheit("my_MM"));
        for (const name of ["fr_FR", "fr_CA", "en_GB", "en_CA", "en", "de_DE", "C", "", "en_USX", "mya_XX"])
            verify(!Weather.useFahrenheit(name), name);
        const r = Weather.parseReport(fixture(), maxBytes, 1);
        compare(Weather.pick({c: r.current.tempC, f: r.current.tempF}, true), 54);
        compare(Weather.pick(r.high, false), 14);
        compare(Weather.pick(r.hours[0], true), 52);
        compare(Weather.pick(null, true), null);
        compare(Weather.tempText(12), "12°");
        compare(Weather.tempText(-2.6), "-3°");
        compare(Weather.tempText(-0.4), "0°", "no minus zero");
        compare(Weather.tempText(null), "--");
        compare(Weather.tempText(NaN), "--");
    }

    function test_placeAndClock() {
        const r = Weather.parseReport(fixture(), maxBytes, 1);
        compare(Weather.placeName({name: "Lyon", latitude: null, longitude: null}, r), "Lyon", "the saved name");
        compare(Weather.placeName({name: "", latitude: null, longitude: null}, r), "Paris", "the answer's area");
        compare(Weather.placeName({name: "", latitude: null, longitude: null}, null), "");
        verify(Weather.usesTwelveHours("h:mm AP"));
        verify(Weather.usesTwelveHours("h:mm ap"));
        verify(!Weather.usesTwelveHours("HH:mm"));
        verify(!Weather.usesTwelveHours("HH 'h' mm"), "quoted text is not a marker");
    }

    // ---- the schedule ---------------------------------------------------------------------------

    function test_schedule() {
        const refresh = 1800000;
        const retry = 120000;
        let s = Weather.emptyState();
        compare(Weather.nextDelay(s, 1000, refresh, retry), 0, "the first fetch at once");
        compare(Weather.status(s, null), "loading");
        s = Weather.afterFetch(s, 1000, true);
        compare(Weather.nextDelay(s, 1000, refresh, retry), refresh, "then every 30 minutes");
        compare(Weather.nextDelay(s, 1000 + refresh - 5, refresh, retry), 5);
        compare(Weather.nextDelay(s, 1000 + 3 * refresh, refresh, retry), 0, "overdue (a suspended machine): at once");
        compare(Weather.status(s, {}), "ok");
        s = Weather.afterFetch(s, 5000, false);
        compare(s.lastOkAt, 1000, "the last good time stays");
        compare(Weather.status(s, {}), "unavailable", "a failure: unavailable, the last values greyed");
        compare(Weather.nextDelay(s, 5000, refresh, retry), retry, "first retry");
        s = Weather.afterFetch(s, 6000, false);
        compare(Weather.nextDelay(s, 6000, refresh, retry), 2 * retry, "doubled");
        for (let i = 0; i < 30; i++)
            s = Weather.afterFetch(s, 7000, false);
        compare(Weather.nextDelay(s, 7000, refresh, retry), refresh, "never longer than the refresh");
        s = Weather.afterFetch(s, 8000, true);
        compare(s.failures, 0);
        compare(Weather.status(s, {}), "ok", "a success clears it");
    }

    // ---- the registry ---------------------------------------------------------------------------

    function test_registry() {
        const m = Registry.find("weather");
        verify(m !== null, "registered");
        compare(m.sizes, ["small", "medium"]);
        compare(m.permissions, ["weather"]);
        compare(Registry.validateManifest(m), "");
        compare(Registry.validateManifest(Object.assign({}, m, {permissions: ["network"]})), "unknown permission network", "network is still no permission");
    }
}
