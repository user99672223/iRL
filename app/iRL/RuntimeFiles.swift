import Foundation

/// Runtime data files shipped in the bundle (from tools/runtime/) and their writable copies in
/// the Wine prefix, where the Windows side (FEX inside Wine, DXMT's PE side) reads them by
/// Windows path.
enum RuntimeFiles {
    /// FEX's global config dir: Config.json (tools/runtime/fex). Read by RocketLeague.exe's FEX and by
    /// FEXOfflineCompiler.exe alike, so the AOT caches match the configuration that loads them.
    static let fexConfigDir = Paths.driveC.appendingPathComponent("fex-config", isDirectory: true)
    static let fexConfigWindows = #"C:\fex-config\"#
    static let dxmtConf = Paths.driveC.appendingPathComponent("irl/dxmt.conf")
    static let dxmtConfWindows = #"C:\irl\dxmt.conf"#

    private static func bundled(_ name: String) -> URL? {
        Bundle.main.url(forResource: (name as NSString).deletingPathExtension, withExtension: (name as NSString).pathExtension)
    }

    /// Copies Config.json into FEX's config dir (every start: the bundle is the source of truth).
    static func installFEXConfig() {
        let fm = FileManager.default
        try? fm.createDirectory(at: fexConfigDir, withIntermediateDirectories: true)
        guard let src = bundled("Config.json") else {
            LogStore.shared.log("[fex] Config.json missing from the bundle", level: .error); return
        }
        let dst = fexConfigDir.appendingPathComponent("Config.json")
        try? fm.removeItem(at: dst)
        do {
            try fm.copyItem(at: src, to: dst)
            let text = (try? String(contentsOf: dst, encoding: .utf8)) ?? ""
            LogStore.shared.log("[fex] config: " + text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "  ", with: ""))
        } catch {
            LogStore.shared.log("[fex] could not install Config.json: \(error.localizedDescription)", level: .error)
        }
    }

    /// dxmt.conf with the upscale factor of the chosen preset.
    static func installDXMTConfig(_ preset: Settings.Preset) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dxmtConf.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let src = bundled("dxmt.conf"), var text = try? String(contentsOf: src, encoding: .utf8) else {
            LogStore.shared.log("[dxmt] dxmt.conf missing from the bundle", level: .error); return
        }
        let factor = String(format: "%.4f", preset.metalfx ?? 1.0)
        var lines = text.components(separatedBy: "\n")
        var found = false
        for i in lines.indices where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("d3d11.metalSpatialUpscaleFactor") {
            lines[i] = "d3d11.metalSpatialUpscaleFactor = \(factor)"; found = true
        }
        if !found { lines.append("d3d11.metalSpatialUpscaleFactor = \(factor)") }
        text = lines.joined(separator: "\n")
        do { try text.write(to: dxmtConf, atomically: true, encoding: .utf8) }
        catch { LogStore.shared.log("[dxmt] could not write dxmt.conf: \(error.localizedDescription)", level: .error) }
    }

    /// DXMT's shader cache database. The IPA carries the precompiled one (Shaders/dxmt/shaders_320.db,
    /// injected by tools/release/make-final-ipa.sh); DXMT's CacheWriter appends runtime-converted
    /// shaders to the same file (WAL), so it must live in a writable directory.
    static let shaderCacheDir: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("dxmt", isDirectory: true)

    /// Copies the bundled DB when the writable one is missing or the bundled one changed (size+mtime
    /// stamp). Returns the directory for DXMT_SHADER_CACHE_PATH, or nil when the IPA has no shaders.
    static func installShaderCache() -> URL? {
        let fm = FileManager.default
        let name = "shaders_320.db"
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Shaders/dxmt/\(name)")
        let dst = shaderCacheDir.appendingPathComponent(name)
        let stampURL = shaderCacheDir.appendingPathComponent("\(name).stamp")
        guard let attrs = try? fm.attributesOfItem(atPath: bundled.path) else {
            LogStore.shared.log("[shaders] no Shaders/ in this IPA: DXMT converts every shader at run time")
            return fm.fileExists(atPath: dst.path) ? shaderCacheDir : nil
        }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let stamp = "\(size) \(Int64(mtime))"
        try? fm.createDirectory(at: shaderCacheDir, withIntermediateDirectories: true)
        let current = try? String(contentsOf: stampURL, encoding: .utf8)
        if !fm.fileExists(atPath: dst.path) || current != stamp {
            for suffix in ["", "-wal", "-shm"] { try? fm.removeItem(at: shaderCacheDir.appendingPathComponent(name + suffix)) }
            do {
                try fm.copyItem(at: bundled, to: dst)
                try stamp.write(to: stampURL, atomically: true, encoding: .utf8)
                LogStore.shared.log("[shaders] installed the precompiled DXMT shader DB (\(size >> 20) MB)", level: .success)
            } catch {
                LogStore.shared.log("[shaders] could not install the shader DB: \(error.localizedDescription)", level: .error)
                return nil
            }
        }
        let dbSize = ((try? fm.attributesOfItem(atPath: dst.path))?[.size] as? NSNumber)?.int64Value ?? 0
        let walSize = ((try? fm.attributesOfItem(atPath: dst.path + "-wal"))?[.size] as? NSNumber)?.int64Value ?? 0
        LogStore.shared.log("[shaders] DXMT shader DB \(dbSize >> 20) MB (+\(walSize >> 10) KB WAL of runtime conversions)")
        return shaderCacheDir
    }

    /// Modules whose preferred base is below 4 GB: Madeira's iOS FEX relocates them at run time
    /// ("subfloor" windows), so an offline cache for them would be wrong. Known ones by name (also
    /// covers maps whose file is not found); any other module is checked by its PE header.
    static let subfloorModules: Set<String> = ["dbghelp.dll", "xinput1_3.dll", "x3daudio1_7.dll"]

    /// The module name of a code map or cache file: "<module>-<16 hex fileid>[...]".
    static func moduleName(ofCacheFile name: String) -> String? {
        guard let r = name.range(of: "-[0-9a-fA-F]{16}", options: .regularExpression) else { return nil }
        return String(name[..<r.lowerBound]).lowercased()
    }

    /// ImageBase from the PE optional header (PE32+), or nil.
    static func preferredBase(of url: URL) -> UInt64? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4096), head.count > 0x40 else { return nil }
        func u16(_ o: Int) -> UInt16 { head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) } }
        func u32(_ o: Int) -> UInt32 { head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func u64(_ o: Int) -> UInt64 { head.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) } }
        guard u16(0) == 0x5A4D else { return nil }
        let pe = Int(u32(0x3C))
        guard pe + 24 + 32 <= head.count, u32(pe) == 0x0000_4550, u16(pe + 24) == 0x20B else { return nil }
        return u64(pe + 24 + 24)
    }

    /// Whether a module may have an AOT cache: not below 4 GB.
    static func aotAllowed(module: String) -> (ok: Bool, why: String) {
        if subfloorModules.contains(module) { return (false, "subfloor module (listed)") }
        let files = (try? FileManager.default.contentsOfDirectory(at: Paths.gameWin64, includingPropertiesForKeys: nil)) ?? []
        if let f = files.first(where: { $0.lastPathComponent.lowercased() == module }), let base = preferredBase(of: f) {
            return base < 0x1_0000_0000 ? (false, String(format: "preferred base 0x%llx < 4 GB", base)) : (true, "")
        }
        return (true, "")
    }

    /// Removes code maps (codemap/new, codemap/ready) and caches of sub-4 GB modules before
    /// FEXOfflineCompiler process-all runs. Returns what was removed.
    @discardableResult
    static func pruneSubfloorAOT() -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for sub in ["codemap/new", "codemap/ready", "cache"] {
            let dir = Paths.fexCache.appendingPathComponent(sub, isDirectory: true)
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                guard let module = moduleName(ofCacheFile: f.lastPathComponent) else { continue }
                let verdict = aotAllowed(module: module)
                if !verdict.ok, (try? fm.removeItem(at: f)) != nil {
                    removed.append("\(sub)/\(f.lastPathComponent) (\(verdict.why))")
                }
            }
        }
        LogStore.shared.log("[aot] sub-4 GB modules kept on the JIT: removed \(removed.count) file(s)" + (removed.isEmpty ? "" : ": " + removed.joined(separator: ", ")))
        return removed
    }

    /// Deletes the generated AOT caches so Prepare AOT runs again (code maps are kept).
    static func invalidateAOTCache(reason: String) {
        let dir = Paths.fexCache.appendingPathComponent("cache", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files { try? FileManager.default.removeItem(at: f) }
        LogStore.shared.log("[aot] cache invalidated (\(files.count) file(s)): \(reason). Run AOT Prepare again.", level: .error)
    }
}

