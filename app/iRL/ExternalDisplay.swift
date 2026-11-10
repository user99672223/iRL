import UIKit
import Metal
import QuartzCore

/// The game's CAMetalLayer. One layer for the process lifetime: DXMT registers it once
/// (madeira_display_set_layer) and keeps presenting to it; only its parent view changes.
final class GameLayerView: UIView {
    static let shared = GameLayerView(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = true
        backgroundColor = .black
        metalLayer.device = MTLCreateSystemDefaultDevice()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        metalLayer.contentsGravity = .resize
    }
    required init?(coder: NSCoder) { fatalError() }

    private static var registered = false
    static func registerOnce() {
        guard !registered else { return }
        registered = true
        madeira_display_set_layer(shared.metalLayer)
    }
}

/// The external monitor (USB-C DisplayPort through the hub): an opaque, full-screen window with
/// only the game layer in it, sized to exactly the output mode, so iOS can scan it out directly.
@MainActor
final class ExternalDisplay {
    static let shared = ExternalDisplay()
    private(set) var window: UIWindow?
    private(set) var screen: UIScreen?
    private(set) var chosen: UIScreenMode?

    /// Output pixels the game should target: the external mode, or the phone's screen without one.
    var outputSize: (w: Int, h: Int) {
        if let m = chosen ?? screen?.currentMode { return (Int(m.size.width), Int(m.size.height)) }
        let b = UIScreen.main.nativeBounds
        return (Int(max(b.width, b.height)), Int(min(b.width, b.height)))
    }

    func describe() -> String {
        guard let screen else { return "external=none (game on the phone screen)" }
        let modes = screen.availableModes.map { "\(Int($0.size.width))x\(Int($0.size.height))" }.joined(separator: ",")
        let cur = screen.currentMode.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "?"
        return "external=\(cur) maxFPS=\(screen.maximumFramesPerSecond) modes=[\(modes)]"
    }

    func attach(_ scene: UIWindowScene) {
        let screen = scene.screen
        self.screen = screen
        // 1440p if offered (the monitor's native mode); otherwise the largest mode at or below 4K.
        let modes = screen.availableModes
        let pick = modes.first { Int($0.size.width) == 2560 && Int($0.size.height) == 1440 }
            ?? modes.filter { $0.size.width <= 3840 }.max { $0.size.width * $0.size.height < $1.size.width * $1.size.height }
        if let pick, screen.currentMode != pick {
            screen.currentMode = pick
        }
        chosen = screen.currentMode
        screen.overscanCompensation = .none

        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        host.view.backgroundColor = .black
        let layerView = GameLayerView.shared
        layerView.removeFromSuperview()
        layerView.frame = host.view.bounds
        layerView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        layerView.contentScaleFactor = 1
        if let m = chosen { layerView.metalLayer.drawableSize = m.size }
        host.view.addSubview(layerView)
        window.rootViewController = host
        window.isHidden = false
        self.window = window
        GameLayerView.registerOnce()
        LogStore.shared.log("[display] external connected: \(describe())", level: .success)
    }

    func detach() {
        window?.isHidden = true
        window = nil
        screen = nil
        chosen = nil
        LogStore.shared.log("[display] external disconnected", level: .error)
    }
}

final class ExternalSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let ws = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated {
            ExternalDisplay.shared.attach(ws)
            window = ExternalDisplay.shared.window
        }
    }
    func sceneDidDisconnect(_ scene: UIScene) {
        MainActor.assumeIsolated { ExternalDisplay.shared.detach() }
    }
}
