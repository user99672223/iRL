#include "IRLCrash.h"
#include <execinfo.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <string.h>
#include <sys/ucontext.h>
#include <time.h>
#include <unistd.h>

static char g_path[1024];
static const int g_signals[] = { SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP, SIGSYS };

/* Async-signal-safe formatting: no stdio, no malloc. */
static void put(int fd, const char *s) { (void)!write(fd, s, strlen(s)); }
static void puthex(int fd, uint64_t v)
{
    char b[19] = "0x"; int i;
    for (i = 0; i < 16; i++) b[2 + i] = "0123456789abcdef"[(v >> (60 - 4 * i)) & 15];
    b[18] = 0; put(fd, b);
}
static void putdec(int fd, long v)
{
    char b[24]; int i = 23; int neg = v < 0; unsigned long u = neg ? -(unsigned long)v : (unsigned long)v;
    b[i] = 0;
    do { b[--i] = '0' + u % 10; u /= 10; } while (u);
    if (neg) b[--i] = '-';
    put(fd, b + i);
}

static void handler(int sig, siginfo_t *info, void *ctx)
{
    int fd = g_path[0] ? open(g_path, O_WRONLY | O_CREAT | O_APPEND, 0644) : STDERR_FILENO;
    if (fd < 0) fd = STDERR_FILENO;
    put(fd, "=== iRL crash ===\nsignal "); putdec(fd, sig);
    put(fd, " code "); putdec(fd, info ? info->si_code : 0);
    put(fd, " addr "); puthex(fd, info ? (uint64_t)(uintptr_t)info->si_addr : 0);
    put(fd, " time "); putdec(fd, (long)time(NULL)); put(fd, "\n");
#if defined(__aarch64__)
    if (ctx) {
        ucontext_t *uc = (ucontext_t *)ctx;
        if (uc->uc_mcontext) {
            const struct __darwin_arm_thread_state64 *ss = &uc->uc_mcontext->__ss;
            const struct __darwin_arm_exception_state64 *es = &uc->uc_mcontext->__es;
            int i;
            put(fd, "far "); puthex(fd, es->__far); put(fd, " esr "); puthex(fd, es->__esr); put(fd, "\n");
            for (i = 0; i < 29; i++) {
                put(fd, "x"); putdec(fd, i); put(fd, "="); puthex(fd, ss->__x[i]);
                put(fd, (i % 4 == 3) ? "\n" : " ");
            }
            put(fd, "\nfp="); puthex(fd, __darwin_arm_thread_state64_get_fp(*ss));
            put(fd, " lr="); puthex(fd, __darwin_arm_thread_state64_get_lr(*ss));
            put(fd, " sp="); puthex(fd, __darwin_arm_thread_state64_get_sp(*ss));
            put(fd, " pc="); puthex(fd, __darwin_arm_thread_state64_get_pc(*ss));
            put(fd, " cpsr="); puthex(fd, ss->__cpsr); put(fd, "\n");
            /* Guest x86-64 registers live in fixed host registers under ARM64EC; the full
             * host dump above is kept so they can be decoded offline against FEX's mapping. */
        }
    }
#endif
    put(fd, "backtrace:\n");
    {
        void *frames[64];
        int n = backtrace(frames, 64);
        backtrace_symbols_fd(frames, n, fd);
    }
    put(fd, "=== end ===\n");
    if (fd != STDERR_FILENO) { fsync(fd); close(fd); }
    signal(sig, SIG_DFL);
    raise(sig);
}

void irl_crash_set_dir(const char *dir)
{
    size_t n = strlen(dir);
    if (n + sizeof("/crash.txt") >= sizeof(g_path)) return;
    memcpy(g_path, dir, n);
    memcpy(g_path + n, "/crash.txt", sizeof("/crash.txt"));
}

void irl_crash_install(const char *dir)
{
    struct sigaction sa;
    size_t i;
    static char altstack[64 * 1024];
    stack_t ss = { .ss_sp = altstack, .ss_size = sizeof(altstack), .ss_flags = 0 };
    irl_crash_set_dir(dir);
    sigaltstack(&ss, NULL);
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    for (i = 0; i < sizeof(g_signals) / sizeof(g_signals[0]); i++) sigaction(g_signals[i], &sa, NULL);
}
