// grassfield-prompter without a bus (bridges/prompter/src, ADR-0035 D-9): the caller's text made plain, the prompter/1 line
// parser and messages, the bound of outstanding requests, the shell's cgroup, the socket peer check, who is trusted as a
// requester (temporary trees stand for the system's root-owned ones), the bus filter that tells a prompt its caller, and
// the GcrPrompt object itself (answers, withdrawals, the password wiped). The process on a private bus:
// tests/security/prompter_bridge.sh.
#include "Filter.h"
#include "Identity.h"
#include "Peer.h"
#include "Prompt.h"
#include "Protocol.h"
#include "Requests.h"
#include "Text.h"

#include <QDir>
#include <QFile>
#include <QJsonDocument>
#include <QJsonObject>
#include <QTemporaryDir>

#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <string>
#include <sys/socket.h>
#include <sys/ptrace.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#include <gtest/gtest.h>

using namespace gf::prompter;

namespace {
    // The executable checks need a system where /usr/bin is root's (not so in a user namespace that does not map root).
    bool rootOwnsSystemFiles() {
        struct stat st{};
        return ::stat("/usr/bin/sleep", &st) == 0 && st.st_uid == 0 && ::stat("/usr/bin", &st) == 0 && st.st_uid == 0;
    }

#define BACKSLASH "\\"
    // A string of code points, so that the source stays ASCII (no invisible or directional character in it).
    QString ucs(std::initializer_list<char32_t> codePoints) {
        QString out;
        for (const char32_t c : codePoints)
            out.append(QString::fromUcs4(&c, 1));
        return out;
    }

    // A JSON escape of four hex digits (backslash, u, the digits).
    std::string jsonU(const char* hex) {
        return std::string(BACKSLASH "u") + hex;
    }

    void writeFile(const QString& path, const QByteArray& content, mode_t mode) {
        QFile f(path);
        ASSERT_TRUE(f.open(QIODevice::WriteOnly | QIODevice::Truncate));
        f.write(content);
        f.close();
        ASSERT_EQ(::chmod(QFile::encodeName(path).constData(), mode), 0);
    }

    ShellLine parsed(const std::string& line, ParseStatus expected) {
        ShellLine out;
        QString   error;
        EXPECT_EQ(parseShellLine(line, &out, &error), expected) << line << " -> " << error.toStdString();
        return out;
    }

    std::string decoded(std::string_view line, const JsonString& raw, std::size_t capacity = 4096) {
        std::string out(capacity, '\0');
        const long  n = decodeJsonString(line.data() + raw.begin, raw.end - raw.begin, out.data(), capacity);
        return n < 0 ? std::string("<invalid>") : out.substr(0, static_cast<std::size_t>(n));
    }

    void spin(int turns = 20) {
        for (int i = 0; i < turns; ++i)
            g_main_context_iteration(nullptr, FALSE);
    }

    QString ownCgroupLeaf() {
        QFile f(QStringLiteral("/proc/self/cgroup"));
        if (!f.open(QIODevice::ReadOnly))
            return {};
        const QString path = unifiedCgroupPath(f.readAll());
        const QStringList parts = path.split(u'/', Qt::SkipEmptyParts);
        return parts.isEmpty() ? QString() : parts.constLast();
    }

    int pidfdOpen(pid_t pid) {
        return static_cast<int>(::syscall(SYS_pidfd_open, pid, 0));
    }
} // namespace

// --- text ---------------------------------------------------------------------------------------------------------------

TEST(PrompterText, ControlsSeparatorsAndRunsOfSpaceBecomeOneSpace) {
    EXPECT_EQ(flatten(QStringLiteral("  Unlock\tthe\n\nkeyring\r\x01now  "), 100), QStringLiteral("Unlock the keyring now"));
    EXPECT_EQ(flatten(ucs({'a', 0x2028, 'b', 0x2029, 'c', 0x85, 'd', 0xA0, 'e'}), 100), QStringLiteral("a b c d e"));
    EXPECT_EQ(flatten(QStringLiteral("\x7f\u0090"), 100), QString());
}

TEST(PrompterText, InvisibleAndDirectionalCharactersAreRemoved) {
    // An override that would make "exe.txt" read "txt.exe", isolates, marks, zero-width characters, a BOM, tags.
    const QString tricky = QStringLiteral("Login") + ucs({0x202E}) + QStringLiteral("txt.exe")
                         + ucs({0x202C, ' ', 0x2066, 'x', 0x2069, 0x200B, 0x200E, 0x061C, 0xFEFF, 0x00AD, 0x034F, 0xE0041, 0xE007F, 'y'});
    EXPECT_EQ(flatten(tricky, 100), QStringLiteral("Logintxt.exe xy"));
    EXPECT_EQ(flatten(ucs({'a', 0xFFFE, 0xFDD0, 0x1FFFF, 'b'}), 100), QStringLiteral("ab"));
}

TEST(PrompterText, LoneSurrogatesBecomeReplacementCharacters) {
    QString lone = QStringLiteral("a");
    lone.append(QChar(0xD800)).append(u'b').append(QChar(0xDC00));
    EXPECT_EQ(flatten(lone, 100), ucs({'a', 0xFFFD, 'b', 0xFFFD}));
    // A real pair stays.
    EXPECT_EQ(flatten(QString::fromUcs4(U"key \U0001F511"), 100), QString::fromUcs4(U"key \U0001F511"));
}

TEST(PrompterText, LongTextIsCutWithAnEllipsisWithinTheCap) {
    const QString cut = flatten(QString(500, u'x'), 32);
    EXPECT_EQ(cut.size(), 32);
    EXPECT_TRUE(cut.endsWith(QChar(0x2026)));
    // Never between the halves of a pair, never a trailing space before the ellipsis.
    const QString pairs = flatten(QString::fromUcs4(U"\U0001F511\U0001F511\U0001F511\U0001F511"), 4);
    EXPECT_LE(pairs.size(), 4);
    EXPECT_FALSE(QChar::isHighSurrogate(pairs.at(pairs.size() - 2).unicode()));
    EXPECT_EQ(flatten(QStringLiteral("abc defgh"), 5), QStringLiteral("abc") + QChar(0x2026));
    EXPECT_EQ(flatten(QStringLiteral("exact"), 5), QStringLiteral("exact"));
    EXPECT_EQ(flatten(QStringLiteral("x"), 0), QString());
    // A huge input costs no more than the cap.
    EXPECT_EQ(flatten(QString(1 << 20, u'y'), caps::kDescription).size(), caps::kDescription);
}

TEST(PrompterText, Utf8InputIsDecodedAndNullIsEmpty) {
    EXPECT_EQ(flattenUtf8("caf\xc3\xa9\n", 10), ucs({'c', 'a', 'f', 0xE9}));
    EXPECT_EQ(flattenUtf8("bad \xff byte", 20), QStringLiteral("bad ") + QChar(0xFFFD) + QStringLiteral(" byte"));
    EXPECT_EQ(flattenUtf8(nullptr, 10), QString());
}

// --- prompter/1: parsing what the shell sends ----------------------------------------------------------------------------

TEST(PrompterProtocol, HelloIsParsed) {
    const ShellLine hello = parsed(R"({"v":"prompter/1","type":"hello","shell":"1.0.0-rc1","kinds":["password","confirm","password"]})", ParseStatus::Ok);
    EXPECT_EQ(hello.type, ShellLine::Type::Hello);
    EXPECT_EQ(hello.kinds, (QStringList{QStringLiteral("password"), QStringLiteral("confirm")}));
    EXPECT_EQ(hello.shell, QStringLiteral("1.0.0-rc1"));
    parsed(R"({"v":"prompter/2","type":"hello","kinds":[]})", ParseStatus::Version);
    parsed(R"({"type":"hello","kinds":[]})", ParseStatus::Malformed);
    parsed(R"({"v":"prompter/1","type":"hello"})", ParseStatus::Malformed);
    parsed(R"({"v":"prompter/1","type":"hello","kinds":[],"extra":true})", ParseStatus::Malformed);
}

TEST(PrompterProtocol, AnswerIsParsedAndThePasswordStaysRaw) {
    const std::string line = R"({"type":"answer","id":"p12","result":"ok","password":"s3cr\"t )" + jsonU("00e9") + jsonU("d83d") + jsonU("dd11")
                           + R"(","choice":true})";
    const ShellLine   a    = parsed(line, ParseStatus::Ok);
    EXPECT_EQ(a.type, ShellLine::Type::Answer);
    EXPECT_EQ(a.id, QStringLiteral("p12"));
    EXPECT_TRUE(a.ok);
    EXPECT_TRUE(a.hasPassword);
    EXPECT_TRUE(a.hasChoice);
    EXPECT_TRUE(a.choice);
    EXPECT_EQ(decoded(line, a.password), std::string("s3cr\"t \xc3\xa9\xf0\x9f\x94\x91"));
    const ShellLine cancel = parsed(R"({"type":"answer","id":"p1","result":"cancel"})", ParseStatus::Ok);
    EXPECT_FALSE(cancel.ok);
    EXPECT_FALSE(cancel.hasPassword);
    // An empty password is a password (gnome-keyring asks about storing unencrypted then).
    const ShellLine empty = parsed(R"({"type":"answer","id":"p2","result":"ok","password":""})", ParseStatus::Ok);
    EXPECT_TRUE(empty.hasPassword);
}

