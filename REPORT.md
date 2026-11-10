# iRL: morning report

_Last updated: 2026-11-10 (run in progress)._

## 1. Status

| Area | State | Notes |
|---|---|---|
| GitHub repo | Done | Public: https://github.com/user99672223/iRL |
| Clones and pins | Done | `workspace/` (git-ignored); exact SHAs in `PINS.md` |
| FEX pin | Done, compiling | `user99672223/FEX` branch `irl-fex-aot` = Madeira `ios-port-2607` + 6 upstream AOT-loader commits (D1). |
| AOT code maps | Done, verified | `tools/aot/gen_codemaps.py`: 22 modules, ~158k seeded blocks (RocketLeague.exe: 81,786) |
| AOT cache generation | In progress | FEXOfflineCompiler.exe built with the runtime FEX; runs on the iPhone (D2). |
| iRL app / IPA | Built (interim) | Lean iRL app CI is green (run 42760542459). `dist/iRL-final.ipa` (204 MB) = that IPA + 19 AOT code maps + shader DB. It's being rebuilt as a Release build (the first one was Debug) together with the simulator fixes. |
| Shaders | Done (pixel), device-fed (vertex) | 21,248 shaders captured by playing RL through Heroic (menus, garage, Free Play, a 4v4 bot match). All 15,428 pixel shaders are precompiled into DXMT's own cache DB (`shaders_320.db`, exact keys), so the phone gets cache hits with no DXMT change. The 5,820 vertex shaders depend on runtime input layouts and get added from the first device log. |
| Step 5 AOT optimizations | Not started | Needs the merged FEX to build first |

## 2. Setup steps for the owner

1. **Get the IPA:** `dist/iRL-final.ipa` in the repo folder on the laptop. To rebuild it from the
   newest green CI run, run `bash tools/release/make-final-ipa.sh`. It adds the AOT code maps and
   precompiled shaders.
2. **Install with Impactor:** iPhone on USB → Impactor → sign in with your Apple ID → pick
   `iRL-final.ipa` → install. Impactor adds Increased Memory Limit automatically. Extended Virtual
   Addressing was removed from the entitlements on purpose (free account).
3. **Trust the profile:** Settings → General → VPN & Device Management → your Apple ID → Trust.
4. **Import the game (once, about 42 GB over USB):** open iRL once, then with the iPhone plugged in,
   unlocked and trusted, run in the repo folder:
   `bash tools/release/push-game.sh`
   It mounts iRL's Documents over USB, checks free space, and copies the game folder into
   **iRL › Games › rocketleague**, skipping EasyAntiCheat. If the cable drops, re-run it and it
   resumes. iRL exposes that folder to Wine as `C:\games\rocketleague`, the path the AOT code maps use.
5. **Enable JIT:** open StikDebug → pick iRL → enable JIT. iRL shows "JIT: on" on its home screen.
6. **Prepare AOT (once per game patch):** in iRL tap **Prepare AOT**. FEX's offline compiler
   translates the game's x86-64 code to ARM64 and writes the caches. Keep the phone on power;
   it takes several minutes. Then close iRL from the app switcher and reopen it, with JIT enabled again.
7. **Sign in to Epic:** in iRL tap **Sign in to Epic** and log in on Epic's page. iRL keeps only the
   refresh token (in the Keychain).
8. **Connect the monitor:** USB-C hub → DisplayPort monitor, plus the DualSense and AirPods Max on the hub.
9. **Start:** JIT enabled → tap **Start**. The game appears on the monitor and the phone shows the
   diagnostics screen.
10. **Send logs:** iRL › **Share logs** zips the last launch's folder. It's also visible in the
    Files app under iRL › Logs.

## 3. Decisions

