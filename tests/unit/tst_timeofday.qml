import QtQuick
import QtTest
import Grassfield.Ui

// The Grassfield artwork's phase of the day (ADR-0040 IQ-W1 C, TimeOfDay.js): the zone's reference point (zone1970.tab, then
// zone.tab, then a link), the NOAA sunrise and sunset, the phases and their exceptions, against the figures of the ADR's probe
// (docs/audits/identity-2026-10-29/timeofday-probe.py). The tables are fixtures cut from tzdata 2026e
// (tests/unit/fixtures/zoneinfo). Local times go through a calendar of a fixed offset, so the runner's own zone never matters.
TestCase {
    name: "TimeOfDay"

    function fixture(name) {
        const xhr = new XMLHttpRequest();
        xhr.open("GET", Qt.resolvedUrl("fixtures/zoneinfo/" + name), false);
        xhr.send();
        verify(xhr.responseText.length > 0, name);
        return xhr.responseText;
    }

    function tables() {
        return {z1970: TimeOfDay.parseTable(fixture("zone1970.tab")), ztab: TimeOfDay.parseTable(fixture("zone.tab")), links: TimeOfDay.parseLinks(fixture("tzdata.zi"))};
    }

    function point(zone) {
        const t = tables();
        return TimeOfDay.reference(zone, t.z1970, t.ztab, t.links);
    }

    // A calendar at a fixed offset from UTC (hours).
    function cal(offset) {
        return {
            ymd: ms => {
                const t = new Date(ms + offset * 3600000);
                return [t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate()];
            },
            local: (y, m, d, hh, mm) => Date.UTC(y, m - 1, d, hh, mm) - offset * 3600000
        };
    }

    // Minutes after UTC midnight of that date.
    function utcMinutes(ms) {
        const t = new Date(ms);
        return t.getUTCHours() * 60 + t.getUTCMinutes();
    }

    function hm(s) {
        const p = s.split(":");
        return parseInt(p[0], 10) * 60 + parseInt(p[1], 10);
    }

    function test_coordinates() {
        const p = TimeOfDay.coord("+4852+00220");
        fuzzyCompare(p[0], 48 + 52 / 60, 1e-9);
        fuzzyCompare(p[1], 2 + 20 / 60, 1e-9);
        const ny = TimeOfDay.coord("+404251-0740023");
        fuzzyCompare(ny[0], 40 + 42 / 60 + 51 / 3600, 1e-9);
        fuzzyCompare(ny[1], -(74 + 0 / 60 + 23 / 3600), 1e-9);
        compare(TimeOfDay.coord("48.8,2.3"), null);
        compare(TimeOfDay.coord(""), null);
    }

    function test_theReferencePoint() {
        compare(point("Europe/Paris").source, "zone1970.tab");
        compare(point("America/New_York").source, "zone1970.tab");
        // The owner's zone: an alias tzdata keeps in zone.tab only (review of 6c310a8).
        compare(point("Europe/Amsterdam").source, "zone.tab");
        compare(point("Africa/Douala").source, "zone.tab");
        compare(point("Europe/Stockholm").source, "zone.tab");
        // A link to America/Toronto, in neither table.
        compare(point("America/Montreal").source, "zone1970.tab via link");
        compare(point("UTC"), null);
        compare(point(""), null);
        // A loop of links ends: no point.
        compare(TimeOfDay.reference("A/a", {}, {}, {"A/a": "B/b", "B/b": "A/a"}), null);
    }

    // The probe's figures: sunrise and sunset within 3 minutes (local times turned to UTC).
    function test_sunriseAndSunset_data() {
        return [
            {tag: "Paris 2026-10-29", zone: "Europe/Paris", date: [2026, 10, 29], offset: 1, rise: "07:31", set: "17:37"},
            {tag: "Paris 2026-06-21", zone: "Europe/Paris", date: [2026, 6, 21], offset: 2, rise: "05:46", set: "21:57"},
            {tag: "New York 2026-10-29", zone: "America/New_York", date: [2026, 10, 29], offset: -4, rise: "07:21", set: "17:57"},
            {tag: "Amsterdam 2026-12-21", zone: "Europe/Amsterdam", date: [2026, 12, 21], offset: 1, rise: "08:47", set: "16:28"}
        ];
    }

    function test_sunriseAndSunset(data) {
        const p = point(data.zone);
        const s = TimeOfDay.sun(data.date[0], data.date[1], data.date[2], p.lat, p.lon);
        verify(s !== null);
        verify(Math.abs(utcMinutes(s.rise) - (hm(data.rise) - data.offset * 60)) <= 3, "sunrise " + utcMinutes(s.rise));
        verify(Math.abs(utcMinutes(s.set) - (hm(data.set) - data.offset * 60)) <= 3, "sunset " + utcMinutes(s.set));
    }

    function test_fixedHours() {
        const r = TimeOfDay.rules(Tokens);
        // No point (UTC): the fixed hours, local time.
        const none = TimeOfDay.boundaries(2026, 10, 29, null, r, cal(0));
        compare(none.how, "fixed: no point");
        compare(none.list.map(e => utcMinutes(e.at)), [hm("06:00"), hm("08:00"), hm("18:00"), hm("20:30")]);
        // Polar night and polar day at Longyearbyen.
        const p = point("Arctic/Longyearbyen");
        compare(TimeOfDay.sun(2026, 12, 21, p.lat, p.lon), null);
        compare(TimeOfDay.sun(2026, 6, 21, p.lat, p.lon), null);
        compare(TimeOfDay.boundaries(2026, 12, 21, p, r, cal(1)).how, "fixed: polar");
        compare(TimeOfDay.boundaries(2026, 6, 21, p, r, cal(2)).how, "fixed: polar");
    }

    function test_theOffsetsAreTheTokens() {
        const r = TimeOfDay.rules(Tokens);
        compare([r.dawn, r.day, r.evening, r.night], [-30, 90, -90, 30]);
        compare(r.fixed, {dawn: "06:00", day: "08:00", evening: "18:00", night: "20:30"});
        const p = point("Europe/Paris");
        const b = TimeOfDay.boundaries(2026, 10, 29, p, r, cal(1));
        compare(b.how, "sun");
        compare(b.list.map(e => e.phase), ["dawn", "day", "evening", "night"]);
        compare(b.list[0].at, b.rise - 30 * 60000);
        compare(b.list[1].at, b.rise + 90 * 60000);
        compare(b.list[2].at, b.set - 90 * 60000);
        compare(b.list[3].at, b.set + 30 * 60000);
    }

    // The probe's explicit points: a day under 3 h has no Day, a night under 1 h has no Night.
    function test_shortDayAndShortNight() {
        const r = TimeOfDay.rules(Tokens);
        const shortDay = TimeOfDay.boundaries(2026, 12, 21, {lat: 66.3, lon: 25.7}, r, cal(2));
        compare(shortDay.list.map(e => e.phase), ["dawn", "evening", "night"]);
        // Dawn runs to the middle of the daylight.
        compare(shortDay.list[1].at, shortDay.rise + (shortDay.set - shortDay.rise) / 2);
        const shortNight = TimeOfDay.boundaries(2026, 6, 21, {lat: 65.6, lon: 25.7}, r, cal(3));
        compare(shortNight.list.map(e => e.phase), ["dawn", "day", "evening"]);
    }

    function test_thePhaseNowAndTheNextChange() {
        const r = TimeOfDay.rules(Tokens);
        const p = point("Europe/Paris");
        // 13:00 in Paris on 2026-10-29: Day, until Evening at 17:37 - 90 min = 16:07 (15:07 UTC), within 3 minutes.
        const noon = TimeOfDay.at(Date.UTC(2026, 9, 29, 12, 0), p, r, cal(1));
        compare(noon.phase, "day");
        verify(Math.abs(utcMinutes(noon.next) - hm("15:07")) <= 3, utcMinutes(noon.next));
        // 06:00 there: still the night of the 28th, until Dawn at 07:31 - 30 min = 07:01 (06:01 UTC).
        const early = TimeOfDay.at(Date.UTC(2026, 9, 29, 5, 0), p, r, cal(1));
        compare(early.phase, "night");
        verify(Math.abs(utcMinutes(early.next) - hm("06:01")) <= 3, utcMinutes(early.next));
        // Just after a boundary the phase has changed and the next one is later.
        const after = TimeOfDay.at(noon.next + 1000, p, r, cal(1));
        compare(after.phase, "evening");
        verify(after.next > noon.next);
        // UTC: the fixed hours (at 19:00 Evening, Night at 20:30).
        const utc = TimeOfDay.at(Date.UTC(2026, 9, 29, 19, 0), null, r, cal(0));
        compare(utc.phase, "evening");
        compare(utcMinutes(utc.next), hm("20:30"));
    }

    function test_malformedTables() {
        compare(TimeOfDay.parseTable("garbage\n#comment\nFR\tnot-a-coord\tEurope/Paris\n"), {});
        compare(TimeOfDay.parseTable("FR\t+4852+00220\t../../etc/passwd\n"), {});
        compare(TimeOfDay.parseLinks("L a\nL a b c\nZ x\n"), {});
        compare(TimeOfDay.parseLinks("L Europe/Brussels Europe/Amsterdam\n"), {"Europe/Amsterdam": "Europe/Brussels"});
    }
}
