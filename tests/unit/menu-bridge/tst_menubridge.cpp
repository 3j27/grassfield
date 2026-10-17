// Unit tests of grassfield-menu-bridge's pure logic (bridges/menu-bridge/src): menu/1 message validation, DBusMenu
// layout reading and mapping, mnemonic handling, start-up guards, the diagnostics XML. The DBusMenu wire format is
// exercised over an in-process peer-to-peer D-Bus connection (no bus daemon, nothing on any session bus).

#include "DBusObjects.h"
#include "Layout.h"
#include "MenuClient.h"
#include "Penalties.h"
#include "Protocol.h"
#include "Safety.h"

#include <QCoreApplication>
#include <QDBusArgument>
#include <QDBusConnection>
#include <QDBusMessage>
#include <QDBusMetaType>
#include <QDBusPendingCallWatcher>
#include <QDBusServer>
#include <QDBusVariant>
#include <QDBusVirtualObject>
#include <QElapsedTimer>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>

#include <gtest/gtest.h>

#include <memory>

#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

using namespace gf::menubridge;

namespace {
    std::optional<ShellMessage> parse(const char* json, QString* error = nullptr) {
        return parseShellMessage(QByteArray(json), error);
    }

    QString errorOf(const char* json) {
        QString error;
        EXPECT_FALSE(parse(json, &error).has_value()) << json;
        return error;
    }

    RawItem item(int id, QVariantMap props, QList<RawItem> children = {}) {
        return RawItem{.id = id, .properties = std::move(props), .children = std::move(children)};
    }

    QJsonArray mapped(const RawItem& root) {
        LayoutBudget budget;
        return mapChildren(root, budget);
    }

    QVariant shortcut(const QList<QStringList>& keys) {
        QVariantList out;
        for (const auto& k : keys)
            out.append(QVariant(k));
        return out;
    }
} // namespace

// ---- menu/1: shell -> bridge ---------------------------------------------------------------------------------------

TEST(ShellMessages, ValidMessagesParse) {
    auto hello = parse(R"({"type":"hello","v":"menu/1","appmenu":true})");
    ASSERT_TRUE(hello.has_value());
    EXPECT_EQ(hello->type, ShellMessage::Type::Hello);
    EXPECT_TRUE(hello->appmenu);

    auto open = parse(R"({"type":"open","window":"55D3C2A0B1F0","service":":1.42","path":"/MenuBar/1","pid":4242,"extra":"ignored"})");
    ASSERT_TRUE(open.has_value());
    EXPECT_EQ(open->type, ShellMessage::Type::Open);
    EXPECT_EQ(open->window, QStringLiteral("55d3c2a0b1f0")); // normalized to lowercase
    EXPECT_EQ(open->service, QStringLiteral(":1.42"));
    EXPECT_EQ(open->path, QStringLiteral("/MenuBar/1"));
    EXPECT_EQ(open->pid, 4242);

    auto show = parse(R"({"type":"about-to-show","window":"1a","id":0})");
    ASSERT_TRUE(show.has_value());
    EXPECT_EQ(show->type, ShellMessage::Type::AboutToShow);
    EXPECT_EQ(show->id, 0);

    auto activate = parse(R"({"type":"activate","window":"1a","id":2147483647})");
    ASSERT_TRUE(activate.has_value());
    EXPECT_EQ(activate->id, 2147483647);

    auto close = parse(R"({"type":"close","window":"ffffffffffffffff"})");
    ASSERT_TRUE(close.has_value());
    EXPECT_EQ(close->type, ShellMessage::Type::Close);
}

TEST(ShellMessages, MalformedInputIsRefused) {
    EXPECT_EQ(errorOf("not json"), QStringLiteral("parse"));
    EXPECT_EQ(errorOf("[1,2]"), QStringLiteral("parse"));
    EXPECT_EQ(errorOf(""), QStringLiteral("parse"));
    EXPECT_EQ(errorOf(R"({"type":"run","window":"1a"})"), QStringLiteral("type"));
    EXPECT_EQ(errorOf(R"({"window":"1a"})"), QStringLiteral("type"));
    EXPECT_EQ(errorOf(R"({"type":"hello","v":"menu/2","appmenu":true})"), QStringLiteral("version"));
    EXPECT_EQ(errorOf(R"({"type":"hello","v":"menu/1","appmenu":"yes"})"), QStringLiteral("field:appmenu"));
    EXPECT_EQ(errorOf(R"({"type":"hello","v":"menu/1"})"), QStringLiteral("field:appmenu"));
}

TEST(ShellMessages, WindowMustBeShortHex) {
    for (const char* json : {R"({"type":"close","window":"0x1a"})", R"({"type":"close","window":""})", R"({"type":"close","window":"12345678901234567"})",
                             R"({"type":"close","window":"1g"})", R"({"type":"close","window":17})", R"({"type":"close"})", R"({"type":"close","window":"1a\n"})"})
        EXPECT_EQ(errorOf(json), QStringLiteral("field:window")) << json;
}

TEST(ShellMessages, OpenFieldsAreValidated) {
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":"org","path":"/m","pid":1})"), QStringLiteral("field:service"));
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":"org.foo bar","path":"/m","pid":1})"), QStringLiteral("field:service"));
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":5,"path":"/m","pid":1})"), QStringLiteral("field:service"));
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":":1.2","path":"m","pid":1})"), QStringLiteral("field:path"));
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":":1.2","path":"/m/","pid":1})"), QStringLiteral("field:path"));
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":":1.2","path":"/a/../b","pid":1})"), QStringLiteral("field:path"));
    for (const char* pid : {"0", "-5", "1.5", "\"42\"", "null", "2147483648", "1e300"}) {
        const QByteArray json = QByteArray(R"({"type":"open","window":"1a","service":":1.2","path":"/m","pid":)") + pid + "}";
        QString          error;
        EXPECT_FALSE(parseShellMessage(json, &error).has_value()) << pid;
        EXPECT_EQ(error, QStringLiteral("field:pid")) << pid;
    }
    EXPECT_EQ(errorOf(R"({"type":"open","window":"1a","service":":1.2","path":"/m"})"), QStringLiteral("field:pid"));
}