TEST(PrompterProtocol, AnswerWithoutAUsableIdCannotBeAttributed) {
    parsed(R"({"type":"answer","result":"ok","password":"x"})", ParseStatus::Malformed);
    parsed(R"({"type":"answer","id":"7","result":"ok"})", ParseStatus::Malformed);
    parsed(R"({"type":"answer","id":"p07","result":"ok"})", ParseStatus::Malformed);
    parsed(R"({"type":"answer","id":true,"result":"ok"})", ParseStatus::Malformed);
}

TEST(PrompterProtocol, WrongFieldsOfAnAttributableAnswerNameTheRequest) {
    EXPECT_EQ(parsed(R"({"type":"answer","id":"p3","result":"yes"})", ParseStatus::Invalid).id, QStringLiteral("p3"));
    EXPECT_EQ(parsed(R"({"type":"answer","id":"p3","result":"ok","password":true})", ParseStatus::Invalid).id, QStringLiteral("p3"));
    EXPECT_EQ(parsed(R"({"type":"answer","id":"p3","result":"ok","choice":"yes"})", ParseStatus::Invalid).id, QStringLiteral("p3"));
    EXPECT_EQ(parsed(R"({"type":"answer","id":"p3","result":"ok","remember":true})", ParseStatus::Invalid).id, QStringLiteral("p3"));
    // A password over the limit is never cut: the request is cancelled.
    const std::string longPassword = R"({"type":"answer","id":"p3","result":"ok","password":")" + std::string(limits::kPassword + 1, 'a') + "\"}";
    EXPECT_EQ(parsed(longPassword, ParseStatus::Invalid).id, QStringLiteral("p3"));
    const std::string atLimit = R"({"type":"answer","id":"p3","result":"ok","password":")" + std::string(limits::kPassword, 'a') + "\"}";
    parsed(atLimit, ParseStatus::Ok);
}

TEST(PrompterProtocol, MalformedLinesAreRefused) {
    for (const std::string& line : {
             std::string(""),
             std::string("not json"),
             std::string(R"({"type":"answer")"),                          // unterminated
             std::string(R"({"type":"answer"} x)"),                       // trailing bytes
             std::string(R"([{"type":"answer"}])"),                       // not an object
             std::string(R"({"type":"answer","id":"p1","n":1})"),         // a number
             std::string(R"({"type":"answer","id":"p1","o":{}})"),        // nesting
             std::string(R"({"type":"answer","type":"hello"})"),          // duplicate key
             std::string("{\"type\":\"ans\twer\"}"),                       // raw control character
             std::string(R"({"type":"answer","id":"p1","password":"\ud800"})"),       // lone surrogate
             std::string(R"({"type":"answer","id":"p1","password":"\udc00\ud800"})"), // reversed pair
             std::string(R"({"type":"answer","id":"p1","password":"a\u0000b"})"),     // NUL
             std::string(R"({"type":"answer","id":"p1","password":"\x"})"),           // bad escape
             std::string("{\"type\":\"answer\",\"password\":\"\xc0\xaf\"}"),          // overlong UTF-8
             std::string("{\"type\":\"answer\",\"password\":\"\xed\xa0\x80\"}"),      // UTF-8 surrogate
             std::string("{\"type\":\"answer\",\"password\":\"\xf4\x90\x80\x80\"}"),  // above U+10FFFF
             std::string("{\"type\":\"answer\",\"password\":\"\xe2\x82\"}"),          // truncated sequence
             std::string(R"({"type":"answer","1key":"x"})"),              // invalid key
             std::string(R"({"kinds":["a",1]})"),                         // array of non-strings
             std::string(R"({"id":"p1"})"),                               // no type
         }) {
        ShellLine out;
        QString   error;
        EXPECT_EQ(parseShellLine(line, &out, &error), ParseStatus::Malformed) << line;
        EXPECT_FALSE(error.isEmpty());
    }
}

TEST(PrompterProtocol, OversizedLinesAndUnknownTypes) {
    std::string huge = R"({"type":"answer","id":"p1","result":"ok","password":")" + std::string(limits::kShellLine, 'a') + "\"}";
    ShellLine   out;
    QString     error;
    EXPECT_EQ(parseShellLine(huge, &out, &error), ParseStatus::Malformed);
    EXPECT_EQ(error, QStringLiteral("line too long"));
    parsed(R"({"type":"shown","id":"p1"})", ParseStatus::Unknown);
    // Arrays and members are bounded.
    std::string many = R"({"v":"prompter/1","type":"hello","kinds":[)";
    for (int i = 0; i < 17; ++i)
        many += (i ? ",\"k" : "\"k") + std::to_string(i) + "\"";
    many += "]}";
    parsed(many, ParseStatus::Malformed);
}

TEST(PrompterProtocol, DecodingRespectsTheCapacityAndCounts) {
    const std::string raw = std::string("abc") + BACKSLASH "n" + jsonU("00e9");
    char              small[4];
    EXPECT_EQ(decodeJsonString(raw.data(), raw.size(), small, sizeof small), -1);
    EXPECT_EQ(decodeJsonString(raw.data(), raw.size(), nullptr, 64), 6);
    char big[16] = {};
    EXPECT_EQ(decodeJsonString(raw.data(), raw.size(), big, sizeof big), 6);
    EXPECT_EQ(std::string(big, 6), std::string("abc\n\xc3\xa9"));
    const std::string quote = "a\"b";
    EXPECT_EQ(decodeJsonString(quote.data(), quote.size(), big, sizeof big), -1);
}

TEST(PrompterProtocol, RequestIds) {
    EXPECT_TRUE(validRequestId(QStringLiteral("p1")));
    EXPECT_TRUE(validRequestId(QStringLiteral("p1234567890123456789")));
    EXPECT_FALSE(validRequestId(QStringLiteral("p")));
    EXPECT_FALSE(validRequestId(QStringLiteral("p0")));
    EXPECT_FALSE(validRequestId(QStringLiteral("p-1")));
    EXPECT_FALSE(validRequestId(QStringLiteral("q1")));
    EXPECT_FALSE(validRequestId(QStringLiteral("p12345678901234567890")));
}

// --- prompter/1: what the bridge sends ---------------------------------------------------------------------------------

TEST(PrompterProtocol, PromptMessageCarriesTheRequesterAndTheTexts) {
    PromptView p;
    p.id                   = QStringLiteral("p4");
    p.kind                 = QStringLiteral("password");
    p.requester.role       = QStringLiteral("gnupg");
    p.requester.path       = QStringLiteral("/usr/bin/pinentry-gnome3");
    p.requester.identified = true;
    p.requester.onBehalf   = true;
    p.title                = QStringLiteral("Unlock");
    p.passwordNew          = true;
    p.hasChoice            = true;
    p.choiceLabel          = QStringLiteral("Remember");
    const QByteArray line  = promptMessage(p);
    ASSERT_TRUE(line.endsWith('\n'));
    EXPECT_EQ(line.count('\n'), 1);
    const QJsonObject o = QJsonDocument::fromJson(line).object();
    EXPECT_EQ(o.value(QStringLiteral("type")).toString(), QStringLiteral("prompt"));
    EXPECT_EQ(o.value(QStringLiteral("id")).toString(), QStringLiteral("p4"));
    EXPECT_EQ(o.value(QStringLiteral("requester")).toObject().value(QStringLiteral("role")).toString(), QStringLiteral("gnupg"));
    EXPECT_TRUE(o.value(QStringLiteral("requester")).toObject().value(QStringLiteral("onBehalf")).toBool());
    EXPECT_EQ(o.value(QStringLiteral("texts")).toObject().value(QStringLiteral("title")).toString(), QStringLiteral("Unlock"));
    EXPECT_EQ(o.value(QStringLiteral("choice")).toObject().value(QStringLiteral("label")).toString(), QStringLiteral("Remember"));
    EXPECT_TRUE(o.value(QStringLiteral("passwordNew")).toBool());
    EXPECT_TRUE(o.value(QStringLiteral("strength")).toBool());
    p.hasChoice = false;
    p.kind      = QStringLiteral("confirm");
    const QJsonObject c = QJsonDocument::fromJson(promptMessage(p)).object();
    EXPECT_TRUE(c.value(QStringLiteral("choice")).isNull());
    EXPECT_FALSE(c.value(QStringLiteral("passwordNew")).toBool()); // never for a confirmation
    const QJsonObject hello = QJsonDocument::fromJson(helloMessage({QStringLiteral("password")})).object();
    EXPECT_EQ(hello.value(QStringLiteral("v")).toString(), QStringLiteral("prompter/1"));
    EXPECT_EQ(hello.value(QStringLiteral("max")).toInt(), limits::kRequests);
    EXPECT_EQ(QJsonDocument::fromJson(cancelMessage(QStringLiteral("p9"))).object().value(QStringLiteral("id")).toString(), QStringLiteral("p9"));
}

