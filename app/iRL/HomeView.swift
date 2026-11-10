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
    @State private var shareURL: URL?

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
                }
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
                Section("Diagnostics") {
                    row("Memory", "\(diag.last.footprintMB) MB used, \(diag.last.availableMB) MB free")
                    row("CPU", String(format: "%.0f %% (%d threads)", diag.last.cpuPercent, diag.last.threads))
                    row("GPU busy", String(format: "%.0f %%", diag.last.gpuBusyPercent))
                    row("FPS", String(format: "%.1f  (p50 %.1f ms, p99 %.1f ms)", diag.last.fps, diag.last.frameP50ms, diag.last.frameP99ms))
                    row("Thermal", diag.last.thermal)
                    row("Battery", diag.last.battery < 0 ? "?" : "\(diag.last.battery) %\(diag.last.charging ? ", charging" : "")")
                    row("Display", ExternalDisplay.shared.screen == nil ? "no monitor" : "\(ExternalDisplay.shared.outputSize.w)×\(ExternalDisplay.shared.outputSize.h)")
                    row("AOT caches", "\(diag.last.aotCaches) modules")
                }
                Section("Log") {
                    ForEach(Array(logs.recent.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption2.monospaced()).lineLimit(2)
                    }
                }
                Section {
                    Button("Share logs") { shareURL = LaunchLogs.shared.zipLatest() }
                    Button("AOT Prepare") { runtime.start(.aotPrepare) }.disabled(runtime.state != .idle)
                    Button("Settings") { showSettings = true }
                }
            }
            .navigationTitle("iRL")
            .transaction { $0.animation = nil }
        }
        .task { await refreshAccount() }
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
    private func row(_ k: String, _ v: String) -> some View { LabeledContent(k, value: v).font(.callout.monospacedDigit()) }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
