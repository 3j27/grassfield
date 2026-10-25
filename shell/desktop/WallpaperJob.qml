pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

// One run of grassfield-wallpaper (ADR-0016): a single Process with an argument vector (no shell), its output collected,
// killed when it runs longer than `timeoutMs`. The feed that created it calls `callback(token, kind, code, out, timedOut)`
// exactly once, when the process has exited and its output has been read, then the job destroys itself. A process that
// could not start at all has no output: the answer comes from the exit alone, a moment later.
Scope {
    id: job

    property var command: []
    property int token: 0
    property string kind: ""
    property int timeoutMs: 30000
    // function (token, kind, code, out, timedOut)
    property var callback: null
    // A streaming job reports the output so far through function (token, text) while it runs.
    property bool streaming: false
    property var progressCallback: null

    readonly property bool running: proc.running
    property string out: ""
    property int code: -2
    property bool gotOut: false
    property bool gotExit: false
    property bool timedOut: false
    property bool reported: false

    function start(): void {
        proc.running = true;
    }

    // SIGTERM (15) or SIGKILL (9).
    function stop(signalNumber: int): void {
        if (proc.running)
            proc.signal(signalNumber);
    }

    function check(): void {
        if (gotOut && gotExit)
            done();
    }

    function done(): void {
        if (reported)
            return;
        reported = true;
        if (callback)
            callback(token, kind, code, out, timedOut);
        destroy(200);
    }

    Process {
        id: proc
        command: job.command
        environment: WallpaperState.toolEnv
        stdout: StdioCollector {
            // A streaming job (a transcode prints its progress as it goes): the text grows while the process runs and
            // `progressCallback(text)` hears every change; the final answer is still the whole text at the end.
            waitForEnd: !job.streaming
            onDataChanged: {
                if (job.streaming && job.progressCallback)
                    job.progressCallback(job.token, text);
            }
            onStreamFinished: {
                job.out = text;
                job.gotOut = true;
                job.check();
            }
        }
        // qmllint disable signal-handler-parameters
        onExited: exitCode => {
            job.code = exitCode;
            job.gotExit = true;
            join.start();
            job.check();
        }
        // qmllint enable signal-handler-parameters
    }

    // The output may never arrive when the process could not start at all.
    Timer {
        id: join
        interval: 150
        onTriggered: job.done()
    }

    Timer {
        interval: job.timeoutMs
        running: proc.running
        onTriggered: {
            job.timedOut = true;
            job.stop(9);
        }
    }
}
