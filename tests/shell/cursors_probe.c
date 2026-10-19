// Probe for tests/shell/cursors.sh: asks libhyprcursor (the library Hyprland uses) for the hotspot of each shape at
// each size, so that the test compares what the compositor sees with the XCursor files.
//
//   cursors_probe THEME "24 32 48" SHAPE...      (XCURSOR_PATH selects the icons directory)
// Prints "SHAPE SIZE HOTSPOT_X HOTSPOT_Y" per line, or "SHAPE SIZE MISSING".
#include <hyprcursor/hyprcursor.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char** argv) {
    if (argc < 4)
        return 2;
    struct hyprcursor_manager_t* m = hyprcursor_manager_create(argv[1]);
    if (!m || !hyprcursor_manager_valid(m)) {
        fprintf(stderr, "theme %s invalid\n", argv[1]);
        return 1;
    }
    for (int i = 3; i < argc; i++) {
        for (const char* s = argv[2]; *s;) {
            char*    end;
            unsigned size = strtoul(s, &end, 10);
            if (end == s)
                break;
            s = end;
            while (*s == ' ' || *s == ',')
                s++;
            struct hyprcursor_cursor_style_info info = {size};
            hyprcursor_load_theme_style(m, info);
            int                        n = 0;
            hyprcursor_cursor_image_data** d = hyprcursor_get_cursor_image_data(m, argv[i], info, &n);
            if (!d || n < 1) {
                printf("%s %u MISSING\n", argv[i], size);
                continue;
            }
            printf("%s %u %d %d\n", argv[i], size, d[0]->hotspotX, d[0]->hotspotY);
            hyprcursor_cursor_image_data_free(d, n);
            hyprcursor_style_done(m, info);
        }
    }
    hyprcursor_manager_free(m);
    return 0;
}
