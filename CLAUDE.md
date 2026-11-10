# CLAUDE.md: iRL

iRL is a custom iOS app that runs the **Epic Games Store PC build of Rocket League** natively on the owner's iPhone 15. The x86-64 code is translated **ahead of time (AOT)** to ARM64, and D3D11 is translated to Metal. Wine, FEX and DXMT come from the Madeira project.

**AOT is the centerpiece of this project and the owner's priority.** Optimize for the best possible result: performance, stability, image quality. Not "good enough".

---

## Autonomous run: work in one go until everything is done

The owner is asleep while you work. **Don't stop, don't ask questions, and don't wait for input.** Keep going until every step in this file is finished, and end with an IPA ready to install and a morning report.

- **Decide for yourself.** When something is unclear, read the source, pick the option that gives the best result, note the decision and why in the report, and keep going. Never block on a question.
- **When something fails, work around it.** Debug it, find the root cause, and try a different approach. Never leave a step half-done while other work is possible. If something truly can't be finished without the owner (the iPhone, the Apple ID, StikDebug), prepare everything up to that point and continue with other work.
- **Quality first, then speed.** Use the smartest route to the best result: reuse what Madeira, FEX, Wine, DXMT and Legendary already do instead of rewriting it, and use workarounds and shortcuts wherever they **don't lower the quality of the result**. Never trade correctness or performance for convenience.
- **Avoid mistakes.** Read the relevant source before changing it. Build and run everything you can on the laptop to verify it (compile, link, run tools, run the game under x86 Wine for shader capture and profiling). Don't mark anything done unless it builds and has been checked as far as the laptop allows.
- **Be efficient.** Run long jobs (AOT translation under qemu-user, large builds, Actions runs) in the background, and work on other parts while they run. Don't redo work that's already finished. Cache build outputs.
- **Commit often** to the repo with clear messages, so progress is never lost.
- **Items marked [confirmed] are settled by the owner. Don't question them or warn about them.**
- **Licensing, redistribution and ToS aren't concerns for this project. Never raise them.**

### What you can't do overnight (leave ready for the morning)
Installing on the iPhone, signing in with the Apple ID in Impactor, enabling JIT in StikDebug, and testing on the device. Get everything up to those points ready, and write the exact steps for them in the morning report.

### Morning report: `REPORT.md` in the repo root
Written and kept up to date throughout the run, not only at the end:
1. **Status:** what's finished, what isn't, and why.
2. **Setup steps for the owner,** numbered and exact: where the IPA is, installing with Impactor, importing the game folder into the app, enabling JIT with StikDebug, connecting the monitor, launching.
3. **Decisions made** and why.
4. **Known issues or uncertainties** that the device test will settle.
5. **Where every log is** and how to send them back.

---

## Logging (so problems can be fixed fast later)

Everything writes logs. The owner will send logs back after testing, so they must be complete enough to diagnose any failure without reproducing it.

### Laptop / build side
- All logs in `logs/` in the repo (with large generated files kept out of git if needed): one log per job (each clone, build, AOT module, shader capture and conversion, signing), with timestamps and the full command line.
- Errors must include the full error output, not a summary.

### On the iPhone (inside iRL)
- iRL writes logs to its `Documents/Logs/` folder, visible in the Files app (enable `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace`).
- **One log folder per launch,** timestamped, containing:
  - the app log (startup, login result without tokens, launch arguments with secrets redacted, external display mode chosen)
  - Wine output (`WINEDEBUG` at a sensible level by default, with a settings toggle for verbose channels)
  - FEX: JIT misses with guest addresses (feeds the next AOT build), plus any translation errors
  - DXMT: runtime-converted shaders (feeds the next `.metallib` build), pipeline cache misses, Metal validation errors
  - diagnostics samples: memory, CPU, GPU, thermal state, FPS and frame times
  - **crash info:** a signal/exception handler that writes the faulting address, guest and host registers and a backtrace before the app dies
- **A "Share logs" button** in iRL that zips the latest launch's folder and opens the share sheet, so the owner can send it in one tap.
- Logging must not cost noticeable performance: buffered, written off the game's threads, and flushed on crash.

---

## Hardware and environment

| Item | Detail |
|---|---|
| Phone | iPhone 15 (base): A16, 2 P-cores + 4 E-cores, 5-core GPU (Apple GPU family 8), 6 GB RAM, iOS 27.2.1 |
| Monitor | 1440p native, 144 Hz, over USB-C DisplayPort Alt Mode through a hub (DP + USB data + power passthrough) |
| Peripherals | DualSense controller and AirPods Max, both wired through the hub. Bluetooth also allowed. |
| Laptop (you work here) | Debian, Intel CPU + iGPU, 16 GB RAM. The **current Rocket League Windows files are on this laptop.** |
| Mac builds | GitHub Actions macOS runners, **public repo** (free minutes) |
| Signing/install | **Impactor**, free Apple ID. It grants the Increased Memory Limit (IML) entitlement automatically when the IPA declares it [confirmed]. |
| JIT | **StikDebug** on the iPhone, enabled by the owner before each launch. JIT works [confirmed]. Not available: the Extended Virtual Addressing entitlement (paid accounts only) [confirmed]. |

