/* iRL: unix-side call tables for Wine modules iRL does not ship (decision D5).
 *
 * Madeira's ntdll (build/ntdll-unix/virtual_ios.c) binds winegstreamer.dll and
 * winevulkan.dll to these tables. Madeira implements them with FFmpeg and a
 * Vulkan loader; Rocket League uses neither (no video files, Wwise audio, D3D11
 * through DXMT), so iRL links tables whose every entry fails cleanly instead of
 * linking FFmpeg, VideoToolbox decoders and the Vulkan thunks.
 * 256 entries covers every function index either PE module defines. */
typedef unsigned int irl_ntstatus;
#define IRL_STATUS_NOT_IMPLEMENTED 0xC0000002u

static irl_ntstatus irl_unix_call_not_implemented(void *args)
{
    (void)args;
    return IRL_STATUS_NOT_IMPLEMENTED;
}

#define IRL_E1 (const void *)irl_unix_call_not_implemented
#define IRL_E8 IRL_E1, IRL_E1, IRL_E1, IRL_E1, IRL_E1, IRL_E1, IRL_E1, IRL_E1
#define IRL_E64 IRL_E8, IRL_E8, IRL_E8, IRL_E8, IRL_E8, IRL_E8, IRL_E8, IRL_E8
#define IRL_E256 IRL_E64, IRL_E64, IRL_E64, IRL_E64

__attribute__((visibility("default"))) const void *winegstreamer_unix_call_funcs[256] = { IRL_E256 };
__attribute__((visibility("default"))) const void *winegstreamer_unix_call_wow64_funcs[256] = { IRL_E256 };
__attribute__((visibility("default"))) const void *winevulkan_unix_call_funcs[256] = { IRL_E256 };
