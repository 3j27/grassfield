#include "applicationslogic.h"

#include <QCollator>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QHash>
#include <QLocale>
#include <QRegularExpression>
#include <QStandardPaths>

#include <algorithm>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

namespace ApplicationsLogic
{

namespace
{
constexpr qint64 kMaxEntryBytes = 256 * 1024;
constexpr int kMaxDepth = 32; // Quickshell has no limit; loops are cut by the visited set, this only bounds a hostile tree
constexpr int kMaxEntries = 20000;

bool hasDesktop(const QString &list, const QStringList &current)
{
    for (const QString &name : list.split(QLatin1Char(';'), Qt::SkipEmptyParts)) {
        if (current.contains(name))
            return true;
    }
    return false;
}

// hidden-entries.sh's terminalHelper(): the Categories value is searched as ";value" for ";TerminalEmulator;" (so a list that
// ends without ';' after it does not count), the Exec value is split on blanks.
bool terminalHelper(const QString &categories, const QString &exec)
{
    if (!(QLatin1Char(';') + categories).contains(QLatin1String(";TerminalEmulator;")))
        return false;
    const QStringList words = exec.split(QRegularExpression(QStringLiteral("[ \t]+")));
    if (words.isEmpty())
        return false;
    QString program = words.first();
    program = program.mid(program.lastIndexOf(QLatin1Char('/')) + 1);
    if (program.endsWith(QLatin1String("client")))
        return true;
    for (int i = 1; i < words.size(); ++i) {
        if (words.at(i) == QLatin1String("--server") || words.at(i) == QLatin1String("--daemon"))
            return true;
    }
    return false;
}

// What Quickshell's DesktopEntries reads. See applicationslogic.h: nothing is trimmed, the first [Desktop Entry] group only.
struct Fields {
    QString type, icon, exec, categories, noDisplay, hidden;
    QString name, genericName, comment;
    QHash<QString, QString> names, genericNames, comments; // by locale suffix
    QStringList nameOrder;                                  // the Name[...] suffixes in file order
};

Fields readFields(QByteArray text)
{
    Fields f;
    if (text.startsWith("\xEF\xBB\xBF"))
        text.remove(0, 3);
    bool inEntry = false, seen = false;
    for (const QByteArray &raw : text.split('\n')) {
        const QString line = QString::fromUtf8(raw);
        if (line.startsWith(QLatin1Char('['))) {
            inEntry = !seen && line == QLatin1String("[Desktop Entry]");
            seen = seen || inEntry;
            continue;
        }
        if (!inEntry || line.isEmpty() || line.startsWith(QLatin1Char('#')))
            continue;
        const int eq = line.indexOf(QLatin1Char('='));
        if (eq <= 0)
            continue;
        const QString key = line.left(eq);
        const QString value = line.mid(eq + 1);
        auto localized = [&](const QString &base, QString &plain, QHash<QString, QString> &byLocale, QStringList *order) {
            if (key == base) {
                plain = value;
            } else if (key.startsWith(base + QLatin1Char('[')) && key.endsWith(QLatin1Char(']'))) {
                const QString suffix = key.mid(base.size() + 1, key.size() - base.size() - 2);
                if (order && !byLocale.contains(suffix))
                    order->append(suffix);
                byLocale.insert(suffix, value);
            }
        };
        if (key == QLatin1String("Type"))
            f.type = value;
        else if (key == QLatin1String("Icon"))
            f.icon = value;
        else if (key == QLatin1String("Exec"))
            f.exec = value;
        else if (key == QLatin1String("Categories"))
            f.categories = value;
        else if (key == QLatin1String("NoDisplay"))
            f.noDisplay = value;
        else if (key == QLatin1String("Hidden"))
            f.hidden = value;
        else {
            localized(QStringLiteral("Name"), f.name, f.names, &f.nameOrder);
            localized(QStringLiteral("GenericName"), f.genericName, f.genericNames, nullptr);
            localized(QStringLiteral("Comment"), f.comment, f.comments, nullptr);
        }
    }
    return f;
}

// What hidden-entries.sh reads, with its own rules: a trailing blank and CR cut, "Key = value" accepted (but no blank before the
// key), the last of a repeated key wins, every [Desktop Entry] group counts.
struct ScriptFields {
    QString onlyShowIn, notShowIn, categories, exec;
};

ScriptFields readScriptFields(const QByteArray &text)
{
    ScriptFields s;
    static const QRegularExpression only(QStringLiteral("^OnlyShowIn[ \t]*="));
    static const QRegularExpression notIn(QStringLiteral("^NotShowIn[ \t]*="));
    static const QRegularExpression cats(QStringLiteral("^Categories[ \t]*="));
    static const QRegularExpression exec(QStringLiteral("^Exec[ \t]*="));
    static const QRegularExpression afterEquals(QStringLiteral("^[^=]*=[ \t]*"));
    QString group;
    for (const QByteArray &raw : text.split('\n')) {
        QString line = QString::fromUtf8(raw);
        while (line.endsWith(QLatin1Char(' ')) || line.endsWith(QLatin1Char('\t')) || line.endsWith(QLatin1Char('\r')))
            line.chop(1);
        if (line.startsWith(QLatin1Char('['))) {
            group = line;
            continue;
        }
        if (group != QLatin1String("[Desktop Entry]"))
            continue;
        const QString value = QString(line).remove(afterEquals);
        if (only.match(line).hasMatch())
            s.onlyShowIn = value;
        else if (notIn.match(line).hasMatch())
            s.notShowIn = value;
        else if (cats.match(line).hasMatch())
            s.categories = value;
        else if (exec.match(line).hasMatch())
            s.exec = value;
    }
    return s;
}

QString pick(const QString &plain, const QHash<QString, QString> &byLocale, const QStringList &locales)
{
    for (const QString &l : locales) {
        const auto it = byLocale.constFind(l);
        if (it != byLocale.cend() && !it->isEmpty())
            return *it;
    }
    return plain;
}

// The Name the grid shows: Name[fr_FR], Name[fr], Name, else the first Name[...] of the file; empty when there is none.
QString nameOf(const Fields &f, const QStringList &locales)
{
    QString name = pick(f.name, f.names, locales);
    if (name.isEmpty()) {
        for (const QString &suffix : f.nameOrder) {
            if (!f.names.value(suffix).isEmpty())
                return f.names.value(suffix);
        }
    }
    return name;
}

// The ids and paths of every desktop file below `dir` (symlinked folders followed, loops cut), in Quickshell's order: each
// folder's entries sorted by name, case-insensitively, files and folders mixed.
void collect(const QDir &base, const QDir &dir, int depth, QSet<QString> &visited, QList<QPair<QString, QString>> &out)
{
    if (depth > kMaxDepth || out.size() >= kMaxEntries)
        return;
    const QString canonical = QFileInfo(dir.absolutePath()).canonicalFilePath();
    if (canonical.isEmpty() || visited.contains(canonical))
        return;
    visited.insert(canonical);
    const QFileInfoList entries =
        dir.entryInfoList(QDir::Files | QDir::Dirs | QDir::NoDotAndDotDot | QDir::Readable, QDir::Name | QDir::IgnoreCase);
    for (const QFileInfo &info : entries) {
        if (info.fileName().contains(QLatin1Char('\n')))
            continue;
        if (info.isDir()) {
            collect(base, QDir(info.absoluteFilePath()), depth + 1, visited, out);
        } else if (info.fileName().endsWith(QLatin1String(".desktop"))) {
            QString id = base.relativeFilePath(info.absoluteFilePath());
            id.chop(8);
            id.replace(QLatin1Char('/'), QLatin1Char('-'));
            out.append({id, info.absoluteFilePath()});
        }
    }
    visited.remove(canonical);
}

// Model.vendorOf: a reverse-DNS id names its vendor in its second label.
QString vendorOf(const QString &id)
{
    static const QRegularExpression re(QStringLiteral("^[a-z]+\\.([A-Za-z0-9_-]+)\\.[A-Za-z0-9_.-]+$"));
    const QRegularExpressionMatch m = re.match(id);
    if (!m.hasMatch())
        return {};
    static const QHash<QString, QString> known = {{QStringLiteral("gnome"), QStringLiteral("GNOME")}, {QStringLiteral("kde"), QStringLiteral("KDE")},
                                                  {QStringLiteral("xfce"), QStringLiteral("Xfce")}, {QStringLiteral("gimp"), QStringLiteral("GIMP")},
                                                  {QStringLiteral("mozilla"), QStringLiteral("Mozilla")},
                                                  {QStringLiteral("libreoffice"), QStringLiteral("LibreOffice")}};
    const QString v = m.captured(1);
    const auto it = known.constFind(v.toLower());
    return it != known.cend() ? *it : v.left(1).toUpper() + v.mid(1);
}
} // namespace

QStringList defaultHelperIds()
{
    return {QStringLiteral("avahi-discover"), QStringLiteral("bssh"), QStringLiteral("bvnc"), QStringLiteral("lstopo"),
            QStringLiteral("org.fcitx.Fcitx5"), QStringLiteral("org.fcitx.fcitx5-qt5-gui-wrapper"),
            QStringLiteral("org.fcitx.fcitx5-qt6-gui-wrapper"), QStringLiteral("fcitx5-migrator")};
}

QStringList localeCandidates(const QString &localeName)
{
    QString name = localeName;
    const int dot = name.indexOf(QLatin1Char('.'));
    if (dot >= 0)
        name = name.left(dot);
    const int at = name.indexOf(QLatin1Char('@'));
    if (at >= 0)
        name = name.left(at);
    QStringList out;
    if (name.isEmpty() || name == QLatin1String("C") || name == QLatin1String("POSIX"))
        return out;
    out << name;
    const int underscore = name.indexOf(QLatin1Char('_'));
    if (underscore > 0)
        out << name.left(underscore);
    return out;
}

Environment processEnvironment()
{
    Environment env;
    const QString home = QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation);
    if (!home.isEmpty())
        env.applicationDirs << home + QStringLiteral("/applications");
    for (const QString &dir : QStandardPaths::standardLocations(QStandardPaths::GenericDataLocation)) {
        const QString apps = dir + QStringLiteral("/applications");
        if (!env.applicationDirs.contains(apps))
            env.applicationDirs << apps;
    }
    env.currentDesktop = qEnvironmentVariable("XDG_CURRENT_DESKTOP").split(QLatin1Char(':'), Qt::SkipEmptyParts);
    env.locales = localeCandidates(QLocale().name());
    const QStringList helpers = defaultHelperIds();
    env.helperIds = QSet<QString>(helpers.cbegin(), helpers.cend());
    return env;
}

