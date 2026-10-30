// grassfield-portal's Choose Application (ADR-0035 D-5, step 5b; docs/specs/system-dialogs.md section 2, OW1, A-OW1): what the
// panel is given (AppChooser::toQml), and org.freedesktop.impl.portal.AppChooser on the run's private bus (tst_filechooser.cpp's
// main) with a fake frontend and a fake x-d-p-gtk: the choice and its token back, Cancel, UpdateChoices, Close and the forward.
#include <gtest/gtest.h>

#include "appchooser.h"

#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDeadlineTimer>
#include <QTest>

#include <functional>
#include <limits>
#include <memory>

using namespace grassfield::portal;

extern QString g_address;

namespace {

constexpr auto kService = "org.freedesktop.impl.portal.desktop.grassfield";
constexpr auto kFakeGtk = "org.test.fakegtk.appchooser";
constexpr int kDeadlineMs = 1500;

// x-d-p-gtk's AppChooser as the forward sees it: holds the call until the test answers it, and records UpdateChoices.
class FakeGtkAppChooser : public QObject
{
    Q_OBJECT
    Q_CLASSINFO("D-Bus Interface", "org.freedesktop.impl.portal.AppChooser")
public:
    QStringList calls;
    QList<QStringList> updates;
    QDBusMessage held;

public Q_SLOTS:
    uint ChooseApplication(const QDBusObjectPath &handle, const QString &, const QString &, const QStringList &choices, const QVariantMap &,
                           const QDBusMessage &message, QVariantMap &)
    {
        calls << QStringLiteral("ChooseApplication %1 %2").arg(handle.path(), choices.join(QLatin1Char(',')));
        message.setDelayedReply(true);
        held = message;
        return 0;
    }
    void UpdateChoices(const QDBusObjectPath &handle, const QStringList &choices)
    {
        Q_UNUSED(handle)
        updates << choices;
    }
};

struct Reply {
    bool done = false;
    bool error = false;
    uint response = 99;
    QVariantMap results;
};

class AppChooserTest : public ::testing::Test
{
protected:
    void SetUp() override
    {
        static int n = 0;
        const QString suffix = QString::number(++n);
        backendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("apps-backend") + suffix));
        frontendBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("apps-frontend") + suffix));
        gtkBus = std::make_unique<QDBusConnection>(QDBusConnection::connectToBus(g_address, QStringLiteral("apps-gtk") + suffix));
        ASSERT_TRUE(backendBus->isConnected() && frontendBus->isConnected() && gtkBus->isConnected());
        AppChooser::Options options;
        options.gtkService = QString::fromLatin1(kFakeGtk);
        options.uiDeadlineMs = kDeadlineMs;
        options.idleQuitMs = 200;
        chooser = std::make_unique<AppChooser>(*backendBus, options);
        exported = std::make_unique<QObject>();
        new AppChooserAdaptor(exported.get(), chooser.get());
        ASSERT_TRUE(backendBus->registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), exported.get(), QDBusConnection::ExportAdaptors));
        ASSERT_TRUE(backendBus->registerService(QString::fromLatin1(kService)));
        QObject::connect(chooser.get(), &AppChooser::opened, chooser.get(), [this](int id, const QVariantMap &request) { opened.append({id, request}); });
        QObject::connect(chooser.get(), &AppChooser::closed, chooser.get(), [this](int id) { closed.append(id); });
        QObject::connect(chooser.get(), &AppChooser::applicationsChanged, chooser.get(),
                         [this](int id, const QStringList &applications) { changed.append({id, applications}); });
        ASSERT_TRUE(gtkBus->registerObject(QStringLiteral("/org/freedesktop/portal/desktop"), &gtk, QDBusConnection::ExportAllSlots));
        ASSERT_TRUE(gtkBus->registerService(QString::fromLatin1(kFakeGtk)));
    }

    void TearDown() override
    {
        backendBus->unregisterService(QString::fromLatin1(kService));
        backendBus->unregisterObject(QStringLiteral("/org/freedesktop/portal/desktop"));
        gtkBus->unregisterService(QString::fromLatin1(kFakeGtk));
        chooser.reset();
        exported.reset();
        QDBusConnection::disconnectFromBus(backendBus->name());
        QDBusConnection::disconnectFromBus(frontendBus->name());
        QDBusConnection::disconnectFromBus(gtkBus->name());
    }

    // The frontend's call (src/open-uri.c): ChooseApplication on the backend's name, no timeout.
    std::shared_ptr<Reply> call(const QString &handle, const QStringList &choices, const QVariantMap &options)
    {
        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.AppChooser"), QStringLiteral("ChooseApplication"));
        m << QVariant::fromValue(QDBusObjectPath(handle)) << QStringLiteral("org.example.Writer") << QString() << choices << options;
        auto reply = std::make_shared<Reply>();
        auto *w = new QDBusPendingCallWatcher(frontendBus->asyncCall(m, std::numeric_limits<int>::max()));
        QObject::connect(w, &QDBusPendingCallWatcher::finished, w, [reply](QDBusPendingCallWatcher *watcher) {
            watcher->deleteLater();
            const QDBusMessage r = watcher->reply();
            reply->done = true;
            reply->error = r.type() != QDBusMessage::ReplyMessage;
            if (!reply->error && r.arguments().size() == 2) {
                reply->response = r.arguments().at(0).toUInt();
                reply->results = qdbus_cast<QVariantMap>(r.arguments().at(1));
            }
        });
        return reply;
    }

    void updateChoices(const QString &handle, const QStringList &choices)
    {
        QDBusMessage m = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.AppChooser"), QStringLiteral("UpdateChoices"));
        m << QVariant::fromValue(QDBusObjectPath(handle)) << choices;
        frontendBus->asyncCall(m);
    }

    bool waitFor(const std::function<bool()> &condition, int ms = 3000)
    {
        QDeadlineTimer deadline(ms);
        while (!condition() && !deadline.hasExpired())
            QTest::qWait(10);
        return condition();
    }

    std::unique_ptr<QDBusConnection> backendBus, frontendBus, gtkBus;
    std::unique_ptr<AppChooser> chooser;
    std::unique_ptr<QObject> exported;
    FakeGtkAppChooser gtk;
    QList<QPair<int, QVariantMap>> opened;
    QList<int> closed;
    QList<QPair<int, QStringList>> changed;
};

} // namespace

