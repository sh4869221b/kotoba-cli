#define _GNU_SOURCE
#include <dlfcn.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

// Wait only on the first matching call in the instrumented CLI subprocess.
static void wait_at_path(const char *variable, const char *path) {
    static int paused;
    const char *target = getenv(variable);
    if (paused || !target || strcmp(target, path) != 0) {
        return;
    }
    paused = 1;
    const int ready = atoi(getenv("KOTOBA_TEST_GATE_READY"));
    const int resume = atoi(getenv("KOTOBA_TEST_GATE_RESUME"));
    char marker = 'R';
    if (write(ready, &marker, 1) != 1 || read(resume, &marker, 1) != 1) {
        _exit(125);
    }
}

int renameat(int source_dir, const char *source, int target_dir, const char *target) {
    int (*real_renameat)(int, const char *, int, const char *) = dlsym(RTLD_NEXT, "renameat");
    wait_at_path("KOTOBA_TEST_GATE_RENAME", target);
    return real_renameat(source_dir, source, target_dir, target);
}

int openat64(int dir, const char *path, int flags, ...) {
    int (*real_openat64)(int, const char *, int, ...) = dlsym(RTLD_NEXT, "openat64");
    if (!(flags & O_PATH) && (flags & O_ACCMODE) == O_RDONLY) {
        wait_at_path("KOTOBA_TEST_GATE_OPEN", path);
    }
    if ((flags & O_CREAT) || (flags & O_TMPFILE) == O_TMPFILE) {
        va_list arguments;
        va_start(arguments, flags);
        mode_t mode = va_arg(arguments, mode_t);
        va_end(arguments);
        return real_openat64(dir, path, flags, mode);
    }
    return real_openat64(dir, path, flags);
}