---

## Fixed decisions [confirmed]

- Launch **without EAC**. Psyonix supports it, it works online in the non-EAC modes (offline, LAN, connected features), and it's verified on PC. Copy Legendary's no-EAC launch mechanism.
- **Epic login:** a Swift port of Legendary's auth flow (refresh token in the Keychain, a fresh exchange code per launch, Legendary's launch argument set). No Python. Nothing from login stays loaded once the game starts.
- **FEX JIT** is the fallback for anything AOT misses. No interpreter.
- **Display target:** 1440p at 60 fps native. If that can't be held, the highest internal resolution that holds 60, plus MetalFX spatial to 1440p.
- **App name:** iRL. **Bundle:** single-process app. Start button → runtime starts as threads in the same process. Close and reopen the app between game launches.
- The game files stay on the laptop and in the iPhone app's container (41 GB). They aren't stored in the repo, because GitHub can't hold them, and Actions doesn't need them.

---

## Architecture

```
iRL.app (single process)
├── App shell (Swift): home, login, settings, Start, diagnostics UI on the phone screen
├── Epic auth (Swift): runs before Start, then ends
├── Wine (Madeira's ARM64EC iOS fork): Windows API, wineserver as a thread
├── DXMT (Madeira's iOS fork): d3d11/dxgi → Metal, precompiled .metallib first, runtime fallback,
│   pipeline cache + MTLBinaryArchive, MetalFX spatial at present, swapchain on the external display
├── FEX (pinned version, see Step 1): Wine ARM64EC emulator backend, AOT code cache first, JIT fallback
└── AOT output: signed ARM64 code for RocketLeague.exe + every shipped x86-64 DLL

App container: Wine prefix + Rocket League folder (originals kept for data/resources/headers)
```