// What the panel is given: desktop ids only (A-OW1: never a path, a ".desktop" name, a hidden name or a control character;
// spaces, '+' and any letter are a name's), each once and at most kMaxApplications from a bounded look; the last choice, the
// document's name and the URI checked; the Open panel's own keys present and empty (FilePanel reads them).
TEST(AppChooserToQml, ChecksWhatTheFrontendGives)
{
    const QVariantMap request = AppChooser::toQml(
        QStringLiteral("org.example.Writer"), QStringLiteral("wayland:abc"),
        {QStringLiteral("org.gnome.TextEditor"), QStringLiteral("../../bin/sh"), QStringLiteral("kate.desktop"), QString(),
         QStringLiteral("org.gnome.TextEditor"), QStringLiteral("kde4-kwrite"), QStringLiteral(".hidden"), QStringLiteral("bad\nname"),
         QStringLiteral("wine-Programs-Notepad++"), QStringLiteral("Some Game")},
        {{QStringLiteral("last_choice"), QStringLiteral("org.kde.kate")},
         {QStringLiteral("filename"), QStringLiteral("notes.txt")},
         {QStringLiteral("uri"), QStringLiteral("file:///home/u/notes.txt")},
         {QStringLiteral("modal"), false}});
    EXPECT_EQ(request.value("kind").toString(), QStringLiteral("application"));
    EXPECT_EQ(request.value("applications").toStringList(),
              (QStringList{QStringLiteral("org.gnome.TextEditor"), QStringLiteral("kde4-kwrite"), QStringLiteral("wine-Programs-Notepad++"),
                           QStringLiteral("Some Game")}));
    EXPECT_EQ(request.value("lastChoice").toString(), QStringLiteral("org.kde.kate"));
    EXPECT_EQ(request.value("filename").toString(), QStringLiteral("notes.txt"));
    EXPECT_EQ(request.value("uri").toString(), QStringLiteral("file:///home/u/notes.txt"));
    EXPECT_FALSE(request.value("modal").toBool());
    EXPECT_TRUE(request.value("parented").toBool());
    EXPECT_FALSE(request.value("multiple").toBool());
    EXPECT_TRUE(request.value("filters").toList().isEmpty());
    EXPECT_TRUE(request.value("choices").toList().isEmpty()) << "the Open panel's check boxes: none";
    EXPECT_EQ(request.value("title").toString(), QString()) << "the panel's own title";

    const QVariantMap wrong = AppChooser::toQml({}, QStringLiteral("x11:1"), {},
                                                {{QStringLiteral("last_choice"), QStringLiteral("../x")},
                                                 {QStringLiteral("filename"), QStringLiteral("../etc/passwd")},
                                                 {QStringLiteral("uri"), QStringLiteral("magnet:?a\nb")},
                                                 {QStringLiteral("modal"), QStringLiteral("no")}});
    EXPECT_EQ(wrong.value("lastChoice").toString(), QString());
    EXPECT_EQ(wrong.value("filename").toString(), QString()) << "a name, never a path";
    EXPECT_EQ(wrong.value("uri").toString(), QStringLiteral("magnet:?a b")) << "one line";
    EXPECT_TRUE(wrong.value("modal").toBool()) << "modal unless the frontend says otherwise with a boolean";
    EXPECT_FALSE(wrong.value("parented").toBool());
    for (const char *name : {".", ".."})
        EXPECT_EQ(AppChooser::toQml({}, {}, {}, {{QStringLiteral("filename"), QString::fromLatin1(name)}}).value("filename").toString(), QString()) << name;
    EXPECT_FALSE(AppChooser::toQml({}, QStringLiteral("wayland:"), {}, {}).value("parented").toBool()) << "a handle needs its id";
    EXPECT_FALSE(AppChooser::isDesktopId(QString(250, u'a'))) << "255 bytes with \".desktop\"";

    QStringList many;
    for (int i = 0; i < AppChooser::kMaxApplications + 10; ++i)
        many << QStringLiteral("app%1").arg(i);
    EXPECT_EQ(AppChooser::toQml({}, {}, many, {}).value("applications").toStringList().size(), AppChooser::kMaxApplications);
    // A bounded look: an id after 4 * kMaxApplications entries is never read, whatever came before it.
    QStringList junk(4 * AppChooser::kMaxApplications, QStringLiteral("a/b"));
    junk << QStringLiteral("org.example.Late");
    EXPECT_TRUE(AppChooser::toQml({}, {}, junk, {}).value("applications").toStringList().isEmpty());
}

