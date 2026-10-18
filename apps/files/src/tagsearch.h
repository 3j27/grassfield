#pragma once

#include <QByteArray>
#include <QString>
#include <QStringList>
#include <QThread>

#include <atomic>

// Finds the local files and folders tagged `tag` (user.xdg.tags, see TagLogic) in `root` and below, on its own
// thread, without any index: breadth first (nearer items first), on the root's filesystem only (like find -xdev, so
// network and removable mounts are not walked), never through symbolic links, hidden entries only when `showHidden`,
// and bounded (kMaxVisited entries, kMaxResults matches, kMaxDepth levels). Matches arrive in batches through found();
// done() tells whether a bound stopped the walk. cancel() stops it at the next entry; a cancelled search emits nothing
// more. The object belongs to the thread that created it and deletes itself (deleteLater) once finished.
class TagSearch : public QThread
{
    Q_OBJECT

public:
    static constexpr int kMaxVisited = 50000;
    static constexpr int kMaxResults = 2000;
    static constexpr int kMaxDepth = 32;

    TagSearch(const QString &root, const QString &tag, bool showHidden);

    void cancel() { m_cancel.store(true); }
    bool cancelled() const { return m_cancel.load(); }

signals:
    void found(const QStringList &paths);
    void done(bool limited, int visited);

protected:
    void run() override;

private:
    bool tagged(const QByteArray &path) const;

    const QByteArray m_root;
    const QString m_tag;
    const bool m_showHidden;
    std::atomic_bool m_cancel{false};
};
