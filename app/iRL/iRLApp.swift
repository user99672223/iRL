import SwiftUI
import UIKit

@main
struct IRLApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup { HomeView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let logs = LaunchLogs.shared
        irl_crash_install(logs.folder.path)        // before Wine installs its own handlers
        jit_install_trap_handler()                  // Madeira's JIT trap backstop (JITAllocator.c)
        logs.collectPreviousRun()
        RuntimeFiles.installFEXConfig()
        try? FileManager.default.createDirectory(at: Paths.gameStore, withIntermediateDirectories: true)
        Paths.linkGame()
        LogStore.shared.log("[game] \(Paths.gameFound ? "found" : "missing") at Documents/Games/rocketleague")
        let info = Bundle.main.infoDictionary ?? [:]
        LogStore.shared.log("[app] iRL \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")) "
            + "iOS \(UIDevice.current.systemVersion) memory-limit-headroom=\(os_proc_available_memory() >> 20)MB "
            + "cs-debugged=\(SigningStatus.current.debugged ? 1 : 0) debugger=\(isDebuggerAttached() ? 1 : 0) "
            + "iml-in-profile=\(Entitlements.provisioned("com.apple.developer.kernel.increased-memory-limit").map { $0 ? "1" : "0" } ?? "none")")
        UIApplication.shared.isIdleTimerDisabled = true
        Gamepad.shared.start()
        Diagnostics.shared.start()
        return true
    }

    // The monitor's scene (ExternalSceneDelegate) is declared in Info.plist for the
    // external-display role. No configurationForConnecting here: returning a configuration for
    // the app role replaces SwiftUI's own scene delegate and leaves the phone window blank.
}
