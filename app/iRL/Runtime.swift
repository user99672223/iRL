import Foundation
import UIKit

/// Starts the runtime in this process: the JIT pool through StikDebug, wineserver as a thread,
/// then Wine (which starts FEX for the x86-64 game). One game run per app launch.
///
/// The order and the environment follow Madeira's ContentView.runWineFullSequence, keeping only
/// what one 64-bit D3D11 game needs.
@MainActor
final class Runtime: ObservableObject {
    static let shared = Runtime()

    enum Mode: String { case game = "Rocket League", aotPrepare = "AOT Prepare" }
    enum State: Equatable { case idle, preparing(String), running(Mode), failed(String) }

    @Published private(set) var state: State = .idle

    /// JIT pool size. Madeira's default (896 MB); RL's working set decides the next value.
    private let poolMB = 896

    func start(_ mode: Mode) {
        guard state == .idle else { return }
        guard jit_check_debugged() else {
            state = .failed("JIT is off. Open StikDebug, enable JIT for iRL, then press Start again.")
            LogStore.shared.log("[launch] JIT not enabled", level: .error)
            return
        }
        if mode == .game, !Paths.gameFound {
            state = .failed("Rocket League is missing: copy it to Documents/Games/rocketleague with tools/release/push-game.sh.")
            return
        }
        Paths.linkGame()
        state = .preparing("Starting \(mode.rawValue)…")
        LogStore.shared.log("[launch] mode=\(mode.rawValue) available-memory=\(os_proc_available_memory() >> 20)MB")

        Task.detached(priority: .userInitiated) {
            var args: [String] = []
            if mode == .game {
                do {
                    args = try await Self.epicArguments()
                } catch {
                    // Offline launch is allowed (CanRunOffline=true); the game then runs without Epic services.
                    LogStore.shared.log("[launch] Epic exchange code unavailable (\((error as? EpicAuthError)?.reason ?? "error")): offline launch", level: .error)
                    args = RocketLeagueLaunch.arguments(exchangeCode: nil, accountID: "", displayName: "")
                }
            }
            await MainActor.run { Runtime.shared.launch(mode, args: args) }
        }
    }

    private static func epicArguments() async throws -> [String] {
        let code = try await EpicAuth.shared.exchangeCode()
        guard let account = await EpicAuth.shared.account() else { throw EpicAuthError.signedOut }
        LogStore.shared.log("[epic] exchange code obtained for this launch", level: .success)
        return RocketLeagueLaunch.arguments(exchangeCode: code, accountID: account.id, displayName: account.name)
    }

