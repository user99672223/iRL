import Foundation

/// iRL's few settings (UserDefaults). Everything else is a measured default, not a knob.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// Verbose Wine channels (+seh, +loaddll, +module, warn+all). Costs CPU: diagnosis only.
    @Published var verboseWine: Bool { didSet { d.set(verboseWine, forKey: "verboseWine") } }
    /// DXMT info logging: every runtime shader conversion and pipeline miss (feeds the .metallib build).
    @Published var verboseDXMT: Bool { didSet { d.set(verboseDXMT, forKey: "verboseDXMT") } }
    /// Metal API validation. Slow; for chasing GPU errors only.
    @Published var metalValidation: Bool { didSet { d.set(metalValidation, forKey: "metalValidation") } }
    /// Output / internal resolution. 1.0 = native 1440p; above 1 renders lower and MetalFX
    /// spatial scales to the output (the game's FXAA stays on before it).
    @Published var renderScale: Double { didSet { d.set(renderScale, forKey: "renderScale") } }
    /// Lower the phone's brightness while the game runs on the monitor.
    @Published var dimPhone: Bool { didSet { d.set(dimPhone, forKey: "dimPhone") } }

    private init() {
        verboseWine = d.bool(forKey: "verboseWine")
        verboseDXMT = d.bool(forKey: "verboseDXMT")
        metalValidation = d.bool(forKey: "metalValidation")
        renderScale = d.object(forKey: "renderScale") as? Double ?? 1.0
        dimPhone = d.object(forKey: "dimPhone") as? Bool ?? true
    }
}
