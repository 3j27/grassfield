#include "appicons.h"

#include <cstdlib>

#include "applicationslogic.h"

#include <QAtomicInt>
#include <QBuffer>
#include <QElapsedTimer>
#include <QFile>
#include <QGuiApplication>
#include <QMutex>
#include <QMutexLocker>
#include <QProcess>
#include <QProcessEnvironment>
#include <QSet>
#include <QHash>
#include <QList>
#include <QImageReader>
#include <QXmlStreamReader>

#include <csignal>
#include <cstring>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <unistd.h>

namespace AppIcons
{

namespace
{
// Every "url(" in `text` must name a fragment of the document: url(#id), also quoted or padded.
bool urlsStayInside(const QString &text)
{
    int from = 0;
    for (;;) {
        const int at = text.indexOf(QLatin1String("url("), from, Qt::CaseInsensitive);
        if (at < 0)
            return true;
        int i = at + 4;
        while (i < text.size() && text.at(i).isSpace())
            ++i;
        if (i < text.size() && (text.at(i) == QLatin1Char('"') || text.at(i) == QLatin1Char('\'')))
            ++i;
        if (i >= text.size() || text.at(i) != QLatin1Char('#'))
            return false;
        from = i;
    }
}

// CSS: no at-rule (@import, @font-face) and no escape that could spell one of the words above.
bool cssIsPlain(const QString &text)
{
    return !text.contains(QLatin1Char('@')) && !text.contains(QLatin1Char('\\')) && urlsStayInside(text);
}
} // namespace

bool svgIsSelfContained(const QByteArray &data)
{
    if (data.isEmpty() || data.size() > kMaxSvgBytes)
        return false;
    QByteArray text = data;
    if (text.startsWith("\xEF\xBB\xBF"))
        text.remove(0, 3);
    // Plain UTF-8 only: a gzip (svgz) or UTF-16 document cannot be checked here and is refused.
    int first = 0;
    while (first < text.size() && (text.at(first) == ' ' || text.at(first) == '\t' || text.at(first) == '\n' || text.at(first) == '\r'))
        ++first;
    if (first >= text.size() || text.at(first) != '<')
        return false;

    QXmlStreamReader xml(text);
    int depth = 0;
    int elements = 0;
    int uses = 0;
    int styleDepth = 0;
    // Inside a <marker> or a <pattern> no url() at all: a marker whose content uses another marker (or a pattern
    // one) multiplies the drawing (300 x 300 vertices took 7.5 s, 1000 x 1000 30 s, 3000 x 3000 over two minutes). Gradients and
    // filters there are lost with it; those icons show the generic one (a mask or clipPath inside another is a chain, not a multiplication: allowed).
    int serverDepth = 0;
    QList<bool> isServer;
    // <use> copies what it references: a use inside something that is itself used multiplies (63 chained uses are 9^7 copies,
    // minutes of CPU). Only a use of an element with no use inside it is accepted, so the expansion is at most kMaxSvgUses
    // copies of one element. Each open element is an index; `ids` maps an id to its index.
    QList<int> open;
    QList<bool> containsUse;
    QList<bool> isStyle;
    QHash<QString, int> ids;
    QStringList useTargets;
    while (!xml.atEnd()) {
        switch (xml.readNext()) {
        case QXmlStreamReader::StartDocument: {
            const QString encoding = xml.documentEncoding().toString();
            if (!encoding.isEmpty() && encoding.compare(QLatin1String("utf-8"), Qt::CaseInsensitive) != 0)
                return false;
            break;
        }
        case QXmlStreamReader::DTD:
        case QXmlStreamReader::EntityReference:
        case QXmlStreamReader::ProcessingInstruction:
            return false;
        case QXmlStreamReader::StartElement: {
            if (++depth > kMaxSvgDepth || ++elements > kMaxSvgElements)
                return false;
            const QString name = xml.name().toString().toLower();
            // <image> and <feImage> are refused whatever they name: QtSvg opens even "#name" as a file relative to the
            // working directory (a FIFO there blocks the worker for good), and a data: image is not bounded in pixels.
            if (name == QLatin1String("image") || name == QLatin1String("feimage") || name == QLatin1String("script")
                || name == QLatin1String("foreignobject") || name == QLatin1String("iframe") || name == QLatin1String("embed")
                || name == QLatin1String("object") || name == QLatin1String("audio") || name == QLatin1String("video")
                || name == QLatin1String("handler") || name == QLatin1String("listener"))
                return false;
            const int index = int(containsUse.size());
            containsUse.append(false);
            isStyle.append(name == QLatin1String("style"));
            const bool inServer = serverDepth > 0;
            const bool server = name == QLatin1String("marker") || name == QLatin1String("pattern");
            isServer.append(server);
            if (server)
                ++serverDepth;
            open.append(index);
            if (name == QLatin1String("style"))
                ++styleDepth;
            if (name == QLatin1String("use")) {
                if (++uses > kMaxSvgUses)
                    return false;
                for (const int i : std::as_const(open))
                    containsUse[i] = true;
            }
            const auto attributes = xml.attributes();
            for (const QXmlStreamAttribute &a : attributes) {
                const QString key = a.name().toString().toLower();
                const QString value = a.value().toString();
                if (key == QLatin1String("href")) {
                    if (!value.startsWith(QLatin1Char('#')))
                        return false;
                    if (name == QLatin1String("use"))
                        useTargets << value.mid(1);
                }
                if (key == QLatin1String("id"))
                    ids.insert(value, index);
                if (key == QLatin1String("base") || key == QLatin1String("src"))
                    return false;
                // <set attributeName="href" to="file"> and <animate ...> write an href later.
                if (key == QLatin1String("attributename") && value.contains(QLatin1String("href"), Qt::CaseInsensitive))
                    return false;
                if (key.startsWith(QLatin1String("on")))
                    return false;
                if (inServer && value.contains(QLatin1String("url("), Qt::CaseInsensitive))
                    return false;
                if (!urlsStayInside(value) || (key == QLatin1String("style") && !cssIsPlain(value)))
                    return false;
            }
            break;
        }
        case QXmlStreamReader::EndElement:
            --depth;
            if (!open.isEmpty()) {
                if (isStyle.at(open.last()))
                    --styleDepth;
                if (isServer.at(open.last()))
                    --serverDepth;
                open.removeLast();
            }
            break;
        case QXmlStreamReader::Characters:
        case QXmlStreamReader::Comment: {
            const QString content = xml.text().toString();
            if (!urlsStayInside(content) || (styleDepth > 0 && !cssIsPlain(content)))
                return false;
            break;
        }
        default:
            break;
        }
    }
    if (xml.hasError() || depth != 0 || elements == 0)
        return false;
    for (const QString &target : std::as_const(useTargets)) {
        const auto it = ids.constFind(target);
        if (it != ids.cend() && containsUse.at(*it))
            return false;
    }
    return true;
}

QImage decode(const QByteArray &data, const QSize &wanted)
{
    QSize want = wanted.expandedTo(QSize(1, 1)).boundedTo(QSize(kMaxSide, kMaxSide));
    static const QByteArray pngMagic("\x89PNG\r\n\x1a\n", 8);
    QByteArray copy = data; // QBuffer needs a non-const array
    QBuffer buffer(&copy);
    if (!buffer.open(QIODevice::ReadOnly))
        return {};
    const bool png = data.startsWith(pngMagic);
    if (png ? data.size() > kMaxPngBytes : !svgIsSelfContained(data))
        return {};

    QImageReader reader(&buffer, png ? "png" : "svg");
    reader.setAutoDetectImageFormat(false);
    reader.setAllocationLimit(64); // MiB
    const QSize size = reader.size();
    if (png) {
        if (!size.isValid() || size.width() > kMaxSide || size.height() > kMaxSide)
            return {};
    } else {
        // An SVG is rendered at the size asked, never at the size it declares (a width of a million pixels).
        const QSize fit = size.isValid() && !size.isEmpty() ? size.scaled(want, Qt::KeepAspectRatio) : want;
        reader.setScaledSize(fit.expandedTo(QSize(1, 1)));
    }
    QImage image = reader.read();
    if (image.isNull())
        return {};
    if (image.width() > want.width() || image.height() > want.height())
        image = image.scaled(want, Qt::KeepAspectRatio, Qt::SmoothTransformation);
    return image;
}

QImage load(const QString &path, const QStringList &roots, const QSize &want)
{
    const qint64 cap = qMax(kMaxPngBytes, kMaxSvgBytes);
    const QByteArray data = ApplicationsLogic::readIconFile(path, roots, cap);
    return data.isEmpty() ? QImage() : decode(data, want);
}

// --- The decode in a process of its own -------------------------------------------------------------------------------

namespace
{
QMutex g_mutex;
QSet<qint64> g_pids;
QSet<QString> g_failed; // paths whose decode timed out or failed in this run: not tried again
QAtomicInt g_quitting;
void (*g_exitHook)() = nullptr;
QAtomicInt g_hookRegistrations;
void runExitHook()
{
    if (g_exitHook)
        g_exitHook();
}
// Registered after the statics that a decode creates, in the first starts only (see setExitHook).
void registerExitHookAgain()
{
    if (g_exitHook && g_hookRegistrations.fetchAndAddRelaxed(1) < 4)
        std::atexit(runExitHook);
}
QString g_program;
QStringList g_arguments;
int g_deadlineMs = AppIcons::kDecodeDeadlineMs;
constexpr qint64 kMaxChildOutput = 16 * 1024 * 1024;
} // namespace

bool isDecodeChildInvocation(int argc, char **argv)
{
    return argc >= 4 && std::strcmp(argv[1], "--decode-icon") == 0;
}

int decodeChildMain(int argc, char **argv)
{
    // The parent set QT_QPA_PLATFORM=offscreen; this process only decodes and has no window, no D-Bus, no settings.
    QGuiApplication app(argc, argv);
    const QSize want(QByteArray(argv[2]).toInt(), QByteArray(argv[3]).toInt());
    QFile in;
    QFile out;
    if (!in.open(stdin, QIODevice::ReadOnly) || !out.open(stdout, QIODevice::WriteOnly))
        return 2;
    // Until EOF (the parent writes a big icon in pieces: one read() returned only the first pipe-full, 64 KiB, and every larger
    // icon showed the generic one), but never more than the cap plus one byte.
    const qint64 cap = qMax(kMaxPngBytes, kMaxSvgBytes);
    QByteArray data;
    for (;;) {
        const QByteArray chunk = in.read(cap + 1 - data.size());
        if (chunk.isEmpty())
            break; // EOF (a blocking read of a pipe returns data or 0 at the end)
        data += chunk;
        if (data.size() > cap)
            return 1;
    }
    const QImage image = decode(data, want);
    if (image.isNull() || !image.save(&out, "PNG"))
        return 1;
    out.flush();
    return 0;
}

void setDecoderForTests(const QString &program, const QStringList &arguments, int deadlineMs)
{
    QMutexLocker lock(&g_mutex);
    g_program = program;
    g_arguments = arguments;
    g_deadlineMs = deadlineMs > 0 ? deadlineMs : kDecodeDeadlineMs;
    g_failed.clear();
    g_quitting.storeRelease(0); // a test that called shutdown() starts over
}

int runningDecodes()
{
    QMutexLocker lock(&g_mutex);
    return int(g_pids.size());
}

void setExitHook(void (*hook)())
{
    g_exitHook = hook;
}

void shutdown()
{
    g_quitting.storeRelease(1);
    QMutexLocker lock(&g_mutex);
    for (const qint64 pid : std::as_const(g_pids))
        ::kill(pid_t(pid), SIGKILL);
}

QImage loadIsolated(const QString &path, const QStringList &roots, const QSize &wanted)
{
    if (g_quitting.loadAcquire())
        return {};
    {
        QMutexLocker lock(&g_mutex);
        if (g_failed.contains(path))
            return {};
    }
    const QByteArray data = ApplicationsLogic::readIconFile(path, roots, qMax(kMaxPngBytes, kMaxSvgBytes));
    if (data.isEmpty())
        return {};
    const QSize want = wanted.expandedTo(QSize(1, 1)).boundedTo(QSize(kMaxSide, kMaxSide));

    QString program;
    QStringList arguments;
    int deadline;
    {
        QMutexLocker lock(&g_mutex);
        program = g_program.isEmpty() ? QCoreApplication::applicationFilePath() : g_program;
        arguments = g_program.isEmpty() ? QStringList{QStringLiteral("--decode-icon")} : g_arguments;
        deadline = g_deadlineMs;
    }
    arguments << QString::number(want.width()) << QString::number(want.height());

    QProcessEnvironment env = QProcessEnvironment::systemEnvironment();
    env.remove(QStringLiteral("WAYLAND_DISPLAY"));
    env.remove(QStringLiteral("DISPLAY"));
    env.insert(QStringLiteral("QT_QPA_PLATFORM"), QStringLiteral("offscreen"));
    env.insert(QStringLiteral("QT_QPA_PLATFORMTHEME"), QStringLiteral("none"));
    QProcess child;
    child.setProcessEnvironment(env);
    child.setProgram(program);
    child.setArguments(arguments);
    child.setProcessChannelMode(QProcess::SeparateChannels);
    // Runs in the forked child before exec: only async-signal-safe calls. No core file (a killed decoder is no crash of Files),
    // limits on memory and CPU time, and it dies with Files.
    child.setChildProcessModifier([] {
#ifndef __SANITIZE_ADDRESS__ // an ASan test build maps terabytes of shadow memory
        struct rlimit as = {3UL << 30, 3UL << 30};
        ::setrlimit(RLIMIT_AS, &as);
#endif
        struct rlimit cpu = {10, 10};
        ::setrlimit(RLIMIT_CPU, &cpu);
        struct rlimit core = {0, 0};
        ::setrlimit(RLIMIT_CORE, &core);
        ::prctl(PR_SET_PDEATHSIG, SIGKILL);
    });
    child.start(QIODevice::ReadWrite);
    if (!child.waitForStarted(2000))
        return {};
    registerExitHookAgain(); // after the process internals the first start created
    const qint64 pid = child.processId();
    {
        QMutexLocker lock(&g_mutex);
        g_pids.insert(pid);
    }
    auto forget = [&] {
        QMutexLocker lock(&g_mutex);
        g_pids.remove(pid);
    };
    // Quit raced with the start: the kill in shutdown() may have run before this pid was registered.
    if (g_quitting.loadAcquire())
        ::kill(pid_t(pid), SIGKILL);
    child.write(data);
    child.closeWriteChannel();
    QElapsedTimer clock;
    clock.start();
    bool finished = false;
    while (!finished && clock.elapsed() < deadline && !g_quitting.loadAcquire())
        finished = child.waitForFinished(50);
    if (!finished) {
        ::kill(pid_t(pid), SIGKILL);
        child.waitForFinished(1000);
        forget();
        if (!g_quitting.loadAcquire()) {
            QMutexLocker lock(&g_mutex);
            g_failed.insert(path);
        }
        return {};
    }
    forget();
    if (child.exitStatus() != QProcess::NormalExit || child.exitCode() != 0) {
        QMutexLocker lock(&g_mutex);
        g_failed.insert(path);
        return {};
    }
    const QByteArray png = child.readAllStandardOutput();
    if (png.isEmpty() || png.size() > kMaxChildOutput)
        return {};
    // The parent decodes only the PNG its own child produced.
    QImage image = QImage::fromData(png, "PNG");
    if (image.width() > kMaxSide || image.height() > kMaxSide)
        return {};
    return image;
}

} // namespace AppIcons
