#include "renamelogic.h"

#include "filelogic.h"

#include <QHash>
#include <QSet>

namespace RenameLogic
{
namespace
{
// The name's stem and its extension with the dot (".txt"; "" for a folder, a dot file without another dot, no dot).
QPair<QString, QString> split(const QString &name, bool isDir)
{
    const int stem = FileLogic::baseNameLength(name, isDir);
    return {name.left(stem), name.mid(stem)};
}
} // namespace

QStringList newNames(const QStringList &names, const QList<bool> &isDir, const Options &options, const QDateTime &now)
{
    QStringList out;
    out.reserve(names.size());
    for (int i = 0; i < names.size(); ++i) {
        const auto [stem, ext] = split(names.at(i), i < isDir.size() && isDir.at(i));
        switch (options.mode) {
        case Mode::Replace:
            out.append(options.find.isEmpty() ? names.at(i) : QString(stem).replace(options.find, options.replaceWith, Qt::CaseSensitive) + ext);
            break;
        case Mode::Add:
            out.append(options.where == Where::BeforeName ? options.addText + stem + ext : stem + options.addText + ext);
            break;
        case Mode::Format: {
            const int n = options.startAt + i;
            QString mark;
            switch (options.format) {
            case Format::NameAndIndex:
                mark = QString::number(n);
                break;
            case Format::NameAndCounter:
                mark = QStringLiteral("%1").arg(n, 5, 10, QLatin1Char('0'));
                break;
            case Format::NameAndDate:
                // A date per item would give every item the same name: the date, then the index after the first.
                mark = now.toString(QStringLiteral("yyyy-MM-dd 'at' HH.mm.ss")) + (i > 0 ? QStringLiteral(" ") + QString::number(i + 1) : QString());
                break;
            }
            const QString base = options.customFormat;
            const QString name = base.isEmpty() ? mark : options.where == Where::BeforeName ? mark + QLatin1Char(' ') + base : base + QLatin1Char(' ') + mark;
            out.append(name + ext);
            break;
        }
        }
    }
    return out;
}

Problem check(const QStringList &oldNames, const QStringList &newNames, const QStringList &folders, QString *name)
{
    auto report = [name](Problem p, const QString &which) {
        if (name)
            *name = which;
        return p;
    };
    if (oldNames.size() != newNames.size() || oldNames.size() != folders.size())
        return report(Problem::InvalidName, QString());
    bool changes = false;
    QSet<QString> seen;
    QSet<QString> sources;
    for (int i = 0; i < oldNames.size(); ++i)
        sources.insert(folders.at(i) + QLatin1Char('/') + oldNames.at(i));
    for (int i = 0; i < newNames.size(); ++i) {
        const QString &n = newNames.at(i);
        if (!FileLogic::isValidFileName(n))
            return report(Problem::InvalidName, n);
        const QString target = folders.at(i) + QLatin1Char('/') + n;
        if (seen.contains(target))
            return report(Problem::Duplicate, n);
        seen.insert(target);
        if (n != oldNames.at(i)) {
            changes = true;
            if (sources.contains(target))
                return report(Problem::TakenInBatch, n);
        }
    }
    return changes ? Problem::None : report(Problem::NothingChanges, QString());
}

} // namespace RenameLogic