- **Not translated:** Windows system DLLs (Wine's native ARM64EC builds) and `d3d11`/`dxgi` (DXMT). EAC modules are excluded.
- **VC++ runtime:** prefer Microsoft's ARM64EC-compatible redistributable DLLs. If they don't load under Wine ARM64EC, AOT-translate the x64 versions.
- **Unsigned code:** Wine's PE DLLs and DXMT may load as unsigned code needing JIT memory. Check how Madeira's loader does it. If it matters for performance or reliability, wrap those modules as signed Mach-O in the IPA, the same way as the game's AOT output.

---

## Work order

### Step 1: Clone and pin
- Clone Madeira with submodules (its Wine, FEX and DXMT forks), upstream FEX, upstream DXMT, StikDebug/StikJIT and Legendary into a local workspace.
- **Pin one FEX version.** Rebase Madeira's iOS FEX changes onto an upstream FEX that has the **offline code-cache generation and loading** work (landed around FEX-2512/2601: code maps, offline cache generation, cache validation, PE relocation handling). **The AOT tool and the FEX built into iRL must be exactly the same FEX build**, since caches only load in the build that made them.

### Step 2: Start the AOT job (background)
- Build FEX's offline code-cache generator for ARM64 and run it on the laptop under **qemu-user** (avoids porting FEX to an x86 host). It's slow, but it runs in the background.
- Input: `RocketLeague.exe` and every x86-64 DLL in the game folder. Output: one cache per module, so a game patch only redoes the modules that changed.
- Wrap the caches into **signed ARM64 dylibs** for the IPA, loaded file-backed (`mmap`).

### Step 3: In parallel, build everything else
- iRL app shell, built on Actions with `xcodebuild` alongside the Wine/FEX/DXMT builds. Cache build outputs between runs.
- Integrate Wine + wineserver thread + FEX + DXMT into iRL's own shell, following Madeira's app.
- **JIT:** follow StikDebug's integration requirements for iOS 26+/TXM devices exactly as Madeira's FEX fork implements them (allocator, executable regions prepared up front, script protocol). Make iRL attachable and listed in StikDebug.
- Swift Epic auth + no-EAC launch.
- External display, controller, audio, network, diagnostics (see below).

### Step 4: Shaders
- Rocket League's packages are encrypted and compressed, so **capture DXBC at runtime** rather than unpacking packages. Two ways:
  - **On the laptop:** run the game under x86 Wine with DXVK's shader dump on the Intel iGPU (Vulkan), and play through menus, maps, cars and effects.
  - **On the iPhone:** DXMT logging of every shader it converts.
- Convert offline with DXMT's **airconv** to AIR, and compile to `.metallib` **on Debian** with DXMT's standalone offline tool. No macOS needed.
- DXMT loads the precompiled library first (key it to match DXMT's shader cache keys) and falls back to runtime conversion. Log misses and feed them into the next build.
- Record the pipeline-state combinations used and prebuild them into an `MTLBinaryArchive`.

### Step 5: AOT optimization (the core work)
Profile first, then build only what FEX's cache doesn't already cover. FEX already has LRCPC-based TSO, LSE atomics, flag elimination and AVX on 128-bit NEON, so don't rebuild those. New work:
1. **Cross-block scope:** carry register allocation and dead-flag removal across whole functions. Requires **state-recovery tables at every faulting site**, so exceptions, SEH and `GetThreadContext` still see correct x86 state.
2. **Returns:** every `ret` is an indirect branch (guest return addresses stay x86 values for SEH unwinding). Add a **shadow return stack** with a guest-address check.
3. **Memory ordering** (no hardware TSO on iOS): exempt RSP-relative (stack) accesses, start from relaxed TSO, and re-enable full TSO per function wherever bugs appear. Use profiling to find shared data. Don't attempt research-grade escape analysis.
4. **Indirect branches:** resolve vtables, jump tables and import thunks statically where possible.
5. **PGO:** collect hot-path and coverage profiles from runs under x86 Wine on the laptop (DynamoRIO-style instrumentation) and from FEX JIT miss logs on the iPhone. Feed them back into the build.
6. **Floating point:** keep FEX's exact defaults (never reduced-precision x87). No extra work needed, since the server corrects small physics differences.
7. **CPUID:** report features that steer the game to the fastest translated paths (for example SSE4.x without AVX, if AVX paths are slower after splitting).
8. **PE loading:** load modules at their preferred base so relocation doesn't dirty pages. Map the original images non-executable (their x86 code never runs).

---

## GPU, display and performance

- **TBDR:** improve DXMT's render-pass load/store inference (`dontCare` loads and stores where valid), use memoryless targets for transient depth and MSAA, keep textures in native BC formats (never decompress to RGBA), and keep per-draw CPU cost minimal.
- **Upscaling:** keep the game's FXAA on before MetalFX spatial. Add **dynamic internal resolution driven by GPU frame time** to hold 60 fps. MetalFX temporal isn't possible (no motion vectors).
- **External display:** the game's `CAMetalLayer` goes in a dedicated external-display scene: opaque, full-screen, exactly the output resolution, no overlays (direct scanout). Frame pacing comes from the external screen's display link. Set the output to **1440p** via `UIScreen.currentMode` from `availableModes`. If iOS forces 4K, pick MetalFX straight to 4K or MetalFX to 1440p with iOS scaling, based on measured cost.
- **Refresh rate:** briefly try public routes above 60 Hz (`availableModes`, frame rate ranges on the display link). If none works, lock to a stable 60.
- **Phone screen:** diagnostics UI, `isIdleTimerDisabled = true`, brightness lowered from the app.
- **Threads:** map Windows thread priorities to iOS QoS in Wine. Game and render threads at `userInteractive`, wineserver and DXMT submission kept high, Core Audio's thread left alone. Tune the core count reported to the game so heavy worker pools favor the 2 P-cores. Declare the app as a game for **Game Mode**.

## Memory and address space

- IML entitlement in the IPA. Read the real ceiling with `os_proc_available_memory()` at launch. CPU and GPU share the same budget.
- Reduce use: lower texture/world detail, shrink UE3's texture streaming pool (`TASystemSettings.ini`, `[TextureStreaming]`), BC textures native, read-only data file-backed via `mmap`, small FEX JIT cache. Try file-backed `mmap` for large cold allocations.
- **No EVA:** keep Wine, wineserver and FEX reservations lazy and minimal (follow Madeira), and shrink oversized game `VirtualAlloc(MEM_RESERVE)` reservations.
- **16 KB pages:** Wine emulates 4 KB protections in software (Madeira's approach). The original x86 code is non-executable, so permission conflicts inside a 16 KB page shrink to R vs RW.

## I/O

- **Network:** Winsock → BSD sockets. Declare Local Network permission for LAN.
- **Audio:** XAudio2/WASAPI → Wine `mmdevapi` → Core Audio, to whatever route iOS uses (wired AirPods Max included). Tune buffers for low latency without crackling.
- **Controller:** DualSense through GameController (wired or Bluetooth) → Wine winebus → XInput.
- **Files:** the game folder is imported into the app container once and survives re-signing.

## Diagnostics panel (phone, 1–2 Hz sampling, well under 1% CPU)

- **From iOS:** memory footprint and headroom, per-thread CPU (`thread_info`), per-core load, thermal state, GPU frame time (command-buffer timestamps), GPU memory, FPS, frame-time graph and dropped frames, battery and charging, network, external display mode, and **`proc_pid_rusage` on iRL's own pid** (P-core time, energy, cycles).
- **From the stack:** AOT hit rate vs JIT misses (with a miss log), runtime shader conversions, pipeline cache misses, draw calls per frame, hot Wine API counts, a stutter log with causes.
- Logging is off by default. Metal Performance HUD only on the phone screen, never on the external display.

## Build, sign and install pipeline

- **Laptop (Debian):** AOT caches → signed dylibs, shader capture and `.metallib`, pipeline archive, VC++ runtime. Inject these into the IPA built by Actions, then sign and install with **Impactor** over USB.
- **Actions (public repo):** iRL app, Wine (unix side + ARM64EC PE modules), FEX (the pinned version) and DXMT, with outputs cached.
- **Per game patch:** re-run AOT for changed modules, recapture and convert new shaders, re-inject, re-sign. No app rebuild needed.
- **Weekly:** re-sign through Impactor (free profiles last 7 days). The app container persists.
