#pragma once

// prompter/1: JSON lines between grassfield-prompter and the shell (ADR-0035 D-9, docs/specs/system-dialogs.md section 5
// "prompter/1 protocol"). Pure logic (QtCore only), unit-tested in tests/unit/prompter/.
//
// bridge -> shell (one JSON object per line):
//   {"v":"prompter/1","type":"hello","bridge":"<version>","kinds":["password","confirm"],"max":8}
//   {"type":"name","state":"released"|"queued"|"owned"}
//   {"type":"prompt","id":"p<N>","kind":"password"|"confirm",
//    "requester":{"role":"app"|"keyring"|"gnupg"|"ssh"|"disk"|"unidentified","name":"...","desktopId":"...","icon":"...","path":"...",
//                 "identified":true|false,"onBehalf":true|false},
//    "texts":{"title":"...","message":"...","description":"...","warning":"...","continue":"...","cancel":"..."},
//    "choice":{"label":"...","chosen":true|false}|null,"passwordNew":true|false,"strength":true|false}
//   {"type":"prompt","id":"p<N>","kind":"nm",                                     (step 9c: NetworkManager's secrets)
//    "network":{"ssid":"...","security":"wpa"|"wpa3"|"wep"|"enterprise","identity":"..."}}
//   {"type":"prompt","id":"p<N>","kind":"kio","requester":{...as above, role "kio" too...}, (step 9e: KIO's passwords)
//    "server":"<host>[:<port>]",
//    "login":{"name":"...","nameMode":"edit"|"fixed"|"none","realm":"...","retry":true|false,"remember":"none"|"off"|"on",
//             "keyring":"protected"|"unprotected"|"unknown"}}
//   {"type":"cancel","id":"p<N>"}
//   {"type":"error","code":"<code>","message":"<text>"}
// shell -> bridge (at most limits::kShellLine bytes per line, the newline excluded):
//   {"v":"prompter/1","type":"hello","shell":"<version>","kinds":["password","confirm","nm"]} (first line, once)
//   {"type":"answer","id":"p<N>","result":"ok"|"cancel"|"refused","password":"...","choice":true|false,"identity":"..."}
//   ("refused": the shell could not take the request (its bound); "identity" only for a kio request of nameMode "edit"
//   answered ok: an nm reply carries the password only, an nm answer with a name is cancelled (opus review of step 9c);
//   for kio, "choice" is "Remember this password", only when it was offered, and a cancel or a refusal carries nothing)
//
// Everything the shell sends is untrusted: a strict parser for flat objects (strings, booleans, null, arrays of strings;
// no numbers, no nesting, no duplicate keys, valid UTF-8, no NUL), every key and type checked. The password is never
// decoded by the parser: the line keeps its raw (escaped) bytes and the bridge decodes them straight into gcr's secure
// memory (decodeJsonString), then wipes the line.

#include <QByteArray>
#include <QString>
#include <QStringList>

#include <cstddef>
#include <functional>
#include <string>
#include <string_view>
#include <vector>

namespace gf::prompter {

    inline constexpr char kProtocol[]      = "prompter/1";
    inline constexpr char kBridgeVersion[] = GRASSFIELD_VERSION;

    namespace limits {
        inline constexpr std::size_t kShellLine   = 16384; // bytes of one shell -> bridge line (newline excluded)
        inline constexpr std::size_t kPassword    = 4096;  // bytes of a password, UTF-8, after decoding
        inline constexpr std::size_t kIdentity    = 1024;  // bytes of an nm answer's identity (a name), UTF-8, after decoding
        inline constexpr int         kRequests    = 8;     // secret requests outstanding at the shell (ADR-0035 D-9)
        inline constexpr int         kPrompts     = 64;    // gcr prompts open at the same time (BeginPrompting without StopPrompting)
        inline constexpr int         kPromptsPerCaller = 8; // of which one bus connection may hold (security review of step 9a, NIT-2)
        inline constexpr int         kBadLines    = 8;     // invalid lines tolerated per shell connection
        inline constexpr int         kKinds       = 16;    // entries of a hello's "kinds"
        inline constexpr int         kShortString = 64;    // bytes of an id, a kind, a version, a result
        inline constexpr qsizetype   kPendingOut  = 1024 * 1024; // bytes waiting for a shell that does not read: it is dropped
    } // namespace limits

    // --- the strict flat JSON object -----------------------------------------------------------------------------------

    struct JsonString {
        std::size_t begin = 0; // offsets in the line of the raw bytes between the quotes, escapes not decoded
        std::size_t end   = 0;
    };

    struct JsonValue {
        enum class Type { String, Bool, Null, Array };
        Type                    type    = Type::Null;
        JsonString              string;
        bool                    boolean = false;
        std::vector<JsonString> items; // Array: strings only
    };

    struct JsonMember {
        std::string key;
        JsonValue   value;
    };

    // Parses `line` as one JSON object whose values are strings, true, false, null or arrays of strings (at most
    // limits::kKinds), with at most 16 members, ASCII keys of at most 32 bytes and no duplicate key. Strings must be
    // valid UTF-8 and their escapes valid (a \u surrogate must be paired; \u0000 is refused). Only white space may follow
    // the object. False with *error set otherwise.
    bool parseFlatObject(std::string_view line, std::vector<JsonMember>* members, QString* error);

