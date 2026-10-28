// Helpers of the Store's unit tests (tests/unit/store/tst_*.cpp): fixtures, scratch scripts standing for pacman, gpgv,
// pacman-key and bsdtar, gzip. Nothing here touches the system's package manager or keys.
#pragma once

#include <QByteArray>
#include <QCoreApplication>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QString>

#include <zlib.h>

namespace storetest {

inline QByteArray readFixture(const QString &name)
{
    QFile f(QStringLiteral(STORE_FIXTURES "/") + name);
    return f.open(QIODevice::ReadOnly) ? f.readAll() : QByteArray();
}

inline void writeFile(const QString &path, const QByteArray &data)
{
    QFile f(path);
    if (f.open(QIODevice::WriteOnly))
        f.write(data);
}

// An executable /bin/sh script at `path`.
inline QString script(const QString &path, const QByteArray &body)
{
    writeFile(path, "#!/bin/sh\n" + body + "\n");
    QFile::setPermissions(path, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
    return path;
}

inline QByteArray gzip(const QByteArray &data)
{
    z_stream s{};
    deflateInit2(&s, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 16 + MAX_WBITS, 8, Z_DEFAULT_STRATEGY);
    QByteArray out(int(deflateBound(&s, uLong(data.size()))) + 32, '\0');
    s.next_in = reinterpret_cast<Bytef *>(const_cast<char *>(data.constData()));
    s.avail_in = uInt(data.size());
    s.next_out = reinterpret_cast<Bytef *>(out.data());
    s.avail_out = uInt(out.size());
    deflate(&s, Z_FINISH);
    out.resize(int(s.total_out));
    deflateEnd(&s);
    return out;
}

// The fixture catalog with one change made to its JSON object.
template<typename F>
QByteArray changedCatalog(F change)
{
    QJsonObject o = QJsonDocument::fromJson(readFixture(QStringLiteral("catalog-good.json"))).object();
    change(o);
    return QJsonDocument(o).toJson(QJsonDocument::Compact);
}

// Qt Network needs an application object; gtest_main makes none.
inline void ensureApp()
{
    if (!QCoreApplication::instance()) {
        static int argc = 1;
        static char name[] = "store-unit-tests";
        static char *argv[] = {name, nullptr};
        static QCoreApplication app(argc, argv);
    }
}

} // namespace storetest
