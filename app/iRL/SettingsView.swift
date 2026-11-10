import SwiftUI

struct SettingsView: View {
    @ObservedObject private var s = Settings.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(footer: Text("The game renders at this size and MetalFX scales it to 2560×1440. Pick the highest preset the diagnostics show holding 60 fps.")) {
                    Picker("Render resolution", selection: $s.presetName) {
                        ForEach(Settings.presets, id: \.name) { Text($0.name).tag($0.name) }
                    }
                    Toggle("Dim the phone while playing", isOn: $s.dimPhone)
                }
                Section(footer: Text("Lets the game use its AVX code paths. Only for a game that stops with an illegal-instruction error. Changing it deletes the AOT cache: run AOT Prepare again.")) {
                    Toggle("AVX (compat)", isOn: $s.avxCompat)
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
