pragma ComponentBehavior: Bound
pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import Grassfield.Ui
import qs.lib
import qs.services
import "Weather.js" as WeatherLogic

// The weather of every Weather widget (ADR-0045 OC-14, docs/specs/widgets.md): one shared sampler, as SystemSampler is for
// System. The widgets never touch the network: this does, on one host, through one program.
//   - Where: Omarchy's saved location, $HOME/.local/state/omarchy/settings/weather.json, read directly as JSON (the file of
//     omarchy-weather-location, shared with the Omarchy session); none saved: wttr.in's own place for the IP address, as
//     Omarchy does. Read when the first widget shows, before every fetch and whenever it changes (a FileView watch).
//   - What: wttr.in's j1 report, one run of `curl` (an argument vector, https only, Tokens.widgetWeatherFetchSeconds and
//     widgetWeatherMaxBytes; Weather.fetchArgs), parsed by Weather.parseReport. Only the parsed values are kept.
//   - When: only while a placed Weather widget is shown (`users` > 0: a desktop widget not covered, a Notifications one
//     while the panel is open; never a gallery preview): at once if nothing is known, then every 30 minutes
//     (widgetWeatherRefreshMs); after a failure 2 min later, doubling up to 30 (Weather.nextDelay). Nothing starts while the
//     session is locked (what is due runs once it is unlocked) or while NetworkManager reports no usable network (a
//     change of connectivity looks again).
//   - A dev session (GRASSFIELD_DEV=1) fetches only from the loopback test server GRASSFIELD_WEATHER_BASE_URL names
//     (http://127.0.0.1:<port>), and its location lives under the dev state ($GRASSFIELD_STATE_HOME/weather-home, the HOME
//     given to omarchy-weather-location), so a nested shell never reads or writes the owner's.
//   - Failure (no network, a timeout, an error, an unreadable answer): status "unavailable"; the last good values stay
//     (the widget greys them).
// Edit Location… runs Omarchy's own `omarchy-weather-location --set <name>` (`--clear` for an empty name), only when that
// command exists (`canEditLocation`, looked up when a widget shows), then reads the file again and fetches for the new place.
Item {
    id: root

    // Number of shown, placed Weather widgets (each adds 1 while shown, removes it when not).
    property int users: 0

    // Omarchy's saved location {name, latitude, longitude}; name "" and no coordinates: the IP address's place.
    property var location: WeatherLogic.parseLocationFile("")
    property bool locationKnown: false
    // The last good report (Weather.parseReport), or null.
    property var report: null
    // {lastOkAt, lastTryAt, failures} (Weather.nextDelay).
    property var sched: WeatherLogic.emptyState()
    readonly property string status: WeatherLogic.status(sched, report)
    readonly property string query: WeatherLogic.locationQuery(location)
    // No saved place: wttr.in finds one from the IP address (the widget shows the location arrow, as macOS for My Location).
    readonly property bool byIp: query === ""
    readonly property string place: WeatherLogic.placeName(location, report)
    // Omarchy's omarchy-weather-location is there (Edit Location… is offered).
    property bool canEditLocation: false

    readonly property string baseUrl: Mode.dev ? WeatherLogic.devBaseUrl(Mode.devValue("WEATHER_BASE_URL")) : WeatherLogic.BASE_URL
    readonly property string home: Mode.dev ? Mode.stateDir + "/weather-home" : Quickshell.env("HOME")
    readonly property string locationPath: root.home ? root.home + "/.local/state/omarchy/settings/weather.json" : ""
    // Observable by tests and the journal.
    property int fetchCount: 0
    property string lastFailure: ""

    onUsersChanged: {
        if (users > 0) {
            lookUp.running = true;
            locationFile.reload();
        }
        root.evaluate();
    }

    Connections {
        target: SessionState
        function onLockedChanged(): void {
            root.evaluate();
        }
    }

    Connections {
        target: Connectivity
        function onFullyConnectedChanged(): void {
            if (Connectivity.fullyConnected)
                root.evaluate();
        }
    }

    // ---- the location ----
    FileView {
        id: locationFile
        path: root.locationPath
        printErrors: false
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.adoptLocation(WeatherLogic.parseLocationFile(locationFile.text()))
        // No file: nothing saved, the IP address's place.
        onLoadFailed: root.adoptLocation(WeatherLogic.parseLocationFile(""))
    }

    function adoptLocation(loc: var): void {
        const changed = WeatherLogic.locationQuery(loc) !== root.query || loc.name !== root.location.name;
        root.location = loc;
        const first = !root.locationKnown;
        root.locationKnown = true;
        if (changed && !first) {
            // Another place: what was shown is not its weather. Fetch for it now.
            root.report = null;
            root.sched = WeatherLogic.emptyState();
            if (fetchProc.running) {
                root.refetch = true;
                return;
            }
        }
        root.evaluate();
    }

    // ---- when ----
    Timer {
        id: nextTimer
        onTriggered: root.evaluate()
    }

    function evaluate(): void {
        if (root.users <= 0 || !root.locationKnown || fetchProc.running || SessionState.locked) {
            nextTimer.stop();
            return;
        }
        const now = Date.now();
        const wait = WeatherLogic.nextDelay(root.sched, now, Tokens.widgetWeatherRefreshMs, Tokens.widgetWeatherRetryMs);
        if (wait > 0) {
            nextTimer.interval = Math.min(wait, Tokens.widgetWeatherRefreshMs);
            nextTimer.restart();
            return;
        }
        root.fetch();
    }

    // ---- the fetch ----
    property bool refetch: false
    property string fetchOut: ""
    property int fetchExit: -2
    property bool gotOut: false
    property bool gotExit: false
    property bool timedOut: false

    function fetch(): void {
        const url = root.baseUrl === "" ? "" : WeatherLogic.reportUrl(root.baseUrl, root.query);
        const args = url === "" ? null : WeatherLogic.fetchArgs(url, Tokens.widgetWeatherFetchSeconds, Tokens.widgetWeatherMaxBytes);
        if (args === null) {
            // A dev session without its test server: nothing is fetched, ever.
            root.finish(false, Mode.dev ? "dev session without GRASSFIELD_WEATHER_BASE_URL" : "no request");
            return;
        }
        if (!Mode.dev && !Connectivity.fullyConnected) {
            root.finish(false, "no usable network");
            return;
        }
        root.fetchCount++;
        root.fetchOut = "";
        root.fetchExit = -2;
        root.gotOut = false;
        root.gotExit = false;
        root.timedOut = false;
        fetchProc.didStart = false;
        fetchProc.command = args;
        fetchTimeout.interval = 2 * Tokens.widgetWeatherFetchSeconds * 1000;
        fetchTimeout.restart();
        fetchProc.running = true;
        // The file may have changed in the Omarchy session meanwhile: read it again once the run is under way, so a new
        // place (adoptLocation) marks this answer stale and fetches again when it ends.
        locationFile.reload();
    }

    function finish(ok: bool, why: string): void {
        root.sched = WeatherLogic.afterFetch(root.sched, Date.now(), ok);
        if (!ok && why !== root.lastFailure)
            console.warn("weather: unavailable (" + why + ")");
        root.lastFailure = ok ? "" : why;
        if (root.refetch) {
            root.refetch = false;
            root.report = null;
            root.sched = WeatherLogic.emptyState();
        }
        root.evaluate();
    }

    function fetchDone(): void {
        if (!(root.gotOut && root.gotExit))
            return;
        root.gotOut = false;
        root.gotExit = false;
        joinTimer.stop();
        fetchTimeout.stop();
        const parsed = root.fetchExit === 0 ? WeatherLogic.parseReport(root.fetchOut, Tokens.widgetWeatherMaxBytes, Tokens.widgetWeatherHours - 1) : null;
        root.fetchOut = "";
        if (parsed !== null && !root.refetch)
            root.report = parsed;
        root.finish(parsed !== null, root.timedOut ? "timed out" : root.fetchExit !== 0 ? "curl exit " + root.fetchExit : "unreadable answer");
    }

    Process {
        id: fetchProc
        // Set by started: a run that ends without it never started (curl missing).
        property bool didStart: false
        stdout: StdioCollector {
            onStreamFinished: {
                root.fetchOut = text;
                root.gotOut = true;
                root.fetchDone();
            }
        }
        onStarted: didStart = true
        // Quickshell sends no `exited` when a start fails, only running going back to false without a `started`.
        onRunningChanged: {
            if (!running && !didStart) {
                root.fetchExit = 127;
                root.gotOut = true;
                root.gotExit = true;
                root.fetchDone();
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            root.fetchExit = exitCode;
            root.gotExit = true;
            // The output may never arrive when the process could not start at all.
            joinTimer.start();
            root.fetchDone();
        }
        // qmllint enable signal-handler-parameters
    }

    Timer {
        id: joinTimer
        interval: 150
        onTriggered: {
            root.gotOut = true;
            root.fetchDone();
        }
    }

    // curl stops itself at --max-time; a run that outlives twice that is killed.
    Timer {
        id: fetchTimeout
        onTriggered: {
            root.timedOut = true;
            if (fetchProc.running)
                fetchProc.signal(9);
        }
    }

    // ---- Edit Location… ----
    Process {
        id: lookUp
        command: ["sh", "-c", "command -v " + WeatherLogic.LOCATION_COMMAND + " >/dev/null"]
        // qmllint disable signal-handler-parameters
        onExited: exitCode => root.canEditLocation = exitCode === 0
        // qmllint enable signal-handler-parameters
    }

    // Saves `name` as Omarchy's location (empty: back to the IP address's place). Returns false when nothing was run.
    function setLocation(name: string): bool {
        const args = WeatherLogic.locationArgs(name, Tokens.widgetWeatherLocationMaxChars);
        if (args === null || !root.canEditLocation || setProc.running || root.locationPath === "")
            return false;
        setProc.command = args;
        setProc.running = true;
        return true;
    }

    // A dev session's own HOME (the dev state): Omarchy's command writes there, never into the owner's state.
    readonly property var setEnvironment: Mode.dev ? ({HOME: root.home}) : ({})

    Process {
        id: setProc
        environment: root.setEnvironment
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            if (exitCode !== 0)
                console.warn("weather: " + WeatherLogic.LOCATION_COMMAND + " failed (" + exitCode + ")");
            locationFile.reload();
        }
        // qmllint enable signal-handler-parameters
    }
}
