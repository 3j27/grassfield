// Test-only reference for tests/shell/dock_name_order.sh: sorts the names it reads (one per line, UTF-8) with Grassfield Files' own
// comparison, FileLogic::compareEntries (apps/files/src/filelogic.cpp, compiled in as it is), through a QCollator set as
// FolderModel sets it (apps/files/src/foldermodel.cpp: the user's locale, the C locale replaced by en_US, numeric mode, case
// insensitive), and prints them in that order. Name sort, ascending, folders not first (a Dock stack does not put folders first).
#include "filelogic.h"

#include <QCollator>
#include <QCoreApplication>
#include <QFile>
#include <QLocale>

#include <algorithm>
#include <cstdio>

int main(int argc, char **argv)
{
    QCoreApplication app(argc, argv);
    QLocale locale;
    if (locale.language() == QLocale::C)
        locale = QLocale(QLocale::English, QLocale::UnitedStates);
    QCollator collator(locale);
    collator.setNumericMode(true);
    collator.setCaseSensitivity(Qt::CaseInsensitive);

    QFile in;
    in.open(stdin, QIODevice::ReadOnly);
    const QStringList lines = QString::fromUtf8(in.readAll()).split(QLatin1Char('\n'), Qt::SkipEmptyParts);
    QList<FileLogic::SortEntry> entries;
    for (const QString &line : lines) {
        FileLogic::SortEntry e;
        e.name = line;
        entries.append(e);
    }
    std::stable_sort(entries.begin(), entries.end(), [&](const FileLogic::SortEntry &a, const FileLogic::SortEntry &b) {
        return FileLogic::compareEntries(a, b, FileLogic::SortKey::Name, false, false, collator) < 0;
    });
    for (const FileLogic::SortEntry &e : entries) {
        const QByteArray bytes = e.name.toUtf8();
        std::fwrite(bytes.constData(), 1, size_t(bytes.size()), stdout);
        std::fputc('\n', stdout);
    }
    return 0;
}
