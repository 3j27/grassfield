#pragma once

#include <QHash>
#include <QObject>
#include <QStringList>

#include <functional>
#include <memory>

// Questions to the disk asked off the GUI thread (ADR-0035 4b-18): a hung mount (an NFS or SMB share gone, a sleeping disk)
// must not stall the thread that draws Files' windows and grassfield-portal's panels and runs the portal's 3-s forward.
// probe(paths) reads its paths in order on a thread of its own and answers answered(token, {path: kind}) once every path
// has answered, once none has for quietMs (a share that is slow but answering is waited for), or after totalMs at most.
// A path that has not answered is kNotResponding. Each path's answer is its own: a healthy path queued behind a hung one in
// the same call is not responding for that call only, and the next call reads it again. A read still running when its call
// ends is stuck: until it returns, a later call gets kNotResponding for that path at once (it is not read twice), and with
// kMaxStuck reads stuck every new path is not responding at once, so stuck reads cannot pile up threads.
class DiskProbe : public QObject
{
    Q_OBJECT

public:
    static constexpr int kNotResponding = -2;
    static constexpr int kMaxStuck = 16;

    struct Options {
        int quietMs = 1000;
        int totalMs = 5000;
        // What a path names (empty: kindOf; the tests give a slow one).
        std::function<int(const QString &path)> stat;
    };

    explicit DiskProbe(const Options &options, QObject *parent = nullptr);
    explicit DiskProbe(QObject *parent = nullptr);
    ~DiskProbe() override;

    // Absolute local paths. Returns the token; answered() follows later, never from inside the call.
    int probe(const QStringList &paths);
    // What a local path names now: 0 nothing, 1 a file (anything but a folder, a dangling symbolic link too), 2 a folder.
    // It reads the disk: never on the GUI thread.
    static int kindOf(const QString &path);
    // Reads stuck now (the tests).
    int stuck() const { return int(m_stuck.size()); }

signals:
    void answered(int token, const QHash<QString, int> &kinds);

private:
    struct Call;
    struct Job;
    struct Shared;
    void readDone(int token, const QString &path, int kind);
    void check(int token);
    void finish(int token);

    Options m_options;
    int m_next = 1;
    QHash<int, std::shared_ptr<Call>> m_calls;
    QHash<QString, int> m_stuck; // path -> token of the call whose read hangs
    std::shared_ptr<Shared> m_shared;
};
