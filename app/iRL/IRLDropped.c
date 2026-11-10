/* Entry points of Madeira features iRL leaves out (tools/build/components.md), for the Madeira
 * runtime sources iRL compiles in place. Each says it is absent instead of failing the link. */
#include <stdio.h>

/* DonorPool.m + the MadeiraMemoryHost extension (Madeira's swap tier). WineProcessBridge.m calls
 * this only when madeira.cfg sets donor-pool-mb; iRL ships no extension, so no pool memory. */
long MadeiraDonorPoolStart(long megabytes, int purgeable)
{
    (void)purgeable;
    fprintf(stderr, "[swap] iRL: donor pool of %ld MB requested, but iRL has no MemoryHost extension: 0 MB\n", megabytes);
    return 0;
}
