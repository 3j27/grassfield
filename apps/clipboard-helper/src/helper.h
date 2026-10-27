// grassfield-clipboard-helper's work (ADR-0034): the offers the compositor announces, the shell's answer to each, the reads, the
// history and the pinned items, their stores, the thumbnails, serving an item back. main.cpp wires stdin and stdout.
#pragma once

#include "cliplogic.h"
#include "diskstore.h"
#include "wlclient.h"

#include <QByteArray>
#include <QHash>
#include <QList>
#include <QObject>
#include <QSocketNotifier>
#include <QString>
#include <QTimer>

#include <functional>
#include <memory>

class ThumbnailJob;

class Helper : public QObject
{
public:
    struct Options {
        QByteArray display;   // absolute socket path (--display)
        QString stateDir;     // .../grassfield/clipboard (--state)
        QString runtimeDir;   // tmpfs directory of thumbnails and previews (--runtime)
        qint64 retentionMs = ClipLogic::kDefaultRetentionMs;
        bool historyStore = false;
        QString program;      // this binary, for the thumbnail worker
    };
    using Output = std::function<void(const QByteArray &line)>;
    // Called when the helper must end (the shell asked, or the compositor connection failed); `code` is the exit code.
    using Quit = std::function<void(int code)>;

    Helper(Options options, Output output, Quit quit, QObject *parent = nullptr);
    ~Helper() override;

    // Loads the stores, connects to the display and reports the state. Capture waits for the shell's resume (`R`). Returns 0
    // when the helper runs, else the exit code (1: the display or the runtime directory failed, 3: an unsupported compositor).
    int start();
    void command(const QByteArray &line);
    // Removes the runtime directory's files (thumbnails, previews) and the directory.
    void cleanup();

    static int clearPinned(const QString &stateDir);
    static int clearHistoryStore(const QString &stateDir);

private:
    struct Pending;
    struct Writer;

    void emitLine(const QList<QByteArray> &fields);
    void emitItem(const QByteArray &id);
    void emitRemoved(const QList<QByteArray> &ids);
    void log(const char *what);
    void updateCapture();
    void selection(WaylandClipboard::Offer *offer, bool first);
    void abortPending();
    void answer(quint64 seq, bool yes, const QString &app);
    void readNext();
    void readable();
    void readDone(ClipLogic::ReadResult::Status status);
    void finishRead();
    void addItem(ClipLogic::Item item, const QByteArray &thumbnail);
    void queueThumbnail(const QByteArray &id);
    void nextThumbnail();
    void expire();
    void pin(const QByteArray &id);
    void unpin(const QByteArray &id);
    void remove(const QByteArray &id);
    void clearHistory();
    void clearPinnedItems();
    void setHistoryStore(bool on);
    void copy(const QByteArray &id, bool plainOnly);
    void ownSelectionConfirmed();
    void send(const QByteArray &mime, int fd);
    void preview(const QByteArray &id);
    void dropPreview(const QByteArray &id);
    QString thumbPath(const QByteArray &id) const;
    QString previewPath(const QByteArray &id) const;
    bool writeRuntimeFile(const QString &path, const QByteArray &bytes);
    void forgetFiles(const QByteArray &id);
    QByteArray newId() const;
    static qint64 nowWall();
    static qint64 nowBoot();

    Options m_options;
    Output m_output;
    Quit m_quit;
    WaylandClipboard *m_wl = nullptr;
    ClipLogic::Store m_store;
    DiskStore m_pinnedDisk;
    DiskStore m_historyDisk;
    QByteArray m_bootId;
    bool m_shellResumed = false;
    quint64 m_seq = 0;
    std::unique_ptr<Pending> m_pending;
    QHash<QByteArray, QString> m_thumbs;
    QList<QByteArray> m_thumbQueue;
    ThumbnailJob *m_thumbJob = nullptr;
    ThumbnailJob *m_previewJob = nullptr;
    QTimer m_expiry;
    // The item we serve (a copy: it stays on the clipboard when the history drops it), and whether only its plain text is offered.
    ClipLogic::Item m_owned;
    bool m_ownedPlainOnly = false;
    QByteArray m_requestedId;
    QList<Writer *> m_writers;
};