TEST(ShellMessages, ItemIdsAreNonNegativeInt32) {
    for (const char* id : {"-1", "0.5", "\"3\"", "2147483648", "true"}) {
        const QByteArray json = QByteArray(R"({"type":"activate","window":"1a","id":)") + id + "}";
        QString          error;
        EXPECT_FALSE(parseShellMessage(json, &error).has_value()) << id;
        EXPECT_EQ(error, QStringLiteral("field:id")) << id;
    }
    EXPECT_EQ(errorOf(R"({"type":"about-to-show","window":"1a"})"), QStringLiteral("field:id"));
}

TEST(ShellMessages, LineLengthIsCapped) {
    QByteArray json = R"({"type":"close","window":"1a","pad":")";
    json += QByteArray(limits::kShellLine, 'x');
    json += "\"}";
    QString error;
    EXPECT_FALSE(parseShellMessage(json, &error).has_value());
    EXPECT_EQ(error, QStringLiteral("too-long"));
}

// ---- menu/1: bridge -> shell ---------------------------------------------------------------------------------------

TEST(BridgeMessages, ExactWireFormat) {
    EXPECT_EQ(statusMessage(QStringLiteral("active"), true), QByteArray(R"({"registrar":true,"state":"active","type":"status","v":"menu/1"})" "\n"));
    EXPECT_EQ(errorMessage(QStringLiteral("1a"), QStringLiteral("pid-mismatch"), QStringLiteral("no")),
              QByteArray(R"({"code":"pid-mismatch","message":"no","type":"error","window":"1a"})" "\n"));
    EXPECT_EQ(menuMessage(QStringLiteral("1a"), 3, QJsonArray{}), QByteArray(R"({"items":[],"revision":3,"type":"menu","window":"1a"})" "\n"));
}

TEST(BridgeMessages, ApplicationTextCannotBreakTheLine) {
    // Labels come from applications: JSON escaping keeps them inside their string, newlines included.
    const QJsonArray items{QJsonObject{{QStringLiteral("label"), QStringLiteral("a\"}\n{\"type\":\"evil")}}};
    const QByteArray line = menuMessage(QStringLiteral("1a"), 1, items);
    EXPECT_EQ(line.count('\n'), 1);
    EXPECT_TRUE(line.endsWith('\n'));
    EXPECT_TRUE(QJsonDocument::fromJson(line).isObject());
}

// ---- names -----------------------------------------------------------------------------------------------------

TEST(Names, BusNamesAndPathsFollowTheDBusRules) {
    for (const char* name : {":1.42", "org.kde.Foo", "a.b", "org._x.y-z"})
        EXPECT_TRUE(isValidBusName(QString::fromLatin1(name))) << name;
    for (const char* name : {"", ":", ":1", "org", ".org.foo", "org..foo", "org.1foo", "org.foo/bar", "org.f\xc3\xa9"})
        EXPECT_FALSE(isValidBusName(QString::fromUtf8(name))) << name;
    EXPECT_FALSE(isValidBusName(QStringLiteral("a.") + QString(254, u'b')));
    for (const char* path : {"/", "/MenuBar/1", "/com/canonical/menu/1A2B"})
        EXPECT_TRUE(isValidObjectPath(QString::fromLatin1(path))) << path;
    for (const char* path : {"", "MenuBar", "//", "/a/", "/a-b", "/a//b", "/a b"})
        EXPECT_FALSE(isValidObjectPath(QString::fromLatin1(path))) << path;
}

// ---- labels ----------------------------------------------------------------------------------------------------

TEST(Labels, MnemonicMarkersAreRemoved) {
    EXPECT_EQ(plainLabel(QStringLiteral("_File")), QStringLiteral("File"));
    EXPECT_EQ(plainLabel(QStringLiteral("Save _As…")), QStringLiteral("Save As…"));
    EXPECT_EQ(plainLabel(QStringLiteral("Open __recent")), QStringLiteral("Open _recent"));
    EXPECT_EQ(plainLabel(QStringLiteral("a___b")), QStringLiteral("a_b"));
    EXPECT_EQ(plainLabel(QStringLiteral("trailing_")), QStringLiteral("trailing"));
    EXPECT_EQ(plainLabel(QStringLiteral("Bookmarks & Lists")), QStringLiteral("Bookmarks & Lists"));
    EXPECT_EQ(plainLabel(QString()), QString());
}

TEST(Labels, ControlAndBidiCharactersAreRemoved) {
    EXPECT_EQ(plainLabel(QStringLiteral("New\nWindow\t\r ")), QStringLiteral("New Window"));
    EXPECT_EQ(plainLabel(QStringLiteral("  lead")), QStringLiteral("lead"));
    EXPECT_EQ(plainLabel(QString::fromUtf8("a\x01" "b\x7f" "c")), QStringLiteral("abc"));
    // Bidirectional overrides and isolates (built from code points: no such characters in this source file).
    EXPECT_EQ(plainLabel(QStringLiteral("pay") + QChar(0x202E) + QStringLiteral("gnp.exe")), QStringLiteral("paygnp.exe"));
    EXPECT_EQ(plainLabel(QChar(0x2066) + QStringLiteral("x") + QChar(0x2069)), QStringLiteral("x"));
    EXPECT_EQ(plainLabel(QStringLiteral("<b>bold</b>")), QStringLiteral("<b>bold</b>")); // plain text: the shell renders it literally
}

TEST(Labels, LengthIsCappedWithoutSplittingSurrogates) {
    EXPECT_EQ(plainLabel(QString(1000, u'x')).size(), limits::kLabel);
    QString emoji = QString(limits::kLabel - 1, u'x') + QString::fromUtf16(u"\U0001F600");
    const QString out = plainLabel(emoji);
    EXPECT_LE(out.size(), limits::kLabel);
    EXPECT_FALSE(out.back().isHighSurrogate());
}

