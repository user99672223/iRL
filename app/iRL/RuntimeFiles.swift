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
