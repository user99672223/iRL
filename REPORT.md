# iRL: morning report

_Last updated: 2026-11-10 (run in progress)._

## 1. Status

| Area | State | Notes |
|---|---|---|
| GitHub repo | Done | Public: https://github.com/user99672223/iRL |
| Clones and pins | Done | `workspace/` (git-ignored); exact SHAs in `PINS.md` |
| FEX pin | Done | Madeira's FEX `ios-port-2607` (`1dc6ed49`). See decision D1. |
| AOT code maps | Done, verified | `tools/aot/gen_codemaps.py`: 22 modules, ~158k seeded blocks (RocketLeague.exe: 81,786) |
| AOT cache generation | Not done | Runs on the iPhone (decision D2); not testable on the laptop |
| iRL app / Actions IPA | In progress | Madeira pinned as base plus an iRL overlay (decision D3) |
| Shaders (.metallib) | Not started | |
| Step 5 AOT optimizations | Blocked by policy | See decision D4 |

## 2. Setup steps for the owner

_Filled in once the IPA build is green._

## 3. Decisions

**D1. FEX pin = Madeira's `ios-port-2607` fork, not a rebase.** It is already newer than the
2512/2601 offline-cache work (code maps, `FEXOfflineCompiler`, cache validation, PE relocations,
`ENABLE_OFFLINE_RUNTIME`). Rebasing the iOS changes would only add risk. The FEX that generates
the caches is the same build that is shipped.

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

**D3. iRL = Madeira (pinned submodule) + iRL overlay.** Madeira already has the Wine
ARM64EC/wineserver thread, FEX, DXMT, StikDebug JIT, IML, Game Mode, file sharing and an Epic
exchange-code launch. Reusing it is higher quality than rewriting it.

**D4. FEX's own policy.** `FEX/CLAUDE.md` says AI must not be used to generate code for
contributions to FEX. I have not modified FEX source. All AOT tooling lives in iRL's `tools/`.
Step 5 items 1–4 and 7–8 are FEXCore code-generation changes. **You need to decide** whether
those may be AI-written in your private fork (never upstreamed), or written by you.

## 4. Known issues / uncertainties

- Whether `FEXOfflineCompiler.exe` runs cleanly inside Madeira's Wine on iOS (D2) is only testable on the device.
- The CI runner label: Madeira's CI uses `xcode-27` and needs the iOS 27 SDK. Being probed on GitHub-hosted runners.

## 5. Logs

- Laptop: `logs/` (one file per job, timestamped, with the full command line).
- Generated AOT inputs: `build/aot/codemap-ready/` plus `manifest.json` (git-ignored, regenerate with the command in the log).