bool parseEntry(const QByteArray &text, const QString &id, const QString &path, const Environment &env, Entry *out)
{
    const Fields f = readFields(text);
    if (f.type != QLatin1String("Application"))
        return false;
    if (f.noDisplay == QLatin1String("true") || f.hidden == QLatin1String("true"))
        return false;
    const QString name = nameOf(f, env.locales);
    if (name.isEmpty())
        return false;
    const ScriptFields s = readScriptFields(text);
    if (!s.onlyShowIn.isEmpty() && !hasDesktop(s.onlyShowIn, env.currentDesktop))
        return false;
    if (!s.notShowIn.isEmpty() && hasDesktop(s.notShowIn, env.currentDesktop))
        return false;
    if (terminalHelper(s.categories, s.exec))
        return false;
    Entry e;
    e.id = id;
    e.path = path;
    e.name = e.baseName = name;
    e.genericName = pick(f.genericName, f.genericNames, env.locales);
    e.comment = pick(f.comment, f.comments, env.locales);
    e.icon = f.icon;
    e.exec = f.exec;
    e.categories = f.categories.split(QLatin1Char(';'), Qt::SkipEmptyParts);
    *out = e;
    return true;
}

void disambiguate(QList<Entry> &entries)
{
    QHash<QString, QList<int>> groups;
    for (int i = 0; i < entries.size(); ++i) {
        entries[i].baseName = entries.at(i).name;
        groups[entries.at(i).name.trimmed().toLower()].append(i);
    }
    for (auto it = groups.cbegin(); it != groups.cend(); ++it) {
        if (it.key().isEmpty() || it.value().size() < 2)
            continue;
        for (const int i : it.value()) {
            Entry &e = entries[i];
            if (e.id.startsWith(QLatin1String("org.grassfield.")))
                continue;
            const QString vendor = vendorOf(e.id);
            const QString generic = e.genericName.trimmed();
            const QString qualifier = !vendor.isEmpty() ? vendor : (!generic.isEmpty() && generic.toLower() != it.key() ? generic : e.id);
            e.name = e.baseName + QStringLiteral(" (") + qualifier + QLatin1Char(')');
        }
        QHash<QString, int> counts;
        for (const int i : it.value())
            counts[entries.at(i).name]++;
        for (const int i : it.value()) {
            if (counts.value(entries.at(i).name) > 1)
                entries[i].name = entries.at(i).baseName + QStringLiteral(" (") + entries.at(i).id + QLatin1Char(')');
        }
    }
}

