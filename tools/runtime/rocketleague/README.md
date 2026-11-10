# Rocket League graphics/memory profile for iRL

- **Resolution:** CLAUDE.md asks for native 1440p60 if it holds, otherwise the highest internal
  resolution that holds 60, upscaled with MetalFX spatial. The default is **1600x900 → MetalFX ×1.6 →
  2560x1440**. It's a middle preset chosen without device numbers. The app's Settings offer the four
  presets. Pick the highest one that the diagnostics screen shows holding 60 fps.
- **Why ResX/ResY rather than ScreenPercentage:** UE3's ScreenPercentage upscales the 3D scene
  bilinearly. MetalFX spatial is a much better upscaler, so the game renders everything at the
  internal size (`ScreenPercentage=100`) and DXMT's MetalFX swapchain does the upscaling.
- **Effects off** (shadows, DoF, AO, bloom, motion blur, lens flares, high-quality materials): they
  are GPU- and bandwidth-heavy on a 5-core TBDR GPU, and competitive players turn them off anyway.
- **Texture memory:** Rocket League's user config has no streaming-pool key. The per-group
  `TEXTUREGROUP_* MaxLODSize` caps are the supported control, so they keep the game's values (the
  laptop profile already caps World at 1024).
- **Vsync off in the game:** DXMT paces to 60 against the external display (`dxmt.conf`).
- **Not done yet:** dynamic resolution driven by GPU frame time needs device frame-time data
  (see REPORT.md, known issues).

## Thread QoS (`thread-qos.txt` → env `MADEIRA_THREAD_QOS`)

Thread names were taken from the real game running under Wine on the laptop (`/proc/<pid>/task/*/comm`,
2026-11-10). Unnamed threads, which include the main game thread, keep `user-interactive`.
| Pattern | Class | Why |
|---|---|---|
| RenderingThread*, AK::EventManage* | user-interactive | Frame-critical: render submission and Wwise audio mixing (crackles otherwise) |
| PoolThread* (13 threads) | user-initiated | UE3 worker pool. One level down so 13 workers can't crowd the main and render threads off the 2 P-cores |
| HttpManager*, Libwebsockets* | default | Online services, latency-tolerant |
| ThreadedTickWeb*, AK::BankManage*, RocketL*:disk*, AsyncIOSystem*, EncryptionWorke*, Rtc* | utility | Loading, I/O, voice chat |
| Rocket*:traceq* | background | Telemetry |
The patterns use `*` because Linux truncates `comm` to 15 characters, while Wine on iOS sees the full
SetThreadDescription name. Madeira's ECO mode still overrides these rules.
