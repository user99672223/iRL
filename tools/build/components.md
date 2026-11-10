# iRL components: what is taken from Madeira, and why

Rule (REPORT.md D5, owner): take only the runtime pieces Rocket League needs; build iRL's own
small app around them. Rocket League here = one 64-bit (x86-64) D3D11 Unreal Engine 3 game, Epic
launch without EAC, Wwise audio, a DualSense, an external monitor.

Build entry point: `tools/build/irl-build.sh <stage>`; CI: `.github/workflows/build.yml`.

## Native (iOS) runtime: kept

| Component | Built by | Why Rocket League needs it |
|---|---|---|
| wineserver (thread) | `madeira/build/wineserver/build.sh` | Wine's server; iOS can't spawn processes, so it runs as a thread |
| ntdll unix side | `madeira/build/ntdll-unix/build.sh`, rewritten by `tools/build/make_lean_ntdll.py` | Wine's core: loader, virtual memory (16 KB pages, JIT pool), threads, signals, sockets (Winsock → BSD), audio endpoint (Core Audio RemoteIO) |
| win32u unix side | `madeira/build/win32u-unix/build.sh` | Windows, messages, display modes, D3DKMT (DXMT needs it) |
| GnuTLS (+nettle, hogweed, gmp) | `madeira/build/gnutls-ios`, `sync-gnutls-libs.sh` | Schannel/bcrypt/crypt32 unix side: the game's HTTPS to Epic and Psyonix |
| FreeType | `madeira/tools/build/build-freetype-ios.sh` | dwrite/gdi text rasterisation (game UI fonts, any Wine dialog) |
| LLVM 15 (iOS) | `madeira/tools/build/build-llvm-ios.sh` | DXMT's runtime DXBC → AIR conversion (fallback for shaders not in the precompiled .metallib) |
| DXMT iOS side (winemetal unix) | `madeira/tools/build/build-dxmt-ios.sh` | D3D11 → Metal |
| FEXCore (iOS, native) | `irl-build.sh fex` from `fex/` (irl-fex-aot) | Linked by FEXBridge.mm (JIT pool setup, FEX checks) |

### ntdll: what the lean build removes
- **winegstreamer unix side (FFmpeg + VideoToolbox decoders): dropped.** The game ships no video
  (no .bik/.bk2/.mp4/.wmv/.webm/.usm in the install) and its audio is Wwise (.bnk/.wem), which
  decodes itself. Its call table is `tools/build/irl_unixlib_stubs.c` (every call returns
  STATUS_NOT_IMPLEMENTED), and winegstreamer.dll is removed from the farm.
- **winevulkan unix side: dropped.** D3D11 goes through DXMT/Metal, not Vulkan.

## Windows (ARM64EC PE) runtime: kept