// ---- layout mapping --------------------------------------------------------------------------------------------

TEST(Layout, MapsAQtStyleMenu) {
    const RawItem root = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}},
                              {item(1, {{QStringLiteral("label"), QStringLiteral("_File")}, {QStringLiteral("children-display"), QStringLiteral("submenu")}},
                                    {
                                        item(2, {{QStringLiteral("label"), QStringLiteral("_New")}, {QStringLiteral("shortcut"), shortcut({{QStringLiteral("Control"), QStringLiteral("N")}})}}),
                                        item(3, {{QStringLiteral("type"), QStringLiteral("separator")}, {QStringLiteral("label"), QStringLiteral("ignored")}}),
                                        item(4, {{QStringLiteral("label"), QStringLiteral("_Redo")}, {QStringLiteral("enabled"), false}}),
                                        item(5, {{QStringLiteral("label"), QStringLiteral("Hidden")}, {QStringLiteral("visible"), false}}),
                                        item(6, {{QStringLiteral("label"), QStringLiteral("_Word Wrap")}, {QStringLiteral("toggle-type"), QStringLiteral("checkmark")}, {QStringLiteral("toggle-state"), 1}}),
                                        item(7, {{QStringLiteral("label"), QStringLiteral("_Theme")}, {QStringLiteral("children-display"), QStringLiteral("submenu")}},
                                             {item(8, {{QStringLiteral("label"), QStringLiteral("Dark")}, {QStringLiteral("toggle-type"), QStringLiteral("radio")}, {QStringLiteral("toggle-state"), 0}})}),
                                    })});
    const QJsonArray items = mapped(root);
    ASSERT_EQ(items.size(), 1);
    const QJsonObject file = items.at(0).toObject();
    EXPECT_EQ(file.value(QStringLiteral("label")).toString(), QStringLiteral("File"));
    EXPECT_TRUE(file.value(QStringLiteral("submenu")).toBool());
    const QJsonArray children = file.value(QStringLiteral("children")).toArray();
    ASSERT_EQ(children.size(), 6);

    const QJsonObject newItem = children.at(0).toObject();
    EXPECT_EQ(QJsonDocument(newItem).toJson(QJsonDocument::Compact),
              QByteArray(R"({"children":[],"enabled":true,"icon-name":"","id":2,"label":"New","shortcut":[["Control","N"]],"submenu":false,"toggle-state":-1,"toggle-type":"","type":"standard","visible":true})"));
    const QJsonObject sep = children.at(1).toObject();
    EXPECT_EQ(sep.value(QStringLiteral("type")).toString(), QStringLiteral("separator"));
    EXPECT_EQ(sep.value(QStringLiteral("label")).toString(), QString());
    EXPECT_FALSE(children.at(2).toObject().value(QStringLiteral("enabled")).toBool());
    EXPECT_FALSE(children.at(3).toObject().value(QStringLiteral("visible")).toBool());
    const QJsonObject wrap = children.at(4).toObject();
    EXPECT_EQ(wrap.value(QStringLiteral("toggle-type")).toString(), QStringLiteral("checkmark"));
    EXPECT_EQ(wrap.value(QStringLiteral("toggle-state")).toInt(), 1);
    const QJsonObject dark = children.at(5).toObject().value(QStringLiteral("children")).toArray().at(0).toObject();
    EXPECT_EQ(dark.value(QStringLiteral("toggle-type")).toString(), QStringLiteral("radio"));
    EXPECT_EQ(dark.value(QStringLiteral("toggle-state")).toInt(), 0);

    const ItemIndex index = indexItems(items);
    EXPECT_EQ(index.activatable, (QSet<int>{2, 6, 8}));  // not the separator, disabled, hidden or submenu items
    EXPECT_EQ(index.submenus, (QSet<int>{0, 1, 7}));
}

TEST(Layout, WrongTypesFallBackToDefaults) {
    const RawItem root = item(0, {}, {item(1, {{QStringLiteral("label"), 42}, {QStringLiteral("enabled"), QStringLiteral("no")}, {QStringLiteral("visible"), 0},
                                               {QStringLiteral("toggle-type"), QStringLiteral("switch")}, {QStringLiteral("toggle-state"), 1},
                                               {QStringLiteral("icon-name"), QStringLiteral("../../etc/passwd")}, {QStringLiteral("shortcut"), QStringLiteral("Ctrl+N")}}),
                                      item(-3, {{QStringLiteral("label"), QStringLiteral("negative id")}})});
    const QJsonArray items = mapped(root);
    ASSERT_EQ(items.size(), 1); // the negative id is skipped
    const QJsonObject o = items.at(0).toObject();
    EXPECT_EQ(o.value(QStringLiteral("label")).toString(), QString());
    EXPECT_TRUE(o.value(QStringLiteral("enabled")).toBool());
    EXPECT_TRUE(o.value(QStringLiteral("visible")).toBool());
    EXPECT_EQ(o.value(QStringLiteral("toggle-type")).toString(), QString());
    EXPECT_EQ(o.value(QStringLiteral("toggle-state")).toInt(), -1);
    EXPECT_EQ(o.value(QStringLiteral("icon-name")).toString(), QString());
    EXPECT_TRUE(o.value(QStringLiteral("shortcut")).toArray().isEmpty());
}