// --- the bound ---------------------------------------------------------------------------------------------------------

TEST(PrompterRequests, AtMostEightAndIdsNeverReused) {
    RequestBook book(limits::kRequests);
    int         owners[10];
    QStringList ids;
    for (int i = 0; i < 8; ++i) {
        const QString id = book.reserve(&owners[i]);
        ASSERT_FALSE(id.isEmpty());
        ids.append(id);
    }
    EXPECT_EQ(book.count(), 8);
    EXPECT_TRUE(book.reserve(&owners[8]).isEmpty()); // the 9th is refused
    EXPECT_TRUE(book.reserve(&owners[0]).isEmpty()); // one request per owner
    EXPECT_EQ(book.ids(), ids);
    EXPECT_EQ(book.owner(ids.at(3)), &owners[3]);
    EXPECT_EQ(book.idOf(&owners[3]), ids.at(3));
    EXPECT_TRUE(book.release(ids.at(3)));
    EXPECT_FALSE(book.release(ids.at(3)));
    EXPECT_EQ(book.owner(ids.at(3)), nullptr);
    const QString next = book.reserve(&owners[8]);
    EXPECT_EQ(next, QStringLiteral("p9")); // a new number, never the released one
    EXPECT_FALSE(ids.contains(next));
    EXPECT_TRUE(book.reserve(nullptr).isEmpty());
}

// --- the shell's cgroup and the socket peer ------------------------------------------------------------------------------

TEST(PrompterPeer, CgroupLineAndUnit) {
    const QByteArray v2 = "0::/user.slice/user-1000.slice/user@1000.service/session.slice/grassfield-shell.service\n";
    const QString    path = unifiedCgroupPath(v2);
    EXPECT_EQ(path, QStringLiteral("/user.slice/user-1000.slice/user@1000.service/session.slice/grassfield-shell.service"));
    EXPECT_TRUE(cgroupIsUnit(path, QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(path, QStringLiteral("grassfield-shell.service"), 1001, true)); // another user's manager
    EXPECT_FALSE(cgroupIsUnit(path, QStringLiteral("grassfield-security.service"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(path + QStringLiteral(" (deleted)"), QStringLiteral("grassfield-shell.service (deleted)"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/app-foot.scope"),
                              QStringLiteral("grassfield-shell.service"), 1000, true));
    // A unit of the same name outside the user's manager (the system manager), or a deeper cgroup inside the unit.
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/system.slice/grassfield-shell.service"), QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(path + QStringLiteral("/child"), QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_TRUE(cgroupIsUnit(QStringLiteral("/system.slice/grassfield-shell.service"), QStringLiteral("grassfield-shell.service"), 1000, false));
    // Only slices between the user's manager and the unit: a cgroup nested in a scope or another unit that merely ends
    // with the unit's name is refused (security review of step 9a, NIT-1).
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/app-foot.scope/grassfield-shell.service"),
                              QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/evil.service/x/grassfield-shell.service"),
                              QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/.slice/grassfield-shell.service"),
                              QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_TRUE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/grassfield-shell.service"),
                             QStringLiteral("grassfield-shell.service"), 1000, true));
    EXPECT_TRUE(cgroupIsUnit(QStringLiteral("/user.slice/user-1000.slice/user@1000.service/app.slice/session.slice/grassfield-shell.service"),
                             QStringLiteral("grassfield-shell.service"), 1000, true));
    // Hybrid hierarchies: only the 0:: line counts; none at all is no cgroup.
    EXPECT_EQ(unifiedCgroupPath("12:pids:/user.slice\n1:name=systemd:/user.slice/x.service\n0::/a/b.service\n"), QStringLiteral("/a/b.service"));
    EXPECT_EQ(unifiedCgroupPath("1:name=systemd:/x.service\n"), QString());
    EXPECT_FALSE(cgroupIsUnit(QString(), QStringLiteral("x.service"), 1000, false));
    EXPECT_FALSE(cgroupIsUnit(QStringLiteral("/"), QStringLiteral("x.service"), 1000, false));
}

TEST(PrompterPeer, PeerUnitNames) {
    EXPECT_TRUE(validPeerUnit(QStringLiteral("grassfield-shell.service"), false));
    EXPECT_TRUE(validPeerUnit(QStringLiteral("grassfield-security.service"), false));
    EXPECT_TRUE(validPeerUnit(QStringLiteral("app@x.service"), false));
    EXPECT_FALSE(validPeerUnit(QStringLiteral("grassfield-shell"), false));
    EXPECT_FALSE(validPeerUnit(QStringLiteral("app-foot.scope"), false));
    EXPECT_FALSE(validPeerUnit(QStringLiteral("a/b.service"), false));
    EXPECT_FALSE(validPeerUnit(QString(), false));
    EXPECT_TRUE(validPeerUnit(QStringLiteral("9d5c228690508d63"), true)); // a container's cgroup, development runs only
    EXPECT_FALSE(validPeerUnit(QStringLiteral(".."), true));
}

TEST(PrompterPeer, FdinfoPid) {
    EXPECT_EQ(pidFromFdinfo("pos:\t0\nflags:\t02000002\nmnt_id:\t15\nino:\t1061\nPid:\t1234\nNSpid:\t1234\n"), 1234);
    EXPECT_EQ(pidFromFdinfo("Pid:\t-1\n"), -1); // exited
    EXPECT_EQ(pidFromFdinfo("Pid:\t0\n"), 0);   // another PID namespace
    EXPECT_EQ(pidFromFdinfo("flags:\t0\n"), 0);
    EXPECT_EQ(pidFromFdinfo("Pid:\tabc\n"), 0);
}

TEST(PrompterPeer, SocketPeerOfOwnCgroupIsAcceptedOthersRefused) {
    const QString leaf = ownCgroupLeaf();
    if (leaf.isEmpty())
        GTEST_SKIP() << "this process sits at the root of its cgroup tree: no unit name to expect";
    int pair[2];
    ASSERT_EQ(::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair), 0);
    const PeerCheck ok = checkSocketPeer(pair[0], ::getuid(), leaf, false);
    EXPECT_TRUE(ok.accepted) << ok.reason.toStdString();
    EXPECT_EQ(ok.pid, ::getpid());
    const PeerCheck other = checkSocketPeer(pair[0], ::getuid(), QStringLiteral("grassfield-shell.service"), false);
    EXPECT_FALSE(other.accepted);
    const PeerCheck user = checkSocketPeer(pair[0], ::getuid() + 1, leaf, false);
    EXPECT_FALSE(user.accepted);
    ::close(pair[0]);
    ::close(pair[1]);
    if (!ok.raceFree)
        std::fprintf(stderr, "note: this kernel has no SO_PEERPIDFD; the peer's cgroup was read through SO_PEERCRED's pid\n");
}

namespace {
    PidfdAnswer pidfdInvalid(int) {
        return {-1, EINVAL, -1}; // Linux 6.5 to 6.15 for a peer that exited and was reaped
    }
    PidfdAnswer pidfdUnknown(int) {
        return {-1, ENOPROTOOPT, -1}; // a kernel without SO_PEERPIDFD
    }
    PidfdAnswer pidfdDenied(int) {
        return {-1, EPERM, -1};
    }
} // namespace

TEST(PrompterPeer, OnlyAKernelWithoutPidfdsFallsBackToThePid) {
    const QString leaf = ownCgroupLeaf();
    if (leaf.isEmpty())
        GTEST_SKIP() << "this process sits at the root of its cgroup tree: no unit name to expect";
    int pair[2];
    ASSERT_EQ(::socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, pair), 0);
    // EINVAL (a reaped peer on Linux 6.5-6.15) and any other error refuse: the PID may belong to another process now.
    const PeerCheck invalid = checkSocketPeer(pair[0], ::getuid(), leaf, false, pidfdInvalid);
    EXPECT_FALSE(invalid.accepted);
    EXPECT_TRUE(invalid.reason.contains(QStringLiteral("no pidfd")));
    EXPECT_FALSE(checkSocketPeer(pair[0], ::getuid(), leaf, false, pidfdDenied).accepted);
    // ENOPROTOOPT (before Linux 6.5): SO_PEERCRED's PID, not race-free.
    const PeerCheck old = checkSocketPeer(pair[0], ::getuid(), leaf, false, pidfdUnknown);
    EXPECT_TRUE(old.accepted) << old.reason.toStdString();
    EXPECT_FALSE(old.raceFree);
    EXPECT_EQ(old.pid, ::getpid());
    ::close(pair[0]);
    ::close(pair[1]);
}

