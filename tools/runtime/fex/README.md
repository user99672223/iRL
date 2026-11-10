# FEX runtime config for iRL

`Config.json` goes in FEX's config directory inside the app (`FEX_APP_CONFIG_LOCATION`, with a
trailing separator). Because it is the *global* config, `RocketLeague.exe` and
`FEXOfflineCompiler.exe` read exactly the same settings, and an AOT cache only matches the
configuration that generated it.

| Option | Value | Why |
|---|---|---|
| EnableCodeCachingWIP | 1 | Loads the AOT caches (`<cache>/cache/<module>-<fileid>-0…0`) and records JIT misses as code maps in `<cache>/codemap/new/`. These feed the next AOT pass. |
| Multiblock | 1 | Whole-function translation (FEX default). Stutter from long compiles is moved to AOT. |
| TSOEnabled | 1 | UE3 is heavily multithreaded, and iOS has no hardware TSO. Correctness comes first (FEX default). |
| VectorTSOEnabled | 0 | FEX default. Vector loads and stores are not used for cross-thread sync in UE3. |
| MemcpySetTSOEnabled | 0 | FEX default. REP MOVS/STOS aren't atomic on x86 either. |
| HalfBarrierTSOEnabled | 1 | FEX default. Unaligned atomics get backpatched to half barriers. |
| X87ReducedPrecision | 0 | CLAUDE.md: never use reduced-precision x87. |

**AVX:** don't set `MADEIRA_FEX_AVX` (for the game or the compiler). Madeira's iOS FEX then reports
no AVX, so Rocket League takes its SSE paths. `RocketLeague.exe` has about 12.5k YMM instructions,
but its 3 `xgetbv` checks gate them, and FEX would run 256-bit ops as two NEON halves plus extra
state saves. If a device log ever shows `STATUS_ILLEGAL_INSTRUCTION` on a VEX opcode, set
`MADEIRA_FEX_AVX=2` for **both** programs and re-run Prepare AOT.