// The panel's choice reaches the frontend with the activation token the call came with.
TEST_F(AppChooserTest, TheChoiceGoesBack)
{
    chooser->setUiLoader([] { return true; });
    auto reply = call(QStringLiteral("/r/a1"), {QStringLiteral("org.gnome.TextEditor"), QStringLiteral("org.kde.kate")},
                      {{QStringLiteral("activation_token"), QStringLiteral("token-1")}});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }));
    EXPECT_EQ(opened.first().second.value("applications").toStringList(),
              (QStringList{QStringLiteral("org.gnome.TextEditor"), QStringLiteral("org.kde.kate")}));
    chooser->answer(opened.first().first, 0, {{QStringLiteral("choice"), QStringLiteral("org.kde.kate")}});
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_FALSE(reply->error);
    EXPECT_EQ(reply->response, 0u);
    EXPECT_EQ(reply->results.value("choice").toString(), QStringLiteral("org.kde.kate"));
    EXPECT_EQ(reply->results.value("activation_token").toString(), QStringLiteral("token-1"));
    EXPECT_EQ(chooser->pending(), 0);
}

// "All Applications": an application the frontend did not recommend is a choice too (the frontend starts any it is given).
TEST_F(AppChooserTest, AnyApplicationCanBeChosen)
{
    chooser->setUiLoader([] { return true; });
    auto reply = call(QStringLiteral("/r/a2"), {QStringLiteral("org.gnome.TextEditor")},
                      {{QStringLiteral("activation_token"), QString(1025, u't')}});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }));
    chooser->answer(opened.first().first, 0, {{QStringLiteral("choice"), QStringLiteral("org.example.Other")}});
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 0u);
    EXPECT_EQ(reply->results.value("choice").toString(), QStringLiteral("org.example.Other"));
    EXPECT_FALSE(reply->results.contains("activation_token")) << "a token over 1024 characters is none";
}

