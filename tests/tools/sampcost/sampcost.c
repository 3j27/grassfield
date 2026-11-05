// Activity monitor probe A10 (ADR-0038, step 0, after the review of e3882de): the CPU cost of one sample, read by read and
// tab by tab, measured in C on the sampler's own clock (CLOCK_THREAD_CPUTIME_ID), so the gates AM-P1 and AM-P2 rest on
// measured numbers. A probe tool, not product code; tests/apps/activity_cost.sh builds and runs it.
//   sampcost spawn N T F   N idle processes with T threads and F extra open descriptors each (waits for ever)
//   sampcost tcp K         K loopback TCP connections in one process, a few kilobytes sent on each (waits for ever)
//   sampcost measure R [PGID]  R samples of each read pattern; prints the median CPU time of one sample. With PGID (the
//                          bench's changing fixture, activity_cost.sh --changing): the one-pass Disk line is measured with
//                          that process group poked between two rounds, as the bench pokes it between two samples
#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <linux/inet_diag.h>
#include <linux/netlink.h>
#include <linux/sock_diag.h>
#include <netinet/in.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <signal.h>
#include <time.h>
#include <unistd.h>

static char buf[1 << 16];

static double cpu_ms(void)
{
    struct timespec t;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &t);
    return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void *idle_thread(void *arg)
{
    (void)arg;
    for (;;)
        pause();
    return NULL;
}

typedef struct {
    int pid;
    int own;
    int statfd, statusfd, statmfd, iofd;
} proc_t;

static proc_t procs[16384];
static int nprocs;
static long nthreads_seen, nfds_seen, nsockets_seen;

static proc_t old[16384];
// Files or lists that could not be opened: out of descriptors (EMFILE, ENFILE; step 1: at a soft limit of 1024), which
// makes the figures too low, apart from the kernel's refusals (EACCES and the like: pid 1's fd/, a non-dumpable agent's),
// which every run has (review of f68789c).
static long open_failures, open_refusals;
static void count_failure(void)
{
    if (errno == EMFILE || errno == ENFILE)
        open_failures++;
    else
        open_refusals++;
}

// Step 1 (the review of 949fc98): the kept stat, status and statm of every process need about three descriptors a process,
// more than the session's soft limit of 1024 on the reference fixture; past it every later open failed and the probe read
// nothing of the threads, the descriptor lists or the sockets. The soft limit is raised as the app raises its own.
static void raise_nofile(void)
{
    struct rlimit r;
    if (getrlimit(RLIMIT_NOFILE, &r) != 0 || r.rlim_cur >= 16384 || r.rlim_cur >= r.rlim_max)
        return;
    rlim_t was = r.rlim_cur;
    r.rlim_cur = r.rlim_max < 16384 ? r.rlim_max : 16384;
    if (setrlimit(RLIMIT_NOFILE, &r) == 0)
        printf("  soft RLIMIT_NOFILE raised from %llu to %llu\n", (unsigned long long)was, (unsigned long long)r.rlim_cur);
}

// The /proc listing every sample needs (new processes appear, ended ones go); the owner from the directory's uid. /proc
// lists pids in increasing order, so the kept descriptors carry over by one merge pass.
static void list_procs(void)
{
    DIR *d = opendir("/proc");
    struct dirent *e;
    uid_t me = getuid();
    int kept = nprocs, j = 0;
    memcpy(old, procs, sizeof(proc_t) * (size_t)kept);
    nprocs = 0;
    while ((e = readdir(d))) {
        if (e->d_name[0] < '1' || e->d_name[0] > '9')
            continue;
        int pid = atoi(e->d_name);
        struct stat st;
        if (fstatat(dirfd(d), e->d_name, &st, 0) != 0)
            continue;
        proc_t p = {pid, st.st_uid == me, -1, -1, -1, -1};
        for (; j < kept && old[j].pid < pid; j++) { // ended: its descriptors go
            if (old[j].statfd >= 0)
                close(old[j].statfd);
            if (old[j].statusfd >= 0)
                close(old[j].statusfd);
            if (old[j].statmfd >= 0)
                close(old[j].statmfd);
            if (old[j].iofd >= 0)
                close(old[j].iofd);
        }
        if (j < kept && old[j].pid == pid) {
            p.statfd = old[j].statfd;
            p.statusfd = old[j].statusfd;
            p.statmfd = old[j].statmfd;
            p.iofd = old[j].iofd;
        }
        procs[nprocs++] = p;
    }
    closedir(d);
}

