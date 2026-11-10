// iRL: the C API Swift calls. The headers live in the pinned madeira/ submodule.
#import "JITAllocator.h"
#import "FEXBridge.h"
#import "WineServerBridge.h"
#import "WineProcessBridge.h"
#import "IOSDisplayShim.h"
#import "Winios/Winios.h"
#import "Winios/WiniosCursor.h"
#import "Winios/WiniosGamepad.h"
#import "IRLCrash.h"
#include <stdint.h>
#include <os/proc.h>

// Wine file logging (build/ntdll-unix/server_ios.c)
void wine_log_set_file(const char *path);
// DXMT present counter and frame intervals (winemetal_unix.c, Winios.m)
uint64_t madeira_get_present_count(void);
uint64_t madeira_shown_frame_count(void);
int madeira_frame_times_us(uint32_t *out, int max, uint32_t window_ms, uint32_t *since_last_us);
void madeira_gpu_meter_enable(int on);
double madeira_gpu_meter_busy_seconds(void);
void winios_phase(const char *name);
