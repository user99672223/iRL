import SwiftUI

struct SettingsView: View {
    @ObservedObject private var s = Settings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("1.0 renders at the monitor's resolution. Higher values render lower and MetalFX scales up to it.")) {
                    Picker("Render scale", selection: $s.renderScale) {
                        ForEach([1.0, 1.25, 1.333, 1.5, 2.0], id: \.self) { Text(String(format: "%.2g×", $0)).tag($0) }
                    }
                    Toggle("Dim the phone while playing", isOn: $s.dimPhone)
                }
                Section("Logging (applies at the next Start)") {
                    Toggle("Verbose Wine log", isOn: $s.verboseWine)
                    Toggle("DXMT shader and pipeline log", isOn: $s.verboseDXMT)
                    Toggle("Metal validation", isOn: $s.metalValidation)
                }
                Section(footer: Text("Compiles the bundled static code maps plus the JIT misses recorded in earlier runs into FEX's AOT cache. Run it once after installing or after a game patch, then close and reopen iRL.")) {
                    LabeledContent("AOT caches", value: "\(Runtime.aotCacheCount()) modules")
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
        }
    }
}