// Cancel is response 1; a choice that is no desktop id ends the request with response 2, never a launch of it.
TEST_F(AppChooserTest, CancelAndAWrongChoice)
{
    chooser->setUiLoader([] { return true; });
    auto cancelled = call(QStringLiteral("/r/a3"), {QStringLiteral("org.gnome.TextEditor")}, {});
    auto wrong = call(QStringLiteral("/r/a4"), {QStringLiteral("org.gnome.TextEditor")}, {});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 2; }));
    // Cancel with a choice in the map (the panel never sends one; any caller of answer could): still Cancel, and no choice.
    chooser->answer(opened.at(0).first, 1, {{QStringLiteral("choice"), QStringLiteral("org.gnome.TextEditor")}});
    chooser->answer(opened.at(1).first, 0, {{QStringLiteral("choice"), QStringLiteral("/usr/bin/evil")}});
    ASSERT_TRUE(waitFor([&] { return cancelled->done && wrong->done; }));
    EXPECT_EQ(cancelled->response, 1u);
    EXPECT_TRUE(cancelled->results.isEmpty()) << "Cancel answers no choice (integrator review of f9a25ce, MINOR)";
    EXPECT_EQ(wrong->response, 2u);
    EXPECT_FALSE(wrong->results.contains("choice"));
}

// UpdateChoices: the open panel gets the frontend's new candidates (checked as ChooseApplication's).
TEST_F(AppChooserTest, UpdateChoicesReachesTheOpenPanel)
{
    chooser->setUiLoader([] { return true; });
    auto reply = call(QStringLiteral("/r/u1"), {QStringLiteral("org.gnome.TextEditor")}, {});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }));
    updateChoices(QStringLiteral("/r/u1"), {QStringLiteral("org.gnome.TextEditor"), QStringLiteral("x/../y"), QStringLiteral("org.kde.kate")});
    updateChoices(QStringLiteral("/r/none"), {QStringLiteral("org.kde.kate")});
    ASSERT_TRUE(waitFor([&] { return changed.size() == 1; }));
    QTest::qWait(100);
    ASSERT_EQ(changed.size(), 1) << "a handle with no request changes nothing";
    EXPECT_EQ(changed.first().first, opened.first().first);
    EXPECT_EQ(changed.first().second, (QStringList{QStringLiteral("org.gnome.TextEditor"), QStringLiteral("org.kde.kate")}));
    chooser->answer(opened.first().first, 1, {});
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
}

