# iRL: morning report

_Last updated: 2026-11-10 07:15 CET. The IPA is ready to install; device test pending._

## 1. Status

| Area | State | Notes |
|---|---|---|
| IPA | **Ready** | `dist/iRL-final.ipa` (198 MB, sha256 `4da1ff00…`). Release build from CI run [42831515317](https://github.com/user99672223/iRL/actions/runs/42831515317) plus the 19 AOT code maps and the precompiled shader DB. No debug or preview dylibs. The dSYM is in that run's `iRL-dSYM` artifact. The Home screen has a **Status** section: JIT ✅/❌ (live), Increased Memory Limit ✅ granted / ❌ not in profile (read from the profile Impactor installs), and the actual memory limit in GB. |
| iRL app | Built, simulator-tested | iRL's own lean SwiftUI app (`app/`, XcodeGen), not a rebranded Madeira (D5). Simulator self-test: 39/39 checks ([run 42765448369](https://github.com/user99672223/iRL/actions/runs/42765448369)), with screenshots in its `sim-selftest` artifact. It caught a blank-phone-screen bug, which is now fixed. |
| FEX | Done | `user99672223/FEX` `irl-fex-aot` @ `4cb2b62b3` = Madeira `ios-port-2607` + upstream's AOT loader (D1) + 3 fixes found on the ARM64 bench. One of those affects the phone: CheckCall read the 32-bit NtDll LUT size with a 64-bit load. |
| AOT inputs | Done, verified, PGO'd | 182,212 entry points across 19 modules: pdata, exports and TLS; direct-call leaf functions; vtables and function-pointer tables from `.reloc`; plus 2,827 game-module functions the JIT had to translate during real boots to the menu on the ARM64 CI bench (`tools/aot/pgo/jit-misses.json`). Result on the bench: JIT misses in rocketleague.exe went from 2,585 to 58 (now also merged), and EOS SDK/vcruntime went to 0. |
| AOT compile + load | **Verified on a real ARM64 CPU** | ARM64 Linux CI bench (Wine 11.4 ARM64EC + this FEX, non-iOS build): 19/19 RL modules compiled in 15 s, 385 MB of caches, loaded at boot. Only 320 JIT-miss blocks in `rocketleague.exe`, and the feedback loop re-imports them. On the phone it runs in the Prepare AOT step. |
| Boot to the main menu | **Verified on ARM64 CI** | RL reached `menu_main_p` / `GameInfo_GFxMenu_TA` in 28.7 s under Wine ARM64EC + FEX + AOT, on software rendering, offline ([run 42764735660](https://github.com/user99672223/iRL/actions/runs/42764735660)). Metal/DXMT and the iPhone's JIT can only be tested on the device. |
| Shaders | Done (pixel), device-fed (vertex) | 21,248 shaders captured from real play on the laptop. All 15,428 pixel shaders are precompiled into DXMT's own cache DB (`shaders_320.db`, exact keys), so DXMT gets cache hits with no code change. Vertex shaders depend on runtime input layouts and are added from the first device log. |
| Runtime tuning | Done (defaults) | FEX config (AOT on, TSO policy, exact x87, no AVX), MetalFX presets (default 900p → 1440p), 60 fps cap, thread QoS from RL's real thread names, Legendary's exact no-EAC launch line. |
| Step 5 deep FEX work | Deferred to after the device logs | See section 4 (what's already in FEX vs. what's left). |

## 2. Setup steps for the owner

1. **IPA:** `dist/iRL-final.ipa` in the repo folder on the laptop. To rebuild it from the newest
   green CI run, run `bash tools/release/make-final-ipa.sh`.
2. **Install with Impactor:** iPhone on USB → Impactor → sign in with your Apple ID → pick
   `iRL-final.ipa` → install. Impactor adds Increased Memory Limit automatically. Extended Virtual
   Addressing was removed from the entitlements on purpose (free account).
3. **Trust the profile:** Settings → General → VPN & Device Management → your Apple ID → Trust.
4. **Import the game (once, about 42 GB over USB):** open iRL once, then with the iPhone plugged in,
   unlocked and trusted, run in the repo folder:
   `bash tools/release/push-game.sh`
   It checks free space, copies the game into **iRL › Games › rocketleague** (skipping EasyAntiCheat),
   resumes if the cable drops, and verifies `RocketLeague.exe`. Home shows **Game: found**.
5. **Enable JIT:** StikDebug → iRL → enable JIT. Home shows JIT on.
6. **Prepare AOT (once per game patch):** tap **Prepare AOT** and keep the phone on power. FEX's
   offline compiler translates the game's x86-64 code to ARM64 (about 385 MB of caches; the laptop
   bench took 15 s on 4 cores, so expect minutes on the phone). Then close iRL from the app switcher,
   reopen it, and enable JIT again.
7. **Sign in to Epic:** tap **Sign in to Epic** and log in. iRL keeps only the refresh token
   (Keychain). If you skip this, the game still reaches the menu offline.
8. **Connect the monitor:** USB-C hub → DisplayPort monitor, with the DualSense and AirPods Max on the hub.
9. **Start:** JIT enabled → **Start**. Expect a black screen of a minute or two on the first launch
   (the laptop took 2 min to reach the menu natively). The game shows on the monitor, and the phone
   shows the diagnostics screen.
10. **Send logs:** **Share logs** zips the last launch's folder. It's also in Files › iRL › Logs.
11. **Feed back JIT misses:** after a session, tap **Prepare AOT** again. It adds every function the
    JIT had to translate during play into the caches.

## 3. Decisions

**D1. FEX = Madeira `ios-port-2607` + upstream's AOT code-cache loader, cherry-picked.**
Madeira's FEX mapped AOT caches on the Wine/ARM64EC path but never used them (`TODO: LoadCache`).
A full merge of FEX-2611 (27 conflicting files) was tried and dropped. Upstream replaced the whole
code-buffer model, and Madeira's iOS JIT-pool sweeper is built on the old one, so merging would mean
rewriting the most crash-prone iOS code blind. Instead, 6 upstream commits applied cleanly (LoadCache /
EnableLoadedSection wiring, FEXOfflineCompiler loading, the WoA syscall ABI, EC-code marking, exe bitness
in code maps), plus offline-compiler stubs for Madeira's iOS hooks and 3 fixes from the ARM64 bench.
Upstream's separate runtime DiskCache (~60 commits) isn't needed for AOT, so it's left out. The partial
merge attempt is kept in `logs/fex-full-merge-partial-resolution-*.patch`.

**D2. AOT caches are generated on the iPhone (Prepare AOT), from code maps built on the laptop.**
The offline compiler is an ARM64EC Windows program, and Madeira's FEX is built with `FEX_IOS_HOST`,
which changes code generation. The A16's CPU features also feed the cache. Only the phone can produce
caches that exactly match the shipped runtime. The laptop does the analysis, the IPA ships the code
maps, and the phone compiles them.

**D2b. Static code maps instead of recorded ones.** Seeds come from PE metadata (entry point,
exports, TLS, `.pdata`), plus direct-call targets (leaf functions) and relocated data pointers into
code (vtables, function tables). The result is 179,443 entries, and the bench showed only 320 misses
in the main exe. Modules loaded below 4 GB (dbghelp, xinput1_3, X3DAudio1_7) stay on the JIT, because
Madeira relocates them at runtime. Prepare AOT also prunes their JIT-miss maps.

**D3. Superseded.** The first idea was Madeira plus an overlay; D5 replaced it.

**D4. Upstream project policies don't apply.** iRL is private and nothing is upstreamed (owner).

**D5. Lean iRL (owner's rule).** iRL keeps only Wine ARM64EC + the wineserver thread, FEX, DXMT
d3d11/dxgi + LLVM, the JIT allocator + StikDebug attach, Epic sign-in/launch, GnuTLS and FreeType.
It drops Steam/Dock, the other stores, cloud saves, D3D12/Mesa/Vulkan/MoltenVK, i386/WoW64, the
built-in pairing helper, touch controls, the animated UI and FFmpeg (the game ships no videos).
`tools/build/components.md` gives the reason for each. Madeira's bridges are compiled in place from
the pinned submodule at `-O0 -DDEBUG=1`, as in Madeira's own Debug build, because Madeira records
that its Release builds crashed the guest.

**D6. Never block.** Decide, log it here, and continue (owner). Shader capture and the trace of the
files the menu needs used Heroic's existing Epic login.

**D7. Rocket League runtime defaults (no device numbers yet).** Render at 1600×900, MetalFX ×1.6 →
2560×1440, 60 fps cap, effects off. FEX TSO is on with FEX's defaults (stack accesses exempt), exact
x87 and AVX hidden (RL's AVX paths are behind `xgetbv` checks). Thread QoS: main/render/audio at
user-interactive, the 13-thread worker pool one level down, I/O utility and telemetry background.
Details are in `tools/runtime/*/README.md`.

**D8. Game files for CI stay private.** The menu file set (281 files, 538 MB compressed, texture
caches kept sparse) is in the private repo `irl-assets`. CI reads it through a read-only deploy
key. No game file is in the public iRL repo, its artifacts or its logs.

## 4. Known issues / uncertainties (the device test settles these)

- **Never run on an iPhone:** JIT pool + StikDebug attach, Wine/DXMT startup on Metal, the external
  display mode switch, DualSense, Epic sign-in, the Release configuration, and Prepare AOT with the
  iOS build of the compiler. Each one logs enough to fix it from your logs.
- **Offline / sign-in failure:** RL exits (hands off to the Epic launcher) without the `-AUTH_*`
  arguments. With a dummy code it reaches the menu offline, verified on the laptop and on CI. iRL's
  fallback uses that form.
- **CI after the menu:** across 4 ARM64 bench runs RL reaches the main menu every time, then crashes
  seconds later reading texture-cache bytes that CI's partial copy of the game doesn't contain. Each run
  streams from different offsets (most recently `Textures6.tfc`). Proving a long idle in CI would need
  all 23 GB of texture caches in the private repo, so it stops here. The phone has the full game. Final
  JIT misses during the boot with PGO: rocketleague.exe 54 (was 2,585), EOS SDK 0, vcruntime 0. The
  remaining ~480 are tiny x64 stubs in Wine's own DLLs (different builds on the phone; its first Prepare
  pass picks them up). Runs: 42764735660, 42765992452, 42766823928, 42767673247, 42769758619, 42774986454.
- **Memory:** CI RSS (5–6.9 GB peak) isn't representative: wined3d on llvmpipe reports 12 GB of "VRAM"
  and keeps GPU resources in process RAM. On the phone DXMT reports the real Metal budget.
  The AOT caches are 385 MB of dirty memory (exe 205 MB, EOS SDK 135 MB). If iOS kills
  the game (jetsam in the log), the first lever is to drop the mostly cold EOS SDK from AOT. The next
  is Madeira's donor-pool extension (left out under D5, stubbed), then lower texture caps.
- **Shader cache hits:** pixel shaders hit only if DXMT runs at Metal 3.2 with its default pixel
  variant. The log prints hit/miss counts (`DXMT_CACHE_STATS=1`). Misses are converted on the phone
  and saved into the same DB. The capture covered menus, the garage, Free Play and one 4v4 bot match.
- **AVX:** if a log shows `STATUS_ILLEGAL_INSTRUCTION` on a VEX opcode, turn on Settings → AVX (compat).
  That re-runs Prepare.
- **Resolution:** pick the highest preset that holds 60 on the diagnostics screen. Dynamic resolution
  needs device frame-time data first.
- **Dropped pieces that might be needed:** the aarch64 DLL farm and winegstreamer. A `c0000135` in the
  log means one is missing.
- **Step 5:**
  - Already in FEX: shadow return stack (call/ret stack), TSO exemption for stack accesses, exact x87,
    CPUID steering, preferred-base loading.
  - Done in the AOT inputs: static resolution of indirect targets.
  - Left for after the device logs: cross-function register allocation, per-function relaxed TSO,
    file-backed (signed dylib) AOT caches to cut dirty memory, and vertex-shader precompiling.

## 5. Logs

- **Laptop:** `logs/`, one file per job, timestamped, with the full command line (secrets redacted).
  Covers clones, FEX build/merge/cherry-picks, code maps, shader capture/conversion/DB, asset tracing,
  and IPA assembly.
- **CI:** GitHub Actions on the iRL repo.
  - `Build iRL IPA`: the device IPA and dSYM.
  - `iRL simulator self-test`: screenshots and app logs.
  - `arm64-bench` (branch `ci-arm64`): Wine/FEX smoke test, AOT on RL, boot to the menu, plus
    Launch.log, code maps and FEX logs.
- **iPhone:** Files › iRL › Logs › one folder per launch, holding:
  - the app log (environment, display mode, launch line with secrets redacted)
  - Wine output
  - FEX logs and the JIT-miss code maps
  - DXMT logs and cache stats
  - diagnostics samples
  - crash reports with registers and a backtrace
  **Share logs** zips the latest folder. Send the zip back.
