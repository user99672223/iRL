/* iOS Simulator only (EXCLUDED_SOURCE_FILE_NAMES on iphoneos): the runtime entry points the
 * Swift app calls, without Wine, FEX or DXMT (their static libraries are device-only). Lets the
 * simulator self-test (-irl-selftest) exercise every app-side path. Nothing here runs on a device. */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>

bool jit_check_debugged(void) { return false; }
void jit_install_trap_handler(void) {}
bool jit_cs_status(uint32_t *flags) { if (flags) *flags = 0; return false; }

int wineserver_start(const char *prefix_path) { (void)prefix_path; return -1; }
int wineserver_is_running(void) { return 0; }
int wineserver_is_ready(void) { return 0; }
int wine_process_start(const char *prefix_path) { (void)prefix_path; return -1; }
int wine_process_is_running(void) { return 0; }
int wine_process_exit_code(void) { return 0; }
int wine_crash_exit_status(uint32_t *status) { if (status) *status = 0; return 0; }
void wine_log_set_file(const char *path) { (void)path; }
void winios_phase(const char *name) { (void)name; }

void madeira_display_set_layer(void *layer) { (void)layer; }
uint64_t madeira_get_present_count(void) { return 0; }
uint64_t madeira_shown_frame_count(void) { return 0; }
int madeira_frame_times_us(uint32_t *out, int max, uint32_t window_ms, uint32_t *since_last_us)
{
    (void)out; (void)max; (void)window_ms;
    if (since_last_us) *since_last_us = 0;
    return 0;
}
void madeira_gpu_meter_enable(int on) { (void)on; }
double madeira_gpu_meter_busy_seconds(void) { return 0; }

struct winios_gamepad;
void winios_gamepad_set_state(int index, const struct winios_gamepad *state) { (void)index; (void)state; }
