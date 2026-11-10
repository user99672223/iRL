import Foundation
import UIKit
import Darwin

/// One sample a second: memory footprint and headroom, CPU (process and per-thread top), thermal
/// state, battery, frames presented, frame-time percentiles, GPU busy time, AOT cache count.
/// Written to diagnostics.csv in the launch folder and shown, still, on the phone screen.
/// Cost: a few syscalls per second on a utility queue.
struct DiagSample {
    var time = Date()
    var footprintMB = 0
    var availableMB = 0
    var cpuPercent = 0.0
    var threads = 0
    var thermal = "nominal"
    var battery = -1
    var charging = false
    var fps = 0.0
    var frameP50ms = 0.0
    var frameP99ms = 0.0
    var gpuBusyPercent = 0.0
    var aotCaches = 0
    var energyJ = 0.0
}

final class Diagnostics: ObservableObject {
    static let shared = Diagnostics()
    @Published private(set) var last = DiagSample()

    private let queue = DispatchQueue(label: "irl.diag", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var csv: FileHandle?
    private var prevPresents: UInt64 = 0
    private var prevGPU = 0.0
    private var prevCPU = 0.0
    private var prevWall = CFAbsoluteTimeGetCurrent()

    func start() {
        let url = LaunchLogs.shared.file("diagnostics.csv")
        FileManager.default.createFile(atPath: url.path,
            contents: Data("time,footprint_mb,available_mb,cpu_pct,threads,thermal,battery,charging,fps,frame_p50_ms,frame_p99_ms,gpu_busy_pct,aot_caches,energy_j\n".utf8))
        csv = try? FileHandle(forWritingTo: url)
        csv?.seekToEndOfFile()
        UIDevice.current.isBatteryMonitoringEnabled = true
        madeira_gpu_meter_enable(1)
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: .seconds(1), leeway: .milliseconds(100))
        let battery = { () -> (Int, Bool) in
            (Int(UIDevice.current.batteryLevel * 100), UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full)
        }
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let bat = DispatchQueue.main.sync { battery() }
            let s = self.sample(battery: bat)
            DispatchQueue.main.async { self.last = s }
        }
        t.resume()
        timer = t
    }

    private func sample(battery: (Int, Bool)) -> DiagSample {
        var s = DiagSample()
        // Memory: phys_footprint is what jetsam counts; os_proc_available_memory is the headroom.
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        if withUnsafeMutablePointer(to: &info, { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }) == KERN_SUCCESS {
            s.footprintMB = Int(info.phys_footprint >> 20)
        }
        s.availableMB = Int(os_proc_available_memory() >> 20)
        // CPU: process user+system time over wall time (100% = one core).
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
        let wall = CFAbsoluteTimeGetCurrent()
        let dt = max(0.001, wall - prevWall)
        s.cpuPercent = (cpu - prevCPU) / dt * 100
        // Threads.
        var list: thread_act_array_t?
        var n: mach_msg_type_number_t = 0
        if task_threads(mach_task_self_, &list, &n) == KERN_SUCCESS, let list {
            s.threads = Int(n)
            for i in 0..<Int(n) { mach_port_deallocate(mach_task_self_, list[i]) }
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: list)), vm_size_t(Int(n) * MemoryLayout<thread_t>.stride))
        }
        // Energy billed to this pid (proc_pid_rusage, IRLDiag.c).
        s.energyJ = Double(irl_energy_nj()) / 1e9
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: s.thermal = "nominal"
        case .fair: s.thermal = "fair"
        case .serious: s.thermal = "serious"
        case .critical: s.thermal = "critical"
        @unknown default: s.thermal = "unknown"
        }
        (s.battery, s.charging) = battery
        // Frames (DXMT presents) and frame-time percentiles over the last second.
        let presents = madeira_shown_frame_count()
        s.fps = Double(presents &- prevPresents) / dt
        var times = [UInt32](repeating: 0, count: 512)
        var sinceLast: UInt32 = 0
        let k = Int(madeira_frame_times_us(&times, Int32(times.count), 1000, &sinceLast))
        if k > 0 {
            let sorted = times[0..<k].sorted()
            s.frameP50ms = Double(sorted[k / 2]) / 1000
            s.frameP99ms = Double(sorted[min(k - 1, k * 99 / 100)]) / 1000
        }
        let gpu = madeira_gpu_meter_busy_seconds()
        s.gpuBusyPercent = (gpu - prevGPU) / dt * 100
        s.aotCaches = Runtime.aotCacheCount()
        prevPresents = presents; prevGPU = gpu; prevCPU = cpu; prevWall = wall
        let line = String(format: "%.0f,%d,%d,%.1f,%d,%@,%d,%d,%.1f,%.2f,%.2f,%.1f,%d,%.2f\n",
                          s.time.timeIntervalSince1970, s.footprintMB, s.availableMB, s.cpuPercent, s.threads, s.thermal,
                          s.battery, s.charging ? 1 : 0, s.fps, s.frameP50ms, s.frameP99ms, s.gpuBusyPercent, s.aotCaches, s.energyJ)
        csv?.write(Data(line.utf8))
        return s
    }
}