QList<Entry> listApplications(const Environment &env)
{
    QSet<QString> seen;
    QList<Entry> result;
    for (const QString &dirPath : env.applicationDirs) {
        const QDir dir(dirPath);
        if (!dir.exists())
            continue;
        QList<QPair<QString, QString>> files;
        QSet<QString> visited;
        collect(dir, dir, 0, visited, files);
        // A file that is not an application with a Name (a Link, a Directory, no Name) does not exist for Quickshell: it masks
        // nothing. A valid one does, also when it is then not listed (Hidden=true, NoDisplay=true, OnlyShowIn elsewhere), and
        // of two valid files of one id in this directory the later one in the sorted walk wins.
        struct Candidate {
            QString path;
            QByteArray text;
        };
        QHash<QString, Candidate> winner;
        QStringList order;
        for (const auto &file : std::as_const(files)) {
            if (seen.contains(file.first))
                continue;
            QFile f(file.second);
            if (!f.open(QIODevice::ReadOnly))
                continue;
            const QByteArray text = f.read(kMaxEntryBytes);
            const Fields fields = readFields(text);
            if (fields.type != QLatin1String("Application") || nameOf(fields, env.locales).isEmpty())
                continue;
            if (!winner.contains(file.first))
                order << file.first;
            winner.insert(file.first, {file.second, text});
        }
        for (const QString &id : std::as_const(order)) {
            // The highest-priority directory that has an id counts.
            seen.insert(id);
            if (env.helperIds.contains(id))
                continue;
            Entry entry;
            if (parseEntry(winner.value(id).text, id, winner.value(id).path, env, &entry))
                result.append(entry);
        }
    }
    disambiguate(result);
    QCollator collator;
    collator.setCaseSensitivity(Qt::CaseInsensitive);
    collator.setNumericMode(true);
    std::sort(result.begin(), result.end(), [&collator](const Entry &a, const Entry &b) {
        const int c = collator.compare(a.name, b.name);
        return c != 0 ? c < 0 : a.id < b.id;
    });
    return result;
}

