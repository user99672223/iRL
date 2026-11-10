# iRL: morning report

_Last updated: 2026-11-10 (run in progress)._

## 1. Status

| Area | State | Notes |
|---|---|---|
| GitHub repo | Done | Public: https://github.com/user99672223/iRL |
| Clones and pins | Done | `workspace/` (git-ignored); exact SHAs in `PINS.md` |
| FEX pin | **Blocked: needs your decision** | Madeira's `ios-port-2607` can't load AOT caches on the Windows/ARM64EC path. See D1. |
| AOT code maps | Done, verified | `tools/aot/gen_codemaps.py`: 22 modules, ~158k seeded blocks (RocketLeague.exe: 81,786) |
| AOT cache generation | Not done | Depends on D1. Plan: run on the iPhone (D2). |
| iRL app / Actions IPA | Building (interim) | Workflow `Build iRL IPA` on macos-26. `plan` passed. This interim full-Madeira build mainly seeds the LLVM/FEX caches; the lean shell (D5) replaces it. |
| Shaders (.metallib) | Not started | |
| Step 5 AOT optimizations | Blocked by policy | See decision D4 |

## 2. Setup steps for the owner

_Filled in once the IPA build is green._

## 3. Decisions

**D1 (revised). The pinned FEX cannot use AOT caches on Windows yet. Rebase pending your call.**
In Madeira's `ios-port-2607`, `Source/Windows/Common/ImageTracker.cpp` maps cache files but never
loads them (`// TODO: CodeCache::LoadCache, CodeCache::RegisterMappedCodeBuffer`, and the same for
`EnableLoadedSection`). Upstream FEX finished this path (FEX-2609 `DiskCache`). Madeira's fork
has no newer iOS branch. A test merge of `FEX-2611` into Madeira's 133 iOS commits stops with
**27 conflicting files**, including `JIT.cpp`, `BranchOps.cpp`, `Allocator.cpp`, `Frontend.cpp` and
the iOS transition code `ARM64EC/Module.S` / `Module.cpp` (merge aborted, nothing changed; log
in `logs/fex-merge-*`). Resolving those means writing FEX source by hand, which D4 rules out
for me. Options:
1. You (or Madeira upstream) do the rebase onto FEX-2611. Everything else in the AOT pipeline is ready to plug in.
2. You allow AI-written conflict resolution in a private, never-upstreamed fork. I would do it on a
   branch with a full log, and nothing is verifiable before a device test.
3. Ship JIT-only now (Madeira as is) and do AOT later.

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

**D4. FEX's own policy.** `FEX/CLAUDE.md` says AI must not be used to generate code for
contributions to FEX. I have not modified FEX source. All AOT tooling lives in iRL's `tools/`.
Step 5 items 1–4 and 7–8 are FEXCore code-generation changes. **You need to decide** whether
those may be AI-written in your private fork (never upstreamed), or written by you.

## 4. Known issues / uncertainties

- Whether `FEXOfflineCompiler.exe` runs cleanly inside Madeira's Wine on iOS (D2) is only testable on the device.
- CI runs on GitHub's `macos-26` (Xcode 26.6, iOS 26.5 SDK, 3 CPU / 7 GB). Madeira's two Xcode-27-only features are already guarded (`build/ntdll-unix/build.sh` page-wait probe, `build-shader-headers.sh` atomic fix). The first full build may approach the 6-hour job limit. Caches make the next runs fast.

## 5. Logs

- Laptop: `logs/` (one file per job, timestamped, with the full command line).
- Generated AOT inputs: `build/aot/codemap-ready/` plus `manifest.json` (git-ignored, regenerate with the command in the log).