    // Decodes the raw bytes of a JSON string (between its quotes, as parseFlatObject validated them) into `out`, which
    // has room for `capacity` bytes, and returns the decoded length; -1 when it does not fit, a byte or escape is not
    // valid, or the text holds a NUL. With out == nullptr only the length is computed (capacity still bounds it).
    long decodeJsonString(const char* raw, std::size_t size, char* out, std::size_t capacity);

    // --- shell -> bridge ---------------------------------------------------------------------------------------------

    // The complete lines at the start of `buffer` (`length` bytes read from the shell, the last line possibly incomplete):
    // each is handed to `handle` without its newline, then wiped with its newline before the next one is handed (a password
    // answer must not stay behind); the incomplete rest is moved to the start and the bytes it leaves behind are wiped too.
    // Returns the rest's length.
    // `handle` returns false when the connection was dropped (whoever dropped it wiped the buffer): nothing more is read,
    // moved or wiped, and 0 is returned. Pure; the bridge's reading of the socket (Bridge::onClientReadable) and the unit
    // tests use it (the integrator's review of PR #95: the line wiping had no test).
    std::size_t takeLines(char* buffer, std::size_t length, const std::function<bool(std::string_view line)>& handle);

    enum class ParseStatus {
        Ok,        // a message the bridge understands
        Malformed, // not one JSON object of the allowed shape, or an answer without a usable id: nothing to attribute it to
        Invalid,   // an answer with a usable id whose other fields are wrong: that request is cancelled
        Unknown,   // a well-formed object of another type
        Version,   // a hello of another protocol version
    };

    struct ShellLine {
        enum class Type { Hello, Answer };
        Type        type = Type::Hello;
        // hello
        QString     shell;
        QStringList kinds;
        // answer
        QString     id;
        bool        ok          = false;
        bool        refused     = false; // result "refused": the shell could not take it (ok is false)
        bool        hasPassword = false;
        JsonString  password; // raw bytes in the line; decoded length checked against limits::kPassword
        bool        hasChoice   = false;
        bool        choice      = false;
        bool        hasIdentity = false;
        JsonString  identity; // raw bytes in the line; decoded length checked against limits::kIdentity
    };

    // Parses one shell line (the newline excluded). On Invalid, out->id names the request concerned.
    ParseStatus parseShellLine(std::string_view line, ShellLine* out, QString* error);

    // A request id the bridge hands out: "p" and a decimal number without leading zero (at most 19 digits).
    bool validRequestId(const QString& id);

    // --- bridge -> shell ---------------------------------------------------------------------------------------------

    struct RequesterView {
        QString role = QStringLiteral("unidentified"); // app, keyring, gnupg, ssh, disk (step 9c), kio (step 9e), unidentified
        QString name;
        QString desktopId;
        QString icon;
        QString path;
        bool    identified = false;
        bool    onBehalf   = false;
    };

    struct PromptView {
        QString       id;
        QString       kind; // password, confirm
        RequesterView requester;
        QString       title, message, description, warning, continueLabel, cancelLabel;
        bool          hasChoice   = false;
        QString       choiceLabel;
        bool          choiceChosen = false;
        bool          passwordNew  = false;
    };

    // A NetworkManager request (kind "nm", step 9c): the network's SSID (flattened), its security ("wpa", "wpa3", "wep",
    // "enterprise") and, for enterprise, the connection's identity as the name field's first text. No requester object:
    // the bridge sends this kind only for a call whose sender is the current owner of org.freedesktop.NetworkManager on
    // the system bus, so the kind itself is the bridge's word on who asks.
    struct NmPromptView {
        QString id;
        QString ssid;
        QString security;
        QString identity;
    };

    // A KIO request (kind "kio", step 9e): who asks (resolved from the caller's credentials, as for gcr: a KIO worker is the
    // role "kio"), the server (a host name and its port only: KioAuth.h serverLabel), the name field's first text and whether
    // it can be changed ("edit"), only shown ("fixed", the caller's readOnly) or absent ("none", hide-username-line), the
    // realm (the server's own words, plain, capped), whether the last name and password failed (the worker's message itself
    // is never sent), "Remember this password" ("none": not offered; "off" or "on": its first state) and the protection of
    // the keyring that would receive it.
    struct KioPromptView {
        QString       id;
        RequesterView requester;
        QString       server;
        QString       name;
        QString       nameMode;
        QString       realm;
        bool          retry = false;
        QString       remember;
        QString       keyring;
    };

    QByteArray helloMessage(const QStringList& kinds);
    QByteArray nameMessage(const QString& state);
    QByteArray promptMessage(const PromptView& prompt);
    QByteArray nmPromptMessage(const NmPromptView& prompt);
    QByteArray kioPromptMessage(const KioPromptView& prompt);
    QByteArray cancelMessage(const QString& id);
    QByteArray errorMessage(const QString& code, const QString& message);

} // namespace gf::prompter
