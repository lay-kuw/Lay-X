import Foundation
import LayXCore

/// Engine / lifecycle preferences (UserDefaults; no content).
enum EnginePreferences {
    static let keepLoadedKey = "lx.keepLoadedMinutes"   // 0 = always
    static let memoryLimitKey = "lx.memoryLimitGB"      // 0 = automatic (75 % of RAM)
    static let kvBitsKey = "lx.kvBits"                  // 0 = off, 8, 4
    static let gpuLimitKey = "lx.gpuLimit"              // 0.3 … 1.0

    static let keepLoadedOptions: [(minutes: Int, label: String)] = [(5, "5 minutes"), (15, "15 minutes"), (60, "1 hour"), (0, "Always")]
    static var physicalGB: Double { Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824 }

    static var keepLoadedMinutes: Int { UserDefaults.standard.object(forKey: keepLoadedKey) as? Int ?? 15 }

    static var engineSettings: EngineSettings {
        let d = UserDefaults.standard
        let gb = d.double(forKey: memoryLimitKey)
        let bits = d.integer(forKey: kvBitsKey)
        return EngineSettings(memoryLimitBytes: gb > 0 ? Int64(gb * 1_073_741_824) : nil, kvBits: bits == 0 ? nil : bits,
                              gpuLimit: d.object(forKey: gpuLimitKey) as? Double ?? 1)
    }
}
