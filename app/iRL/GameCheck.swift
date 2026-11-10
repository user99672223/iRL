import Foundation

/// Compares Documents/Games/rocketleague with the file list of the laptop's install
/// (GameFiles.tsv, "<size>\t<relative path>" per line, injected into the IPA by
/// tools/release/make-final-ipa.sh). Missing or wrong-size files go to Documents/game-check.txt,
/// which can be sent back to the laptop so only those files are resent.
@MainActor
final class GameCheck: ObservableObject {
    static let shared = GameCheck()
    @Published private(set) var summary: String?
    @Published private(set) var running = false

    nonisolated static var report: URL { Paths.documents.appendingPathComponent("game-check.txt") }

    func run() {
        guard !running else { return }
        running = true
        summary = "Checking…"
        Task.detached(priority: .userInitiated) {
            let result = GameCheck.check()
            await MainActor.run {
                self.summary = result
                self.running = false
                LogStore.shared.log("[game-check] \(result)", level: result.contains("All ") ? .success : .error)
            }
        }
    }

    /// Files › iRL › Incoming: a folder sent from the laptop with only the missing files, in the
    /// game's own layout (tools/release/missing-files.sh). Each file is moved to the same relative
    /// path under Games/rocketleague, replacing a partial copy; folders are created as needed.
    nonisolated static var incoming: URL { Paths.documents.appendingPathComponent("Incoming", isDirectory: true) }

    nonisolated static func mergeIncoming() -> Int {
        let fm = FileManager.default
        try? fm.createDirectory(at: incoming, withIntermediateDirectories: true)
        // Accept Incoming/<anything>/Binaries|Engine|TAGame... (the sent folder) or the layout directly.
        var roots: [URL] = []
        for top in (try? fm.contentsOfDirectory(at: incoming, includingPropertiesForKeys: nil)) ?? [] {
            let names = Set(((try? fm.contentsOfDirectory(atPath: top.path)) ?? []))
            if !names.isDisjoint(with: ["Binaries", "Engine", "TAGame"]) { roots.append(top) }
        }
        let direct = Set((try? fm.contentsOfDirectory(atPath: incoming.path)) ?? [])
        if !direct.isDisjoint(with: ["Binaries", "Engine", "TAGame"]) { roots.append(incoming) }
        var moved = 0
        for root in roots {
            guard let walk = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
            let base = root.standardizedFileURL.path + "/"
            for case let f as URL in walk {
                guard (try? f.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let rel = String(f.standardizedFileURL.path.dropFirst(base.count))
                guard ["Binaries/", "Engine/", "TAGame/"].contains(where: rel.hasPrefix) else { continue }
                let dst = Paths.gameStore.appendingPathComponent(rel)
                try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.removeItem(at: dst)
                if (try? fm.moveItem(at: f, to: dst)) != nil { moved += 1 }
            }
            if root != incoming { try? fm.removeItem(at: root) }
        }
        return moved
    }

    nonisolated static func check() -> String {
        let merged = mergeIncoming()
        let result = verify()
        return merged > 0 ? "Placed \(merged) files from Incoming. " + result : result
    }

    nonisolated static func verify(list: String? = nil) -> String {
        guard let text = list ?? Bundle.main.url(forResource: "GameFiles", withExtension: "tsv")
                .flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else {
            return "No file list in this IPA"
        }
        let fm = FileManager.default
        var total = 0, missing: [String] = [], wrong: [String] = [], missingBytes: Int64 = 0
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t"), let size = Int64(line[..<tab]) else { continue }
            let rel = String(line[line.index(after: tab)...])
            total += 1
            let path = Paths.gameStore.appendingPathComponent(rel).path
            if let attrs = try? fm.attributesOfItem(atPath: path), let have = (attrs[.size] as? NSNumber)?.int64Value {
                if have != size { wrong.append("\(rel)\t\(have)/\(size)"); missingBytes += size }
            } else {
                missing.append(rel); missingBytes += size
            }
        }
        var out = "# game-check \(ISO8601DateFormatter().string(from: Date()))\n"
        out += "# expected \(total) files; missing \(missing.count); wrong size \(wrong.count)\n"
        out += missing.map { "missing\t\($0)" }.joined(separator: "\n")
        if !wrong.isEmpty { out += (missing.isEmpty ? "" : "\n") + wrong.map { "size\t\($0)" }.joined(separator: "\n") }
        try? (out + "\n").write(to: report, atomically: true, encoding: .utf8)
        let bad = missing.count + wrong.count
        if bad == 0 { return "All \(total) files OK" }
        return "\(bad) of \(total) files missing or incomplete (\(String(format: "%.2f", Double(missingBytes) / 1e9)) GB). List: Files › iRL › game-check.txt"
    }
}
