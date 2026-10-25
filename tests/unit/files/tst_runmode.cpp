#include <gtest/gtest.h>

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QStringList>

#include "runmode.h"

// The C++ side of the run-mode rule (apps/runmode.h) against the shared vectors tests/fixtures/run-mode-vectors.json, the
// same file shell/lib/RunMode.js is held to (tests/unit/tst_runmode.qml): parity of the two implementations (ADR-0019).
namespace rm = grassfield::apps::runmode;

namespace
{
// Every variable a vector may set. A vector's environment replaces all of them: a variable it does not name is unset.
const QStringList kVariables = {
    "GRASSFIELD_DEV", "GRASSFIELD_SESSION", "GRASSFIELD_VISUAL_FIXTURES", "GRASSFIELD_PRIVATE_BUS", "GRASSFIELD_CONFIG_HOME",
    "GRASSFIELD_STATE_HOME", "GRASSFIELD_FIXED_TIME", "GRASSFIELD_OPEN_POLICY", "GRASSFIELD_SHELL_DIR", "HOME", "XDG_CONFIG_HOME",
    "XDG_STATE_HOME"};

// Sets the environment of a vector for its scope and puts the previous one back.
class ScopedEnv
{
public:
    explicit ScopedEnv(const QJsonObject &env)
    {
        for (const QString &name : kVariables) {
            const QByteArray key = name.toUtf8();
            m_saved.append({name, qEnvironmentVariableIsSet(key.constData()), qEnvironmentVariable(key.constData())});
            if (env.contains(name))
                qputenv(key.constData(), env.value(name).toString().toUtf8());
            else
                qunsetenv(key.constData());
        }
    }
    ~ScopedEnv()
    {
        for (const Saved &s : m_saved) {
            const QByteArray key = s.name.toUtf8();
            if (s.wasSet)
                qputenv(key.constData(), s.value.toUtf8());
            else
                qunsetenv(key.constData());
        }
    }

private:
    struct Saved {
        QString name;
        bool wasSet;
        QString value;
    };
    QList<Saved> m_saved;
};

QJsonObject fixture()
{
    const QDir tests = QFileInfo(QStringLiteral(__FILE__)).absoluteDir(); // tests/unit/files
    QFile file(QDir::cleanPath(tests.filePath(QStringLiteral("../../fixtures/run-mode-vectors.json"))));
    EXPECT_TRUE(file.open(QIODevice::ReadOnly)) << file.fileName().toStdString();
    return QJsonDocument::fromJson(file.readAll()).object();
}

QString value(const QJsonObject &env, const char *name)
{
    return env.value(QLatin1String(name)).toString();
}
} // namespace

TEST(RunMode, ModesMatchTheSharedVectors)
{
    const QJsonArray modes = fixture().value(QStringLiteral("modes")).toArray();
    ASSERT_GT(modes.size(), 10);
    for (const QJsonValue &entry : modes) {
        const QJsonObject v = entry.toObject();
        const std::string name = v.value(QStringLiteral("name")).toString().toStdString();
        const QJsonObject env = v.value(QStringLiteral("env")).toObject();
        // The pure functions over the raw values.
        EXPECT_EQ(rm::dev(value(env, "GRASSFIELD_DEV"), value(env, "GRASSFIELD_SESSION")), v.value(QStringLiteral("dev")).toBool()) << name;
        EXPECT_EQ(rm::session(value(env, "GRASSFIELD_SESSION")), v.value(QStringLiteral("session")).toBool()) << name;
        // The same through the process environment.
        const ScopedEnv scoped(env);
        EXPECT_EQ(rm::dev(), v.value(QStringLiteral("dev")).toBool()) << name;
        EXPECT_EQ(rm::session(), v.value(QStringLiteral("session")).toBool()) << name;
        // Update notices are for a packaged session only: the session value itself.
        EXPECT_EQ(rm::session(), v.value(QStringLiteral("updateNotices")).toBool()) << name;
    }
}

