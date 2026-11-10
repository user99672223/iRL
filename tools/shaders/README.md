# Shader capture and offline conversion (CLAUDE.md Step 4)

Rocket League's packages are encrypted, so its DXBC shaders are captured at runtime on the laptop and
converted offline to Metal with DXMT's own converter (airconv), built natively on Debian.

## 1. Capture (laptop, x86 Proton + DXVK)

| Piece | What is used |
|---|---|
| Epic login | Heroic's existing Legendary session (`~/.config/heroic/legendaryConfig/legendary`). No password is entered. |
| Launch | `legendary launch Sugar --dry-run --override-exe Binaries/Win64/RocketLeague.exe --json` gives a fresh exchange code and Legendary's argument set. Launching `RocketLeague.exe` directly skips `Launcher.exe`/EAC (no-EAC mode). |
| Runtime | Heroic's GE-Proton (GE-Proton11-9) and its DXVK, in Heroic's own Rocket League prefix |
| Dump | `DXVK_SHADER_DUMP_PATH` (DXVK writes every DXBC it compiles as `<stage>.<hash>.dxbc`, plus `.spv`) |
| GPU | Intel UHD (CML GT2) via Mesa ANV (`MESA_VK_DEVICE_SELECT=8086:9a49`) |

```bash
tools/shaders/capture.sh 1800          # runs the game for N seconds, logs to logs/shader-capture-*.log
tools/shaders/rl-ui.sh shot out.png    # screenshot of the game window (Xwayland)
tools/shaders/rl-ui.sh click X Y       # click (coordinates in the 960-wide screenshot space)
tools/shaders/tour.sh 6 /tmp           # from the Exhibition screen: N random-arena 4v4 bot matches
tools/shaders/collect.py build/shaders/dxbc build/shaders/raw-*   # dedupe and sort by stage
```

xdotool comes from Debian's own `xdotool`/`libxdo3` packages, unpacked into `build/tools-xdotool`
(no system install). Logs redact the exchange code, the Epic username and the user ID.

**Run on 2026-11-10 (game version `++Prime+Update60.1-CL-533021`, Season 24).** Covered: boot, title,
main menu and garage car, Play/Offline menus, Season setup screen, Free Play on Futura Garden (boost,
jumps, ball launch and shot drills), and a 4v4 Rookie-bot Exhibition on a random arena. Two runs, 90 s
and 1800 s.

| Stage | Unique shaders |
|---|---|
| Pixel (ps) | 15,428 |
| Vertex (vs) | 5,820 |
| Hull/domain/geometry/compute | 0 seen |
| **Total** | **21,248** (SHA-256 of the DXBC bytes; the DXBC MD5 checksum is kept in `manifest.json`) |

Not yet covered, for the next capture: most other arenas (the tour script now joins a team; it got
stuck on "Choose team" in the first run), Rumble/Hoops/Dropshot/Snow Day, replays, goal explosions
from scored goals, the item shop, and rain/night maps. The device-side DXMT miss log will also list
anything missed.

## 2. airconv on Debian

`tools/shaders/build-airconv-linux.sh` builds `madeira/dxmt/src/airconv` natively against host
**LLVM 15.0.7**, the version Madeira pins. LLVM is built from the official release tarballs, only
the 34 libraries airconv links (`logs/shader-llvm15-build-*.log` has the exact cmake line).
Linux-only adjustments, all done at build time, with nothing changed in `madeira/`:
- an empty `d3dcompiler.h` shim (the CLI only uses `D3DDisassemble` under `#ifdef __WIN32`)
- `-include optional/string/cstring` (libstdc++ doesn't pull these in transitively like libc++)
- LP64 fix: `Create{Extract,Insert}Element(v, 0ull)` is ambiguous where `uint64_t` is
  `unsigned long`, so the build compiles patched copies with `(uint64_t)0`
- DXBCParser built with exceptions enabled, as DXMT's meson does
- **The helper AIR modules (msad, samplepos, tessellation) are 1-byte stubs.** They are `.metal`
  sources that only Apple's `metal` compiler can build. airconv links them into every shader with
  `LinkOnlyNeeded`, so a shader that doesn't use them is unaffected. `convert.py` rejects any shader
  whose IR still declares a non-`air.*`/`llvm.*` function, so those stay on DXMT's runtime path.
  To lift this, put the real `air_*.h` from a macOS run of `tools/build/build-shader-headers.sh` in
  `build/airconv/gen/`.

## 3. Conversion

```bash
tools/shaders/convert.py --jobs 7      # build/shaders/metallib/<stage>/<sha256>.metallib + report.json
```

The output is a valid `MTLB` container written by DXMT's own `MetallibWriter`. No Apple tools are needed.

**Result 2026-11-10: 21,248 of 21,248 converted** (15,428 ps + 5,820 vs), 0 failures, 0 needing a helper module, in
81 s on 7 threads. Log: `logs/shader-convert-20261110T053359.log`.

## 4. Open integration points (device side)

- **Variants:** the airconv CLI compiles the default variant only. DXMT's runtime passes per-PSO
  arguments (IA input layout for VS, sample mask / dual-source etc. for PS) and keys its cache on
  them (`dxmt_shader_cache`, `kDXMTShaderCacheVersion = 19`). A precompiled entry is only a hit
  if the loader keys it by the DXBC hash plus the default argument set. Variant-specific entries
  need either the runtime argument records (log them from DXMT on the device, then replay them here)
  or a variant-agnostic load path.
- **Final `.metallib` vs `MTLBinaryArchive`:** per-shader metallibs skip DXBC→AIR conversion and
  Metal's front end on the device. GPU-binary pipeline archives (`MTLBinaryArchive`) can only be
  produced on Apple hardware. Harvest them on the device on first run.
