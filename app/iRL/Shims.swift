import Foundation
import Combine

// The few app-side types Madeira's StikJITHelper.swift (reused in place) expects, implemented
// for iRL. Same names and call shapes, none of Madeira's app behind them.

/// Log sink: app.log in the launch folder (LaunchLogs) plus the last lines for the phone screen.
final class LogStore: ObservableObject {
    static let shared = LogStore()
    enum Level: String { case info = "INFO", success = "OK", error = "ERR", debug = "DBG" }

    @Published private(set) var recent: [String] = []
    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    func log(_ message: String, level: Level = .info) {
        let line = "[\(formatter.string(from: Date()))] [\(level.rawValue)] \(message)"
        LaunchLogs.shared.append(line)
        if level == .error || level == .success || level == .info {
            DispatchQueue.main.async {
                self.recent.append(line)
                if self.recent.count > 40 { self.recent.removeFirst(self.recent.count - 40) }
            }
        }
    }
}

/// Documents/madeira.cfg, the file Madeira's C runtime also reads (build/madeira_cfg.h):
/// `key = value` lines; `env.NAME = value` lines are exported to the runtime's environment.
enum MadeiraConfig {
    static var url: URL { Paths.documents.appendingPathComponent("madeira.cfg") }

    static func all() -> [String: String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            out[line[..<eq].trimmingCharacters(in: .whitespaces)] = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    static func get(_ key: String) -> String? { all()[key].flatMap { $0.isEmpty ? nil : $0 } }
    /// iRL has no per-game profiles: one game.
    static func gameValue(_ key: String) -> String? { nil }

    static func flag(_ name: String, fallback: Bool = true) -> Bool {
        if let v = all()["env." + name] { return v != "0" }
        return getenv(name).map { String(cString: $0) != "0" } ?? fallback
    }

    @discardableResult
    static func set(_ key: String, _ value: String?) -> Bool {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard !t.hasPrefix("#"), let eq = t.firstIndex(of: "=") else { return true }
            return t[..<eq].trimmingCharacters(in: .whitespaces) != key
        }
        if let value { lines.append("\(key) = \(value)") }
        return (try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)) != nil
    }
}

/// Code-signing flags (CS_GET_TASK_ALLOW, CS_DEBUGGED) from JITAllocator.c.
struct SigningStatus {
    let known: Bool
    let flags: UInt32
    var debuggable: Bool { !known || flags & 0x4 != 0 }
    var debugged: Bool { known && flags & 0x1000_0000 != 0 }
    static var current: SigningStatus {
        var flags: UInt32 = 0
        let known = jit_cs_status(&flags)
        return SigningStatus(known: known, flags: flags)
    }
}

func isDebuggerAttached() -> Bool {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return false }
    return (info.kp_proc.p_flag & P_TRACED) != 0
}

/// Winios asks whether pointer input goes to the game. iRL is controller-only.
@_cdecl("winios_mouse_routing_enabled")
func winios_mouse_routing_enabled() -> Int32 { 0 }