    private func launch(_ mode: Mode, args: [String]) {
        configureEnvironment(mode, args: args)
        if mode == .aotPrepare { stageCodemaps() }

        let poolMB = self.poolMB
        let fail: @Sendable (String) -> Void = { msg in Task { @MainActor in Runtime.shared.state = .failed(msg) } }
        DispatchQueue.global(qos: .userInitiated).async {
            winios_phase("pool-alloc-begin")
            LogStore.shared.log("[jit] allocating \(poolMB)MB JIT pool through StikDebug")
            guard let pool = StikJITHelper.allocatePool(poolSize: poolMB * 1024 * 1024) else {
                let why = StikJITHelper.poolFailure ?? "no reason recorded"
                LogStore.shared.log("[jit] pool allocation FAILED: \(why)", level: .error)
                fail("JIT memory could not be set up: \(why)")
                return
            }
            setenv("WINE_IOS_JIT_RX", String(format: "%lx", Int(bitPattern: pool.rx)), 1)
            setenv("WINE_IOS_JIT_RW", String(format: "%lx", Int(bitPattern: pool.rw)), 1)
            setenv("WINE_IOS_JIT_SIZE", String(format: "%lx", pool.size), 1)
            if let h = StikJITHelper.poolHole { setenv("WINE_IOS_JIT_HOLE", String(format: "%lx:%lx", h.off, h.end), 1) }
            else { unsetenv("WINE_IOS_JIT_HOLE") }
            if let h = StikJITHelper.poolHole2 { setenv("WINE_IOS_JIT_HOLE2", String(format: "%lx:%lx", h.off, h.end), 1) }
            else { unsetenv("WINE_IOS_JIT_HOLE2") }
            if let low = StikJITHelper.poolLow { setenv("WINE_IOS_JIT_TAIL_REGION", String(format: "%lx:%lx", low.rx, low.size), 1) }
            else { unsetenv("WINE_IOS_JIT_TAIL_REGION") }
            LogStore.shared.log(String(format: "[jit] pool RX=0x%lx RW=0x%lx %ldMB", Int(bitPattern: pool.rx), Int(bitPattern: pool.rw), pool.size >> 20), level: .success)
            winios_phase("pool-ready")

            // The executable pool is mapped: the debugger can go (Madeira's early detach, ml524).
            StikJITHelper.detachDebugger()
            winios_phase("detach-done")

            let prefix = Paths.prefix.path
            try? FileManager.default.createDirectory(at: Paths.prefix, withIntermediateDirectories: true)
            wine_log_set_file(LaunchLogs.shared.file("wine.log").path)
            guard wineserver_start(prefix) == 0 else {
                LogStore.shared.log("[launch] wineserver failed to start", level: .error)
                fail("wineserver failed to start (see app.log)")
                return
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            while wineserver_is_ready() == 0, wineserver_is_running() != 0, CFAbsoluteTimeGetCurrent() - t0 < 5 {
                Thread.sleep(forTimeInterval: 0.01)
            }
            LogStore.shared.log(String(format: "[launch] wineserver ready after %.0f ms", (CFAbsoluteTimeGetCurrent() - t0) * 1000))
            winios_phase("wine-start")
            guard wine_process_start(prefix) == 0 else {
                LogStore.shared.log("[launch] Wine failed to start", level: .error)
                fail("Wine failed to start (see app.log)")
                return
            }
            LogStore.shared.log("[launch] \(mode.rawValue) started", level: .success)
            Task { @MainActor in Runtime.shared.state = .running(mode) }
            Runtime.watchExit(mode)
        }
    }

    nonisolated private static func watchExit(_ mode: Mode) {
        DispatchQueue.global(qos: .utility).async {
            while wine_process_is_running() != 0 { Thread.sleep(forTimeInterval: 1) }
            var status: UInt32 = 0
            let crashed = wine_crash_exit_status(&status) != 0
            LogStore.shared.log(String(format: "[launch] %@ exited, code=%d%@", mode.rawValue, wine_process_exit_code(),
                                       crashed ? String(format: " NTSTATUS=0x%08x", status) : ""),
                                level: crashed ? .error : .info)
            LaunchLogs.shared.flush()
            Task { @MainActor in
                Runtime.shared.state = .failed(mode == .aotPrepare
                    ? "AOT Prepare finished. Close and reopen iRL, then press Start."
                    : "The game exited. Close and reopen iRL before the next launch.")
            }
        }
    }

    /// The runtime's environment. Everything here is logged (with secrets redacted).
    private func configureEnvironment(_ mode: Mode, args: [String]) {
        let settings = Settings.shared
        var env: [(String, String)] = []
        switch mode {
        case .game:
            env.append(("MADEIRA_EXE", Paths.gameExeWindows))
            env.append(("MADEIRA_ARGS", RocketLeagueLaunch.commandLine(args)))
            // Rocket League's thread names -> QoS classes (tools/runtime/rocketleague/thread-qos.txt,
            // parsed by thread_ios.c tq_init_once): render/game threads on the P-cores.
            if let url = Bundle.main.url(forResource: "thread-qos", withExtension: "txt"),
               let rules = try? String(contentsOf: url, encoding: .utf8)
                .split(whereSeparator: \.isNewline).first.map({ $0.trimmingCharacters(in: .whitespaces) }),
               !rules.isEmpty {
                env.append(("MADEIRA_THREAD_QOS", rules))
            } else {
                LogStore.shared.log("[launch] thread-qos.txt missing from the bundle: default thread QoS", level: .error)
                unsetenv("MADEIRA_THREAD_QOS")
            }
        case .aotPrepare:
            unsetenv("MADEIRA_THREAD_QOS")
            // Its output (cache generation per module) goes to Wine's stderr, which the next app
            // start moves into this launch's folder as wine-stderr.log (LaunchLogs).
            // FEX's own offline compiler (same FEXCore build as xtajit64.dll), an ARM64EC program
            // linked into C:\windows\system32 from the bundle's farm.
            env.append(("MADEIRA_EXE", "FEXOfflineCompiler.exe"))
            env.append(("MADEIRA_ARGS", "process-all"))
        }
        // Wine's log level. Verbose adds loader, exception and module channels.
        env.append(("WINEDEBUG", settings.verboseWine ? "+seh,+loaddll,+module,+timestamp,warn+all,err+all" : "fixme-all,err+all"))
        // FEX: one global config (Config.json: EnableCodeCachingWIP=1, TSO policy, no reduced x87),
        // the same for the game and FEXOfflineCompiler, so the AOT caches match what loads them.
        // The cache is flat: <cache>cache\<module>-<fileid>-<config>; JIT misses go to codemap\new.
        RuntimeFiles.installFEXConfig()
        env.append(("FEX_APP_CONFIG_LOCATION", RuntimeFiles.fexConfigWindows))
        env.append(("FEX_APP_CACHE_LOCATION", Paths.fexCacheWindows))
        if settings.avxCompat { env.append(("MADEIRA_FEX_AVX", "2")) } else { unsetenv("MADEIRA_FEX_AVX") }
        // Display: the game renders at the preset's size (its fullscreen mode = the virtual monitor);
        // DXMT's MetalFX spatial swapchain scales that to the 2560x1440 layer.
        let preset = settings.preset
        env.append(("MADEIRA_SCREEN_W", String(preset.w)))
        env.append(("MADEIRA_SCREEN_H", String(preset.h)))
        RuntimeFiles.installDXMTConfig(preset)
        env.append(("DXMT_CONFIG_FILE", RuntimeFiles.dxmtConfWindows))
        unsetenv("DXMT_CONFIG")
        if preset.metalfx != nil { env.append(("DXMT_METALFX_SPATIAL_SWAPCHAIN", "1")) } else { unsetenv("DXMT_METALFX_SPATIAL_SWAPCHAIN") }
        if mode == .game { RocketLeagueConfig.apply(preset) }
        // Precompiled shaders: DXMT's own cache DB in a writable dir (absolute unix path ending in '/',
        // the only form dxmt_shader_cache.cpp honours). DXMT_SHADER_CACHE=0 or DXMT_PRECISE_MINMAX=0
        // would bypass or rename the DB, so they are never set.
        unsetenv("DXMT_SHADER_CACHE")
        unsetenv("DXMT_PRECISE_MINMAX")
        if let dir = RuntimeFiles.installShaderCache() {
            let path = dir.path.hasSuffix("/") ? dir.path : dir.path + "/"
            env.append(("DXMT_SHADER_CACHE_PATH", path))
        }
        env.append(("DXMT_CACHE_STATS", "1"))
        if settings.verboseDXMT { env.append(("DXMT_LOG_LEVEL", "info")) }
        if settings.metalValidation { env.append(("MTL_DEBUG_LAYER", "1")) }

        try? FileManager.default.createDirectory(at: Paths.fexCache, withIntermediateDirectories: true)
        for (k, v) in env { setenv(k, v, 1) }
        let shown = env.map { $0.0 == "MADEIRA_ARGS" && mode == .game ? "\($0.0)=\(RocketLeagueLaunch.redacted(args))" : "\($0.0)=\($0.1)" }
        LogStore.shared.log("[launch] environment: " + shown.joined(separator: " | "))
        let out = ExternalDisplay.shared.outputSize
        LogStore.shared.log("[display] \(ExternalDisplay.shared.describe()) preset=\"\(preset.name)\" render=\(preset.w)x\(preset.h) "
            + (preset.metalfx.map { String(format: "MetalFX x%.4g -> %dx%d", $0, Int((Double(preset.w) * $0).rounded()), Int((Double(preset.h) * $0).rounded())) } ?? "native")
            + " layer=\(out.w)x\(out.h)")
    }

    /// Static code maps from the IPA (laptop-generated) into <cache>/codemap/ready, where
    /// FEXOfflineCompiler process-all reads them alongside the JIT-miss maps in codemap/new.
    func stageCodemaps() {
        let fm = FileManager.default
        let ready = Paths.fexCache.appendingPathComponent("codemap/ready", isDirectory: true)
        try? fm.createDirectory(at: ready, withIntermediateDirectories: true)
        try? fm.createDirectory(at: Paths.fexCache.appendingPathComponent("codemap/new", isDirectory: true), withIntermediateDirectories: true)
        guard let src = Paths.bundledCodemaps, let maps = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else {
            LogStore.shared.log("[aot] no static code maps in this IPA: only JIT-miss maps will be compiled", level: .error)
            return
        }
        var n = 0
        for m in maps {
            let dst = ready.appendingPathComponent(m.lastPathComponent)
            // process-all merges codemap/new into ready; keep a merged map that is newer than ours.
            if fm.fileExists(atPath: dst.path) { continue }
            if (try? fm.copyItem(at: m, to: dst)) != nil { n += 1 }
        }
        LogStore.shared.log("[aot] staged \(n) static code map(s) into codemap/ready (\(maps.count) in the IPA)")
    }

    /// AOT state for the phone screen: how many module caches exist.
    nonisolated static func aotCacheCount() -> Int {
        let dir = Paths.fexCache.appendingPathComponent("cache", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count
    }
}
