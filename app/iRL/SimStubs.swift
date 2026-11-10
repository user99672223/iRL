// iOS Simulator only (EXCLUDED_SOURCE_FILE_NAMES on iphoneos). Stands in for Madeira's
// StikJITHelper.swift, which needs a real device, a debugger and the JIT pool.
import Foundation

enum StikJITHelper {
    static var poolFailure: String? { "the iOS Simulator has no StikDebug JIT" }
    static var poolHole: (off: Int, end: Int)? { nil }
    static var poolHole2: (off: Int, end: Int)? { nil }
    static var poolLow: (rx: Int, size: Int)? { nil }
    static func allocatePool(poolSize: Int = 128 * 1024 * 1024) -> (rx: UnsafeMutableRawPointer, rw: UnsafeMutableRawPointer, size: Int)? { nil }
    static func detachDebugger() {}
}