static int read_at(int dir, const char *name)
{
    int fd = openat(dir, name, O_RDONLY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    ssize_t n = read(fd, buf, sizeof buf);
    close(fd);
    return (int)n;
}

static int read_path(const char *path)
{
    return read_at(AT_FDCWD, path);
}

static void stat_status_open(void)
{
    char p[64];
    for (int i = 0; i < nprocs; i++) {
        snprintf(p, sizeof p, "/proc/%d/stat", procs[i].pid);
        read_path(p);
        snprintf(p, sizeof p, "/proc/%d/status", procs[i].pid);
        read_path(p);
    }
}

static void stat_status_kept(void)
{
    char p[64];
    for (int i = 0; i < nprocs; i++) {
        if (procs[i].statfd < 0) {
            snprintf(p, sizeof p, "/proc/%d/stat", procs[i].pid);
            procs[i].statfd = open(p, O_RDONLY | O_CLOEXEC);
            snprintf(p, sizeof p, "/proc/%d/status", procs[i].pid);
            procs[i].statusfd = open(p, O_RDONLY | O_CLOEXEC);
        }
        if (procs[i].statfd >= 0 && pread(procs[i].statfd, buf, sizeof buf, 0) < 0)
            continue;
        if (procs[i].statusfd >= 0 && pread(procs[i].statusfd, buf, sizeof buf, 0) < 0)
            continue;
    }
}

// One kept file per process, re-read with pread: which = 0 stat, 1 status, 2 statm.
static void kept_one(int which)
{
    static const char *names[] = {"stat", "status", "statm"};
    char p[64];
    for (int i = 0; i < nprocs; i++) {
        int *fd = which == 0 ? &procs[i].statfd : which == 1 ? &procs[i].statusfd : &procs[i].statmfd;
        if (*fd < 0) {
            snprintf(p, sizeof p, "/proc/%d/%s", procs[i].pid, names[which]);
            *fd = open(p, O_RDONLY | O_CLOEXEC);
            if (*fd < 0)
                count_failure();
        }
        if (*fd >= 0 && pread(*fd, buf, sizeof buf, 0) < 0)
            continue;
    }
}

static void kept_stat(void) { kept_one(0); }
static void kept_status(void) { kept_one(1); }
static void kept_statm(void) { kept_one(2); }

static void io_own(void)
{
    char p[64];
    for (int i = 0; i < nprocs; i++)
        if (procs[i].own) {
            snprintf(p, sizeof p, "/proc/%d/io", procs[i].pid);
            read_path(p);
        }
}

// Step 1's plan (review of f68789c: like for like with the sampler): io kept open and re-read with pread.
static void io_kept(void)
{
    char p[64];
    for (int i = 0; i < nprocs; i++) {
        if (!procs[i].own)
            continue;
        if (procs[i].iofd < 0) {
            snprintf(p, sizeof p, "/proc/%d/io", procs[i].pid);
            procs[i].iofd = open(p, O_RDONLY | O_CLOEXEC);
            if (procs[i].iofd < 0)
                count_failure();
        }
        if (procs[i].iofd >= 0 && pread(procs[i].iofd, buf, sizeof buf, 0) < 0)
            continue;
    }
}

// Step 1's plan: the listing without an fstatat per process, and the owners (fstatat) of every process, of which a sample
// does a tenth (AD33).
static void list_names(void)
{
    DIR *d = opendir("/proc");
    struct dirent *e;
    long n = 0;
    while ((e = readdir(d)))
        if (e->d_name[0] >= '1' && e->d_name[0] <= '9')
            n++;
    closedir(d);
    (void)n;
}

static void owners_all(void)
{
    static int dir = -1;
    char name[16];
    struct stat st;
    if (dir < 0)
        dir = open("/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    for (int i = 0; i < nprocs; i++) {
        snprintf(name, sizeof name, "%d", procs[i].pid);
        fstatat(dir, name, &st, 0);
    }
}

static void threads_own(void)
{
    char p[64];
    nthreads_seen = 0;
    for (int i = 0; i < nprocs; i++) {
        if (!procs[i].own)
            continue;
        snprintf(p, sizeof p, "/proc/%d/task", procs[i].pid);
        DIR *d = opendir(p);
        if (!d) {
            count_failure();
            continue;
        }
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] < '1' || e->d_name[0] > '9')
                continue;
            char q[300];
            snprintf(q, sizeof q, "%s/status", e->d_name);
            read_at(dirfd(d), q);
            nthreads_seen++;
        }
        closedir(d);
    }
}