TEST(Layout, ShortcutsAreSanitized) {
    const QList<QStringList> many = {{QStringLiteral("Control"), QStringLiteral("A")}, {QStringLiteral("Control"), QStringLiteral("B")}, {QStringLiteral("Control"), QStringLiteral("C")},
                                     {QStringLiteral("Control"), QStringLiteral("D")}, {QStringLiteral("Control"), QStringLiteral("E")}};
    const RawItem root = item(0, {}, {item(1, {{QStringLiteral("shortcut"), shortcut(many)}}),
                                      item(2, {{QStringLiteral("shortcut"), shortcut({{QStringLiteral("Control"), QStringLiteral("bad key")}, {QStringLiteral("Shift"), QStringLiteral("plus")}})}}),
                                      item(3, {{QStringLiteral("shortcut"), shortcut({QStringList(7, QStringLiteral("Alt"))})}})});
    const QJsonArray items = mapped(root);
    EXPECT_EQ(items.at(0).toObject().value(QStringLiteral("shortcut")).toArray().size(), limits::kShortcuts);
    EXPECT_EQ(QJsonDocument(items.at(1).toObject().value(QStringLiteral("shortcut")).toArray()).toJson(QJsonDocument::Compact), QByteArray(R"([["Shift","plus"]])"));
    EXPECT_TRUE(items.at(2).toObject().value(QStringLiteral("shortcut")).toArray().isEmpty());
}

TEST(Layout, DepthIsCapped) {
    RawItem leaf = item(100, {{QStringLiteral("label"), QStringLiteral("deep")}});
    for (int i = 20; i >= 1; --i)
        leaf = item(i, {{QStringLiteral("children-display"), QStringLiteral("submenu")}}, {leaf});
    LayoutBudget     budget;
    const QJsonArray items = mapChildren(item(0, {}, {leaf}), budget);
    EXPECT_TRUE(budget.truncated);
    int        depth = 0;
    QJsonArray level = items;
    while (!level.isEmpty()) {
        ++depth;
        level = level.at(0).toObject().value(QStringLiteral("children")).toArray();
    }
    EXPECT_EQ(depth, limits::kDepth);
}

TEST(Layout, ItemCountIsCapped) {
    QList<RawItem> many;
    for (int i = 1; i <= limits::kItems + 500; ++i)
        many.append(item(i, {{QStringLiteral("label"), QStringLiteral("x")}}));
    LayoutBudget     budget;
    const QJsonArray items = mapChildren(item(0, {}, many), budget);
    EXPECT_EQ(items.size(), limits::kItems);
    EXPECT_TRUE(budget.truncated);
}

// ---- DBusMenu over a real (peer-to-peer) D-Bus connection ------------------------------------------------------

namespace {
    QDBusArgument marshal(const RawItem& node) {
        QDBusArgument arg;
        arg.beginStructure();
        arg << node.id << node.properties;
        arg.beginArray(qMetaTypeId<QDBusVariant>());
        for (const RawItem& child : node.children)
            arg << QDBusVariant(QVariant::fromValue(marshal(child)));
        arg.endArray();
        arg.endStructure();
        return arg;
    }

    // A minimal com.canonical.dbusmenu that records the signatures of the calls it gets.
    class FakeMenu : public QDBusVirtualObject {
      public:
        QStringList calls;
        RawItem     layout;

        QString     introspect(const QString&) const override {
            return {};
        }

        bool handleMessage(const QDBusMessage& msg, const QDBusConnection& conn) override {
            calls << msg.member() + u':' + msg.signature();
            if (msg.member() == QLatin1String("GetLayout"))
                conn.send(msg.createReply(QVariantList{QVariant::fromValue<uint>(7), QVariant::fromValue(marshal(layout))}));
            else if (msg.member() == QLatin1String("AboutToShow"))
                conn.send(msg.createReply(QVariant(false)));
            else
                conn.send(msg.createReply());
            return true;
        }
    };

    QDBusMessage callAndWait(QDBusConnection& conn, const QDBusMessage& msg) {
        QDBusPendingCallWatcher watcher(conn.asyncCall(msg, 3000));
        QElapsedTimer           timer;
        timer.start();
        while (!watcher.isFinished() && timer.elapsed() < 5000)
            QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        return watcher.reply();
    }
} // namespace

TEST(DBusMenuWire, ExplicitSignaturesAndLayoutRoundTrip) {
    qDBusRegisterMetaType<QList<QStringList>>();
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    QDBusServer server(QStringLiteral("unix:dir=") + dir.path());
    if (!server.isConnected()) // e.g. a sandbox that forbids creating Unix sockets
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here: " << qPrintable(server.lastError().message());
    server.setAnonymousAuthenticationAllowed(true);

    FakeMenu menu;
    menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}},
                       {item(1, {{QStringLiteral("label"), QStringLiteral("_File")}, {QStringLiteral("children-display"), QStringLiteral("submenu")}},
                             {item(2, {{QStringLiteral("label"), QStringLiteral("_New")},
                                       {QStringLiteral("shortcut"), QVariant::fromValue(QList<QStringList>{{QStringLiteral("Control"), QStringLiteral("N")}})},
                                       {QStringLiteral("icon-data"), QByteArray("ignored")}})})});
    bool registered = false;
    QObject::connect(&server, &QDBusServer::newConnection, [&](const QDBusConnection& peer) {
        QDBusConnection c(peer);
        registered = c.registerVirtualObject(QStringLiteral("/MenuBar/1"), &menu, QDBusConnection::SingleNode);
    });
    QDBusConnection client = QDBusConnection::connectToPeer(server.address(), QStringLiteral("menu-bridge-test"));
    ASSERT_TRUE(client.isConnected()) << qPrintable(client.lastError().message());
    QElapsedTimer timer;
    timer.start();
    while (!registered && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
    ASSERT_TRUE(registered);

    const QDBusMessage reply = callAndWait(client, getLayoutCall(QString(), QStringLiteral("/MenuBar/1")));
    ASSERT_EQ(reply.type(), QDBusMessage::ReplyMessage) << qPrintable(reply.errorMessage());
    EXPECT_EQ(reply.signature(), QStringLiteral("u(ia{sv}av)"));
    RawItem      root;
    LayoutBudget budget;
    ASSERT_TRUE(readLayout(qvariant_cast<QDBusArgument>(reply.arguments().at(1)), root, 0, budget));
    EXPECT_FALSE(root.properties.contains(QStringLiteral("icon-data")) || root.children.value(0).children.value(0).properties.contains(QStringLiteral("icon-data")));
    const QJsonArray items = mapped(root);
    ASSERT_EQ(items.size(), 1);
    const QJsonObject newItem = items.at(0).toObject().value(QStringLiteral("children")).toArray().at(0).toObject();
    EXPECT_EQ(newItem.value(QStringLiteral("label")).toString(), QStringLiteral("New"));
    EXPECT_EQ(QJsonDocument(newItem.value(QStringLiteral("shortcut")).toArray()).toJson(QJsonDocument::Compact), QByteArray(R"([["Control","N"]])"));

    EXPECT_EQ(callAndWait(client, aboutToShowCall(QString(), QStringLiteral("/MenuBar/1"), 1)).type(), QDBusMessage::ReplyMessage);
    EXPECT_EQ(callAndWait(client, eventCall(QString(), QStringLiteral("/MenuBar/1"), 2)).type(), QDBusMessage::ReplyMessage);
    // Chromium accepts only these exact types (it has no introspection data to coerce untyped arguments).
    EXPECT_EQ(menu.calls, (QStringList{QStringLiteral("GetLayout:iias"), QStringLiteral("AboutToShow:i"), QStringLiteral("Event:isvu")}));
    QDBusConnection::disconnectFromPeer(QStringLiteral("menu-bridge-test"));
}

