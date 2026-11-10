#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Installs fatal-signal handlers that write the signal, faulting address, all ARM64 host
 * registers and a backtrace to <dir>/crash.txt, then re-raise with the default action.
 * Call once at app start, BEFORE Wine starts: Wine then installs its own SIGSEGV/SIGBUS/SIGILL/
 * SIGTRAP handlers for Windows exceptions (guest faults become SEH, logged by Wine itself), and
 * this handler only sees what Wine passes on or never claims (SIGABRT, crashes in the app shell). */
void irl_crash_install(const char *dir);
/* Self-test: writes a report for a fake SIGSEGV to the current crash.txt without raising. */
int irl_crash_selftest(void);
/* Re-points the crash file at a new launch folder (cheap; async-signal-safe storage). */
void irl_crash_set_dir(const char *dir);
#ifdef __cplusplus
}
#endif

/* IRLDiag.c */
uint64_t irl_energy_nj(void);