| Component | Built by | Why |
|---|---|---|
| Wine ARM64EC builtins + ntdll | `madeira/build/wine-pe/build-modules.sh`, `build-ntdll.sh` (module list: `madeira/build/windows-runtime/targets.py arm64ec list`) | Windows itself, native ARM64EC so only the game's own code is translated |
| DXMT d3d11, dxgi, d3d10core, winemetal (ARM64EC) | meson in `irl-build.sh` (same options as Madeira's windows-runtime) | The game's D3D11 device and swapchain |
| xtajit64.dll (FEX ARM64EC) | `irl-build.sh fex`, options identical to `madeira/build/fex-arm64ec/build.sh` | x86-64 → ARM64: AOT cache first, JIT for misses |
| FEXOfflineCompiler.exe (ARM64EC) | same FEX tree and options as xtajit64.dll | iRL's AOT Prepare: compiles code maps into FEX caches with the exact FEX build that loads them |
| faultrep.dll | `madeira/build/faultrep/build.sh` | RocketLeague.exe imports it (c0000135 at load without it) |
| wineios.drv | `madeira/build/wineios-drv/wineios.c` | Wine's display/input driver on iOS |
| VC++ x64 runtime | `madeira/tools/build/prepare-vcruntime.sh` | Microsoft's DLLs linked over Wine's (CLAUDE.md: prefer Microsoft's redistributable) |
| nls tables, prefix template, cacert.pem | committed in Madeira | Wine prefix creation, code pages, TLS roots |

Removed from the farm after the build (`prune_farm`): d3d12/d3d12core/madeira_d3d12, d3d9, nvapi64,
winevulkan/vulkan-1, winegstreamer, dockhost, tftrace, Madeira's `*-x64.exe` test programs.

## Dropped entirely

| Component | Why not |
|---|---|
| i386/WoW64 Wine, xtajit.dll (fex-wow64), syswow64 | Rocket League is 64-bit only |
| aarch64 DLL farm | Only needed for native-ARM64 or WoW64 processes; RL and its helper DLLs are x86-64 → ARM64EC farm. If a device log shows an aarch64 process, revisit |
| Madeira Dock, Steam client, Steam cloud/achievements/workshop | Not Steam |
| GOG / EA / itch / Epic library, downloads, cloud saves | One game, imported once from the laptop |
| rppairing, StikJIT framework, JIT helper extension | StikDebug enables JIT [confirmed] |
| MemoryHost extension + DonorPool | Madeira's swap tier; candidate to revisit if RL hits the memory ceiling (measure first) |
| MoltenVK, zink, Mesa, KosmicKrisp, Vulkan PE (DXVK, vkd3d-proton), madeira-d3d12, mesa-d3d12 | RL is D3D11 → DXMT → Metal |
| FFmpeg | See above |
| LuaJIT (love compat), tftrace, wine-mono, wine-gecko | Not used by RL |
| Touch controls, pad assist, keyboard/mouse emulation, library UI, Onboarding, animated shaders | Controller-only game on an external monitor; still phone UI |

## Madeira app sources iRL compiles (referenced in place from the pinned `madeira/` submodule, not copied)

Referencing them in place keeps them exactly at the pinned version (relative includes such as
`../../build/madeira_cfg.h` keep working) and avoids a drifting copy.

| File | Why |
|---|---|
| `WineServerBridge.m` | Starts wineserver as a thread |
| `WineProcessBridge.m` | Prefix setup, DLL farm links, environment, starts the guest program (MADEIRA_EXE / MADEIRA_ARGS) |
| `FEXBridge.mm` | FEX init and the JIT write offset FEX inside Wine needs |
| `JITAllocator.c` | JIT memory regions, TXM/iOS 26 rules, trap handler, CS flags |
| `wine_stubs.c` | Link stubs the Wine unix libs expect |
| `IOSDisplayShim.m` | HWND → CAMetalLayer for DXMT (`madeira_display_set_layer`) |
| `PrefixExtractor.c` | Unpacks the bundled prefix template on first launch |
| `PadOutput.m` | DualSense output path the wineserver HID pad calls into |
| `Winios/Winios.m`, `WiniosCursor.c`, `WiniosGamepad.c`, `WiniosGL.m`, `BackgroundCPUCap.c`, `MetalBackgroundGate.m` | Wine's iOS driver host side: windows, compositor, XInput slots, frame counters (WiniosGL is linked because Winios.m's frame counter references it; it is idle without GL) |
| `StikJITHelper.swift` | StikDebug attach + JIT pool placement (script protocol `madeira-jit.js`, also bundled) |

iRL's own code (`app/iRL/`): app shell and scenes, Epic auth (auth only, ported from
`SwiftEpic/EpicAPI.swift`), launch sequence, external display, DualSense → XInput bridge,
diagnostics sampler, per-launch logs + Share, crash handler, and the small shims StikJITHelper
expects (`LogStore`, `MadeiraConfig`, `SigningStatus`).

## Defaults that must be measured on the device, not copied

| Default | Madeira value | iRL now | Measure |
|---|---|---|---|
| JIT pool | 896 MB | 896 MB | JIT pool fill vs. memory headroom with AOT caches loaded |
| Build configuration | Debug (Release crashed the guest) | Debug | Retry Release once the game runs |
| Wine logging | many channels | `fixme-all,err+all` (verbose toggle) | Log volume and CPU per minute |
| DXMT logging | census throttles on | off unless toggled | Per-frame cost |
| Metal layer display sync | disabled (private API) | iOS default | Frame pacing on the external display |
| Phone overlays (FPS overlay, glow) | on | none (still diagnostics) | n/a |