static void fds_own(void)
{
    char p[64], target[256];
    nfds_seen = 0;
    for (int i = 0; i < nprocs; i++) {
        if (!procs[i].own)
            continue;
        snprintf(p, sizeof p, "/proc/%d/fd", procs[i].pid);
        DIR *d = opendir(p);
        if (!d) {
            count_failure();
            continue;
        }
        struct dirent *e;
        while ((e = readdir(d))) {
            if (e->d_name[0] < '0' || e->d_name[0] > '9')
                continue;
            if (readlinkat(dirfd(d), e->d_name, target, sizeof target) < 0)
                continue;
            nfds_seen++;
        }
        closedir(d);
    }
}

// One NETLINK_SOCK_DIAG dump of the TCP sockets of one family, with tcp_info (what `ss -ti` asks for).
static unsigned tcp_states = ~0U; // step 1's plan leaves out TIME_WAIT (6), CLOSE (7) and LISTEN (10), as the sampler

static void tcp_dump(int family)
{
    int s = socket(AF_NETLINK, SOCK_DGRAM | SOCK_CLOEXEC, NETLINK_SOCK_DIAG);
    struct {
        struct nlmsghdr nlh;
        struct inet_diag_req_v2 r;
    } req;
    memset(&req, 0, sizeof req);
    req.nlh.nlmsg_len = sizeof req;
    req.nlh.nlmsg_type = SOCK_DIAG_BY_FAMILY;
    req.nlh.nlmsg_flags = NLM_F_REQUEST | NLM_F_DUMP;
    req.r.sdiag_family = (unsigned char)family;
    req.r.sdiag_protocol = IPPROTO_TCP;
    req.r.idiag_states = tcp_states;
    req.r.idiag_ext = 1 << (INET_DIAG_INFO - 1);
    send(s, &req, sizeof req, 0);
    for (;;) {
        ssize_t n = recv(s, buf, sizeof buf, 0);
        if (n <= 0)
            break;
        int done = 0;
        for (struct nlmsghdr *h = (struct nlmsghdr *)buf; NLMSG_OK(h, (unsigned)n); h = NLMSG_NEXT(h, n)) {
            if (h->nlmsg_type == NLMSG_DONE || h->nlmsg_type == NLMSG_ERROR) {
                done = 1;
                break;
            }
            nsockets_seen++;
        }
        if (done)
            break;
    }
    close(s);
}

static void tcp_both(void);
static void tcp_both_step1(void)
{
    tcp_states = ~0U & ~((1U << 6) | (1U << 7) | (1U << 10));
    tcp_both();
    tcp_states = ~0U;
}

static void tcp_both(void)
{
    nsockets_seen = 0;
    tcp_dump(AF_INET);
    tcp_dump(AF_INET6);
}

static void system_files(void)
{
    const char *files[] = {"/proc/stat", "/proc/loadavg", "/proc/meminfo", "/proc/pressure/memory", "/proc/swaps",
                           "/proc/diskstats", "/proc/net/dev", "/proc/uptime"};
    for (size_t i = 0; i < sizeof files / sizeof *files; i++)
        read_path(files[i]);
}

// The GPU columns (CPU and Energy tabs): every sample, the fdinfo of the DRM descriptors the descriptor turns found (their
// discovery is fds_own's). A client can show through several descriptors (Mesa's pipe loader and iris's buffer manager
// each duplicate the one they are given, and a duplicate is the same client); since the integrator's AM-P2 run of
// f68789c the sampler reads one descriptor per (pid, drm-pdev, drm-client-id) between two descriptor turns. Steps 0 and
// 1 read no fdinfo; this cloud machine has no GPU, so these lines read 0 here.
typedef struct {
    int pid, fd, primary;
    char key[128];
} drm_t;

static drm_t drms[4096];
static int ndrms, ndrm_clients;

static int fdinfo_value(const char *text, const char *name, const char **value)
{
    size_t n = strlen(name);
    for (const char *line = text; *line; ) {
        if (strncmp(line, name, n) == 0) {
            *value = line + n;
            while (**value == ' ' || **value == '\t')
                (*value)++;
            return (int)strcspn(*value, "\n");
        }
        const char *next = strchr(line, '\n');
        if (!next)
            break;
        line = next + 1;
    }
    return -1;
}

