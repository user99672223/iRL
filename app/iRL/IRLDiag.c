#include "IRLCrash.h"
#include <stdint.h>
#include <unistd.h>
#include <sys/resource.h>

/* libproc.h is not part of the iOS SDK; the function is (Madeira's ntdll uses it too). */
extern int proc_pid_rusage(int pid, int flavor, rusage_info_t *buffer);

/* Energy billed to this process so far, in nanojoules (0 when unavailable). */
uint64_t irl_energy_nj(void)
{
    struct rusage_info_v6 ri;
    if (proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&ri) != 0) return 0;
    return ri.ri_energy_nj;
}
