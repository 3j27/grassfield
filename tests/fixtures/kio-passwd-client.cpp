// KIO's REAL password-server client (KF6 KIOCore's KPasswdServerClient, the one every KIO worker uses) driven line by line,
// for tests/security/kio_passwd.sh (ADR-0035 D-12 b, step 9e). Built by that test against the installed KF6 KIOCore; never
// installed. One client object for the whole run, as a worker keeps one: its sequence number follows the host it last asked
// for (kpasswdserverclient.cpp:76-79).
//
// Commands on standard input, one per line (fields separated by single spaces; "-" for an empty field):
//   check <url> [user]                         checkAuthInfo
//   query <url> <user> <error|-> [flags...]    queryAuthInfo; flags: keep (keepPassword), readonly, noprompt (errorMsg
//                                              "<NoAuthPrompt>"), skipcache (skip-caching-on-query, as openPasswordDialogV2),
//                                              hidename (hide-username-line), anon (the "anonymous" field, true), realm=<r>,
//                                              window=<n>
//   add <url> <user> <password> [flags...]     addAuthInfo; flags: keep, realm=<r>, window=<n>
//   remove <host> <protocol> <user|->          removeAuthInfo
//   quit
// Each command prints one line, flushed: "check modified=<0|1> user=<u> password=<p>", "query rc=<n> modified=<0|1>
// user=<u> password=<p> keep=<0|1> anon=<present:value> url=<url>", "add done", "remove done". Test passwords only: this
// world is the test's private bus.
#include <KPasswdServerClient>
#include <kio/authinfo.h>

#include <QCoreApplication>
#include <QStringList>
#include <QUrl>

#include <cstdio>
#include <iostream>
#include <string>

namespace {
    QString field(const QStringList& words, int i) {
        if (i >= words.size() || words.at(i) == QLatin1String("-"))
            return {};
        return words.at(i);
    }

    QString line(const KIO::AuthInfo& info) {
        const QVariant anon = info.getExtraField(QStringLiteral("anonymous"));
        return QStringLiteral("modified=%1 user=%2 password=%3 keep=%4 anon=%5 url=%6")
            .arg(info.isModified() ? 1 : 0)
            .arg(info.username.isEmpty() ? QStringLiteral("-") : info.username, info.password.isEmpty() ? QStringLiteral("-") : info.password)
            .arg(info.keepPassword ? 1 : 0)
            .arg(anon.isValid() ? (anon.toBool() ? QStringLiteral("true") : QStringLiteral("false")) : QStringLiteral("none"), info.url.toString());
    }

    void say(const QString& text) {
        std::printf("%s\n", text.toUtf8().constData());
        std::fflush(stdout);
    }
} // namespace

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    KPasswdServerClient client;
    std::string         input;
    while (std::getline(std::cin, input)) {
        const QStringList words = QString::fromStdString(input).split(u' ');
        const QString     op    = words.value(0);
        if (op == QLatin1String("quit"))
            break;
        KIO::AuthInfo info;
        qlonglong     window = 0;
        for (int i = 2; i < words.size(); ++i) {
            const QString w = words.at(i);
            if (w == QLatin1String("keep"))
                info.keepPassword = true;
            else if (w == QLatin1String("readonly"))
                info.readOnly = true;
            else if (w == QLatin1String("skipcache"))
                info.setExtraField(QStringLiteral("skip-caching-on-query"), true);
            else if (w == QLatin1String("hidename"))
                info.setExtraField(QStringLiteral("hide-username-line"), true);
            else if (w == QLatin1String("anon"))
                info.setExtraField(QStringLiteral("anonymous"), true);
            else if (w.startsWith(QLatin1String("realm=")))
                info.realmValue = w.mid(6);
            else if (w.startsWith(QLatin1String("window=")))
                window = w.mid(7).toLongLong();
        }
        if (op == QLatin1String("check")) {
            info.url      = QUrl(field(words, 1));
            info.username = field(words, 2);
            const bool found = client.checkAuthInfo(&info, window, 0);
            say(QStringLiteral("check found=%1 ").arg(found ? 1 : 0) + line(info));
        } else if (op == QLatin1String("query")) {
            info.url      = QUrl(field(words, 1));
            info.username = field(words, 2);
            QString error = field(words, 3);
            if (words.contains(QStringLiteral("noprompt")))
                error = QStringLiteral("<NoAuthPrompt>");
            const int rc = client.queryAuthInfo(&info, error.replace(u'_', u' '), window, 0);
            say(QStringLiteral("query rc=%1 ").arg(rc) + line(info));
        } else if (op == QLatin1String("add")) {
            info.url      = QUrl(field(words, 1));
            info.username = field(words, 2);
            info.password = field(words, 3);
            for (int i = 4; i < words.size(); ++i) {
                if (words.at(i) == QLatin1String("keep"))
                    info.keepPassword = true;
            }
            client.addAuthInfo(info, window);
            say(QStringLiteral("add done"));
        } else if (op == QLatin1String("remove")) {
            client.removeAuthInfo(field(words, 1), field(words, 2), field(words, 3));
            say(QStringLiteral("remove done"));
        } else {
            say(QStringLiteral("unknown %1").arg(op));
        }
    }
    return 0;
}