static void find_drm(void)
{
    char p[64], target[256];
    ndrms = ndrm_clients = 0;
    for (int i = 0; i < nprocs; i++) {
        if (!procs[i].own)
            continue;
        snprintf(p, sizeof p, "/proc/%d/fd", procs[i].pid);
        DIR *d = opendir(p);
        if (!d)
            continue;
        int first = ndrms;
        struct dirent *e;
        while ((e = readdir(d)) && ndrms < (int)(sizeof drms / sizeof *drms)) {
            if (e->d_name[0] < '0' || e->d_name[0] > '9')
                continue;
            ssize_t n = readlinkat(dirfd(d), e->d_name, target, sizeof target - 1);
            if (n <= 0)
                continue;
            target[n] = '\0';
            if (strncmp(target, "/dev/dri/", 9) != 0)
                continue;
            drm_t *m = &drms[ndrms];
            m->pid = procs[i].pid;
            m->fd = atoi(e->d_name);
            snprintf(p, sizeof p, "/proc/%d/fdinfo/%d", m->pid, m->fd);
            int len = read_path(p);
            if (len <= 0)
                continue;
            buf[len < (int)sizeof buf ? len : (int)sizeof buf - 1] = '\0';
            const char *pdev, *client;
            int npdev = fdinfo_value(buf, "drm-pdev:", &pdev), nclient = fdinfo_value(buf, "drm-client-id:", &client);
            m->key[0] = '\0';
            m->primary = 0; // no client or no engine time: the sampler reads it at its descriptor turns only
            if (npdev >= 0 && nclient >= 0 && strstr(buf, "drm-engine-") != NULL) {
                snprintf(m->key, sizeof m->key, "%.*s|%.*s", npdev, pdev, nclient, client);
                m->primary = 1;
                for (int k = first; k < ndrms; k++)
                    if (strcmp(drms[k].key, m->key) == 0)
                        m->primary = 0;
            }
            ndrm_clients += m->primary;
            ndrms++;
        }
        closedir(d);
    }
}

static void drm_read(int primaries_only)
{
    char p[64];
    for (int i = 0; i < ndrms; i++) {
        if (primaries_only && !drms[i].primary)
            continue;
        snprintf(p, sizeof p, "/proc/%d/fdinfo/%d", drms[i].pid, drms[i].fd);
        read_path(p); // a descriptor closed since find_drm: nothing to count
    }
}

static void drm_every(void) { drm_read(0); }
static void drm_clients(void) { drm_read(1); }