// UpdateChoices from another caller than the request's is ignored; an UpdateChoices the open panel had follows the request to
// x-d-p-gtk when the panel does not draw in time (integrator review of f9a25ce, NITs).
TEST_F(AppChooserTest, UpdatesComeFromTheCallerAndFollowAForward)
{
    chooser->setUiLoader([] { return true; });
    auto reply = call(QStringLiteral("/r/f1"), {QStringLiteral("org.gnome.TextEditor")}, {});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }));
    QDBusMessage other = QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/org/freedesktop/portal/desktop"),
                                                        QStringLiteral("org.freedesktop.impl.portal.AppChooser"), QStringLiteral("UpdateChoices"));
    other << QVariant::fromValue(QDBusObjectPath(QStringLiteral("/r/f1"))) << QStringList{QStringLiteral("org.example.Intruder")};
    gtkBus->asyncCall(other);
    updateChoices(QStringLiteral("/r/f1"), {QStringLiteral("org.kde.kate")});
    ASSERT_TRUE(waitFor([&] { return changed.size() == 1; }));
    QTest::qWait(100);
    ASSERT_EQ(changed.size(), 1) << "another caller's update is ignored";
    EXPECT_EQ(changed.first().second, QStringList{QStringLiteral("org.kde.kate")});
    // No frame within the deadline: the call goes to x-d-p-gtk, and the last candidates after it.
    ASSERT_TRUE(waitFor([&] { return gtk.held.type() == QDBusMessage::MethodCallMessage; }, 3 * kDeadlineMs));
    ASSERT_TRUE(waitFor([&] { return gtk.updates.size() == 1; }));
    EXPECT_EQ(gtk.updates.first(), QStringList{QStringLiteral("org.kde.kate")});
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(0u), QVariantMap{{QStringLiteral("choice"), QStringLiteral("a/b")}}}));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_FALSE(reply->results.contains("choice")) << "gtk's choice is a desktop id or none";
}

// Without a UI the call goes to x-d-p-gtk, UpdateChoices after it too, and gtk's answer comes back with only the interface's
// results.
TEST_F(AppChooserTest, WithoutAUiTheCallAndItsUpdatesGoToGtk)
{
    chooser->setUiLoader([] { return false; });
    auto reply = call(QStringLiteral("/r/g1"), {QStringLiteral("org.gnome.TextEditor"), QStringLiteral("org.kde.kate")}, {});
    ASSERT_TRUE(waitFor([&] { return gtk.held.type() == QDBusMessage::MethodCallMessage; }));
    EXPECT_TRUE(opened.isEmpty());
    EXPECT_EQ(gtk.calls, QStringList{QStringLiteral("ChooseApplication /r/g1 org.gnome.TextEditor,org.kde.kate")});
    updateChoices(QStringLiteral("/r/g1"), {QStringLiteral("org.kde.kate")});
    ASSERT_TRUE(waitFor([&] { return gtk.updates.size() == 1; }));
    EXPECT_EQ(gtk.updates.first(), QStringList{QStringLiteral("org.kde.kate")});
    gtkBus->send(gtk.held.createReply(QVariantList{QVariant::fromValue(0u),
                                                   QVariantMap{{QStringLiteral("choice"), QStringLiteral("org.kde.kate")},
                                                               {QStringLiteral("activation_token"), QStringLiteral("gtk-token")},
                                                               {QStringLiteral("uris"), QStringList{QStringLiteral("file:///x")}}}}));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 0u);
    EXPECT_EQ(reply->results.value("choice").toString(), QStringLiteral("org.kde.kate"));
    EXPECT_EQ(reply->results.value("activation_token").toString(), QStringLiteral("gtk-token"));
    EXPECT_FALSE(reply->results.contains("uris")) << "only what the interface defines";
}

// Close (the application went away) ends the request with response 2 and takes the panel away; a late answer is ignored.
TEST_F(AppChooserTest, CloseEndsTheRequest)
{
    chooser->setUiLoader([] { return true; });
    auto reply = call(QStringLiteral("/r/c1"), {QStringLiteral("org.gnome.TextEditor")}, {});
    ASSERT_TRUE(waitFor([&] { return opened.size() == 1; }));
    const int id = opened.first().first;
    frontendBus->asyncCall(QDBusMessage::createMethodCall(QString::fromLatin1(kService), QStringLiteral("/r/c1"),
                                                          QStringLiteral("org.freedesktop.impl.portal.Request"), QStringLiteral("Close")));
    ASSERT_TRUE(waitFor([&] { return reply->done; }));
    EXPECT_EQ(reply->response, 2u);
    EXPECT_TRUE(closed.contains(id));
    chooser->answer(id, 0, {{QStringLiteral("choice"), QStringLiteral("org.gnome.TextEditor")}});
    EXPECT_EQ(chooser->pending(), 0);
}

#include "tst_appchooser.moc"