QStringList iconRoots()
{
    QStringList candidates = {qEnvironmentVariable("HOME"), QStandardPaths::writableLocation(QStandardPaths::GenericDataLocation)};
    candidates << QStandardPaths::standardLocations(QStandardPaths::GenericDataLocation);
    candidates << QStringLiteral("/usr") << QStringLiteral("/opt") << QStringLiteral("/var/lib/flatpak") << QStringLiteral("/var/lib/snapd/desktop")
               << QStringLiteral("/var/lib/AccountsService/icons") << QStringLiteral("/tmp") << QStringLiteral("/var/tmp")
               << qEnvironmentVariable("XDG_RUNTIME_DIR") << QStringLiteral("/media") << QStringLiteral("/mnt") << QStringLiteral("/run/media")
               << QStringLiteral("/srv");
    QStringList roots;
    for (const QString &c : std::as_const(candidates)) {
        if (!c.startsWith(QLatin1Char('/')))
            continue;
        const QString real = QFileInfo(c).canonicalFilePath();
        if (!real.isEmpty() && real != QLatin1String("/") && !roots.contains(real))
            roots << real;
    }
    return roots;
}

QString safeIconFile(const QString &path, const QStringList &roots, qint64 cap)
{
    auto under = [&roots](const QString &p) {
        for (const QString &r : roots) {
            if (p == r || p.startsWith(r + QLatin1Char('/')))
                return true;
        }
        return false;
    };
    static const QRegularExpression control(QStringLiteral("[\\x00-\\x1f\\x7f]"));
    if (!path.startsWith(QLatin1Char('/')) || path.size() > 4096 || path.contains(control))
        return {};
    const QString real = QFileInfo(path).canonicalFilePath();
    if (real.isEmpty() || !under(real))
        return {};
    const QByteArray native = QFile::encodeName(real);
    struct stat info;
    if (::lstat(native.constData(), &info) != 0 || !S_ISREG(info.st_mode))
        return {};
    const int fd = ::open(native.constData(), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY | O_CLOEXEC);
    if (fd < 0)
        return {};
    bool ok = ::fstat(fd, &info) == 0 && S_ISREG(info.st_mode) && info.st_size > 0 && info.st_size <= cap;
    if (ok) {
        char link[4097];
        const QByteArray self = "/proc/self/fd/" + QByteArray::number(fd);
        const ssize_t n = ::readlink(self.constData(), link, sizeof(link) - 1);
        ok = n > 0 && under(QString::fromLocal8Bit(link, static_cast<int>(n)));
    }
    ::close(fd);
    return ok ? real : QString();
}

QUrl locationUrl()
{
    return QUrl(QStringLiteral("grassfield-apps:/"));
}

bool isLocationUrl(const QUrl &url)
{
    return url.scheme() == QLatin1String("grassfield-apps");
}

QUrl entryUrl(const QString &id)
{
    QUrl url;
    url.setScheme(QStringLiteral("grassfield-app"));
    url.setPath(QLatin1Char('/') + id);
    return url;
}

QString entryId(const QUrl &url)
{
    if (url.scheme() != QLatin1String("grassfield-app"))
        return {};
    return url.path().mid(1);
}

} // namespace ApplicationsLogic