// The Disk tab in one pass, in the sampler's order (PR #47): the listing, then each process's stat and, for an own process,
// its io (both kept, pread), a tenth of the owners (in turn) and the system files. The step-1 plan sums its parts, each
// measured alone with its own caches warm; this is what the same reads cost together. Since step 2b the sampler reads
// every system file at every sample (each tab's graph keeps its history), as the summed plans always counted: this pass
// reads them too, not the disk statistics alone.
static int disk_turn;
static void disk_one_pass(void)
{
    static int dir = -1;
    char p[64], name[16];
    struct stat st;
    if (dir < 0)
        dir = open("/proc", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    list_names();
    for (int i = 0; i < nprocs; i++) {
        if (procs[i].statfd < 0) {
            snprintf(p, sizeof p, "/proc/%d/stat", procs[i].pid);
            procs[i].statfd = open(p, O_RDONLY | O_CLOEXEC);
        }
        if (procs[i].statfd >= 0)
            (void)!pread(procs[i].statfd, buf, sizeof buf, 0);
        if (i % 10 == disk_turn) {
            snprintf(name, sizeof name, "%d", procs[i].pid);
            fstatat(dir, name, &st, 0);
        }
        if (!procs[i].own)
            continue;
        if (procs[i].iofd < 0) {
            snprintf(p, sizeof p, "/proc/%d/io", procs[i].pid);
            procs[i].iofd = open(p, O_RDONLY | O_CLOEXEC);
        }
        if (procs[i].iofd >= 0)
            (void)!pread(procs[i].iofd, buf, sizeof buf, 0);
    }
    disk_turn = (disk_turn + 1) % 10;
    system_files();
}

typedef void (*step_fn)(void);

static int cmp(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static pid_t poke_group; // the bench's changing fixture: poked between two rounds of the one-pass Disk line

static double median_of(step_fn f, int rounds)
{
    double t[1000];
    f(); // warm: the first round opens kept descriptors and fills caches
    for (int r = 0; r < rounds; r++) {
        double a = cpu_ms();
        f();
        t[r] = cpu_ms() - a;
    }
    qsort(t, (size_t)rounds, sizeof *t, cmp);
    return t[rounds / 2];
}

// The same, the changing fixture's processes poked after each round and given 5 ms, outside the measured time: the lines
// they change and what their work costs the machine are the same for this line as for the bench's samples.
static double median_poked(step_fn f, int rounds)
{
    double t[1000];
    f();
    for (int r = 0; r < rounds; r++) {
        kill(-poke_group, SIGUSR1);
        struct timespec settle = {0, 5000000};
        nanosleep(&settle, NULL);
        double a = cpu_ms();
        f();
        t[r] = cpu_ms() - a;
    }
    qsort(t, (size_t)rounds, sizeof *t, cmp);
    return t[rounds / 2];
}

static void step_list(void) { list_procs(); }

int main(int argc, char **argv)
{
    if (argc >= 5 && strcmp(argv[1], "spawn") == 0) {
        int n = atoi(argv[2]), threads = atoi(argv[3]), fds = atoi(argv[4]);
        for (int i = 0; i < n; i++)
            if (fork() == 0) {
                for (int k = 0; k < fds; k++)
                    open("/dev/null", O_RDONLY);
                pthread_t th;
                for (int k = 1; k < threads; k++)
                    pthread_create(&th, NULL, idle_thread, NULL);
                idle_thread(NULL);
            }
        for (;;)
            pause();
    }
    if (argc >= 3 && strcmp(argv[1], "tcp") == 0) {
        int k = atoi(argv[2]);
        int srv = socket(AF_INET, SOCK_STREAM, 0), one = 1;
        setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons(9201), .sin_addr.s_addr = htonl(INADDR_LOOPBACK)};
        bind(srv, (struct sockaddr *)&a, sizeof a);
        listen(srv, k + 8);
        for (int i = 0; i < k; i++) {
            int c = socket(AF_INET, SOCK_STREAM, 0);
            connect(c, (struct sockaddr *)&a, sizeof a);
            int peer = accept(srv, NULL, NULL);
            memset(buf, 'x', 4096);
            if (write(c, buf, 4096) < 0 || read(peer, buf, 4096) < 0)
                return 1;
        }
        for (;;)
            pause();
    }
    if (argc >= 3 && strcmp(argv[1], "measure") == 0) {
        int rounds = atoi(argv[2]);
        poke_group = argc >= 4 ? (pid_t)atoi(argv[3]) : 0;
        raise_nofile();
        list_procs();
        int own = 0;
        for (int i = 0; i < nprocs; i++)
            own += procs[i].own;
        double list = median_of(step_list, rounds);
        double open2 = median_of(stat_status_open, rounds);
        double kept2 = median_of(stat_status_kept, rounds);
        double kstat = median_of(kept_stat, rounds);
        double kstatus = median_of(kept_status, rounds);
        double kstatm = median_of(kept_statm, rounds);
        double io = median_of(io_own, rounds);
        double thr = median_of(threads_own, rounds);
        double fds = median_of(fds_own, rounds);
        double tcp = median_of(tcp_both, rounds);
        double sys = median_of(system_files, rounds);
        double names = median_of(list_names, rounds);
        double owners = median_of(owners_all, rounds);
        double iokept = median_of(io_kept, rounds);
        double tcp1 = median_of(tcp_both_step1, rounds);
        double disk1 = poke_group > 0 ? median_poked(disk_one_pass, rounds) : median_of(disk_one_pass, rounds);
        find_drm();
        double drmall = median_of(drm_every, rounds);
        double drmone = median_of(drm_clients, rounds);
        printf("  processes listed: %d (own %d, other owners %d); own threads %ld; own descriptors %ld; TCP sockets %ld\n",
               nprocs, own, nprocs - own, nthreads_seen, nfds_seen, nsockets_seen);
        printf("  median CPU time of one sample over %d rounds (CLOCK_THREAD_CPUTIME_ID):\n", rounds);
        printf("    /proc listing (readdir + fstatat)            %7.3f ms\n", list);
        printf("    stat + status, open/read/close each           %7.3f ms  (%.1f us per process)\n", open2, open2 * 1e3 / nprocs);
        printf("    stat + status, kept descriptors and pread     %7.3f ms  (%.1f us per process)\n", kept2, kept2 * 1e3 / nprocs);
        printf("    stat alone, kept                              %7.3f ms  (%.1f us per process)\n", kstat, kstat * 1e3 / nprocs);
        printf("    status alone, kept                            %7.3f ms  (%.1f us per process)\n", kstatus, kstatus * 1e3 / nprocs);
        printf("    statm alone, kept                             %7.3f ms  (%.1f us per process)\n", kstatm, kstatm * 1e3 / nprocs);
        printf("    io of own processes                           %7.3f ms  (%.1f us per own process)\n", io, io * 1e3 / own);
        printf("    task/*/status of own processes (wake-ups)     %7.3f ms  (%.1f us per thread)\n", thr, thr * 1e3 / (nthreads_seen ? nthreads_seen : 1));
        printf("    fd/ readlinks of own processes                %7.3f ms  (%.2f us per descriptor)\n", fds, fds * 1e3 / (nfds_seen ? nfds_seen : 1));
        printf("    sock_diag TCP dump (IPv4 + IPv6, tcp_info)    %7.3f ms  (%.2f us per socket)\n", tcp, tcp * 1e3 / (nsockets_seen ? nsockets_seen : 1));
        printf("    system files (stat, loadavg, meminfo, pressure, swaps, diskstats, net/dev, uptime) %7.3f ms\n", sys);
        // Step 0's plan, ADR-0038 d after this probe: the listing gives the owner; stat for every process; status only for
        // the Memory tab; io for own processes on the Disk and Energy tabs; per-thread status (wake-ups) spread over five
        // samples; descriptor lists re-read in turn, a tenth of the processes per sample, plus one sock_diag dump on the
        // Network tab. AM-P2's limits come from these figures.
        double base = list + kstat + sys;
        printf("  per tab, one sample, step 0's read plan (listing + stat + system files, plus the tab's own reads; AM-P2's limits come from these):\n");
        printf("    CPU                                           %7.3f ms\n", base + fds / 10);
        printf("    Memory (+ status)                             %7.3f ms\n", base + kstatus);
        printf("    Disk (+ io)                                   %7.3f ms\n", base + io);
        printf("    Energy (+ io + a fifth of the threads + a tenth of the descriptor lists) %7.3f ms\n", base + io + thr / 5 + fds / 10);
        printf("    Network (+ a tenth of the descriptor lists + sock_diag) %7.3f ms\n", base + fds / 10 + tcp);
        // Step 1's plan, the sampler's (review of f68789c: the ratios compare the same reads): the owners a tenth per sample
        // (AD33); the Memory tab on statm and a fifth of status (AD32); io kept and re-read; the TCP dump without
        // listeners, TIME_WAIT and closed sockets; the CPU and Energy tabs read the fdinfo of one descriptor per DRM client
        // (the integrator's run of f68789c).
        double base1 = names + owners / 10 + kstat + sys;
        printf("    own processes' io, kept and pread             %7.3f ms  (%.1f us per own process)\n", iokept, iokept * 1e3 / own);
        printf("    fdinfo of every own DRM descriptor            %7.3f ms  (%d descriptors)\n", drmall, ndrms);
        printf("    fdinfo of one descriptor per DRM client       %7.3f ms  (%d clients)\n", drmone, ndrm_clients);
        printf("  per tab, one sample, step 1's read plan (the sampler's: owners a tenth per sample, statm and a fifth of status, io kept, no listener or TIME_WAIT socket, one fdinfo per DRM client):\n");
        printf("    step 1 CPU                                    %7.3f ms\n", base1 + fds / 10 + drmone);
        printf("    step 1 Memory                                 %7.3f ms\n", base1 + kstatm + kstatus / 5);
        printf("    step 1 Disk                                   %7.3f ms\n", base1 + iokept);
        printf("    step 1 Disk, in one pass (the sampler's order) %7.3f ms\n", disk1);
        printf("    step 1 Energy                                 %7.3f ms\n", base1 + iokept + thr / 5 + fds / 10 + drmone);
        printf("    step 1 Network                                %7.3f ms\n", base1 + fds / 10 + tcp1);
        printf("  for comparison, everything every sample (stat + status + io + every thread + every descriptor): %7.3f ms\n",
               list + kstat + kstatus + io + thr + fds + tcp + sys);
        printf("  files or lists that could not be opened: %ld out of descriptors%s; %ld refused by the kernel (another owner's or "
               "a non-dumpable process: expected)\n",
               open_failures, open_failures ? " (the figures above are too low)" : "", open_refusals);
        return 0;
    }
    fprintf(stderr, "usage: sampcost spawn N T F | tcp K | measure R [PGID]\n");
    return 2;
}