**D1 (final). FEX = Madeira `ios-port-2607` + upstream's AOT code-cache loader, cherry-picked.**
Madeira's FEX mapped AOT caches on the Wine/ARM64EC path but never used them (`TODO: LoadCache`).
A full merge of FEX-2611 (27 conflicting files) was tried and dropped. Upstream replaced the whole
code-buffer model (`SharedCodeBufferManager`), and Madeira's iOS JIT-pool sweeper, generation
counters and migrate locks are built on the old model. Porting them would mean rewriting the most
crash-prone iOS code without a device to test on. Instead, these 6 upstream commits applied with no
conflicts: wire up `LoadCache`/`EnableLoadedSection`, adapt the loading to FEXOfflineCompiler, the
WoA syscall ABI fix, marking cache memory as EC code, and recording exe bitness in the code map.
Upstream's separate runtime "DiskCache" (FEX-2609, ~60 commits) isn't needed for AOT, so it is left out.
Skipped: running cache generation in a subprocess (iOS can't spawn processes; the Prepare step runs
it as a Wine program instead). Fork: https://github.com/user99672223/FEX/tree/irl-fex-aot.
Partial merge attempt kept in `logs/fex-full-merge-partial-resolution-*.patch`.

**D2. The AOT caches are generated on the iPhone, not on the laptop under qemu-user.** Reasons found in the source:
- FEX's offline compiler for Windows targets is itself an ARM64EC Windows program
  (`Source/Tools/FEXOfflineCompiler`, `MINGW` branch). It maps images through Win32 APIs.
- Madeira's FEX is built with `FEX_IOS_HOST`, which changes code generation in about 20 FEXCore
  files (JIT, dispatcher, register use). A laptop build would either mismatch the shipped FEX, or
  need an iOS-host ARM64EC binary running under Wine-arm64 under qemu, where its iOS-specific
  TEB/allocator code doesn't apply.
- The cache also depends on host CPU features. On the device they are the real A16 features, so
  there is no chance of a mismatch.

So the laptop does the expensive analysis (code maps; later PGO), and the IPA ships them.
On first launch iRL runs FEX's own `FEXOfflineCompiler.exe` (the same build as the runtime) in a
one-time "Prepare AOT" pass, and FEX's runtime loads the caches it produced.

**D2b. Static code maps instead of recorded ones.** FEX only compiles blocks listed in a code
map, normally recorded during play. `gen_codemaps.py` seeds them from the PE metadata every x64
image has: the entry point, exports, TLS callbacks, and every primary `.pdata` function start
(chained unwind fragments are skipped). This covers essentially every non-leaf function before the
first run. FileId and the format follow the pinned source exactly (`ImageTracker.cpp`,
`CodeCache.h`), and `check_codemap.py` verifies them. Later PGO and JIT-miss logs merge in through
`--extra`.

**D3 (superseded by D5). ~~iRL = Madeira + overlay.~~** The first CI run still builds that way
(it fills the LLVM and FEX caches, which D5 keeps). The overlay and generated workflow are temporary.

**D5. Owner's rule (2026-11-10): lean iRL, not a rebranded Madeira.** Take only the runtime pieces
Rocket League needs, and build iRL's own small app shell around them.
- **Keep:** Wine ARM64EC + wineserver thread, FEX ARM64EC, DXMT d3d11/dxgi + the LLVM it needs for
  runtime shader conversion, the JIT allocator + StikDebug attach (JIT fully on), the Epic
  sign-in/exchange-code launch from `EpicGames.swift` (only that part, read before porting),
  GnuTLS, FreeType.
- **Drop:** Steam/Madeira Dock, GOG/EA/itch libraries, cloud saves, D3D12/Mesa/zink/MoltenVK/
  KosmicKrisp/Vulkan, the whole i386/WoW64 build (CI jobs too), the built-in StikJIT/rppairing helper
  (StikDebug covers JIT), touch controls, the animated library UI.
- **FFmpeg: drop.** Checked the installed game: it ships no video files (no .bik/.bk2/.mp4/.wmv/.webm/.usm).
  Audio is Wwise (.bnk/.wem, decoded by Wwise itself), and the splash is a PNG. If a device log ever
  shows a Media Foundation or GStreamer call, revisit.
- Madeira's runtime defaults (logging, overlays, allocator settings) get **measured, not copied**.
- The phone screen gets a **still diagnostics view only**. CI is trimmed to match.

**D4. Upstream project policies don't apply.** iRL is private and nothing is upstreamed (owner, 2026-11-10).