/// Rocket League's TASystemSettings.ini: the keys in TASystemSettings.overrides.json, set in
/// [SystemSettings], every other key left as it is. Applied at each Start (covers a fresh import)
/// and whenever the render resolution preset changes.
enum RocketLeagueConfig {
    private static let relative = "Documents/My Games/Rocket League/TAGame/Config/TASystemSettings.ini"

    /// Wine's user profile dirs (the iOS user is "mobile"; Madeira's prefix may also have others).
    private static func iniFiles() -> [URL] {
        let users = Paths.driveC.appendingPathComponent("users", isDirectory: true)
        var names = ((try? FileManager.default.contentsOfDirectory(atPath: users.path)) ?? [])
            .filter { $0 != "Public" && !$0.hasPrefix(".") }
        if names.isEmpty { names = ["mobile"] }
        return names.map { users.appendingPathComponent($0).appendingPathComponent(relative) }
    }

    static func overrides(for preset: Settings.Preset) -> [(String, String)] {
        var keys: [(String, String)] = []
        if let url = Bundle.main.url(forResource: "TASystemSettings.overrides", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let section = json["SystemSettings"] as? [String: String] {
            keys = section.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
        } else {
            LogStore.shared.log("[rl-config] TASystemSettings.overrides.json missing from the bundle", level: .error)
        }
        keys.removeAll { $0.0 == "ResX" || $0.0 == "ResY" }
        keys.append(("ResX", String(preset.w)))
        keys.append(("ResY", String(preset.h)))
        return keys
    }

    static func apply(_ preset: Settings.Preset) {
        let keys = overrides(for: preset)
        for url in iniFiles() {
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try merge(old, keys).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                LogStore.shared.log("[rl-config] could not write \(url.path): \(error.localizedDescription)", level: .error)
            }
        }
        LogStore.shared.log("[rl-config] preset \"\(preset.name)\": render \(preset.w)x\(preset.h)"
            + (preset.metalfx.map { String(format: ", MetalFX x%.4g -> output %dx%d", $0, Int((Double(preset.w) * $0).rounded()), Int((Double(preset.h) * $0).rounded())) } ?? ", native output")
            + " (\(keys.count) keys in [SystemSettings])")
    }

