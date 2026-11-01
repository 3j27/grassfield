// A screen-sharing stream made the way xdg-desktop-portal-hyprland 1.4.1 makes one (src/portals/Screencopy.cpp:693, 1015-1017:
// pw_context_new with no properties, then pw_stream_new(core, "xdph-streaming-<random>", {media.class = Video/Source})), for
// tests/shell/share_picker_ipc.sh: built there as a program named xdg-desktop-portal-hyprland, so that PipeWire derives the
// node's properties from the program's name exactly as for xdph (node.name from application.name; the stream's name only in
// media.name). It offers one video format, connects as a driver, and runs until SIGTERM or SIGINT.
#include <pipewire/pipewire.h>
#include <signal.h>
#include <spa/param/video/format-utils.h>

static struct pw_main_loop *loop;

static void quit(void *data, int sig) {
    (void)data;
    (void)sig;
    pw_main_loop_quit(loop);
}

int main(int argc, char **argv) {
    pw_init(&argc, &argv);
    loop = pw_main_loop_new(NULL);
    if (!loop)
        return 1;
    pw_loop_add_signal(pw_main_loop_get_loop(loop), SIGTERM, quit, NULL);
    pw_loop_add_signal(pw_main_loop_get_loop(loop), SIGINT, quit, NULL);
    struct pw_context *context = pw_context_new(pw_main_loop_get_loop(loop), NULL, 0);
    struct pw_core *core = context ? pw_context_connect(context, NULL, 0) : NULL;
    if (!core)
        return 1;
    struct pw_stream *stream = pw_stream_new(core, argc > 1 ? argv[1] : "xdph-streaming-test",
                                             pw_properties_new(PW_KEY_MEDIA_CLASS, "Video/Source", NULL));
    uint8_t buffer[1024];
    struct spa_pod_builder builder = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));
    const struct spa_pod *params[1];
    params[0] = spa_pod_builder_add_object(&builder, SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
                                           SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
                                           SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
                                           SPA_FORMAT_VIDEO_format, SPA_POD_Id(SPA_VIDEO_FORMAT_BGRx),
                                           SPA_FORMAT_VIDEO_size, SPA_POD_Rectangle(&SPA_RECTANGLE(64, 64)),
                                           SPA_FORMAT_VIDEO_framerate, SPA_POD_Fraction(&SPA_FRACTION(0, 1)));
    if (!stream || pw_stream_connect(stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
                                     PW_STREAM_FLAG_DRIVER | PW_STREAM_FLAG_ALLOC_BUFFERS, params, 1) < 0)
        return 1;
    pw_main_loop_run(loop);
    pw_stream_destroy(stream);
    pw_core_disconnect(core);
    pw_context_destroy(context);
    pw_main_loop_destroy(loop);
    return 0;
}