TEST(PrompterPeer, RefusalsAreLoggedOncePerWindow) {
    LogThrottle throttle(10000);
    qint64      suppressed = -1;
    EXPECT_TRUE(throttle.allow(1000, &suppressed));
    EXPECT_EQ(suppressed, 0);
    for (int i = 0; i < 50; ++i)
        EXPECT_FALSE(throttle.allow(1000 + i * 100, &suppressed));
    EXPECT_TRUE(throttle.allow(11000, &suppressed));
    EXPECT_EQ(suppressed, 50);
    EXPECT_FALSE(throttle.allow(11001, &suppressed));
    EXPECT_TRUE(throttle.allow(30000, &suppressed));
    EXPECT_EQ(suppressed, 1);
}

TEST(PrompterPeer, SocketPathAndDirectory) {
    EXPECT_EQ(socketPath(QString(), QStringLiteral("/run/user/1000")), QStringLiteral("/run/user/1000/grassfield/prompter.sock"));
    EXPECT_EQ(socketPath(QStringLiteral("relative.sock"), QStringLiteral("/run/user/1000")), QString());
    EXPECT_EQ(socketPath(QString(), QString()), QString());
    EXPECT_FALSE(fitsSocketPath(QStringLiteral("/") + QString(120, u'a')));
    QTemporaryDir dir;
    ASSERT_TRUE(dir.isValid());
    const QString socket = dir.path() + QStringLiteral("/grassfield/prompter.sock");
    EXPECT_TRUE(prepareSocketDirectory(socket).isEmpty());
    struct stat st{};
    ASSERT_EQ(::lstat(QFile::encodeName(dir.path() + QStringLiteral("/grassfield")).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, 0700u);
    // A symlink in its place is refused.
    const QString link = dir.path() + QStringLiteral("/linked");
    ASSERT_EQ(::symlink(QFile::encodeName(dir.path() + QStringLiteral("/grassfield")).constData(), QFile::encodeName(link).constData()), 0);
    EXPECT_FALSE(prepareSocketDirectory(link + QStringLiteral("/prompter.sock")).isEmpty());
    // Group and other bits of an existing directory are removed.
    ASSERT_EQ(::chmod(QFile::encodeName(dir.path() + QStringLiteral("/grassfield")).constData(), 0755), 0);
    EXPECT_TRUE(prepareSocketDirectory(socket).isEmpty());
    ASSERT_EQ(::lstat(QFile::encodeName(dir.path() + QStringLiteral("/grassfield")).constData(), &st), 0);
    EXPECT_EQ(st.st_mode & 0777, 0700u);
    // A missing directory in a parent that others can write is not created.
    const QString open = dir.path() + QStringLiteral("/open");
    ASSERT_TRUE(QDir().mkpath(open));
    ASSERT_EQ(::chmod(QFile::encodeName(open).constData(), 0777), 0);
    EXPECT_FALSE(prepareSocketDirectory(open + QStringLiteral("/grassfield/prompter.sock")).isEmpty());
}

// --- trusted executables and desktop entries (a temporary tree stands for the system: owner = this user, top = the tree) ---

class PrompterTrust : public ::testing::Test {
  protected:
    void SetUp() override {
        ASSERT_TRUE(m_dir.isValid());
        m_top = m_dir.path();
        ASSERT_TRUE(QDir().mkpath(m_top + QStringLiteral("/usr/bin")));
        ASSERT_TRUE(QDir().mkpath(m_top + QStringLiteral("/usr/share/applications")));
        for (const char* d : {"", "/usr", "/usr/bin", "/usr/share", "/usr/share/applications"})
            ASSERT_EQ(::chmod(QFile::encodeName(m_top + QLatin1String(d)).constData(), 0755), 0);
        writeFile(bin(QStringLiteral("editor")), "#!/bin/sh\n", 0755);
        writeFile(bin(QStringLiteral("python9")), "#!/bin/sh\n", 0755);
        writeFile(bin(QStringLiteral("keyringd")), "#!/bin/sh\n", 0755);
    }
    QString bin(const QString& name) const {
        return m_top + QStringLiteral("/usr/bin/") + name;
    }
    QString apps() const {
        return m_top + QStringLiteral("/usr/share/applications");
    }
    void entry(const QString& name, const QByteArray& exec, const QByteArray& extra = {}) {
        writeFile(apps() + u'/' + name, "[Desktop Entry]\nType=Application\nName=" + name.toUtf8().replace(".desktop", "") + "\nName[fr]=Localised\nIcon=icon-"
                                             + name.toUtf8().replace(".desktop", "") + "\nExec=" + exec + "\n" + extra,
                  0644);
    }
    Where where() const {
        Where w;
        w.applications = apps();
        w.programDirs  = {m_top + QStringLiteral("/usr/bin")};
        w.known        = {{bin(QStringLiteral("keyringd")), QStringLiteral("keyring")}};
        w.owner        = ::getuid();
        w.top          = m_top;
        return w;
    }
    ExeFacts facts(const QString& path) const {
        ExeFacts f;
        f.path     = path;
        f.file     = fileIdOf(path);
        f.alive     = true;
        f.sameUser  = true;
        f.traced    = false;
        f.codeKnown = true;
        f.codeFiles = {path};
        return f;
    }

    QTemporaryDir m_dir;
    QString       m_top;
};

TEST_F(PrompterTrust, OwnedNotWritableFilesAndDirectoriesOnly) {
    const uid_t me = ::getuid();
    EXPECT_TRUE(trustedPath(bin(QStringLiteral("editor")), me, m_top));
    EXPECT_FALSE(trustedPath(bin(QStringLiteral("editor")), me + 1, m_top)); // another owner
    EXPECT_FALSE(trustedPath(QStringLiteral("usr/bin/editor"), me, m_top));  // relative
    EXPECT_FALSE(trustedPath(m_top + QStringLiteral("/usr/bin/../bin/editor"), me, m_top));
    EXPECT_FALSE(trustedPath(m_top + QStringLiteral("/usr//bin/editor"), me, m_top));
    EXPECT_FALSE(trustedPath(bin(QStringLiteral("editor (deleted)")), me, m_top));
    EXPECT_FALSE(trustedPath(m_top + QStringLiteral("/usr/bin"), me, m_top)); // not a regular file
    EXPECT_FALSE(trustedPath(QStringLiteral("/elsewhere/editor"), me, m_top)); // outside the tree
    // Writable by group or others: the file, then a directory above it.
    ASSERT_EQ(::chmod(QFile::encodeName(bin(QStringLiteral("editor"))).constData(), 0775), 0);
    EXPECT_FALSE(trustedPath(bin(QStringLiteral("editor")), me, m_top));
    ASSERT_EQ(::chmod(QFile::encodeName(bin(QStringLiteral("editor"))).constData(), 0755), 0);
    ASSERT_EQ(::chmod(QFile::encodeName(m_top + QStringLiteral("/usr")).constData(), 0757), 0);
    EXPECT_FALSE(trustedPath(bin(QStringLiteral("editor")), me, m_top));
    ASSERT_EQ(::chmod(QFile::encodeName(m_top + QStringLiteral("/usr")).constData(), 0755), 0);
    // A symlink, as the file or as a directory on the way.
    ASSERT_EQ(::symlink("editor", QFile::encodeName(bin(QStringLiteral("link"))).constData()), 0);
    EXPECT_FALSE(trustedPath(bin(QStringLiteral("link")), me, m_top));
    ASSERT_EQ(::symlink(QFile::encodeName(m_top + QStringLiteral("/usr/bin")).constData(), QFile::encodeName(m_top + QStringLiteral("/bin")).constData()), 0);
    EXPECT_FALSE(trustedPath(m_top + QStringLiteral("/bin/editor"), me, m_top));
}

TEST_F(PrompterTrust, ExecLinesThatAreTheProgramItself) {
    EXPECT_EQ(execProgramOnly(QStringLiteral("/usr/bin/editor %U")), QStringLiteral("/usr/bin/editor"));
    EXPECT_EQ(execProgramOnly(QStringLiteral("editor")), QStringLiteral("editor"));
    EXPECT_EQ(execProgramOnly(QStringLiteral("editor %f %i %c %k")), QStringLiteral("editor"));
    EXPECT_EQ(execProgramOnly(QStringLiteral("\"/opt/my app/run\" %F")), QStringLiteral("/opt/my app/run"));
    // Anything that picks something else to run, or a quoting error.
    EXPECT_TRUE(execProgramOnly(QStringLiteral("python9 /usr/share/tool/tool.py")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("editor --new-window")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("env FOO=1 editor")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("FOO=1 editor")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("sh -c editor")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("editor;rm")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("\"unterminated %f")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QStringLiteral("%f")).isEmpty());
    EXPECT_TRUE(execProgramOnly(QString()).isEmpty());
}

TEST_F(PrompterTrust, DesktopEntryParsing) {
    const DesktopEntry e = parseDesktopEntry(
        "# comment\n[Desktop Action new]\nName=Wrong\nExec=wrong\n[Desktop Entry]\nType=Application\nName = Text\\sEditor\nName[fr]=\xc3\x89" "diteur\nIcon=accessories-text-editor\n"
        "Exec=editor %U\nHidden=false\n[Other]\nName=Also wrong\n");
    EXPECT_TRUE(e.application);
    EXPECT_FALSE(e.hidden);
    EXPECT_EQ(e.name, QStringLiteral("Text Editor"));
    EXPECT_EQ(e.icon, QStringLiteral("accessories-text-editor"));
    EXPECT_EQ(e.exec, QStringLiteral("editor %U"));
    EXPECT_FALSE(parseDesktopEntry("[Desktop Entry]\nType=Link\n").application);
    EXPECT_TRUE(parseDesktopEntry("[Desktop Entry]\nHidden=true\n").hidden);
}

TEST_F(PrompterTrust, TheOneEntryThatRunsTheExecutable) {
    entry(QStringLiteral("org.example.Editor.desktop"), "editor %U");
    entry(QStringLiteral("tool.desktop"), "python9 /usr/share/tool/tool.py"); // an interpreter with a script: never python9's
    const RequesterView editor = requesterFor(facts(bin(QStringLiteral("editor"))), where());
    EXPECT_EQ(editor.role, QStringLiteral("app"));
    EXPECT_TRUE(editor.identified);
    EXPECT_FALSE(editor.onBehalf);
    EXPECT_EQ(editor.name, QStringLiteral("org.example.Editor")); // the unlocalised Name
    EXPECT_EQ(editor.icon, QStringLiteral("icon-org.example.Editor"));
    EXPECT_EQ(editor.desktopId, QStringLiteral("org.example.Editor.desktop"));
    EXPECT_EQ(editor.path, bin(QStringLiteral("editor")));
    const RequesterView python = requesterFor(facts(bin(QStringLiteral("python9"))), where());
    EXPECT_EQ(python.role, QStringLiteral("unidentified"));
    EXPECT_FALSE(python.identified);
    EXPECT_EQ(python.path, bin(QStringLiteral("python9")));
    // A second entry for the same file: neither is shown.
    entry(QStringLiteral("org.example.Editor2.desktop"), editor.path.toUtf8());
    EXPECT_EQ(requesterFor(facts(bin(QStringLiteral("editor"))), where()).role, QStringLiteral("unidentified"));
}

TEST_F(PrompterTrust, EntriesThatDoNotCount) {
    entry(QStringLiteral("hidden.desktop"), "editor", "Hidden=true\n");
    entry(QStringLiteral("link.desktop"), "editor", "Type=Link\n");
    EXPECT_EQ(requesterFor(facts(bin(QStringLiteral("editor"))), where()).role, QStringLiteral("unidentified"));
    // A writable entry file is not read.
    entry(QStringLiteral("writable.desktop"), "editor");
    ASSERT_EQ(::chmod(QFile::encodeName(apps() + QStringLiteral("/writable.desktop")).constData(), 0666), 0);
    EXPECT_EQ(requesterFor(facts(bin(QStringLiteral("editor"))), where()).role, QStringLiteral("unidentified"));
    ASSERT_EQ(::chmod(QFile::encodeName(apps() + QStringLiteral("/writable.desktop")).constData(), 0644), 0);
    EXPECT_EQ(requesterFor(facts(bin(QStringLiteral("editor"))), where()).role, QStringLiteral("app"));
}

TEST_F(PrompterTrust, KnownCallersAskOnSomeoneElsesBehalf) {
    entry(QStringLiteral("keyring.desktop"), "keyringd"); // the role wins over an entry
    const RequesterView keyring = requesterFor(facts(bin(QStringLiteral("keyringd"))), where());
    EXPECT_EQ(keyring.role, QStringLiteral("keyring"));
    EXPECT_TRUE(keyring.identified);
    EXPECT_TRUE(keyring.onBehalf);
    EXPECT_TRUE(keyring.name.isEmpty()); // the shell names the role in its own words
}

TEST_F(PrompterTrust, AnAppsNameNeedsOnlyTrustedCodeInItsProcess) {
    entry(QStringLiteral("org.example.Editor.desktop"), "editor");
    writeFile(m_top + QStringLiteral("/usr/bin/libtrusted.so"), "\x7f" "ELF", 0644);
    ExeFacts clean = facts(bin(QStringLiteral("editor")));
    clean.codeFiles.append(m_top + QStringLiteral("/usr/bin/libtrusted.so"));
    EXPECT_EQ(requesterFor(clean, where()).role, QStringLiteral("app"));
    // LD_PRELOAD or LD_LIBRARY_PATH code from the user's files, a library replaced since it was loaded, memfd code:
    // the app's name is not lent (security review of step 9a, MINOR-2, decision 9-14).
    for (const QString& foreign : {QStringLiteral("/home/u/.local/lib/evil.so"), m_top + QStringLiteral("/usr/bin/libtrusted.so (deleted)"),
                                   QStringLiteral("/memfd:code (deleted)")}) {
        ExeFacts preloaded = clean;
        preloaded.codeFiles.append(foreign);
        const RequesterView r = requesterFor(preloaded, where());
        EXPECT_EQ(r.role, QStringLiteral("unidentified")) << foreign.toStdString();
        EXPECT_EQ(r.path, bin(QStringLiteral("editor")));
    }
    ExeFacts unread = clean;
    unread.codeKnown = false;
    EXPECT_EQ(requesterFor(unread, where()).role, QStringLiteral("unidentified"));
    // A traced process can run anyone's code: unidentified, whatever it runs (a known caller too).
    ExeFacts traced = clean;
    traced.traced   = true;
    EXPECT_EQ(requesterFor(traced, where()).role, QStringLiteral("unidentified"));
    ExeFacts tracedKeyring = facts(bin(QStringLiteral("keyringd")));
    tracedKeyring.traced   = true;
    EXPECT_EQ(requesterFor(tracedKeyring, where()).role, QStringLiteral("unidentified"));
    // A known caller keeps its role with extra code: any program can make it ask anyway (the row names the program that
    // asks, never a guarantee about the text; decision 9-14).
    ExeFacts keyringPlugins = facts(bin(QStringLiteral("keyringd")));
    keyringPlugins.codeFiles.append(QStringLiteral("/home/u/.local/lib/evil.so"));
    EXPECT_EQ(requesterFor(keyringPlugins, where()).role, QStringLiteral("keyring"));
}

TEST(PrompterIdentity, MapsAndStatusParsing) {
    bool              ok   = false;
    const QStringList code = executableFiles("55d4a0e00000-55d4a0e02000 r--p 00000000 00:1f 1234                       /usr/bin/sleep\n"
                                             "55d4a0e02000-55d4a0e06000 r-xp 00002000 00:1f 1234                       /usr/bin/sleep\n"
                                             "7f00a0000000-7f00a0028000 r-xp 00028000 00:1f 99                         /usr/lib/libc.so.6\n"
                                             "7f00a1000000-7f00a1001000 r-xp 00000000 00:00 0 \n"
                                             "7f00a2000000-7f00a2001000 r-xp 00000000 00:1f 7                          /home/u/my lib.so (deleted)\n"
                                             "7f00a3000000-7f00a3001000 rw-p 00000000 00:1f 8                          /usr/lib/data.bin\n"
                                             "7ffd0a000000-7ffd0a002000 r-xp 00000000 00:00 0                          [vdso]\n",
                                             &ok);
    EXPECT_TRUE(ok);
    EXPECT_EQ(code, (QStringList{QStringLiteral("/usr/bin/sleep"), QStringLiteral("/usr/lib/libc.so.6"), QStringLiteral("/home/u/my lib.so (deleted)")}));
    executableFiles("garbage\n", &ok);
    EXPECT_FALSE(ok);
    EXPECT_EQ(tracerPid("Name:\tsleep\nTracerPid:\t0\n"), 0);
    EXPECT_EQ(tracerPid("TracerPid:\t4242\n"), 4242);
    EXPECT_EQ(tracerPid("Name:\tsleep\n"), -1);
    EXPECT_EQ(tracerPid("TracerPid:\tx\n"), -1);
    // gcr-ssh-agent asks on behalf of ssh (security review of step 9a, NIT-4).
    bool ssh = false;
    for (const KnownCaller& k : knownCallers())
        ssh = ssh || (k.path == QLatin1String("/usr/lib/gcr-ssh-agent") && k.role == QLatin1String("ssh"));
    EXPECT_TRUE(ssh);
}

TEST_F(PrompterTrust, EveryFailureIsUnidentified) {
    entry(QStringLiteral("org.example.Editor.desktop"), "editor");
    ExeFacts gone = facts(bin(QStringLiteral("editor")));
    gone.alive    = false;
    EXPECT_EQ(requesterFor(gone, where()).role, QStringLiteral("unidentified"));
    ExeFacts other = facts(bin(QStringLiteral("editor")));
    other.sameUser = false;
    EXPECT_EQ(requesterFor(other, where()).role, QStringLiteral("unidentified"));
    ExeFacts nothing;
    EXPECT_EQ(requesterFor(nothing, where()).path, QString());
    // The name now leads to another file than the one the process runs (replaced since it started).
    ExeFacts replaced = facts(bin(QStringLiteral("editor")));
    replaced.file     = fileIdOf(bin(QStringLiteral("python9")));
    EXPECT_EQ(requesterFor(replaced, where()).role, QStringLiteral("unidentified"));
    // An executable the user could have written (here: group-writable directory).
    ASSERT_EQ(::chmod(QFile::encodeName(m_top + QStringLiteral("/usr/bin")).constData(), 0775), 0);
    const RequesterView home = requesterFor(facts(bin(QStringLiteral("editor"))), where());
    EXPECT_EQ(home.role, QStringLiteral("unidentified"));
    EXPECT_EQ(home.path, bin(QStringLiteral("editor"))); // shown, in the secondary style
    ASSERT_EQ(::chmod(QFile::encodeName(m_top + QStringLiteral("/usr/bin")).constData(), 0755), 0);
    // A path with a newline and a direction override is shown flattened.
    ExeFacts weird = facts(QStringLiteral("/home/u/Login") + QChar(0x202E) + QStringLiteral("\nKeychain"));
    EXPECT_EQ(requesterFor(weird, where()).path, QStringLiteral("/home/u/Login Keychain"));
}

TEST(PrompterIdentity, ProcessesThroughTheirPidfd) {
    // This process: its own executable, alive.
    const int self = pidfdOpen(::getpid());
    if (self < 0)
        GTEST_SKIP() << "no pidfd_open on this kernel";
    char          buffer[4096];
    const ssize_t n = ::readlink("/proc/self/exe", buffer, sizeof buffer - 1);
    ASSERT_GT(n, 0);
    const ExeFacts mine = exeFactsOfPidfd(self);
    ::close(self);
    EXPECT_TRUE(mine.alive);
    EXPECT_EQ(mine.path, QFile::decodeName(QByteArray(buffer, n)));
    EXPECT_TRUE(mine.file.valid);
    // A child running a system program, then gone: once it has exited, nothing about it is reported.
    const pid_t child = ::fork();
    if (child == 0) {
        ::execl("/usr/bin/sleep", "sleep", "5", static_cast<char*>(nullptr));
        ::_exit(127);
    }
    ASSERT_GT(child, 0);
    const int pidfd = pidfdOpen(child);
    ASSERT_GE(pidfd, 0);
    ExeFacts running;
    for (int i = 0; i < 100 && running.path != QLatin1String("/usr/bin/sleep"); ++i) {
        running = exeFactsOfPidfd(pidfd); // until the child has exec'd
        ::usleep(10000);
    }
    EXPECT_EQ(running.path, QStringLiteral("/usr/bin/sleep"));
    EXPECT_TRUE(running.alive);
    EXPECT_FALSE(running.traced);
    EXPECT_TRUE(running.codeKnown);
    EXPECT_TRUE(running.codeFiles.contains(QStringLiteral("/usr/bin/sleep")));
    EXPECT_GE(running.codeFiles.size(), 2); // the program and at least the C library
    if (rootOwnsSystemFiles()) {
        running.sameUser = true;
        Where w;
        w.applications = QStringLiteral("/nonexistent");
        EXPECT_EQ(requesterFor(running, w).role, QStringLiteral("unidentified")); // trusted, but no entry runs it
        w.known = {{QStringLiteral("/usr/bin/sleep"), QStringLiteral("gnupg")}};
        EXPECT_EQ(requesterFor(running, w).role, QStringLiteral("gnupg"));
    }
    ::kill(child, SIGKILL);
    ::waitpid(child, nullptr, 0);
    const ExeFacts gone = exeFactsOfPidfd(pidfd);
    ::close(pidfd);
    EXPECT_FALSE(gone.alive);
    EXPECT_TRUE(gone.path.isEmpty());
    EXPECT_TRUE(gone.codeFiles.isEmpty());
    EXPECT_EQ(requesterFor(gone).role, QStringLiteral("unidentified"));
    // A traced child: TracerPid names this process.
    const pid_t traced = ::fork();
    if (traced == 0) {
        if (::ptrace(PTRACE_TRACEME, 0, nullptr, nullptr) != 0)
            ::_exit(126);
        ::execl("/usr/bin/sleep", "sleep", "5", static_cast<char*>(nullptr));
        ::_exit(127);
    }
    ASSERT_GT(traced, 0);
    int status = 0;
    ASSERT_EQ(::waitpid(traced, &status, 0), traced); // stopped at its exec, or exited when ptrace is not allowed
    if (WIFEXITED(status)) {
        std::fprintf(stderr, "note: ptrace is not allowed here; the traced case was not run\n");
        return;
    }
    const int tracedFd = pidfdOpen(traced);
    ASSERT_GE(tracedFd, 0);
    const ExeFacts underTrace = exeFactsOfPidfd(tracedFd);
    ::close(tracedFd);
    EXPECT_TRUE(underTrace.alive);
    EXPECT_TRUE(underTrace.traced);
    ExeFacts asKnown = underTrace;
    asKnown.sameUser = true;
    Where w;
    w.known = {{QStringLiteral("/usr/bin/sleep"), QStringLiteral("gnupg")}};
    EXPECT_EQ(requesterFor(asKnown, w).role, QStringLiteral("unidentified"));
    ::kill(traced, SIGKILL);
    ::waitpid(traced, nullptr, 0);
}

// --- the bus filter --------------------------------------------------------------------------------------------------------

namespace {
    GVariant* performBody(std::initializer_list<std::pair<const char*, GVariant*>> properties) {
        GVariantBuilder b;
        g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
        for (const auto& [name, value] : properties)
            g_variant_builder_add(&b, "{sv}", name, value);
        return g_variant_ref_sink(g_variant_new("(osa{sv}s)", "/org/gnome/keyring/Prompt/p1", "password", &b, "[sx-aes-1]\npublic=abc"));
    }

    GVariant* property(GVariant* body, const char* name) {
        GVariant* dict  = g_variant_get_child_value(body, 2);
        GVariant* value = g_variant_lookup_value(dict, name, nullptr);
        g_variant_unref(dict);
        return value;
    }
} // namespace

TEST(PrompterFilter, OnlyGcrPropertiesAndTheBusSender) {
    const std::string longText(kMaxPropertyBytes + 1, 'x');
    GVariant*         body = performBody({
        {"title", g_variant_new_string("Unlock")},
        {"choice-label", g_variant_new_string("Remember")},
        {"password-new", g_variant_new_boolean(TRUE)},
        {"grassfield-caller", g_variant_new_string(":1.666")}, // a caller cannot choose who it is
        {"bogus", g_variant_new_string("x")},
        {"choice-chosen", g_variant_new_string("yes")},          // wrong type
        {"password-strength", g_variant_new_int32(5)},           // the prompter's, not the caller's
        {"message", g_variant_new_string(longText.c_str())},     // too long
    });
    GVariant* clean = g_variant_ref_sink(sanitizePerformPrompt(body, ":1.42"));
    ASSERT_NE(clean, nullptr);
    EXPECT_STREQ(g_variant_get_type_string(clean), "(osa{sv}s)");
    GVariant* dict = g_variant_get_child_value(clean, 2);
    EXPECT_EQ(g_variant_n_children(dict), 4u); // title, choice-label, password-new, grassfield-caller
    g_variant_unref(dict);
    GVariant* caller = property(clean, "grassfield-caller");
    ASSERT_NE(caller, nullptr);
    EXPECT_STREQ(g_variant_get_string(caller, nullptr), ":1.42");
    g_variant_unref(caller);
    for (const char* dropped : {"bogus", "choice-chosen", "password-strength", "message"})
        EXPECT_EQ(property(clean, dropped), nullptr) << dropped;
    // The callback path, the type and the exchange are kept.
    GVariant* exchange = g_variant_get_child_value(clean, 3);
    EXPECT_STREQ(g_variant_get_string(exchange, nullptr), "[sx-aes-1]\npublic=abc");
    g_variant_unref(exchange);
    g_variant_unref(clean);
    g_variant_unref(body);
    // Another shape: nothing.
    GVariant* wrong = g_variant_ref_sink(g_variant_new("(os)", "/x", "password"));
    EXPECT_EQ(sanitizePerformPrompt(wrong, ":1.42"), nullptr);
    g_variant_unref(wrong);
    // No sender: an empty caller, which the bridge shows as unidentified.
    GVariant* anon  = performBody({});
    GVariant* anon2 = g_variant_ref_sink(sanitizePerformPrompt(anon, nullptr));
    GVariant* none  = property(anon2, "grassfield-caller");
    EXPECT_STREQ(g_variant_get_string(none, nullptr), "");
    g_variant_unref(none);
    g_variant_unref(anon2);
    g_variant_unref(anon);
}

namespace {
    GDBusMessage* call(const char* path, const char* member, GVariant* body, const char* sender = ":1.7", const char* iface = kPrompterIface) {
        GDBusMessage* m = g_dbus_message_new_method_call(kPrompterName, path, iface, member);
        g_dbus_message_set_sender(m, sender);
        g_dbus_message_set_serial(m, 42);
        if (body)
            g_dbus_message_set_body(m, body);
        g_dbus_message_lock(m);
        return m;
    }

    GDBusMessage* ownerChanged(const char* name, const char* oldOwner, const char* newOwner, const char* sender = "org.freedesktop.DBus") {
        GDBusMessage* m = g_dbus_message_new_signal("/org/freedesktop/DBus", "org.freedesktop.DBus", "NameOwnerChanged");
        g_dbus_message_set_sender(m, sender);
        g_dbus_message_set_body(m, g_variant_new("(sss)", name, oldOwner, newOwner));
        return m;
    }

    std::string errorName(GDBusMessage* reply) {
        return reply && g_dbus_message_get_message_type(reply) == G_DBUS_MESSAGE_TYPE_ERROR ? std::string(g_dbus_message_get_error_name(reply)) : std::string();
    }
} // namespace

TEST(PrompterFilter, MessagesThroughTheFilter) {
    CallerBook    book(limits::kPromptsPerCaller);
    GDBusMessage* reply    = nullptr;
    GVariant*     body     = performBody({{"grassfield-caller", g_variant_new_string(":1.666")}});
    GDBusMessage* perform  = call(kPrompterPath, "PerformPrompt", body);
    GDBusMessage* filtered = filterIncoming(book, perform, &reply);
    ASSERT_NE(filtered, nullptr);
    EXPECT_EQ(reply, nullptr);
    EXPECT_NE(filtered, perform); // a sanitized copy
    GVariant* caller = property(g_dbus_message_get_body(filtered), "grassfield-caller");
    EXPECT_STREQ(g_variant_get_string(caller, nullptr), ":1.7");
    g_variant_unref(caller);
    g_object_unref(filtered);
    // Without an interface field the call is sanitized all the same (whatever GDBus then does with it).
    GDBusMessage* bare = call(kPrompterPath, "PerformPrompt", body, ":1.8", nullptr);
    filtered           = filterIncoming(book, bare, &reply);
    ASSERT_NE(filtered, nullptr);
    EXPECT_NE(filtered, bare);
    caller = property(g_dbus_message_get_body(filtered), "grassfield-caller");
    EXPECT_STREQ(g_variant_get_string(caller, nullptr), ":1.8");
    g_variant_unref(caller);
    g_object_unref(filtered);
    // Other calls and other interfaces pass untouched; outgoing messages are not even looked at by promptFilter.
    GDBusMessage* other = call(kPrompterPath, "Introspect", nullptr, ":1.7", "org.freedesktop.DBus.Introspectable");
    EXPECT_EQ(filterIncoming(book, other, &reply), other);
    g_object_unref(other);
    GDBusMessage* elsewhere = call("/elsewhere", "PerformPrompt", body);
    EXPECT_EQ(filterIncoming(book, elsewhere, &reply), elsewhere);
    g_object_unref(elsewhere);
    FilterState   state;
    GDBusMessage* outgoing = call(kPrompterPath, "PerformPrompt", body);
    EXPECT_EQ(promptFilter(nullptr, outgoing, FALSE, &state), outgoing);
    g_object_unref(outgoing);
    // A PerformPrompt of another shape never reaches gcr: its caller gets InvalidArgs, as a reply to its own call.
    GDBusMessage* malformed = call(kPrompterPath, "PerformPrompt", g_variant_new("(s)", "x"));
    EXPECT_EQ(filterIncoming(book, malformed, &reply), nullptr);
    ASSERT_NE(reply, nullptr);
    EXPECT_EQ(errorName(reply), "org.freedesktop.DBus.Error.InvalidArgs");
    EXPECT_EQ(g_dbus_message_get_reply_serial(reply), 42u);
    EXPECT_STREQ(g_dbus_message_get_destination(reply), ":1.7");
    g_object_unref(reply);
    g_variant_unref(body);
}

TEST(PrompterFilter, EachCallerHoldsAtMostItsShareOfPrompts) {
    CallerBook book(3);
    EXPECT_TRUE(book.begin(":1.1", "/p/1"));
    EXPECT_TRUE(book.begin(":1.1", "/p/2"));
    EXPECT_TRUE(book.begin(":1.1", "/p/2")); // gcr refuses the repeat itself: not counted twice
    EXPECT_TRUE(book.begin(":1.1", "/p/3"));
    EXPECT_EQ(book.open(":1.1"), 3);
    EXPECT_FALSE(book.begin(":1.1", "/p/4"));
    EXPECT_TRUE(book.begin(":1.2", "/p/1")); // another caller keeps its own share
    book.stop(":1.1", "/p/9");                // a stop for nothing frees nothing
    EXPECT_FALSE(book.begin(":1.1", "/p/4"));
    book.stop(":1.1", "/p/1");
    EXPECT_TRUE(book.begin(":1.1", "/p/4"));
    book.gone(":1.1");
    EXPECT_EQ(book.open(":1.1"), 0);
    EXPECT_EQ(book.callers(), 1);
    book.stop(":1.2", "/p/1");
    EXPECT_EQ(book.callers(), 0); // nothing kept for a caller with nothing open
}

TEST(PrompterFilter, BeginPromptingOverTheShareIsRefusedUntilStopOrDeparture) {
    CallerBook    book(limits::kPromptsPerCaller);
    GDBusMessage* reply = nullptr;
    for (int i = 0; i < limits::kPromptsPerCaller; ++i) {
        const std::string path = "/org/gnome/keyring/Prompt/p" + std::to_string(i);
        GDBusMessage*     begin = call(kPrompterPath, "BeginPrompting", g_variant_new("(o)", path.c_str()));
        EXPECT_EQ(filterIncoming(book, begin, &reply), begin);
        EXPECT_EQ(reply, nullptr);
        g_object_unref(begin);
    }
    GDBusMessage* over = call(kPrompterPath, "BeginPrompting", g_variant_new("(o)", "/org/gnome/keyring/Prompt/over"));
    EXPECT_EQ(filterIncoming(book, over, &reply), nullptr);
    EXPECT_EQ(errorName(reply), "org.freedesktop.DBus.Error.LimitsExceeded");
    EXPECT_EQ(g_dbus_message_get_reply_serial(reply), 42u);
    g_object_unref(reply);
    // Another connection is not affected.
    GDBusMessage* other = call(kPrompterPath, "BeginPrompting", g_variant_new("(o)", "/org/gnome/keyring/Prompt/p0"), ":1.9");
    EXPECT_EQ(filterIncoming(book, other, &reply), other);
    g_object_unref(other);
    // StopPrompting frees a place.
    GDBusMessage* stop = call(kPrompterPath, "StopPrompting", g_variant_new("(o)", "/org/gnome/keyring/Prompt/p0"));
    EXPECT_EQ(filterIncoming(book, stop, &reply), stop);
    g_object_unref(stop);
    EXPECT_EQ(book.open(":1.7"), limits::kPromptsPerCaller - 1);
    // A NameOwnerChanged that does not come from the bus daemon changes nothing; the bus's own one forgets the caller.
    GDBusMessage* forged = ownerChanged(":1.7", ":1.7", "", ":1.9");
    EXPECT_EQ(filterIncoming(book, forged, &reply), forged);
    g_object_unref(forged);
    EXPECT_EQ(book.open(":1.7"), limits::kPromptsPerCaller - 1);
    GDBusMessage* acquired = ownerChanged("org.example.Name", "", ":1.7"); // a well-known name changing hands: ignored
    EXPECT_EQ(filterIncoming(book, acquired, &reply), acquired);
    g_object_unref(acquired);
    EXPECT_EQ(book.open(":1.7"), limits::kPromptsPerCaller - 1);
    GDBusMessage* left = ownerChanged(":1.7", ":1.7", "");
    EXPECT_EQ(filterIncoming(book, left, &reply), left);
    g_object_unref(left);
    EXPECT_EQ(book.open(":1.7"), 0);
    EXPECT_EQ(book.open(":1.9"), 1);
}

// --- the GcrPrompt object ---------------------------------------------------------------------------------------------------

namespace {
    struct FakeSink : PromptSink {
        int        submits = 0, withdrawals = 0, forgotten = 0;
        GfPrompt*  last    = nullptr;
        PromptKind kind    = PromptKind::None;
        void       submit(GfPrompt* prompt) override {
            ++submits;
            last = prompt;
            kind = pendingKind(prompt);
        }
        void withdraw(GfPrompt*) override {
            ++withdrawals;
        }
        void forget(GfPrompt*) override {
            ++forgotten;
        }
    };

    struct Outcome {
        bool        done = false;
        bool        hasPassword = false;
        std::string password;
        int         reply = -1;
        int         errorCode = 0;
    };

    void onPassword(GObject* source, GAsyncResult* result, gpointer data) {
        auto*        out   = static_cast<Outcome*>(data);
        GError*      error = nullptr;
        const gchar* pw    = gcr_prompt_password_finish(GCR_PROMPT(source), result, &error);
        out->done          = true;
        out->hasPassword   = pw != nullptr;
        if (pw)
            out->password = pw;
        out->errorCode = error ? error->code : 0;
        g_clear_error(&error);
    }

    void onConfirm(GObject* source, GAsyncResult* result, gpointer data) {
        auto*   out   = static_cast<Outcome*>(data);
        GError* error = nullptr;
        out->reply    = gcr_prompt_confirm_finish(GCR_PROMPT(source), result, &error);
        out->done     = true;
        out->errorCode = error ? error->code : 0;
        g_clear_error(&error);
    }

    void countNotify(GObject*, GParamSpec*, gpointer data) {
        ++*static_cast<int*>(data);
    }
} // namespace

TEST(PrompterPrompt, PasswordAnsweredThenWiped) {
    FakeSink  sink;
    GfPrompt* prompt = newPrompt(&sink);
    g_object_set(prompt, "title", "Unlock", "choice-label", "Remember", "password-new", TRUE, nullptr);
    int strength = 0, chosen = 0;
    g_signal_connect(prompt, "notify::password-strength", G_CALLBACK(countNotify), &strength);
    g_signal_connect(prompt, "notify::choice-chosen", G_CALLBACK(countNotify), &chosen);
    Outcome out;
    gcr_prompt_password_async(GCR_PROMPT(prompt), nullptr, onPassword, &out);
    EXPECT_EQ(sink.submits, 1);
    EXPECT_EQ(sink.kind, PromptKind::Password);
    const PromptFields f = promptFields(prompt);
    EXPECT_EQ(f.title, QStringLiteral("Unlock"));
    EXPECT_TRUE(f.passwordNew);
    answerConfirm(prompt, true, -1); // the wrong kind: nothing happens
    spin();
    EXPECT_FALSE(out.done);
    answerPassword(prompt, gcr_secure_memory_strdup("s3cret"), 1);
    for (int i = 0; i < 100 && !out.done; ++i)
        spin(1);
    ASSERT_TRUE(out.done);
    EXPECT_TRUE(out.hasPassword);
    EXPECT_EQ(out.password, "s3cret");
    EXPECT_EQ(strength, 1);
    EXPECT_EQ(chosen, 1);
    gint     reportedStrength = -1;
    gboolean reportedChoice   = FALSE;
    g_object_get(prompt, "password-strength", &reportedStrength, "choice-chosen", &reportedChoice, nullptr);
    EXPECT_EQ(reportedStrength, 1);
    EXPECT_TRUE(reportedChoice);
    // Wiped in a later turn (libgcr has encrypted it by then).
    spin();
    EXPECT_FALSE(holdsPassword(prompt));
    EXPECT_EQ(pendingKind(prompt), PromptKind::None);
    g_object_run_dispose(G_OBJECT(prompt));
    EXPECT_EQ(sink.forgotten, 1);
    g_object_unref(prompt);
}

TEST(PrompterPrompt, EmptyPasswordHasStrengthZeroAndCancelIsNoPassword) {
    FakeSink  sink;
    GfPrompt* prompt = newPrompt(&sink);
    Outcome   out;
    gcr_prompt_password_async(GCR_PROMPT(prompt), nullptr, onPassword, &out);
    answerPassword(prompt, gcr_secure_memory_strdup(""), 1); // no choice was shown: "choice-chosen" stays
    for (int i = 0; i < 100 && !out.done; ++i)
        spin(1);
    EXPECT_TRUE(out.hasPassword);
    EXPECT_EQ(out.password, "");
    gint     strength = -1;
    gboolean chosen   = TRUE;
    g_object_get(prompt, "password-strength", &strength, "choice-chosen", &chosen, nullptr);
    EXPECT_EQ(strength, 0);
    EXPECT_FALSE(chosen);
    Outcome cancelled;
    gcr_prompt_password_async(GCR_PROMPT(prompt), nullptr, onPassword, &cancelled);
    answerPassword(prompt, nullptr, -1); // the user's Cancel
    for (int i = 0; i < 100 && !cancelled.done; ++i)
        spin(1);
    EXPECT_TRUE(cancelled.done);
    EXPECT_FALSE(cancelled.hasPassword);
    EXPECT_EQ(cancelled.errorCode, 0);
    g_object_unref(prompt);
}

TEST(PrompterPrompt, ConfirmAnswers) {
    FakeSink  sink;
    GfPrompt* prompt = newPrompt(&sink);
    Outcome   yes;
    gcr_prompt_confirm_async(GCR_PROMPT(prompt), nullptr, onConfirm, &yes);
    EXPECT_EQ(sink.kind, PromptKind::Confirm);
    answerPassword(prompt, gcr_secure_memory_strdup("ignored"), -1); // wrong kind: zeroed and freed, nothing answered
    answerConfirm(prompt, true, -1);
    for (int i = 0; i < 100 && !yes.done; ++i)
        spin(1);
    EXPECT_EQ(yes.reply, GCR_PROMPT_REPLY_CONTINUE);
    Outcome no;
    gcr_prompt_confirm_async(GCR_PROMPT(prompt), nullptr, onConfirm, &no);
    answerConfirm(prompt, false, -1);
    for (int i = 0; i < 100 && !no.done; ++i)
        spin(1);
    EXPECT_EQ(no.reply, GCR_PROMPT_REPLY_CANCEL);
    g_object_unref(prompt);
}

TEST(PrompterPrompt, WithdrawnByTheCallerEndsCancelled) {
    FakeSink      sink;
    GfPrompt*     prompt      = newPrompt(&sink);
    GCancellable* cancellable = g_cancellable_new();
    Outcome       out;
    gcr_prompt_password_async(GCR_PROMPT(prompt), cancellable, onPassword, &out);
    EXPECT_EQ(sink.submits, 1);
    g_cancellable_cancel(cancellable); // gcr's StopPrompting, or the caller leaving the bus
    EXPECT_EQ(sink.withdrawals, 1);
    EXPECT_FALSE(out.done); // never inside the caller's own call
    for (int i = 0; i < 100 && !out.done; ++i)
        spin(1);
    EXPECT_TRUE(out.done);
    EXPECT_FALSE(out.hasPassword);
    EXPECT_EQ(out.errorCode, G_IO_ERROR_CANCELLED);
    // An answer that comes after it is not taken.
    answerPassword(prompt, gcr_secure_memory_strdup("late"), -1);
    spin();
    EXPECT_FALSE(holdsPassword(prompt));
    // Already cancelled when asked: never handed to the sink.
    Outcome early;
    gcr_prompt_password_async(GCR_PROMPT(prompt), cancellable, onPassword, &early);
    EXPECT_EQ(sink.submits, 1);
    for (int i = 0; i < 100 && !early.done; ++i)
        spin(1);
    EXPECT_EQ(early.errorCode, G_IO_ERROR_CANCELLED);
    g_object_unref(cancellable);
    // Closed while pending (gcr_prompt_close): withdrawn, cancelled.
    Outcome closed;
    gcr_prompt_confirm_async(GCR_PROMPT(prompt), nullptr, onConfirm, &closed);
    gcr_prompt_close(GCR_PROMPT(prompt));
    EXPECT_EQ(sink.withdrawals, 2);
    for (int i = 0; i < 100 && !closed.done; ++i)
        spin(1);
    EXPECT_EQ(closed.reply, GCR_PROMPT_REPLY_CANCEL);
    g_object_unref(prompt);
}

TEST(PrompterPrompt, NoSinkMeansCancelledAndTheCallerPropertyStaysPrivate) {
    GfPrompt* prompt = newPrompt(nullptr);
    Outcome   out;
    gcr_prompt_password_async(GCR_PROMPT(prompt), nullptr, onPassword, &out);
    for (int i = 0; i < 100 && !out.done; ++i)
        spin(1);
    EXPECT_TRUE(out.done);
    EXPECT_FALSE(out.hasPassword);
    g_object_set(prompt, kCallerProperty, ":1.9", nullptr);
    EXPECT_EQ(promptCaller(prompt), QStringLiteral(":1.9"));
    // Not one of GcrPrompt's properties: libgcr never echoes it back to a caller.
    EXPECT_EQ(g_object_interface_find_property(g_type_default_interface_peek(GCR_TYPE_PROMPT), kCallerProperty), nullptr);
    EXPECT_NE(g_object_class_find_property(G_OBJECT_GET_CLASS(prompt), kCallerProperty), nullptr);
    g_object_unref(prompt);
}

int main(int argc, char** argv) {
    ::testing::InitGoogleTest(&argc, argv);
    return RUN_ALL_TESTS();
}