    /// Sets `keys` in [SystemSettings], keeping every other line (and the file's line endings).
    static func merge(_ text: String, _ keys: [(String, String)]) -> String {
        let eol = text.contains("\r\n") ? "\r\n" : "\n"
        var lines = text.isEmpty ? [] : text.components(separatedBy: eol)
        if lines.last == "" { lines.removeLast() }
        var start = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare("[SystemSettings]") == .orderedSame }
        if start == nil {
            if !lines.isEmpty { lines.append("") }
            lines.append("[SystemSettings]")
            start = lines.count - 1
        }
        var end = lines.count
        for i in (start! + 1)..<lines.count where lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") { end = i; break }
        var pending = keys
        for i in (start! + 1)..<end {
            let t = lines[i]
            guard let eq = t.firstIndex(of: "=") else { continue }
            let k = t[..<eq].trimmingCharacters(in: .whitespaces)
            if let j = pending.firstIndex(where: { $0.0.caseInsensitiveCompare(k) == .orderedSame }) {
                lines[i] = "\(k)=\(pending[j].1)"
                pending.remove(at: j)
            }
        }
        var insertAt = end
        while insertAt > start! + 1 && lines[insertAt - 1].trimmingCharacters(in: .whitespaces).isEmpty { insertAt -= 1 }
        lines.insert(contentsOf: pending.map { "\($0.0)=\($0.1)" }, at: insertAt)
        return lines.joined(separator: eol) + eol
    }
}
