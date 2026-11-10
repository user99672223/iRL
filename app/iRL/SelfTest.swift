import Foundation
import SwiftUI
import UIKit

/// `-irl-selftest`: exercises every app-side path without Wine (CI, iOS Simulator), then shows
/// Home, Settings and Diagnostics in turn for screenshots.
///
/// Files (Documents/):
///   selftest-screen.txt   the screen now shown (home, settings, diagnostics): CI screenshots on change
///   selftest-result.txt   PASS or FAIL, then one line per check; written last
/// The same report goes to the launch folder as selftest.txt (and so into Share logs).
@MainActor
final class SelfTest: ObservableObject {
    static let shared = SelfTest()
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("-irl-selftest") }

    enum Screen: String { case home, settings, diagnostics }
    @Published var screen: Screen?

    private var lines: [String] = []
    private var failures = 0
    private let fm = FileManager.default

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failures += 1 }
        let line = "\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : ": \(detail)")"
        lines.append(line)
        LogStore.shared.log("[selftest] \(line)", level: ok ? .success : .error)
    }

    private func announce(_ s: Screen) async {
        // Close the previous sheet first: SwiftUI drops a presentation that starts while another dismisses.
        screen = nil
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        screen = s
        try? await Task.sleep(nanoseconds: 1_500_000_000)   // the sheet finishes presenting
        // Handshake with CI: hold the screen until the screenshot is taken (ack file), at most 30 s.
        let ack = Paths.documents.appendingPathComponent("selftest-ack-\(s.rawValue)")
        try? fm.removeItem(at: ack)
        try? s.rawValue.write(to: Paths.documents.appendingPathComponent("selftest-screen.txt"), atomically: true, encoding: .utf8)
        for _ in 0..<60 where !fm.fileExists(atPath: ack.path) {
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        let colours = renderedColours()
        check("screen \(s.rawValue) drawn", colours > 1,
              "\(colours) distinct colours sampled; " + (fm.fileExists(atPath: ack.path) ? "screenshot acknowledged" : "no screenshot ack within 30 s"))
    }

    func run() async {
        LogStore.shared.log("[selftest] start")
        try? fm.removeItem(at: Paths.documents.appendingPathComponent("selftest-result.txt"))
        logFolder()
        presets()
        iniMerge()
        fexConfig()
        codemaps()
        shaderCache()
        aotInvalidation()
        gameLink()
        gameFileCheck()
        launchArguments()
        crashWriter()
        await announce(.home)
        await announce(.diagnostics)
        await announce(.settings)
        screen = nil
        shareZip()   // last: the zip carries every line above
        finish()
    }

    /// Distinct colours at 25 points of the frontmost window's content area (below the status bar):
    /// 1 means nothing was drawn (the blank-window failure this check exists for).
    private func renderedColours() -> Int {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }.flatMap(\.windows)
        guard let window = windows.last(where: { !$0.isHidden }) ?? windows.first else { return 0 }
        let bounds = window.bounds
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            window.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
        var seen = Set<UInt32>()
        let bpr = cg.bytesPerRow, bpp = cg.bitsPerPixel / 8
        for i in 1...5 {
            for j in 1...5 {
                let x = cg.width * i / 6, y = cg.height / 8 + (cg.height * 3 / 4) * j / 6
                let o = y * bpr + x * bpp
                seen.insert(UInt32(p[o]) << 16 | UInt32(p[o + 1]) << 8 | UInt32(p[o + 2]))
            }
        }
        return seen.count
    }

    // MARK: checks

    private func logFolder() {
        let logs = LaunchLogs.shared
        check("launch folder exists", fm.fileExists(atPath: logs.folder.path), logs.folder.lastPathComponent)
        LogStore.shared.log("[selftest] app.log probe")
        logs.flush()
        let size = (try? fm.attributesOfItem(atPath: logs.file("app.log").path)[.size] as? NSNumber)??.intValue ?? 0
        check("app.log written (buffered writer flushed)", size > 0, "\(size) bytes")
    }

    private func readSystemSettings(_ url: URL) -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var inSection = false, out: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inSection = t.caseInsensitiveCompare("[SystemSettings]") == .orderedSame; continue }
            guard inSection, let eq = t.firstIndex(of: "=") else { continue }
            out[t[..<eq].trimmingCharacters(in: .whitespaces)] = t[t.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    private func presets() {
        // A prefix user profile with the owner's own keys, which must survive every preset change.
        let ini = Paths.driveC.appendingPathComponent("users/mobile/Documents/My Games/Rocket League/TAGame/Config/TASystemSettings.ini")
        try? fm.createDirectory(at: ini.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? "[SystemSettings]\r\nOwnerKey=Kept\r\nResX=800\r\n\r\n[Other]\r\nX=1\r\n".write(to: ini, atomically: true, encoding: .utf8)
        let settings = Settings.shared
        let original = settings.presetName
        for p in Settings.presets {
            settings.presetName = p.name    // didSet applies the preset
            let keys = readSystemSettings(ini)
            let expected = RocketLeagueConfig.overrides(for: p)
            let missing = expected.filter { keys[$0.0] != $0.1 }.map { $0.0 }
            check("preset \"\(p.name)\" -> TASystemSettings.ini", missing.isEmpty && keys["ResX"] == String(p.w) && keys["ResY"] == String(p.h),
                  missing.isEmpty ? "ResX=\(keys["ResX"] ?? "?") ResY=\(keys["ResY"] ?? "?") (\(expected.count) keys)" : "wrong or missing: \(missing.joined(separator: ","))")
            check("preset \"\(p.name)\" keeps other keys", keys["OwnerKey"] == "Kept")
            RuntimeFiles.installDXMTConfig(p)
            let conf = (try? String(contentsOf: RuntimeFiles.dxmtConf, encoding: .utf8)) ?? ""
            let want = String(format: "d3d11.metalSpatialUpscaleFactor = %.4f", p.metalfx ?? 1.0)
            check("preset \"\(p.name)\" -> dxmt.conf factor", conf.contains(want) && conf.contains("preferredMaxFrameRate"), want)
        }
        let text = (try? String(contentsOf: ini, encoding: .utf8)) ?? ""
        check("TASystemSettings.ini keeps CRLF and other sections", text.contains("\r\n") && text.contains("[Other]\r\nX=1"))
        settings.presetName = original
    }

    private func iniMerge() {
        let empty = RocketLeagueConfig.merge("", [("ResX", "1600")])
        check("ini merge: new file gets the section", empty == "[SystemSettings]\nResX=1600\n", empty.debugDescription)
        let tail = RocketLeagueConfig.merge("[A]\nx=1\n[SystemSettings]", [("ResY", "900")])
        check("ini merge: section header as last line", tail == "[A]\nx=1\n[SystemSettings]\nResY=900\n", tail.debugDescription)
        let caseIns = RocketLeagueConfig.merge("[systemsettings]\nresx=1\n", [("ResX", "2")])
        check("ini merge: keys and section match case-insensitively", caseIns.contains("resx=2") && !caseIns.contains("ResX=2\nresx"), caseIns.debugDescription)
    }

    private func fexConfig() {
        RuntimeFiles.installFEXConfig()
        let dst = RuntimeFiles.fexConfigDir.appendingPathComponent("Config.json")
        let ok = (try? Data(contentsOf: dst)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { $0["Config"] as? [String: String] }
        check("FEX Config.json installed", ok?["EnableCodeCachingWIP"] == "1" && ok?["X87ReducedPrecision"] == "0",
              ok.map { "\($0.count) options" } ?? "missing or not JSON")
        check("FEX config dir is the Windows path's directory", RuntimeFiles.fexConfigWindows == #"C:\fex-config\"#)
    }

    private func codemaps() {
        let ready = Paths.fexCache.appendingPathComponent("codemap/ready", isDirectory: true)
        try? fm.removeItem(at: ready)
        Runtime.shared.stageCodemaps()
        let bundled = Paths.bundledCodemaps.flatMap { try? fm.contentsOfDirectory(atPath: $0.path) } ?? []
        let staged = (try? fm.contentsOfDirectory(atPath: ready.path)) ?? []
        check("static code maps staged into codemap/ready", !bundled.isEmpty && Set(bundled).isSubset(of: Set(staged)),
              "\(staged.count) staged of \(bundled.count) in AOT/codemaps")
        // Sub-4 GB modules: their maps and caches go, everything else stays.
        let newDir = Paths.fexCache.appendingPathComponent("codemap/new", isDirectory: true)
        let cacheDir = Paths.fexCache.appendingPathComponent("cache", isDirectory: true)
        try? fm.createDirectory(at: newDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let planted = [newDir.appendingPathComponent("dbghelp.dll-0427e8779ebf384f.1234.bin"),
                       ready.appendingPathComponent("XInput1_3.dll-1e6371744c752f50"),
                       cacheDir.appendingPathComponent("x3daudio1_7.dll-04f207b246e461e6-0000000000000000"),
                       newDir.appendingPathComponent("rocketleague.exe-92e02b0b487870ca.1234.bin")]
        for f in planted { try? Data([0]).write(to: f) }
        let removed = RuntimeFiles.pruneSubfloorAOT()
        // Every planted sub-4 GB file is gone, the 64-bit-base module stays, and nothing else was
        // removed (the CI's dummy xinput1_3.dll static map, staged above, is pruned too, correctly).
        let onlySubfloor = removed.allSatisfy { r in RuntimeFiles.subfloorModules.contains { r.lowercased().contains("/" + $0 + "-") } }
        check("sub-4 GB modules pruned from code maps and caches",
              !planted[0...2].contains { fm.fileExists(atPath: $0.path) } && fm.fileExists(atPath: planted[3].path) && onlySubfloor,
              "\(removed.count) removed: " + removed.joined(separator: ", "))
        try? fm.removeItem(at: planted[3])
        check("codemap/new exists for JIT-miss maps", fm.fileExists(atPath: Paths.fexCache.appendingPathComponent("codemap/new").path))
    }

    private func shaderCache() {
        let dir = RuntimeFiles.shaderCacheDir
        try? fm.removeItem(at: dir)
        let first = RuntimeFiles.installShaderCache()
        let db = dir.appendingPathComponent("shaders_320.db")
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Shaders/dxmt/shaders_320.db")
        let same = (try? Data(contentsOf: db)) == (try? Data(contentsOf: bundled))
        check("shader DB copied to Library/Caches/dxmt", first != nil && same, db.path)
        check("DXMT_SHADER_CACHE_PATH form (absolute, trailing /)", (first?.path ?? "").hasPrefix("/"))
        // Unchanged bundle: no second copy (runtime-converted shaders in the DB are kept).
        try? "runtime".write(to: dir.appendingPathComponent("shaders_320.db-wal"), atomically: true, encoding: .utf8)
        _ = RuntimeFiles.installShaderCache()
        check("unchanged bundled DB is not copied again", fm.fileExists(atPath: dir.appendingPathComponent("shaders_320.db-wal").path))
        // Changed bundle (stamp differs): fresh copy, old WAL gone.
        try? "0 0".write(to: dir.appendingPathComponent("shaders_320.db.stamp"), atomically: true, encoding: .utf8)
        _ = RuntimeFiles.installShaderCache()
        let stamp = (try? String(contentsOf: dir.appendingPathComponent("shaders_320.db.stamp"), encoding: .utf8)) ?? ""
        check("newer bundled DB replaces the cache (stamp)", stamp != "0 0" && !fm.fileExists(atPath: dir.appendingPathComponent("shaders_320.db-wal").path), "stamp=\(stamp)")
    }

    private func aotInvalidation() {
        let cache = Paths.fexCache.appendingPathComponent("cache", isDirectory: true)
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        try? Data([1]).write(to: cache.appendingPathComponent("rocketleague.exe-0000000000000000-0000000000000000"))
        let s = Settings.shared
        let before = s.avxCompat
        s.avxCompat.toggle()
        check("AVX (compat) toggle clears the AOT cache", Runtime.aotCacheCount() == 0)
        s.avxCompat = before
    }

    private func gameLink() {
        try? fm.createDirectory(at: Paths.gameStore, withIntermediateDirectories: true)
        Paths.linkGame()
        let dest = try? fm.destinationOfSymbolicLink(atPath: Paths.game.path)
        check("C:\\games\\rocketleague links to Documents/Games/rocketleague", dest == Paths.gameStore.path, dest ?? "no link")
        check("game reported missing without RocketLeague.exe", !Paths.gameFound)
    }

    private func gameFileCheck() {
        let g = Paths.gameStore
        func put(_ url: URL, _ n: Int) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(repeating: 7, count: n).write(to: url)
        }
        let list = "3\tBinaries/Win64/a.dll\n5\tTAGame/b.upk\n4\tTAGame/Sub/c.tfc\n"
        put(g.appendingPathComponent("Binaries/Win64/a.dll"), 3)
        put(g.appendingPathComponent("TAGame/b.upk"), 2)                       // cut short, like a failed transfer
        let first = GameCheck.verify(list: list)
        let report = (try? String(contentsOf: GameCheck.report, encoding: .utf8)) ?? ""
        check("game check finds missing and partial files", first.hasPrefix("2 of 3")
              && report.contains("missing\tTAGame/Sub/c.tfc") && report.contains("size\tTAGame/b.upk\t2/5"), first)
        let sent = GameCheck.incoming.appendingPathComponent("rocketleague")
        put(sent.appendingPathComponent("TAGame/b.upk"), 5)
        put(sent.appendingPathComponent("TAGame/Sub/c.tfc"), 4)
        let moved = GameCheck.mergeIncoming()
        let second = GameCheck.verify(list: list)
        check("Incoming files placed at their game paths", moved == 2 && second == "All 3 files OK"
              && !fm.fileExists(atPath: sent.path), "moved \(moved): \(second)")
        for p in ["Binaries/Win64/a.dll", "TAGame"] { try? fm.removeItem(at: g.appendingPathComponent(p)) }
        try? fm.removeItem(at: GameCheck.report)
    }

    private func launchArguments() {
        let args = RocketLeagueLaunch.arguments(exchangeCode: "CODE123", accountID: "ACCT", displayName: "Name")
        let keys = args.map { $0.split(separator: "=").first.map(String.init) ?? $0 }
        let expected = ["-AUTH_LOGIN", "-AUTH_PASSWORD", "-AUTH_TYPE", "-epicapp", "-epicenv", "-EpicPortal",
                        "-epicusername", "-epicuserid", "-epiclocale", "-epicsandboxid"]
        check("launch arguments: Legendary's set and order", keys == expected, keys.joined(separator: " "))
        check("launch arguments: Sugar, Prod, sandbox", args.contains("-epicapp=Sugar") && args.contains("-epicenv=Prod")
              && args.contains("-epicsandboxid=9773aa1aa54f4f7b80e44bef04986cea"))
        let red = RocketLeagueLaunch.redacted(args)
        check("launch arguments: secrets redacted in logs", !red.contains("CODE123") && !red.contains("ACCT") && !red.contains("=Name"), red)
        let offline = RocketLeagueLaunch.arguments(exchangeCode: nil, accountID: "", displayName: "")
        let offlineKeys = offline.map { $0.split(separator: "=").first.map(String.init) ?? $0 }
        check("offline launch: full set with a dummy code, no user name/id",
              offlineKeys == expected.filter { $0 != "-epicusername" && $0 != "-epicuserid" }
              && offline.contains("-AUTH_PASSWORD=" + String(repeating: "0", count: 32)), offline.joined(separator: " "))
        check("game exe path", Paths.gameExeWindows == #"C:\games\rocketleague\Binaries\Win64\RocketLeague.exe"#)
    }

    private func crashWriter() {
        let file = LaunchLogs.shared.file("crash.txt")
        try? fm.removeItem(at: file)
        let rc = irl_crash_selftest()
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check("crash report writer", rc == 0 && text.contains("=== iRL crash ===") && text.contains("signal 11")
              && text.contains("0x0000000000001234") && text.contains("backtrace:") && text.contains("=== end ==="),
              "\(text.count) bytes")
    }

    private func shareZip() {
        LaunchLogs.shared.flush()
        let zip = LaunchLogs.shared.zipLatest()
        let head = zip.flatMap { try? FileHandle(forReadingFrom: $0) }.map { h -> Data in defer { try? h.close() }; return h.readData(ofLength: 2) }
        check("Share logs zip", head == Data([0x50, 0x4b]), zip?.lastPathComponent ?? "no zip")
    }

    private func finish() {
        let report = ([failures == 0 ? "PASS" : "FAIL"] + lines).joined(separator: "\n") + "\n"
        try? report.write(to: LaunchLogs.shared.file("selftest.txt"), atomically: true, encoding: .utf8)
        LogStore.shared.log("[selftest] done: \(failures) failure(s)", level: failures == 0 ? .success : .error)
        LaunchLogs.shared.flush()
        try? report.write(to: Paths.documents.appendingPathComponent("selftest-result.txt"), atomically: true, encoding: .utf8)
    }
}
