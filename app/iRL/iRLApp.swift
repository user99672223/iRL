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
        let info = Bundle.main.infoDictionary ?? [:]
        LogStore.shared.log("[app] iRL \(info["CFBundleShortVersionString"] ?? "?") (\(info["CFBundleVersion"] ?? "?")) "
            + "iOS \(UIDevice.current.systemVersion) memory-limit-headroom=\(os_proc_available_memory() >> 20)MB "
            + "cs-debugged=\(SigningStatus.current.debugged ? 1 : 0) debugger=\(isDebuggerAttached() ? 1 : 0)")
        UIApplication.shared.isIdleTimerDisabled = true
        Gamepad.shared.start()
        Diagnostics.shared.start()
        return true
    }

    // The monitor gets its own scene: the game layer only (ExternalDisplay).
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if session.role == .windowExternalDisplayNonInteractive {
            let config = UISceneConfiguration(name: "External", sessionRole: session.role)
            config.delegateClass = ExternalSceneDelegate.self
            return config
        }
        return UISceneConfiguration(name: "Default", sessionRole: session.role)
    }
}
