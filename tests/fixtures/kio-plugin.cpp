// A worker plugin of the user's own, for tests/security/kio_passwd.sh (ADR-0035 D-12 b, step 9e; the security review of
// step 9e, MINOR-2, from the reviewer's probe): KIO's worker executable loads whatever library its command line names
// (KIO 6.31.0 kioworker.cpp:49-65), so `/usr/lib/kf6/kioworker <this .so> smb x y` runs this code as kioworker. Its
// kdemain asks org.kde.kpasswdserver6 for smb://plugin.example/share, as a worker would, and prints "plugin result
// modified=<0|1>" when the result comes (at most 20 s). Built by that test from the user's files (never root's); never
// installed. Test data only.
#include <gio/gio.h>

#include <cstdio>

namespace {
    GMainLoop* loop = nullptr;

    void onResult(GDBusConnection*, const gchar*, const gchar*, const gchar*, const gchar*, GVariant* parameters, gpointer) {
        gint64    requestId = 0;
        gint64    seqNr     = 0;
        GVariant* info      = nullptr;
        g_variant_get(parameters, "(xx@(ysssssssssbbbba{s(siv)}))", &requestId, &seqNr, &info);
        gboolean modified = FALSE;
        g_variant_get_child(info, 13, "b", &modified);
        std::printf("plugin result modified=%d\n", modified ? 1 : 0);
        std::fflush(stdout);
        g_variant_unref(info);
        g_main_loop_quit(loop);
    }
} // namespace

extern "C" __attribute__((visibility("default"))) int kdemain(int, char**) {
    GError*          error = nullptr;
    GDBusConnection* bus   = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
    if (!bus) {
        std::printf("plugin no bus\n");
        return 1;
    }
    loop = g_main_loop_new(nullptr, FALSE);
    g_dbus_connection_signal_subscribe(bus, nullptr, "org.kde.KPasswdServer", "queryAuthInfoAsyncResult", "/modules/kpasswdserver", nullptr,
                                       G_DBUS_SIGNAL_FLAGS_NONE, onResult, nullptr, nullptr);
    GVariantBuilder extra;
    g_variant_builder_init(&extra, G_VARIANT_TYPE("a{s(siv)}"));
    GVariant* info  = g_variant_new("(ysssssssssbbbb@a{s(siv)})", static_cast<guchar>(1), "smb://plugin.example/share", "", "", "", "", "", "", "", "",
                                    FALSE, FALSE, TRUE, FALSE, g_variant_builder_end(&extra));
    GVariant* reply = g_dbus_connection_call_sync(bus, "org.kde.kpasswdserver6", "/modules/kpasswdserver", "org.kde.KPasswdServer", "queryAuthInfoAsync",
                                                  g_variant_new("(@(ysssssssssbbbba{s(siv)})sxxx)", info, "", static_cast<gint64>(0),
                                                                static_cast<gint64>(0), static_cast<gint64>(0)),
                                                  G_VARIANT_TYPE("(x)"), G_DBUS_CALL_FLAGS_NO_AUTO_START, 5000, nullptr, &error);
    if (!reply) {
        std::printf("plugin call failed\n");
        return 1;
    }
    g_variant_unref(reply);
    g_timeout_add_seconds(20, [](gpointer) -> gboolean {
        g_main_loop_quit(loop);
        return G_SOURCE_REMOVE;
    }, nullptr);
    g_main_loop_run(loop);
    return 0;
}