namespace {
    // A private peer-to-peer connection serving `menu` at /MenuBar/1 (no bus daemon).
    struct PeerMenu {
        QTemporaryDir dir;
        QDBusServer*  server = nullptr;
        FakeMenu      menu;
        bool          registered = false;
        QDBusConnection client{QStringLiteral("unconnected")};
        QString       name;

        explicit PeerMenu(const QString& connectionName) : name(connectionName) {
            server = new QDBusServer(QStringLiteral("unix:dir=") + dir.path());
            if (!server->isConnected())
                return;
            server->setAnonymousAuthenticationAllowed(true);
            QObject::connect(server, &QDBusServer::newConnection, [this](const QDBusConnection& peer) {
                QDBusConnection c(peer);
                registered = c.registerVirtualObject(QStringLiteral("/MenuBar/1"), &menu, QDBusConnection::SingleNode);
            });
            client = QDBusConnection::connectToPeer(server->address(), name);
            QElapsedTimer timer;
            timer.start();
            while (!registered && timer.elapsed() < 5000)
                QCoreApplication::processEvents(QEventLoop::AllEvents, 50);
        }
        ~PeerMenu() {
            QDBusConnection::disconnectFromPeer(name);
            delete server;
        }
        bool ok() const {
            return server && server->isConnected() && registered;
        }
        int getLayoutCalls() const {
            return static_cast<int>(menu.calls.filter(QStringLiteral("GetLayout:")).size());
        }
    };

    void pump(int ms) {
        QElapsedTimer timer;
        timer.start();
        while (timer.elapsed() < ms)
            QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    }
} // namespace

// A burst of LayoutUpdated signals less than the 40 ms coalescing delay apart must not starve the refetch (the timer
// used to restart on every signal: 1 ms spam gave one GetLayout in 10 s).
TEST(MenuClientRefetch, BurstOfSignalsStillRefetchesEveryCoalescingInterval) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-burst"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    peer.menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}}, {item(1, {{QStringLiteral("label"), QStringLiteral("File")}})});
    MenuClient client(peer.client, QStringLiteral("1"), QString(), QStringLiteral("/MenuBar/1"));
    client.start();
    QElapsedTimer timer;
    timer.start();
    while (!client.ready() && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    ASSERT_TRUE(client.ready());
    ASSERT_EQ(peer.getLayoutCalls(), 1);

    // 1 ms spam for 600 ms: with the restarting timer this would stay at 1; with a pending timer it is about 600/40.
    QTimer spam;
    spam.setInterval(1);
    QObject::connect(&spam, &QTimer::timeout, [&] { QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage())); });
    spam.start();
    pump(600);
    spam.stop();
    pump(150);
    const int calls = peer.getLayoutCalls() - 1;
    EXPECT_GE(calls, 6) << "refetch starved by the signal burst";
    EXPECT_LE(calls, 18) << "refetch not coalesced";
}

// More items than any real menu has: refused, no menu, and not a single GetLayout more however many signals follow.
TEST(MenuClientRefetch, OversizedLayoutIsRefusedAndNeverReread) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-huge"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    QList<RawItem> many;
    for (int i = 1; i <= limits::kItems + 500; ++i)
        many.append(item(i, {{QStringLiteral("label"), QStringLiteral("x")}}));
    peer.menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}}, many);
    MenuClient client(peer.client, QStringLiteral("2"), QString(), QStringLiteral("/MenuBar/1"));
    QString    code;
    int        menus = 0;
    QObject::connect(&client, &MenuClient::failed, [&](const QString&, const QString& c, const QString&) { code = c; });
    QObject::connect(&client, &MenuClient::menuChanged, [&](const QString&) { ++menus; });
    client.start();
    QElapsedTimer timer;
    timer.start();
    while (code.isEmpty() && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    EXPECT_EQ(code, QStringLiteral("oversized"));
    EXPECT_EQ(menus, 0);
    for (int i = 0; i < 20; ++i)
        QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage()));
    pump(200);
    EXPECT_EQ(peer.getLayoutCalls(), 1);
}

TEST(DBusMenuWire, NonLayoutArgumentsAreRefused) {
    QDBusArgument notAStruct;
    notAStruct << QStringLiteral("x");
    RawItem      root;
    LayoutBudget budget;
    EXPECT_FALSE(readLayout(notAStruct, root, 0, budget));
}

