import QtQuick
import QtTest
import "../../shell/platform/Minimized.js" as Minimized
import "../../shell/platform/StagesState.js" as StagesState
import "../../shell/stages/Layout.js" as Layout

// Stages shell side (docs/specs/stages.md "Shell side"): the verb and config builders, the event state, the strip layout and
// what clicks and drops ask of the plugin. Test names state the user-visible rule.
TestCase {
    name: "Stages"

    readonly property var t: ({tileWidth: 160, tileHeight: 120, tileGap: 24, edgeMargin: 12, maxTiles: 8, revealZone: 6})
    readonly property var screen: ({x: 0, y: 0, width: 1920, height: 1080})
    readonly property var insets: ({left: 0, top: 32, bottom: 0})

    function event(extra) {
        const base = {v: "gfc/1", type: "stages", on: true, monitors: [{monitor: "GF-REF", workspace: 2, active: 5, hidden: false, overlap: false,
                stages: [{id: 5, slot: -1, windows: [{address: "aa"}]},
                         {id: 7, slot: 0, windows: [{address: "b1", x: 10, y: 20, w: 100, h: 80}, {address: "b2", x: 12, y: 22, w: 100, h: 80}]},
                         {id: 9, slot: 1, windows: [{address: "0xC3"}]}]}]};
        return JSON.stringify(Object.assign(base, extra || {}));
    }

    function mon() {
        return StagesState.parse(event()).monitors["GF-REF"];
    }

    // ---- plugin verb and config ----

    function test_stagesIsAGuardedPluginVerb() {
        verify(Minimized.isPluginVerb("stages"));
        verify(Minimized.guardedPluginCall("stages", ["\"{}\""]).indexOf("p.stages") > 0);
    }

    function test_theVerbAcceptsOnlyTheFiveOperationsAndIsGuarded() {
        const strips = [{monitor: "GF-REF", hidden: false, tiles: [{x: 12, y: 100, w: 160, h: 120}]}];
        const lua = Minimized.stagesCall({op: "on", durationMs: 350, curve: [0.2, 0, 0, 1], strips: strips});
        verify(lua.indexOf("p.stages(") > 0);
        verify(lua.indexOf("\\\"op\\\":\\\"on\\\"") > 0);
        for (const op of ["off", "activate", "merge", "move"])
            verify(Minimized.stagesCall({op: op}) !== "");
        compare(Minimized.stagesCall({op: "explode"}), "");
        compare(Minimized.stagesCall({}), "");
        compare(Minimized.stagesCall(null), "");
        compare(Minimized.stagesCall([1]), "");
    }

    function test_whatTheStripBuildsIsWithinTheContractLimits() {
        // The plugin validates strictly (docs/specs/stages.md contract 3); the shell's own requests stay inside the limits.
        const g = Layout.geometry(screen, insets, 8, t);
        const req = Layout.onRequest([{monitor: "GF-REF", hidden: false, tiles: g.tiles}], 350, [0.2, 0, 0, 1]);
        verify(Minimized.stagesCall(req).length < 8192);
        for (const r of g.tiles)
            verify(r.w >= 16 && r.w <= 800 && r.h >= 16 && r.h <= 800);
        compare(g.tiles.length, 8);
    }

    // ---- event state ----

    function test_theEventBecomesAStatePerMonitor() {
        const s = StagesState.parse(event());
        verify(s.on);
        compare(s.reason, "");
        compare(s.monitors["GF-REF"].active, 5);
        compare(s.monitors["GF-REF"].stages.length, 3);
        compare(s.monitors["GF-REF"].stages[2].windows[0].address, "c3");
    }

    // ADR-0007 amendment 2026-10-24: the event is a change notice (Hyprland cuts socket2 events at 1024 bytes); the state
    // with its monitors comes from `hyprctl grassfield-stages`.
    function test_aNoticeIsNotAState() {
        const text = JSON.stringify({v: "gfc/1", type: "stages", gen: 42, on: true});
        const n = StagesState.parseNotice(text);
        verify(n.on);
        compare(n.gen, 42);
        compare(n.reason, "");
        compare(n.monitors, undefined, "a notice never carries monitors");
        verify(!StagesState.parse(text).complete, "a notice read as a reply is not a state");
        const s = StagesState.parse(event({gen: 43}));
        verify(s.complete);
        compare(s.gen, 43);
        compare(StagesState.parse(event()).gen, -1, "no generation");
        compare(StagesState.parseNotice(JSON.stringify({v: "gfc/1", type: "stages", gen: -5, on: false})).gen, -1);
        compare(StagesState.parseNotice(JSON.stringify({v: "gfc/1", type: "stages", gen: 3, on: false, reason: "interrupted"})).reason, "interrupted");
        compare(StagesState.parseNotice(JSON.stringify({v: "gfc/1", type: "stages", gen: 3, on: false, reason: "made-up"})).reason, "");
        compare(StagesState.parseNotice(JSON.stringify({v: "gfc/1", type: "minimize", gen: 3, on: true})), null);
        compare(StagesState.parseNotice(JSON.stringify({v: "gfc/2", type: "stages", gen: 3, on: true})), null);
        compare(StagesState.parseNotice("not json"), null);
    }

    // ---- the state fetch (StagesLink runs one `hyprctl grassfield-stages` at a time; a fake fetcher here) ----

    // A fake StagesLink: applies StagesState's fetch steps and counts the fetches started; `retryMs` is the last backoff
    // asked (0 none), `staleMs` when the time bound wants a look (0 none), `state` what the strip would show, `now` a
    // fake clock in ms (advance with wait(), which also fires the time bound when it falls due, as StagesLink's timer).
    function link(active) {
        return {
            fetch: StagesState.newFetch(),
            state: null,
            started: 0,
            retryMs: 0,
            staleMs: 0,
            staleAt: -1,
            now: 1000,
            active: active === undefined ? true : active,
            ctx: function () {
                return {active: this.active, shown: this.state, now: this.now};
            },
            apply: function (out) {
                this.fetch = out.fetch;
                if (out.state !== undefined)
                    this.state = out.state;
                this.retryMs = out.retryMs;
                this.staleMs = out.staleMs;
                this.staleAt = out.staleMs > 0 ? this.now + out.staleMs : -1;
                if (out.start)
                    this.started += 1;
            },
            wait: function (ms) {
                const until = this.now + ms;
                if (this.staleAt >= 0 && this.staleAt <= until) {
                    this.now = this.staleAt;
                    this.apply(StagesState.onTick(this.fetch, this.ctx()));
                }
                this.now = until;
            },
            notice: function (gen, on) {
                const text = JSON.stringify({v: "gfc/1", type: "stages", gen: gen, on: on !== false});
                this.apply(StagesState.onNotice(this.fetch, StagesState.parseNotice(text), this.ctx()));
            },
            reply: function (text) {
                this.apply(StagesState.onReply(this.fetch, text, this.ctx()));
            },
            timeout: function () {
                this.apply(StagesState.onTimeout(this.fetch, this.ctx()));
            },
            retry: function () {
                this.apply(StagesState.onRetry(this.fetch, this.ctx()));
            }
        };
    }

    function test_aNoticeFetchesTheStateOnce() {
        const l = link();
        l.notice(1);
        compare(l.started, 1);
        compare(l.state, null, "nothing is shown before the reply");
        l.reply(event({gen: 1}));
        compare(l.state.gen, 1);
        compare(l.state.monitors["GF-REF"].stages.length, 3);
        verify(!l.fetch.running);
        compare(l.started, 1);
    }

    function test_noticesDuringAFetchCoalesceIntoOneMoreFetch() {
        const l = link();
        l.notice(1);
        l.notice(2);
        l.notice(3);
        compare(l.started, 1, "one fetch at a time");
        l.reply(event({gen: 1}));
        compare(l.state.gen, 1);
        compare(l.started, 2, "the notices that came meanwhile ask one more fetch, not three");
        l.reply(event({gen: 3}));
        compare(l.state.gen, 3);
        compare(l.started, 2);
        verify(!l.fetch.running);
    }

    function test_anOutOfOrderReplyNeverReplacesANewerState() {
        const l = link();
        l.notice(5);
        l.reply(event({gen: 5}));
        l.notice(6);
        l.reply(event({gen: 4}));
        compare(l.state.gen, 5, "an older reply is dropped");
        l.notice(7, false);
        compare(l.state.on, false, "an off notice is shown at once, nothing to fetch");
        compare(l.state.gen, 7);
        compare(l.started, 2);
        l.notice(8);
        l.reply(event({gen: 6}));
        compare(l.state.on, false, "a reply older than the off notice does not turn Stages back on");
        compare(l.state.gen, 7);
    }

    function test_aFailedFetchIsRetriedWithBackoffThenTheStateIsUnknown() {
        const l = link();
        l.notice(1);
        l.reply(event({gen: 1}));
        l.notice(2);
        l.reply("");
        compare(l.retryMs, 200, "an empty reply (hyprctl failed) is retried");
        compare(l.state.gen, 1, "the shown state stays while retrying");
        l.retry();
        l.reply("unknown request");
        compare(l.retryMs, 400, "the plugin went away between the notice and the fetch");
        l.retry();
        l.timeout();
        compare(l.retryMs, 800, "a fetch that never answered");
        l.retry();
        l.reply(JSON.stringify({v: "gfc/1", type: "stages", gen: 2, on: true}));
        compare(l.retryMs, 0, "three retries at most");
        compare(l.state, null, "then the state is unknown: the strip hides rather than show a stale state as current");
        compare(l.started, 5);
        verify(!l.fetch.running);
        compare(l.fetch.tries, 0);
        l.notice(3);
        compare(l.started, 6, "the next notice starts over");
    }

    function test_aRetryThatSucceedsShowsTheStateAndClearsTheFailures() {
        const l = link();
        l.notice(1);
        l.timeout();
        compare(l.retryMs, 200);
        l.retry();
        l.reply(event({gen: 1}));
        compare(l.state.gen, 1);
        compare(l.fetch.tries, 0);
        compare(l.retryMs, 0);
    }

    function test_aNewNoticeDuringTheBackoffFetchesAtOnce() {
        const l = link();
        l.notice(1);
        l.reply("");
        compare(l.retryMs, 200);
        l.notice(2);
        compare(l.started, 2);
        compare(l.fetch.tries, 0);
        l.retry();
        compare(l.started, 2, "a retry due while a fetch runs starts nothing");
    }

    // Re-review of c3cb01b (stale-sim.log: 50 notices with every fetch failing kept the gen-1 state): each notice restarts
    // the retries, never the clock; 3 s after the first unanswered notice nothing is shown.
    function test_failingFetchesUnderAStreamOfNoticesGiveUpTheStateAfterThreeSeconds() {
        const l = link();
        l.notice(1);
        l.reply(event({gen: 1}));
        compare(l.staleMs, 0, "an answered notice leaves no clock running");
        let gen = 2;
        for (let i = 0; i < 2; i++) {
            l.notice(gen++);
            l.reply('{"v":"gfc/1","type":"error"}');
            l.wait(200);
            l.retry();
            l.reply("");
            l.wait(800);
        }
        compare(l.state.gen, 1, "under 3 s the shown state stays (2 s after the first unanswered notice)");
        compare(l.staleAt, 4000, "the bound is 3 s after the first unanswered notice (t=1000), not after the latest");
        l.notice(gen++);
        l.reply("");
        l.wait(1000);
        compare(l.state, null, "3 s after the first unanswered notice the stale state is given up");
        for (let i = 0; i < 50; i++) {
            l.notice(gen++);
            l.reply("");
            l.wait(1000);
        }
        compare(l.state, null, "and stays given up while every fetch fails");
        l.notice(gen);
        l.reply(event({gen: gen}));
        compare(l.state.gen, gen, "the first successful fetch shows the state again");
        compare(l.staleMs, 0);
    }

    function test_aFetchThatNeverAnswersHidesTheStateAtThreeSecondsNotAtTheNextStep() {
        const l = link();
        l.notice(1);
        l.reply(event({gen: 1}));
        l.notice(2);
        compare(l.staleMs, 3000, "the time bound is armed with the notice");
        l.wait(2000);
        compare(l.state.gen, 1);
        l.timeout();
        compare(l.staleMs, 1000);
        l.wait(1000);
        compare(l.state, null, "the bound fires at 3 s, while the retry waits");
    }

    function test_notices_answeredByFetchesInTimeNeverGoStale() {
        // Notices faster than the fetches: every fetch succeeds but another notice came during it; the clock follows the
        // oldest notice not yet answered, so a steady flow of answers never hides the strip.
        const l = link();
        let gen = 1;
        l.notice(gen++);
        for (let i = 0; i < 40; i++) {
            l.wait(150);
            l.notice(gen++);
            l.wait(100);
            l.reply(event({gen: gen - 2}));
            verify(l.state !== null, "cycle " + i);
            verify(l.staleMs > 0 && l.staleMs <= 3000);
        }
        l.wait(100);
        l.reply(event({gen: gen - 1}));
        compare(l.state.gen, gen - 1);
        compare(l.staleMs, 0, "all answered: no clock");
    }

    // An event-driven model of StagesLink on a virtual clock (the re-review's stale-sim2): notices every `noticeEvery` ms,
    // each fetch answering after fetchMs(n) ms (2000 or more: never, the 2-s deadline ends it) with a state or, when
    // ok(n) is false, a failure; the retry, deadline and time-bound timers. Returns {hides, fetches, final}.
    function simulate(fetchMs, ok, noticeEvery, until) {
        let now = 0, seq = 0, gen = 1, fetches = 0, awaiting = null, f = StagesState.newFetch(), state = null;
        let retryT = null, staleT = null, deadT = null;
        const q = [], hides = [];
        const at = (t, k, d) => q.push({t: t, k: k, d: d, s: seq++});
        const ctx = () => ({active: true, shown: state, now: now});
        const step = o => {
            f = o.fetch;
            if (o.state !== undefined) {
                if (o.state === null && state !== null)
                    hides.push(now);
                state = o.state;
            }
            if (o.retryMs > 0) {
                retryT = {t: now + o.retryMs};
                at(retryT.t, "retry", retryT);
            }
            if (o.staleMs > 0) {
                staleT = {t: now + o.staleMs};
                at(staleT.t, "stale", staleT);
            } else {
                staleT = null;
            }
            if (o.start) {
                fetches++;
                const id = {};
                awaiting = id;
                deadT = {t: now + StagesState.fetchDeadlineMs};
                at(deadT.t, "dead", {id: id, ref: deadT});
                if (fetchMs(fetches) < StagesState.fetchDeadlineMs)
                    at(now + fetchMs(fetches), "reply", {id: id, g: gen, n: fetches});
            }
        };
        const notice = g => StagesState.parseNotice(JSON.stringify({v: "gfc/1", type: "stages", gen: g, on: true}));
        step(StagesState.onNotice(f, notice(gen), ctx()));
        for (let t = noticeEvery; t < until; t += noticeEvery)
            at(t, "notice");
        while (q.length) {
            q.sort((a, b) => a.t - b.t || a.s - b.s);
            const e = q.shift();
            if (e.t > until)
                break;
            now = e.t;
            if (e.k === "notice") {
                gen++;
                step(StagesState.onNotice(f, notice(gen), ctx()));
            } else if (e.k === "reply") {
                if (awaiting !== e.d.id)
                    continue;
                awaiting = null;
                deadT = null;
                step(StagesState.onReply(f, ok(e.d.n) ? event({gen: e.d.g}) : "", ctx()));
            } else if (e.k === "dead") {
                if (deadT !== e.d.ref || awaiting !== e.d.id)
                    continue;
                awaiting = null;
                step(StagesState.onTimeout(f, ctx()));
            } else if (e.k === "retry") {
                if (retryT !== e.d)
                    continue;
                retryT = null;
                step(StagesState.onRetry(f, ctx()));
            } else if (e.k === "stale") {
                if (staleT !== e.d)
                    continue;
                staleT = null;
                step(StagesState.onTick(f, ctx()));
            }
        }
        return {hides: hides, fetches: fetches, final: state};
    }

    // Re-review of b60bc3a..85aaab9 (stale-sim2: 7 hides in 20 s with 1.6-s fetches): slow fetches that succeed under a
    // steady flow of notices never hide the strip; failing or hung fetches still do, within 3 s plus one fetch deadline.
    function test_slowFetchesUnderSteadyNoticesNeverMakeTheStripFlicker() {
        for (const ms of [900, 1400, 1600, 1900]) {
            const r = simulate(() => ms, () => true, 300, 20000);
            compare(r.hides.length, 0, ms + " ms fetches, a notice every 300 ms: hidden at " + r.hides);
            verify(r.final !== null && r.final.gen > 50, ms + " ms fetches keep the state current");
        }
        const sparse = simulate(() => 1900, () => true, 2500, 20000);
        compare(sparse.hides.length, 0);
    }

    function test_failingOrHungFetchesStillHideTheStateInBoundedTime() {
        const failing = simulate(() => 5, () => false, 1000, 20000);
        compare(failing.final, null);
        const firstOk = simulate(() => 5, n => n === 1, 1000, 20000);
        compare(firstOk.hides.length, 1, "shown after the first fetch, hidden once the others fail");
        verify(firstOk.hides[0] <= 1000 + StagesState.staleAfterMs + StagesState.fetchDeadlineMs);
        compare(firstOk.final, null);
        const hung = simulate(n => n === 1 ? 50 : 99999, () => true, 1000, 20000);
        compare(hung.hides.length, 1, "fetches that never answer hide the state");
        verify(hung.hides[0] <= 1000 + StagesState.staleAfterMs + StagesState.fetchDeadlineMs, "hidden at " + hung.hides[0]);
    }

    function test_nothingIsFetchedOrShownWhileStagesIsNotActive() {
        const l = link(false);
        l.notice(1);
        l.notice(2, false);
        compare(l.started, 0);
        compare(l.state, null);
        const m = link();
        m.notice(1);
        m.active = false;
        m.reply(event({gen: 1}));
        compare(m.state, null, "a reply that ends after Stages stopped is dropped");
        m.active = true;
        m.notice(2);
        m.active = false;
        m.timeout();
        compare(m.retryMs, 0, "no retry once Stages stopped");
        verify(!m.fetch.running);
    }

    function test_foreignOrMalformedEventsAreIgnored() {
        compare(StagesState.parse("not json"), null);
        compare(StagesState.parse(JSON.stringify({v: "gfc/2", type: "stages", on: true, monitors: []})), null);
        compare(StagesState.parse(JSON.stringify({v: "gfc/1", type: "overview", on: true})), null);
        compare(StagesState.parse(JSON.stringify({v: "gfc/1", type: "stages", on: "yes"})), null);
    }

    function test_unknownReasonsAndBadEntriesAreDropped() {
        const s = StagesState.parse(event({reason: "made-up", monitors: [{monitor: "bad name", stages: []}, {monitor: "A", stages: [{id: -3, slot: 0, windows: []}, {id: 1, slot: 0, windows: [{address: "zz"}]}]}]}));
        compare(s.reason, "");
        compare(Object.keys(s.monitors).length, 1);
        compare(s.monitors.A.stages.length, 1);
        compare(s.monitors.A.stages[0].windows.length, 0);
        compare(StagesState.parse(event({on: false, reason: "no-strip"})).reason, "no-strip");
    }

    function test_theStripIsTheStagesOtherThanTheActiveOne() {
        const strip = StagesState.stripStages(mon());
        compare(strip.length, 2);
        compare(strip[0].id, 7);
        compare(StagesState.stageAtSlot(mon(), 1).id, 9);
        compare(StagesState.stageAtSlot(mon(), -1), null);
        compare(StagesState.stageOfWindow(mon(), "0xB2").id, 7);
        compare(StagesState.stripStages(null).length, 0);
    }

    // ---- layout ----

    function test_tilesAreCentredVerticallyAndNeverMoreThanFit() {
        const g = Layout.geometry(screen, insets, 3, t);
        compare(g.tiles.length, 3);
        const top = g.tiles[0].y;
        const bottom = g.tiles[2].y + g.tiles[2].h;
        // free height is [insets.top + edge, screen.height - edge]
        fuzzyCompare((top - (32 + 12)) , (1080 - 12) - bottom, 1);
        compare(g.tiles[1].y - g.tiles[0].y, 120 + 24);
        compare(Layout.capacity(100, t), 1);
        compare(Layout.capacity(100000, t), 8);
        compare(Layout.tileCount(0, 1000, t), 1);
        compare(Layout.tileCount(20, 1000, t), Layout.capacity(1000, t));
    }

    function test_theSurfaceCoversEveryTileAndTheInputBoxCoversTheTiles() {
        const g = Layout.geometry(screen, insets, 4, t);
        for (const r of g.tiles) {
            verify(r.x >= g.surface.x && r.x + r.w <= g.surface.x + g.surface.w);
            verify(r.y >= g.surface.y && r.y + r.h <= g.surface.y + g.surface.h);
            // box is relative to the surface
            verify(r.x - g.surface.x >= g.box.x && r.x - g.surface.x + r.w <= g.box.x + g.box.w);
            verify(r.y - g.surface.y >= g.box.y && r.y - g.surface.y + r.h <= g.box.y + g.box.h);
        }
    }

    function test_aDockOnTheLeftPushesTheStripRight() {
        const g = Layout.geometry(screen, {left: 80, top: 32, bottom: 0}, 1, t);
        compare(g.surface.x, 80);
        compare(g.tiles[0].x, 80 + 12);
    }

    function test_theStripHidesWhileAWindowOverlapsUnlessRevealed() {
        verify(Layout.shown(true, 2, false, false));
        verify(!Layout.shown(true, 2, true, false));
        verify(Layout.shown(true, 2, true, true));
        verify(!Layout.shown(true, 0, false, false));
        verify(!Layout.shown(false, 2, false, false));
    }

    function test_theInputRegionIsNeverEmptyWhileStagesIsOn() {
        verify(Layout.edgeActive(true, false));
        verify(!Layout.edgeActive(true, true));
        verify(!Layout.edgeActive(false, false));
    }

    // ---- clicks and drops ----

    function test_clickingATileActivatesItsStageAndShiftMergesIt() {
        compare(JSON.stringify(Layout.clickRequest(mon(), 0, false)), JSON.stringify({op: "activate", stage: 7}));
        compare(JSON.stringify(Layout.clickRequest(mon(), 1, true)), JSON.stringify({op: "merge", stage: 9}));
        compare(Layout.clickRequest(mon(), 5, false), null);
        compare(Layout.clickRequest(mon(), -1, false), null);
        compare(Layout.clickRequest(null, 0, false), null);
    }

    function test_droppingOnTheStageMovesTheFrontWindowIntoTheActiveStage() {
        const geo = Layout.geometry(screen, insets, 2, t);
        const target = Layout.dropTarget(geo.surface.w + 40, 100, geo);
        compare(target.kind, "stage");
        const req = Layout.dropRequest(mon(), 0, target);
        compare(req.op, "move");
        compare(req.address, "0xb2");
        compare(req.stage, 5);
    }

    function test_droppingOnAnotherTileMovesItIntoThatStage() {
        const geo = Layout.geometry(screen, insets, 2, t);
        const r = geo.tiles[1];
        const target = Layout.dropTarget(r.x - geo.surface.x + 10, r.y - geo.surface.y + 10, geo);
        compare(target.kind, "tile");
        compare(target.slot, 1);
        compare(Layout.dropRequest(mon(), 0, target).stage, 9);
        // on its own tile or on nothing: nothing is asked
        compare(Layout.dropRequest(mon(), 1, target), null);
        compare(Layout.dropRequest(mon(), 0, {kind: "none"}), null);
    }

    function test_theBadgeShowsTheFrontWindowsAppFirst() {
        const apps = {b1: "org.a", b2: "org.b", aa: "org.c"};
        const ids = Layout.appIds(mon().stages[1], a => apps[a] || "");
        compare(ids[0], "org.b");
        compare(ids.length, 2);
        compare(Layout.appIds(null, a => "x").length, 0);
    }
}
