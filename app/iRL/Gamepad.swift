import GameController
import CoreHaptics

/// DualSense (wired or Bluetooth) through GameController -> Winios XInput slots -> the game's
/// XInput. Player 1 only: Rocket League on one screen. Sampled at 250 Hz off the main thread.
final class Gamepad {
    static let shared = Gamepad()
    private let queue = DispatchQueue(label: "irl.gamepad", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var controller: GCController?
    private var packet: UInt32 = 0

    func start() {
        GCController.shouldMonitorBackgroundEvents = true
        NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: nil) { [weak self] n in
            guard let c = n.object as? GCController, c.extendedGamepad != nil else { return }
            self?.queue.async { self?.controller = c }
            LogStore.shared.log("[pad] connected: \(c.productCategory) \(c.vendorName ?? "")", level: .success)
        }
        NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: nil) { [weak self] n in
            self?.queue.async {
                if (n.object as? GCController) === self?.controller {
                    self?.controller = nil
                    winios_gamepad_set_state(0, nil)
                }
            }
            LogStore.shared.log("[pad] disconnected", level: .error)
        }
        queue.async { self.controller = GCController.controllers().first { $0.extendedGamepad != nil } }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.sample() }
        t.resume()
        timer = t
    }

    private static func axis(_ v: Float) -> Int16 { Int16(max(-32767, min(32767, (v * 32767).rounded()))) }
    private static func trigger(_ v: Float) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }

    private func sample() {
        guard let pad = controller?.extendedGamepad else { return }
        var s = winios_gamepad()
        s.connected = 1
        let buttons: [(GCControllerButtonInput?, UInt16)] = [
            (pad.dpad.up, 0x0001), (pad.dpad.down, 0x0002), (pad.dpad.left, 0x0004), (pad.dpad.right, 0x0008),
            (pad.buttonMenu, 0x0010), (pad.buttonOptions, 0x0020),
            (pad.leftThumbstickButton, 0x0040), (pad.rightThumbstickButton, 0x0080),
            (pad.leftShoulder, 0x0100), (pad.rightShoulder, 0x0200),
            (pad.buttonA, 0x1000), (pad.buttonB, 0x2000), (pad.buttonX, 0x4000), (pad.buttonY, 0x8000),
        ]
        for (b, mask) in buttons where b?.isPressed == true { s.buttons |= mask }
        s.left_trigger = Self.trigger(pad.leftTrigger.value)
        s.right_trigger = Self.trigger(pad.rightTrigger.value)
        s.lx = Self.axis(pad.leftThumbstick.xAxis.value)
        s.ly = Self.axis(pad.leftThumbstick.yAxis.value)
        s.rx = Self.axis(pad.rightThumbstick.xAxis.value)
        s.ry = Self.axis(pad.rightThumbstick.yAxis.value)
        winios_gamepad_set_state(0, &s)
    }
}
