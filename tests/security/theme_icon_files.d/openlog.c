// LD_PRELOAD shim for tests/security/theme_icon_files.sh: logs every open/openat/fopen as "OPEN <pid> <flags> <path>" to
// the file named by $OPENLOG (appended; children inherit the variable, and their standard error is not the test's),
// then calls the real function. The test checks that no process of the shell opens a file in a
// user-writable icon folder, except the ThemeIcons copy helper with O_NOFOLLOW|O_NONBLOCK (or a directory listing).
#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void logOpen(const char *path, int flags)
{
    static int fd = -2;
    if (!path)
        return;
    if (fd == -2) {
        const char *file = getenv("OPENLOG");
        static int (*real)(const char *, int, ...);
        if (!real)
            real = dlsym(RTLD_NEXT, "open");
        fd = file ? real(file, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0600) : -1;
    }
    if (fd < 0)
        return;
    char line[4352];
    int n = snprintf(line, sizeof line, "OPEN %d %d %s\n", (int)getpid(), flags, path);
    if (n > 0)
        (void)!write(fd, line, n < (int)sizeof line ? (size_t)n : sizeof line - 1);
}

#define MODE_ARG(flags, mode) \
    do { \
        if ((flags) & (O_CREAT | O_TMPFILE)) { \
            va_list args; \
            va_start(args, flags); \
            mode = va_arg(args, int); \
            va_end(args); \
        } \
    } while (0)

int open(const char *path, int flags, ...)
{
    static int (*real)(const char *, int, ...);
    if (!real)
        real = dlsym(RTLD_NEXT, "open");
    mode_t mode = 0;
    MODE_ARG(flags, mode);
    logOpen(path, flags);
    return real(path, flags, mode);
}

int open64(const char *path, int flags, ...)
{
    static int (*real)(const char *, int, ...);
    if (!real)
        real = dlsym(RTLD_NEXT, "open64");
    mode_t mode = 0;
    MODE_ARG(flags, mode);
    logOpen(path, flags);
    return real(path, flags, mode);
}

int openat(int dir, const char *path, int flags, ...)
{
    static int (*real)(int, const char *, int, ...);
    if (!real)
        real = dlsym(RTLD_NEXT, "openat");
    mode_t mode = 0;
    MODE_ARG(flags, mode);
    logOpen(path, flags);
    return real(dir, path, flags, mode);
}

int openat64(int dir, const char *path, int flags, ...)
{
    static int (*real)(int, const char *, int, ...);
    if (!real)
        real = dlsym(RTLD_NEXT, "openat64");
    mode_t mode = 0;
    MODE_ARG(flags, mode);
    logOpen(path, flags);
    return real(dir, path, flags, mode);
}

FILE *fopen(const char *path, const char *how)
{
    static FILE *(*real)(const char *, const char *);
    if (!real)
        real = dlsym(RTLD_NEXT, "fopen");
    logOpen(path, -1);
    return real(path, how);
}

FILE *fopen64(const char *path, const char *how)
{
    static FILE *(*real)(const char *, const char *);
    if (!real)
        real = dlsym(RTLD_NEXT, "fopen64");
    logOpen(path, -1);
    return real(path, how);
}