// Every outbound call is announced (callBegun) before it is sent and ended (callEnded) when its reply was handled:
// the crash attribution of the bridge relies on it (GetLayout, the re-read after LayoutUpdated, AboutToShow, Event).
TEST(MenuClientCalls, EveryOutboundCallIsAnnouncedAndEnded) {
    PeerMenu peer(QStringLiteral("menu-bridge-test-calls"));
    if (!peer.ok())
        GTEST_SKIP() << "cannot create a private D-Bus peer socket here";
    peer.menu.layout = item(0, {{QStringLiteral("children-display"), QStringLiteral("submenu")}},
                            {item(1, {{QStringLiteral("label"), QStringLiteral("File")}, {QStringLiteral("children-display"), QStringLiteral("submenu")}}, {item(2, {{QStringLiteral("label"), QStringLiteral("New")}})})});
    MenuClient client(peer.client, QStringLiteral("3"), QString(), QStringLiteral("/MenuBar/1"));
    int        begun = 0;
    int        ended = 0;
    int        seenAtSend = -1;
    QObject::connect(&client, &MenuClient::callBegun, [&] {
        ++begun;
        seenAtSend = static_cast<int>(peer.menu.calls.size()); // nothing of this call has reached the application yet
    });
    QObject::connect(&client, &MenuClient::callEnded, [&] { ++ended; });
    client.start();
    EXPECT_EQ(begun, 1);
    EXPECT_EQ(seenAtSend, 0);
    QElapsedTimer timer;
    timer.start();
    while (ended < 1 && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    EXPECT_EQ(ended, 1);
    EXPECT_EQ(client.outstanding(), 0);

    // The re-read after a LayoutUpdated signal is announced as well (it used to be unmarked).
    QMetaObject::invokeMethod(&client, "onMenuSignal", Q_ARG(QDBusMessage, QDBusMessage()));
    timer.restart();
    while (ended < 2 && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    EXPECT_EQ(begun, 2);
    EXPECT_EQ(ended, 2);

    ASSERT_TRUE(client.aboutToShow(1));
    EXPECT_EQ(begun, 3);
    EXPECT_EQ(client.outstanding(), 1);
    ASSERT_TRUE(client.activate(2));
    EXPECT_EQ(begun, 4);
    EXPECT_EQ(client.outstanding(), 2);
    timer.restart();
    while (client.outstanding() > 0 && timer.elapsed() < 5000)
        QCoreApplication::processEvents(QEventLoop::AllEvents, 5);
    EXPECT_EQ(ended, 4);
}

// ---- penalties and the state file --------------------------------------------------------------------------------

namespace {
    struct Clock {
        qint64 now = 1000;
    };
    PenaltyBook book(Clock& c) {
        return PenaltyBook([&c] { return c.now; });
    }
    const QString kApp  = QStringLiteral("exe:/usr/bin/evil");
    const QString kOther = QStringLiteral("exe:/usr/bin/calc");
} // namespace

TEST(Penalties, IdentityOfThisProcessSurvivesANewPid) {
    const QString me = appIdentity(::getpid());
    EXPECT_TRUE(me.startsWith(QStringLiteral("exe:/"))) << qPrintable(me);
    EXPECT_TRUE(validIdentity(me));
    // Another pid of the same executable (here: our own parent chain is not guaranteed, so fork).
    const pid_t child = ::fork();
    if (child == 0)
        ::_exit(appIdentity(::getpid()) == appIdentity(::getppid()) ? 0 : 1);
    ASSERT_GT(child, 0);
    int status = 0;
    ASSERT_EQ(::waitpid(child, &status, 0), child);
    EXPECT_TRUE(WIFEXITED(status) && WEXITSTATUS(status) == 0) << "a forked child must have the parent's identity";
    EXPECT_EQ(appIdentity(2147483000), QStringLiteral("pid:2147483000")); // no such process: the pid is all there is
}

TEST(Penalties, IdentityValidation) {
    EXPECT_TRUE(validIdentity(QStringLiteral("exe:/usr/bin/foo bar")));
    EXPECT_TRUE(validIdentity(QStringLiteral("pid:4242")));
    EXPECT_FALSE(validIdentity(QString()));
    EXPECT_FALSE(validIdentity(QStringLiteral("exe:relative")));
    EXPECT_FALSE(validIdentity(QStringLiteral("exe:/a\nb")));
    EXPECT_FALSE(validIdentity(QStringLiteral("pid:12x")));
    EXPECT_FALSE(validIdentity(QStringLiteral("pid:")));
    EXPECT_FALSE(validIdentity(QStringLiteral("exe:/") + QString(penalty::kMaxIdentity, u'a')));
    EXPECT_FALSE(validIdentity(QStringLiteral("window 1")));
}

TEST(Penalties, CrashRefusesForTheBaseSpanThenDoubles) {
    Clock      c;
    PenaltyBook b = book(c);
    QString    why;
    EXPECT_FALSE(b.refused(kApp, &why));
    b.record(kApp, Offence::Crash);
    EXPECT_TRUE(b.refused(kApp, &why));
    EXPECT_FALSE(b.refused(kOther, &why)) << "another application is not affected";
    c.now += penalty::kDenyBaseSec - 1;
    EXPECT_TRUE(b.refused(kApp, &why));
    c.now += 1;
    EXPECT_FALSE(b.refused(kApp, &why));
    b.record(kApp, Offence::Crash); // second strike: twice as long
    c.now += penalty::kDenyBaseSec * 2 - 1;
    EXPECT_TRUE(b.refused(kApp, &why));
    c.now += 1;
    EXPECT_FALSE(b.refused(kApp, &why));
    for (int i = 0; i < 20; ++i)
        b.record(kApp, Offence::Oversized);
    c.now += penalty::kDenyMaxSec - 1;
    EXPECT_TRUE(b.refused(kApp, &why)) << "capped, never overflows";
    c.now += 1;
    EXPECT_FALSE(b.refused(kApp, &why));
}

TEST(Penalties, LayoutFailureBacksOffShortlyAndDeliveryEndsIt) {
    Clock      c;
    PenaltyBook b = book(c);
    QString    why;
    b.record(kApp, Offence::LayoutFailed);
    EXPECT_TRUE(b.refused(kApp, &why));
    c.now += 2;
    EXPECT_FALSE(b.refused(kApp, &why));
    for (int i = 0; i < 20; ++i)
        b.record(kApp, Offence::LayoutFailed);
    c.now += penalty::kLayoutMaxSec - 1;
    EXPECT_TRUE(b.refused(kApp, &why));
    c.now += 1;
    EXPECT_FALSE(b.refused(kApp, &why));
    b.record(kApp, Offence::LayoutFailed);
    b.delivered(kApp);
    EXPECT_FALSE(b.refused(kApp, &why));
}

TEST(Penalties, EntriesDecay) {
    Clock      c;
    PenaltyBook b = book(c);
    QString    why;
    b.record(kApp, Offence::Crash);
    c.now += penalty::kDenyBaseSec;
    EXPECT_FALSE(b.refused(kApp, &why));
    EXPECT_TRUE(b.has(kApp)) << "the strike is remembered for the doubling";
    // Leaving the bus in good standing forgives one strike.
    b.leftCleanly(kApp);
    EXPECT_FALSE(b.has(kApp));
    // A refused application's exit does not clear its refusal.
    b.record(kApp, Offence::Crash);
    b.leftCleanly(kApp);
    EXPECT_TRUE(b.refused(kApp, &why));
    // Without a new strike for kForgiveSec the entry is dropped.
    c.now += penalty::kForgiveSec;
    EXPECT_FALSE(b.refused(kApp, &why));
    EXPECT_FALSE(b.has(kApp));
}

TEST(Penalties, BoundedLruKeepsRefusalsAndForgetsTheOldest) {
    Clock      c;
    PenaltyBook b = book(c);
    b.record(kApp, Offence::Crash); // refused: kept while others are evicted
    for (int i = 0; i < penalty::kMaxEntries * 2; ++i)
        b.record(QStringLiteral("pid:%1").arg(i + 1), Offence::LayoutFailed);
    EXPECT_LE(b.size(), penalty::kMaxEntries);
    EXPECT_TRUE(b.has(kApp));
    EXPECT_TRUE(b.has(QStringLiteral("pid:%1").arg(penalty::kMaxEntries * 2)));
    EXPECT_FALSE(b.has(QStringLiteral("pid:1")));
}

TEST(PenaltyState, InflightIdentitiesBecomeCrashRefusals) {
    Clock      c;
    PenaltyBook before = book(c);
    const QByteArray data = before.serialize({kApp, QStringLiteral("exe:/opt/with space/app")}, QStringLiteral("boot-1"));
    PenaltyBook after = book(c);
    QString     why;
    QStringList crashed;
    ASSERT_TRUE(after.load(data, QStringLiteral("boot-1"), &why, &crashed)) << qPrintable(why);
    EXPECT_EQ(crashed, (QStringList{kApp, QStringLiteral("exe:/opt/with space/app")}));
    EXPECT_TRUE(after.refused(kApp, &why));
    EXPECT_FALSE(after.refused(kOther, &why));
    // A refusal is carried over the next restart too (and keeps its strike count).
    const QByteArray again = after.serialize({}, QStringLiteral("boot-1"));
    PenaltyBook third = book(c);
    ASSERT_TRUE(third.load(again, QStringLiteral("boot-1"), &why, nullptr)) << qPrintable(why);
    EXPECT_TRUE(third.refused(kApp, &why));
    c.now += penalty::kDenyBaseSec;
    EXPECT_FALSE(third.refused(kApp, &why));
    third.record(kApp, Offence::Crash);
    c.now += penalty::kDenyBaseSec * 2 - 1;
    EXPECT_TRUE(third.refused(kApp, &why)) << "the second strike doubled";
}

TEST(PenaltyState, ForgedOrDamagedContentIsRefusedWhole) {
    Clock      c;
    QString    why;
    const QString boot = QStringLiteral("boot-1");
    const auto valid = [&](const QByteArray& body) {
        PenaltyBook b = book(c);
        return b.load(QByteArray("grassfield-menu-bridge-state 1\nboot boot-1\n") + body, boot, &why, nullptr);
    };
    EXPECT_TRUE(valid("inflight exe:/usr/bin/x\n"));
    EXPECT_FALSE(valid("inflight exe:relative\n"));
    EXPECT_FALSE(valid("inflight exe:/a%0Ab\n")) << "control characters";
    EXPECT_FALSE(valid("inflight pid:1x\n"));
    EXPECT_FALSE(valid("inflight a b\n"));
    EXPECT_FALSE(valid("deny 0 1 1 exe:/x\n")) << "zero strikes";
    EXPECT_FALSE(valid("deny 1 99999999999 1 exe:/x\n")) << "deny far in the future";
    EXPECT_FALSE(valid("deny 1 5 99999 exe:/x\n")) << "last strike in the future";
    EXPECT_FALSE(valid("deny 1 5 5 exe:/x extra\n"));
    EXPECT_FALSE(valid("unknown line\n"));
    {
        PenaltyBook b = book(c);
        EXPECT_FALSE(b.load("grassfield-menu-bridge-state 2\nboot boot-1\n", boot, &why, nullptr));
        EXPECT_FALSE(b.load("grassfield-menu-bridge-state 1\nboot other\n", boot, &why, nullptr)) << "another boot";
        EXPECT_FALSE(b.load("", boot, &why, nullptr));
        EXPECT_EQ(b.size(), 0) << "nothing merged from a refused file";
    }
    QByteArray many;
    for (int i = 0; i < penalty::kMaxEntries * 2 + 1; ++i)
        many += "inflight pid:" + QByteArray::number(i + 1) + "\n";
    EXPECT_FALSE(valid(many)) << "entry count is bounded";
    // One bad line among good ones: nothing at all is merged (an attacker cannot smuggle entries in).
    PenaltyBook b = book(c);
    EXPECT_FALSE(b.load("grassfield-menu-bridge-state 1\nboot boot-1\ninflight exe:/usr/bin/x\ninflight bad\n", boot, &why, nullptr));
    EXPECT_FALSE(b.has(QStringLiteral("exe:/usr/bin/x")));
}

TEST(PenaltyState, FileIsReadWithoutFollowingSymlinksAndBounded) {
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString path = dir.path() + QStringLiteral("/s.state");
    QByteArray    data;
    QString       why;
    EXPECT_FALSE(readStateFile(path, &data, &why));
    EXPECT_TRUE(why.isEmpty()) << "a missing file is not an error";

    ASSERT_TRUE(writeStateFile(path, QByteArray("hello\n")));
    EXPECT_TRUE(readStateFile(path, &data, &why));
    EXPECT_EQ(data, QByteArray("hello\n"));
    EXPECT_EQ(QFile::permissions(path) & (QFile::ReadGroup | QFile::WriteGroup | QFile::ReadOther | QFile::WriteOther), QFile::Permissions());

    // A symlink (even to a valid file) is refused.
    const QString link = dir.path() + QStringLiteral("/l.state");
    ASSERT_TRUE(QFile::link(path, link));
    EXPECT_FALSE(readStateFile(link, &data, &why));
    EXPECT_FALSE(why.isEmpty());

    // Writing over a symlink replaces the link, it does not write through it.
    ASSERT_TRUE(writeStateFile(link, QByteArray("replaced\n")));
    EXPECT_FALSE(QFileInfo(link).isSymLink());
    ASSERT_TRUE(readStateFile(path, &data, &why));
    EXPECT_EQ(data, QByteArray("hello\n")) << "the symlink's target was not written";

    // Oversized files are refused.
    QFile big(dir.path() + QStringLiteral("/big.state"));
    ASSERT_TRUE(big.open(QIODevice::WriteOnly));
    big.write(QByteArray(penalty::kMaxStateBytes + 1, 'x'));
    big.close();
    EXPECT_FALSE(readStateFile(big.fileName(), &data, &why));
    EXPECT_FALSE(why.isEmpty());
    // A FIFO is not a regular file (and must not block the bridge).
    const QString fifo = dir.path() + QStringLiteral("/f.state");
    ASSERT_EQ(::mkfifo(QFile::encodeName(fifo).constData(), 0600), 0);
    EXPECT_FALSE(readStateFile(fifo, &data, &why));
    EXPECT_FALSE(why.isEmpty());
}

// ---- start-up guards -------------------------------------------------------------------------------------------

TEST(Safety, DefaultSessionBusIsDetected) {
    EXPECT_TRUE(isDefaultSessionBus(QString(), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("unix:path=/run/user/1000/bus"), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("unix:path=/run/user/1000//bus,guid=0123"), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("unix:runtime=yes"), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("unix:tmpdir=/tmp;unix:path=/run/user/1000/bus"), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("autolaunch:"), 1000));
    EXPECT_TRUE(isDefaultSessionBus(QStringLiteral("garbage"), 1000));
    EXPECT_FALSE(isDefaultSessionBus(QStringLiteral("unix:path=/tmp/dbus-AbCdEf,guid=0123"), 1000));
    EXPECT_FALSE(isDefaultSessionBus(QStringLiteral("unix:abstract=/tmp/dbus-XYZ,guid=1"), 1000));
    EXPECT_FALSE(isDefaultSessionBus(QStringLiteral("unix:path=/run/user/1001/bus"), 1000)); // another user's path is not ours
}

TEST(Safety, SocketPath) {
    EXPECT_EQ(socketPath(QString(), QStringLiteral("/run/user/1000")), QStringLiteral("/run/user/1000/grassfield/menu-bridge.sock"));
    EXPECT_EQ(socketPath(QStringLiteral("/x/.dev/run/menu-bridge.sock"), QStringLiteral("/run/user/1000")), QStringLiteral("/x/.dev/run/menu-bridge.sock"));
    EXPECT_EQ(socketPath(QStringLiteral("relative.sock"), QStringLiteral("/run/user/1000")), QString());
    EXPECT_EQ(socketPath(QString(), QString()), QString());
    EXPECT_TRUE(fitsSocketPath(QStringLiteral("/run/user/1000/grassfield/menu-bridge.sock")));
    EXPECT_FALSE(fitsSocketPath(QStringLiteral("/") + QString(120, u'a')));
    EXPECT_FALSE(fitsSocketPath(QString()));
}

TEST(Safety, SocketDirectoryIsPrivate) {
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString sock = dir.path() + QStringLiteral("/grassfield/menu-bridge.sock");
    EXPECT_EQ(prepareSocketDirectory(sock), QString());
    EXPECT_EQ(QFile::permissions(dir.path() + QStringLiteral("/grassfield")) & (QFile::ReadGroup | QFile::WriteGroup | QFile::ExeGroup | QFile::ReadOther | QFile::WriteOther | QFile::ExeOther),
              QFile::Permissions());
    // A symlink in place of the directory is refused.
    const QString linked = dir.path() + QStringLiteral("/link");
    ASSERT_TRUE(QFile::link(dir.path() + QStringLiteral("/grassfield"), linked));
    EXPECT_NE(prepareSocketDirectory(linked + QStringLiteral("/menu-bridge.sock")), QString());
}

// ---- diagnostics interface -------------------------------------------------------------------------------------

TEST(Diagnostics, CodeMatchesTheVersionedXml) {
    QFile file(QStringLiteral(GRASSFIELD_MENU_BRIDGE_DBUS_XML));
    ASSERT_TRUE(file.open(QIODevice::ReadOnly));
    const QString xml = QString::fromUtf8(file.readAll());
    EXPECT_TRUE(xml.contains(diagnosticsInterfaceXml())) << "update DBusObjects.cpp and dbus/org.grassfield.MenuBridge1.xml together";
    EXPECT_TRUE(xml.contains(QStringLiteral("org.grassfield.MenuBridge1")));
}

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
