import SwiftUI

/// The phone screen: Start, sign-in, a still diagnostics readout, Share logs. No animation:
/// the phone is a status panel while the game runs on the monitor.
struct HomeView: View {
    @ObservedObject private var runtime = Runtime.shared
    @ObservedObject private var diag = Diagnostics.shared
    @ObservedObject private var logs = LogStore.shared
    @ObservedObject private var settings = Settings.shared
    @State private var account: String?
    @State private var showSignIn = false
    @State private var showSettings = false
    @State private var showDiagnostics = false
    @State private var shareURL: URL?
    @ObservedObject private var selfTest = SelfTest.shared
    @ObservedObject private var gameCheck = GameCheck.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button(action: start) {
                        Label(startTitle, systemImage: "play.fill").font(.title2.bold())
                    }
                    .disabled(runtime.state != .idle)
                    Text(statusText).font(.callout).foregroundStyle(.secondary)
                    LabeledContent("Game", value: Paths.gameFound ? "found" : "missing")
                    Button(gameCheck.running ? "Checking game files…" : "Check game files") { gameCheck.run() }
                        .disabled(gameCheck.running || runtime.state != .idle)
                    if let s = gameCheck.summary { Text(s).font(.callout).foregroundStyle(s.hasPrefix("All") ? .green : .red) }
                }
                StatusSection(diag: diag)
                Section("Epic Games") {
                    if let account {
                        LabeledContent("Signed in", value: account)
                        Button("Sign out", role: .destructive) {
                            Task { await EpicAuth.shared.signOut(); await refreshAccount() }
                        }
                    } else {
                        Button("Sign in") { showSignIn = true }
                    }
                }
                DiagnosticsSection(diag: diag)
                Section("Log") {
                    ForEach(Array(logs.recent.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).lineLimit(2)
                    }
                }
                Section {
                    Button("Share logs") { shareURL = LaunchLogs.shared.zipLatest() }
                    Button("AOT Prepare") { runtime.start(.aotPrepare) }.disabled(runtime.state != .idle)
                    Button("Diagnostics") { showDiagnostics = true }
                    Button("Settings") { showSettings = true }
                }
            }
            .navigationTitle("iRL")
            .transaction { $0.animation = nil }
        }
        .task { await refreshAccount() }
        .task { if SelfTest.requested { await SelfTest.shared.run() } }
        .onChange(of: selfTest.screen) { _, screen in
            showSettings = screen == .settings
            showDiagnostics = screen == .diagnostics
        }
        .sheet(isPresented: $showDiagnostics) { DiagnosticsView() }
        .sheet(isPresented: $showSignIn, onDismiss: { Task { await refreshAccount() } }) { EpicSignInView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(item: $shareURL) { url in ShareSheet(items: [url]) }
        .onChange(of: runtime.state) { _, state in
            if case .running = state, settings.dimPhone, ExternalDisplay.shared.screen != nil {
                UIScreen.main.brightness = 0.1
            }
        }
    }

    private var startTitle: String { runtime.state == .idle ? "Start Rocket League" : "Running" }
    private var statusText: String {
        switch runtime.state {
        case .idle: return ExternalDisplay.shared.screen == nil ? "Ready. No monitor connected: the game will use the phone screen." : "Ready."
        case .preparing(let s): return s
        case .running(let m): return "\(m.rawValue) is running."
        case .failed(let s): return s
        }
    }

    private func start() { runtime.start(.game) }
    private func refreshAccount() async { account = await EpicAuth.shared.account()?.name }
}

/// JIT and memory-limit status, refreshed with each diagnostics sample (1 Hz).
struct StatusSection: View {
    @ObservedObject var diag: Diagnostics
    var body: some View {
        let jit = jit_check_debugged()
        let iml = Entitlements.provisioned("com.apple.developer.kernel.increased-memory-limit")
        let limitMB = diag.last.footprintMB + diag.last.availableMB
        Section("Status") {
            LabeledContent("JIT") {
                Text(jit ? "✅ enabled" : "❌ off: enable in StikDebug").foregroundStyle(jit ? .green : .red)
            }
            LabeledContent("Increased Memory Limit") {
                Text(iml == true ? "✅ granted" : iml == false ? "❌ not in profile" : "? no profile")
                    .foregroundStyle(iml == true ? .green : .red)
            }
            LabeledContent("Memory limit", value: String(format: "%.2f GB", Double(limitMB) / 1024))
        }
        .font(.callout.monospacedDigit())
    }
}

/// Reads the entitlements the installed provisioning profile grants (embedded.mobileprovision, which
/// Impactor writes when it signs). nil when there is no profile (simulator).
enum Entitlements {
    private static let granted: [String: Any]? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any]
        else { return nil }
        return plist["Entitlements"] as? [String: Any] ?? [:]
    }()
    static func provisioned(_ key: String) -> Bool? {
        guard let granted else { return nil }
        if let b = granted[key] as? Bool { return b }
        return granted[key] != nil
    }
}

/// The still diagnostics readout (1 Hz): on Home and as its own screen.
struct DiagnosticsSection: View {
    @ObservedObject var diag: Diagnostics
    var body: some View {
        Section("Diagnostics") {
            row("Memory", "\(diag.last.footprintMB) MB used, \(diag.last.availableMB) MB free")
            row("CPU", String(format: "%.0f %% (%d threads)", diag.last.cpuPercent, diag.last.threads))
            row("GPU busy", String(format: "%.0f %%", diag.last.gpuBusyPercent))
            row("FPS", String(format: "%.1f  (p50 %.1f ms, p99 %.1f ms)", diag.last.fps, diag.last.frameP50ms, diag.last.frameP99ms))
            row("Thermal", diag.last.thermal)
            row("Battery", diag.last.battery < 0 ? "?" : "\(diag.last.battery) %\(diag.last.charging ? ", charging" : "")")
            row("Energy", String(format: "%.1f J", diag.last.energyJ))
            row("Display", ExternalDisplay.shared.screen == nil ? "no monitor" : "\(ExternalDisplay.shared.outputSize.w)×\(ExternalDisplay.shared.outputSize.h)")
            row("AOT caches", "\(diag.last.aotCaches) modules")
        }
    }
    private func row(_ k: String, _ v: String) -> some View { LabeledContent(k, value: v).font(.callout.monospacedDigit()) }
}

struct DiagnosticsView: View {
    @ObservedObject private var diag = Diagnostics.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List { DiagnosticsSection(diag: diag) }
                .navigationTitle("Diagnostics")
                .toolbar { Button("Done") { dismiss() } }
                .transaction { $0.animation = nil }
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
