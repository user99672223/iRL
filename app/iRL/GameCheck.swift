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

    static var report: URL { Paths.documents.appendingPathComponent("game-check.txt") }

    func run() {
        guard !running else { return }
        running = true
        summary = "Checking…"
        Task.detached(priority: .userInitiated) {
            let result = GameCheck.check()
            await MainActor.run {
                self.summary = result
                self.running = false
                LogStore.shared.log("[game-check] \(result)", level: result.hasPrefix("All") ? .success : .error)
            }
        }
    }

    nonisolated static func check() -> String {
        guard let url = Bundle.main.url(forResource: "GameFiles", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
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
