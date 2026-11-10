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
| iRL app / Actions IPA | Building (interim) | Workflow `Build iRL IPA` on macos-26. `plan` passed. This interim full-Madeira build mainly seeds the LLVM/FEX caches; the lean shell (D5) replaces it. |
| Shaders (.metallib) | In progress | Capture running: RL under Heroic's Wine + DXVK shader dump, using Heroic's Epic login |
| Step 5 AOT optimizations | Not started | Needs the merged FEX to build first |

## 2. Setup steps for the owner

_Filled in once the IPA build is green._

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

## 4. Known issues / uncertainties

- Whether `FEXOfflineCompiler.exe` runs cleanly inside Madeira's Wine on iOS (D2) is only testable on the device.
- CI runs on GitHub's `macos-26` (Xcode 26.6, iOS 26.5 SDK, 3 CPU / 7 GB). Madeira's two Xcode-27-only features are already guarded (`build/ntdll-unix/build.sh` page-wait probe, `build-shader-headers.sh` atomic fix). The first full build may approach the 6-hour job limit. Caches make the next runs fast.

## 5. Logs

- Laptop: `logs/` (one file per job, timestamped, with the full command line).
- Generated AOT inputs: `build/aot/codemap-ready/` plus `manifest.json` (git-ignored, regenerate with the command in the log).
