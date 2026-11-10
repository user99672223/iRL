import Foundation

/// iRL's few settings (UserDefaults). Everything else is a measured default, not a knob.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    /// Render resolution presets (tools/runtime/rocketleague/TASystemSettings.overrides.json):
    /// the game renders at ResX x ResY, MetalFX spatial scales by `metalfx` to 2560x1440.
    struct Preset: Hashable {
        let name: String, w: Int, h: Int, metalfx: Double?
    }
    static let presets: [Preset] = [
        Preset(name: "1440p native", w: 2560, h: 1440, metalfx: nil),
        Preset(name: "1080p + MetalFX", w: 1920, h: 1080, metalfx: 1.3333),
        Preset(name: "900p + MetalFX (default)", w: 1600, h: 900, metalfx: 1.6),
        Preset(name: "720p + MetalFX", w: 1280, h: 720, metalfx: 2.0),
    ]
    static let defaultPreset = "900p + MetalFX (default)"

    @Published var presetName: String {
        didSet {
            d.set(presetName, forKey: "presetName")
            RocketLeagueConfig.apply(preset)
        }
    }
    var preset: Preset { Self.presets.first { $0.name == presetName } ?? Self.presets[2] }

    /// AVX for the guest (MADEIRA_FEX_AVX=2), for the game and FEXOfflineCompiler alike.
    /// Off by default: Rocket League takes its SSE paths. Flipping it invalidates the AOT cache.
    @Published var avxCompat: Bool {
        didSet {
            guard avxCompat != oldValue else { return }
            d.set(avxCompat, forKey: "avxCompat")
            RuntimeFiles.invalidateAOTCache(reason: "AVX (compat) \(avxCompat ? "on" : "off")")
        }
    }
    /// Verbose Wine channels (+seh, +loaddll, +module, warn+all). Costs CPU: diagnosis only.
    @Published var verboseWine: Bool { didSet { d.set(verboseWine, forKey: "verboseWine") } }
    /// DXMT info logging: every runtime shader conversion and pipeline miss (feeds the .metallib build).
    @Published var verboseDXMT: Bool { didSet { d.set(verboseDXMT, forKey: "verboseDXMT") } }
    /// Metal API validation. Slow; for chasing GPU errors only.
    @Published var metalValidation: Bool { didSet { d.set(metalValidation, forKey: "metalValidation") } }
    /// Lower the phone's brightness while the game runs on the monitor.
    @Published var dimPhone: Bool { didSet { d.set(dimPhone, forKey: "dimPhone") } }

    private init() {
        presetName = d.string(forKey: "presetName") ?? Self.defaultPreset
        avxCompat = d.bool(forKey: "avxCompat")
        verboseWine = d.bool(forKey: "verboseWine")
        verboseDXMT = d.bool(forKey: "verboseDXMT")
        metalValidation = d.bool(forKey: "metalValidation")
        dimPhone = d.object(forKey: "dimPhone") as? Bool ?? true
    }
}
