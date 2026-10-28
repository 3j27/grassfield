#include "statefile.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QMutex>
#include <QSaveFile>

namespace grassfield::store {

namespace {

QMutex &stateLock()
{
    static QMutex lock;
    return lock;
}

QJsonObject readLocked(const QString &path)
{
    QFile f(path);
    QByteArray data;
    if (f.open(QIODevice::ReadOnly) && f.size() <= 1024 * 1024)
        data = f.read(1024 * 1024);
    const QJsonObject o = QJsonDocument::fromJson(data).object();
    return o.value(QStringLiteral("version")).toInt() == 1 ? o : QJsonObject{{QStringLiteral("version"), 1}};
}

} // namespace

QJsonObject readStoreState(const QString &path)
{
    const QMutexLocker locker(&stateLock());
    return readLocked(path);
}

bool updateStoreState(const QString &path, const std::function<void(QJsonObject &)> &change)
{
    const QMutexLocker locker(&stateLock());
    QJsonObject state = readLocked(path);
    change(state);
    state.insert(QStringLiteral("version"), 1);
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile f(path);
    const QByteArray data = QJsonDocument(state).toJson(QJsonDocument::Indented);
    if (!f.open(QIODevice::WriteOnly) || f.write(data) != data.size())
        return false;
    return f.commit();
}

} // namespace grassfield::store