**D6. Never block.** Decide, log it here, keep going (owner, 2026-11-10). Shader capture uses Heroic's existing Epic login.

## 4. Known issues / uncertainties (the device test settles these)

- **Memory reserve (if iOS kills the game for memory):** Madeira has an opt-in "donor pool": its
  MadeiraMemoryHost extension hands Wine memory that isn't billed to the app's footprint (`DonorPool.m`,
  enabled by `donor-pool-mb` in madeira.cfg; off by default in Madeira too). iRL leaves the extension out
  (lean rule, D5) and stubs the entry point. If the launch log shows a jetsam kill, bringing the extension
  back is the first memory lever, ahead of lowering texture caps.
- **Shader cache hits:** precompiled pixel shaders only hit if the phone uses Metal 3.2 (`shaders_320.db`)
  and DXMT's default pixel variant. The launch log prints DXMT's cache hit/miss counts
  (`DXMT_CACHE_STATS=1`). Misses are converted on the phone and saved into the same DB.
- **Shader coverage:** the capture covered menus, the garage, Free Play and one 4v4 bot match. Other
  arenas, modes and goal explosions convert on the phone the first time they appear.

- **Prepare AOT runs `FEXOfflineCompiler.exe` under Wine on the phone.** It's a verified ARM64EC
  binary (`llvm-readobj`: COFF-ARM64EC, CHPE metadata) that imports only ntdll, kernel32 and the CRT.
  It has never run, because there's no ARM64 Windows/Wine on the laptop. If it fails, the game still
  runs on the JIT, and the log shows why.
- **AOT coverage:** 19 modules seeded from PE metadata. X3DAudio1_7, dbghelp and xinput1_3 load below
  4 GB, and Madeira's FEX relocates those at runtime ("subfloor windows"), so they stay on the JIT
  (all cold code). Every JIT miss is recorded as a code map in `<FEX cache>/codemap/new/`, so the
  next Prepare pass adds it.
- **Code-map format:** written to match `irl-fex-aot` exactly (FileId hash, 64-bit executable marker
  `0xffffffef`, lowercase `c:\games\rocketleague\…` paths) and checked by a parser that mirrors
  `CodeMap::ParseCodeMap`. The game folder must appear at `C:\games\rocketleague` in the prefix.
- **AVX hidden:** Rocket League's AVX paths (about 12.5k YMM instructions) are behind `xgetbv` checks,
  so it uses SSE. If a log shows `STATUS_ILLEGAL_INSTRUCTION` on a VEX opcode, turn on Settings → AVX
  (compat), which re-runs Prepare.
- **Resolution:** the default is 900p → MetalFX ×1.6 → 1440p, chosen without device numbers. Pick
  the highest preset that holds 60 on the diagnostics screen. Dynamic resolution driven by GPU
  frame time isn't implemented yet; it needs device frame-time logs first.
- **Step 5 status:**
  - Already in the shipped FEX, so not rebuilt:
    - shadow return stack: Madeira's FEX call/return stack (`ResetCallRetStack`, `JIT/BranchOps.cpp`)
    - stack accesses exempt from TSO: `IsNonTSOReg`, RSP-based accesses
    - exact floating point: `X87ReducedPrecision=0`
    - CPUID steering to SSE: AVX hidden
    - preferred-base loading: Wine maps at `ImageBase` when free; RL's exe is at `0x140000000`
  - Done in the AOT inputs: static resolution of indirect targets. Vtables and function-pointer
    tables are found through `.reloc` and seeded, along with direct-call leaf functions. 179,443
    entry points in total.
  - Not done: cross-function register allocation (item 1) and per-function relaxed TSO (item 3b).
    They are FEX code-generation changes that need state-recovery tables and device crash and
    profile logs to validate. The JIT-miss code maps and diagnostics from your first test decide
    whether they're worth it.
- **CI:** the first lean build runs on GitHub's macos-26 (Xcode 26.6). Madeira's two Xcode-27-only
  features are guarded.

## 5. Logs

- Laptop: `logs/` (one file per job, timestamped, with the full command line).
- Generated AOT inputs: `build/aot/codemap-ready/` plus `manifest.json` (git-ignored, regenerate with the command in the log).
