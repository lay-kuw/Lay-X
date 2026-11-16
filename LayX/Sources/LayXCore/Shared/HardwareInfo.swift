import Darwin
import IOKit
import Foundation

/// Facts about this Mac, recorded with every benchmark so results are interpretable.
public struct HardwareInfo: Sendable, Codable, Hashable {
    public var chip: String
    public var performanceCores: Int
    public var efficiencyCores: Int
    public var gpuCores: Int?
    public var memoryBytes: Int64
    public var osVersion: String

    public static let current: HardwareInfo = {
        let pv = ProcessInfo.processInfo.operatingSystemVersion
        return HardwareInfo(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon",
            performanceCores: sysctlInt("hw.perflevel0.physicalcpu") ?? 0,
            efficiencyCores: sysctlInt("hw.perflevel1.physicalcpu") ?? 0,
            gpuCores: gpuCoreCount(),
            memoryBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            osVersion: "macOS \(pv.majorVersion).\(pv.minorVersion)" + (pv.patchVersion > 0 ? ".\(pv.patchVersion)" : ""))
    }()

    /// e.g. "M5 Max · 40-core GPU · 128 GB · macOS 27.2"
    public var summary: String {
        var parts = [chip.replacingOccurrences(of: "Apple ", with: "")]
        if let g = gpuCores { parts.append("\(g)-core GPU") }
        parts.append("\(memoryBytes / (1 << 30)) GB")
        parts.append(osVersion)
        return parts.joined(separator: " · ")
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }, as: UTF8.self)
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }

    /// GPU core count from the IORegistry (AGXAccelerator "gpu-core-count"); nil if unavailable.
    static func gpuCoreCount() -> Int? {
        let matching = IOServiceMatching("AGXAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let service = IOIteratorNext(iterator)
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? NSNumber)?.intValue
    }
}

/// System-wide memory in use (wired + active + compressed), for the sidebar meter.
public enum SystemMemory {
    public static func usedBytes() -> Int64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        let page = Int64(getpagesize())
        return (Int64(stats.wire_count) + Int64(stats.active_count) + Int64(stats.compressor_page_count)) * page
    }

    /// Physical memory not in use (total − wired − active − compressed): what a new model can take without
    /// pushing the system into swap.
    public static func availableBytes() -> Int64 {
        max(Int64(HardwareInfo.current.memoryBytes) - (usedBytes() ?? 0), 0)
    }
}

/// Memory reported by the inference engine.
public struct EngineMemory: Sendable, Codable, Hashable {
    public var activeBytes: Int64
    public var cacheBytes: Int64
    public var peakBytes: Int64
    public init(activeBytes: Int64, cacheBytes: Int64, peakBytes: Int64) {
        self.activeBytes = activeBytes
        self.cacheBytes = cacheBytes
        self.peakBytes = peakBytes
    }
}