TEST(RunMode, DirsMatchTheSharedVectors)
{
    const QJsonArray dirs = fixture().value(QStringLiteral("dirs")).toArray();
    ASSERT_GT(dirs.size(), 3);
    for (const QJsonValue &entry : dirs) {
        const QJsonObject v = entry.toObject();
        const std::string name = v.value(QStringLiteral("name")).toString().toStdString();
        const QJsonObject env = v.value(QStringLiteral("env")).toObject();
        const QString config = v.value(QStringLiteral("configDir")).toString();
        const QString state = v.value(QStringLiteral("stateDir")).toString();
        EXPECT_EQ(rm::configDir(value(env, "GRASSFIELD_CONFIG_HOME"), value(env, "XDG_CONFIG_HOME"), value(env, "HOME")), config) << name;
        EXPECT_EQ(rm::stateDir(value(env, "GRASSFIELD_STATE_HOME"), value(env, "XDG_STATE_HOME"), value(env, "HOME")), state) << name;
        const ScopedEnv scoped(env);
        EXPECT_EQ(rm::configDir(), config) << name;
        EXPECT_EQ(rm::stateDir(), state) << name;
    }
}

TEST(RunMode, PlumbingMatchesTheSharedVectors)
{
    const QJsonArray plumbing = fixture().value(QStringLiteral("plumbing")).toArray();
    ASSERT_GT(plumbing.size(), 3);
    for (const QJsonValue &entry : plumbing) {
        const QJsonObject v = entry.toObject();
        const std::string name = v.value(QStringLiteral("name")).toString().toStdString();
        const QJsonObject env = v.value(QStringLiteral("env")).toObject();
        const QString variable = v.value(QStringLiteral("variable")).toString(); // GRASSFIELD_<name>
        const QString expected = v.value(QStringLiteral("value")).toString();
        EXPECT_EQ(rm::devPlumbing(value(env, "GRASSFIELD_DEV"), value(env, "GRASSFIELD_SESSION"), env.value(variable).toString()), expected) << name;
        const ScopedEnv scoped(env);
        ASSERT_TRUE(variable.startsWith(QLatin1String("GRASSFIELD_"))) << name;
        EXPECT_EQ(rm::devValue(variable.mid(11).toUtf8().constData()), expected) << name;
    }
}

TEST(RunMode, ALeakedDevValueInAPackagedSessionChangesNothing)
{
    const ScopedEnv scoped(QJsonObject{{"GRASSFIELD_DEV", "1"}, {"GRASSFIELD_SESSION", "1"}, {"GRASSFIELD_SHELL_DIR", "/tmp/evil"},
                                       {"GRASSFIELD_OPEN_POLICY", "allow"}});
    EXPECT_FALSE(rm::dev());
    EXPECT_TRUE(rm::session());
    EXPECT_EQ(rm::devValue("OPEN_POLICY"), QString());
    EXPECT_EQ(rm::shellIpcArgs(), (QStringList{"ipc", "-p", "/usr/share/grassfield/shell", "call"}));
}

TEST(RunMode, ShellIpcArgsUseTheDevShellInADevSession)
{
    {
        const ScopedEnv scoped(QJsonObject{{"GRASSFIELD_DEV", "1"}, {"GRASSFIELD_SHELL_DIR", "/work/shell"}});
        EXPECT_EQ(rm::shellIpcArgs(), (QStringList{"ipc", "-p", "/work/shell", "call"}));
    }
    // A dev session without the variable has no shell to call: empty, never the installed shell (the caller refuses).
    {
        const ScopedEnv scoped(QJsonObject{{"GRASSFIELD_DEV", "1"}});
        EXPECT_TRUE(rm::shellIpcArgs().isEmpty());
    }
    {
        const ScopedEnv scoped(QJsonObject{{"GRASSFIELD_DEV", "1"}, {"GRASSFIELD_SHELL_DIR", ""}});
        EXPECT_TRUE(rm::shellIpcArgs().isEmpty());
    }
    // A plain session talks to the installed shell, whatever GRASSFIELD_SHELL_DIR says.
    {
        const ScopedEnv scoped(QJsonObject{{"GRASSFIELD_SHELL_DIR", "/work/shell"}});
        EXPECT_EQ(rm::shellIpcArgs(), (QStringList{"ipc", "-p", "/usr/share/grassfield/shell", "call"}));
    }
}
