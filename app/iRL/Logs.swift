import Foundation
import UIKit

/// Documents/Logs/<yyyyMMdd-HHmmss>/: one folder per app launch (the app is closed and reopened
/// between game launches, so this is one folder per game launch).
///
///   app.log         this file's log (startup, login result without tokens, launch arguments
///                   with secrets redacted, display mode, AOT/JIT, errors)
///   wine.log        Wine's own log (wine_log_set_file) and, after the run, madeira-log.txt
///                   (the guest's stderr, FEX and DXMT messages)
///   diagnostics.csv 1 Hz samples (DiagnosticsSampler)
///   crash.txt       fatal signals (IRLCrash.c)
///   fex-jit-miss/   FEX code maps the run recorded (<cache>/codemap/new): every block the JIT
///                   had to compile. Feed for the next AOT build.
///   dxmt/           DXMT's logs (runtime shader conversions, pipeline misses)
///
/// Writes go through one serial utility queue, buffered, so no game thread ever waits on a file.
final class LaunchLogs {
    static let shared = LaunchLogs()

    let root: URL
    let folder: URL
    private let queue = DispatchQueue(label: "irl.logs", qos: .utility)
    private var handle: FileHandle?
    private var buffer = Data()
    private var flushScheduled = false

    private init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Logs", isDirectory: true)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        folder = root.appendingPathComponent(stamp.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("app.log")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        handle = try? FileHandle(forWritingTo: file)
    }

    func file(_ name: String) -> URL { folder.appendingPathComponent(name) }

    func append(_ line: String) {
        queue.async {
            self.buffer.append(Data((line + "\n").utf8))
            if self.buffer.count > 64 * 1024 { self.flushLocked() }
            else if !self.flushScheduled {
                self.flushScheduled = true
                self.queue.asyncAfter(deadline: .now() + 1) { self.flushLocked() }
            }
        }
    }

    func flush() { queue.sync { flushLocked() } }

    private func flushLocked() {
        flushScheduled = false
        guard !buffer.isEmpty else { return }
        handle?.write(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    /// The previous launch's runtime output belongs in the previous launch's folder.
    func collectPreviousRun() {
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent != folder.lastPathComponent }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let previous = folders.last else { return }
        collectRuntimeOutput(into: previous, move: true)
    }

    /// Copies (or moves) Wine's log, FEX's JIT-miss code maps and DXMT's logs into `dir`.
    func collectRuntimeOutput(into dir: URL, move: Bool) {
        let fm = FileManager.default
        let docs = Paths.documents
        let wineLog = docs.appendingPathComponent("madeira-log.txt")
        if fm.fileExists(atPath: wineLog.path) {
            let dst = dir.appendingPathComponent("wine-stderr.log")
            try? fm.removeItem(at: dst)
            if move { try? fm.moveItem(at: wineLog, to: dst) } else { try? fm.copyItem(at: wineLog, to: dst) }
        }
        let jitMiss = Paths.fexCache.appendingPathComponent("codemap/new", isDirectory: true)
        if let maps = try? fm.contentsOfDirectory(at: jitMiss, includingPropertiesForKeys: nil), !maps.isEmpty {
            let dst = dir.appendingPathComponent("fex-jit-miss", isDirectory: true)
            try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
            for m in maps {
                let to = dst.appendingPathComponent(m.lastPathComponent)
                try? fm.removeItem(at: to)
                try? fm.copyItem(at: m, to: to)   // FEX keeps them as AOT input: copy, never move
            }
        }
        let gameBin = Paths.gameWin64
        if let files = try? fm.contentsOfDirectory(at: gameBin, includingPropertiesForKeys: nil) {
            let logs = files.filter { $0.pathExtension == "log" && $0.lastPathComponent.contains("_") }
            if !logs.isEmpty {
                let dst = dir.appendingPathComponent("dxmt", isDirectory: true)
                try? fm.createDirectory(at: dst, withIntermediateDirectories: true)
                for l in logs {
                    let to = dst.appendingPathComponent(l.lastPathComponent)
                    try? fm.removeItem(at: to)
                    if move { try? fm.moveItem(at: l, to: to) } else { try? fm.copyItem(at: l, to: to) }
                }
            }
        }
    }

    /// Zips the latest launch's folder (after snapshotting the runtime output into it).
    func zipLatest() -> URL? {
        flush()
        collectRuntimeOutput(into: folder, move: false)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("iRL-logs-\(folder.lastPathComponent).zip")
        try? FileManager.default.removeItem(at: out)
        var result: URL?
        var error: NSError?
        // NSFileCoordinator's .forUploading produces a zip of a directory, no third-party code needed.
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &error) { zipped in
            try? FileManager.default.copyItem(at: zipped, to: out)
            result = out
        }
        if let error { LogStore.shared.log("Share logs: zip failed: \(error.localizedDescription)", level: .error) }
        return result
    }
}

/// Paths in the app container. The game folder is imported once into the Wine prefix's C: drive
/// (Files app › iRL › wine › drive_c › games › rocketleague) and survives re-signing.
enum Paths {
    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let prefix = documents.appendingPathComponent("wine", isDirectory: true)
    static let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
    static let game = driveC.appendingPathComponent("games/rocketleague", isDirectory: true)
    static let gameWin64 = game.appendingPathComponent("Binaries/Win64", isDirectory: true)
    static let gameExeWindows = #"C:\games\rocketleague\Binaries\Win64\RocketLeague.exe"#
    /// FEX's cache root (FEX_APP_CACHE_LOCATION, a Windows path ending in a separator).
    static let fexCache = driveC.appendingPathComponent("fex-cache", isDirectory: true)
    static let fexCacheWindows = #"C:\fex-cache\"#
    /// Static code maps the laptop injected into the IPA (tools/aot/inject-ipa.sh adds
    /// Payload/iRL.app/AOT/codemaps/<module>-<fileid> and AOT/manifest.json).
    static var bundledCodemaps: URL? {
        let u = Bundle.main.bundleURL.appendingPathComponent("AOT/codemaps", isDirectory: true)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}
