// One KIO job, as Files starts them (KIO::stat, no progress window), for tests/security/kio_passwd.sh (ADR-0035 D-12 b, step
// 9e): KIO spawns its real worker executable (/usr/lib/kf6/kioworker) for the URL's protocol, and the worker asks
// org.kde.kpasswdserver6 for a login as it would for a real server (the job has a UI delegate, as Files' jobs have). Built by that test against the installed KF6 KIOCore;
// never installed. Prints "stat ok" or "stat error <code>" and exits 0 or 1.
#include <KIO/StatJob>
#include <KJobUiDelegate>

#include <QCoreApplication>
#include <QUrl>

#include <cstdio>

int main(int argc, char** argv) {
    QCoreApplication app(argc, argv);
    if (argc != 2) {
        std::fprintf(stderr, "usage: kio-stat URL\n");
        return 2;
    }
    KIO::StatJob* job = KIO::stat(QUrl(QString::fromLocal8Bit(argv[1])), KIO::StatJob::SourceSide, KIO::StatBasic, KIO::HideProgressInfo);
    // A job with a UI delegate is interactive, as Files' are: without one KIO tells the worker not to ask (simplejob.cpp:161-163).
    job->setUiDelegate(new KJobUiDelegate);
    const bool    ok  = job->exec();
    if (ok)
        std::printf("stat ok\n");
    else
        std::printf("stat error %d\n", job->error());
    std::fflush(stdout);
    return ok ? 0 : 1;
}
