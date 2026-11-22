import Foundation
import Darwin
import IOKit

// MARK: - Raw readers (no private APIs, no root needed)

struct CPUTicks { var user, system, idle, nice: UInt64 }

enum Sys {
    static func sysctlInt(_ name: String) -> Int? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Per-core cumulative tick counters.
    static func cpuTicks() -> [CPUTicks] {
        var numCPU: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPU, &info, &count) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        let n = Int(CPU_STATE_MAX)
        return (0..<Int(numCPU)).map { i in
            func t(_ s: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[i * n + Int(s)])) }
            return CPUTicks(user: t(CPU_STATE_USER), system: t(CPU_STATE_SYSTEM),
                            idle: t(CPU_STATE_IDLE), nice: t(CPU_STATE_NICE))
        }
    }

    static func vmStats() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let r = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        return r == KERN_SUCCESS ? stats : nil
    }

    static func swap() -> (used: UInt64, total: UInt64) {
        var s = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &s, &size, nil, 0) == 0 else { return (0, 0) }
        return (s.xsu_used, s.xsu_total)
    }

    struct GPURaw { var util: Double; var renderer: Double; var tiler: Double
                    var inUseMem: UInt64; var allocMem: UInt64; var name: String; var cores: Int }

    /// Reads the GPU driver's PerformanceStatistics from the IORegistry.
    static func gpu() -> GPURaw? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }
        var result: GPURaw?
        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            guard result == nil,
                  let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString,
                                                               kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
            else { continue }
            func num(_ k: String) -> Double { (stats[k] as? NSNumber)?.doubleValue ?? 0 }
            let model = IORegistryEntryCreateCFProperty(service, "model" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String ?? "GPU"
            let cores = (IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber)?.intValue ?? 0
            result = GPURaw(util: num("Device Utilization %"), renderer: num("Renderer Utilization %"),
                            tiler: num("Tiler Utilization %"),
                            inUseMem: UInt64(num("In use system memory")), allocMem: UInt64(num("Alloc system memory")),
                            name: model, cores: cores)
        }
        return result
    }
}

// MARK: - Published model

struct MemoryInfo {
    var total: UInt64 = 0
    var app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, cached: UInt64 = 0, free: UInt64 = 0
    var gpuInUse: UInt64 = 0, gpuAllocated: UInt64 = 0
    var swapUsed: UInt64 = 0, swapTotal: UInt64 = 0
    var pressure: Int = 1
    var used: UInt64 { app + wired + compressed }
    /// Everything that's "used" and not attributed to the GPU driver.
    var cpuSide: UInt64 { used > gpuInUse ? used - gpuInUse : 0 }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct VolumeInfo: Identifiable {
    var id: String { path }
    var name: String, path: String, total: UInt64, available: UInt64
    var used: UInt64 { total > available ? total - available : 0 }
    var fraction: Double { total > 0 ? Double(used) / Double(total) : 0 }
}

struct CoreGroup: Identifiable { var id: String { name }; var name: String; var count: Int }

@MainActor
final class Monitor: ObservableObject {
    static let historyLength = 90

    @Published var cpuTotal: Double = 0
    @Published var cpuUser: Double = 0
    @Published var cpuSystem: Double = 0
    @Published var perCore: [Double] = []
    @Published var cpuHistory: [Double] = []
    @Published var coreHistory: [[Double]] = []
    @Published var gpuUtil: Double = 0
    @Published var gpuRenderer: Double = 0
    @Published var gpuTiler: Double = 0
    @Published var gpuHistory: [Double] = []
    @Published var memHistory: [Double] = []
    @Published var memory = MemoryInfo()
    @Published var volumes: [VolumeInfo] = []

    let cpuName = Sys.sysctlString("machdep.cpu.brand_string") ?? "CPU"
    let coreGroups: [CoreGroup] = {
        let n = Sys.sysctlInt("hw.nperflevels") ?? 0
        return (0..<n).compactMap { i in
            guard let c = Sys.sysctlInt("hw.perflevel\(i).logicalcpu") else { return nil }
            return CoreGroup(name: Sys.sysctlString("hw.perflevel\(i).name") ?? "Level \(i)", count: c)
        }
    }()
    private(set) var gpuName = "GPU"
    private(set) var gpuCores = 0

    private var lastTicks: [CPUTicks] = []
    private var timer: Timer?
    private var tick = 0

    private var interval: Double = 0

    init() {
        memory.total = UInt64(ProcessInfo.processInfo.physicalMemory)
        lastTicks = Sys.cpuTicks()
        sample()
        reschedule()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        }
    }

    /// Restarts the timer when the "interval" preference changes.
    private func reschedule() {
        let wanted = max(0.5, UserDefaults.standard.double(forKey: "interval").nonZero ?? 1)
        guard wanted != interval else { return }
        interval = wanted
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: wanted, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer?.tolerance = wanted * 0.1
    }

    private func push(_ v: Double, to arr: inout [Double]) {
        arr.append(v)
        if arr.count > Self.historyLength { arr.removeFirst(arr.count - Self.historyLength) }
    }

    func sample() {
        // CPU
        let now = Sys.cpuTicks()
        if now.count == lastTicks.count, !now.isEmpty {
            var cores: [Double] = []
            var tu: UInt64 = 0, ts: UInt64 = 0, tAll: UInt64 = 0
            for (a, b) in zip(lastTicks, now) {
                let u = (b.user &- a.user) + (b.nice &- a.nice)
                let s = b.system &- a.system
                let all = u + s + (b.idle &- a.idle)
                cores.append(all > 0 ? Double(u + s) / Double(all) : 0)
                tu += u; ts += s; tAll += all
            }
            perCore = cores
            cpuUser = tAll > 0 ? Double(tu) / Double(tAll) : 0
            cpuSystem = tAll > 0 ? Double(ts) / Double(tAll) : 0
            cpuTotal = cpuUser + cpuSystem
            if coreHistory.count != cores.count { coreHistory = Array(repeating: [], count: cores.count) }
            for i in cores.indices { push(cores[i], to: &coreHistory[i]) }
            push(cpuTotal, to: &cpuHistory)
        }
        lastTicks = now

        // GPU
        var m = memory
        if let g = Sys.gpu() {
            gpuUtil = g.util / 100; gpuRenderer = g.renderer / 100; gpuTiler = g.tiler / 100
            gpuName = g.name; gpuCores = g.cores
            m.gpuInUse = g.inUseMem; m.gpuAllocated = g.allocMem
        }
        push(gpuUtil, to: &gpuHistory)

        // Memory
        if let vm = Sys.vmStats() {
            let page = UInt64(vm_kernel_page_size)
            m.app = (UInt64(vm.internal_page_count) - UInt64(min(vm.purgeable_count, vm.internal_page_count))) * page
            m.wired = UInt64(vm.wire_count) * page
            m.compressed = UInt64(vm.compressor_page_count) * page
            m.cached = (UInt64(vm.external_page_count) + UInt64(vm.purgeable_count)) * page
            m.free = UInt64(vm.free_count) * page
        }
        let sw = Sys.swap(); m.swapUsed = sw.used; m.swapTotal = sw.total
        m.pressure = Sys.sysctlInt("kern.memorystatus_vm_pressure_level") ?? 1
        memory = m
        push(m.fraction, to: &memHistory)

        // Storage (every 10 s is plenty)
        if tick % 10 == 0 { volumes = Self.readVolumes() }
        tick += 1
    }

    static func readVolumes() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
                                      .volumeIsReadOnlyKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            // Skip read-only volumes such as mounted installer disk images (always "full").
            guard let v = try? url.resourceValues(forKeys: Set(keys)), let total = v.volumeTotalCapacity, total > 0,
                  v.volumeIsReadOnly != true || url.path == "/"
            else { return nil }
            let avail = v.volumeAvailableCapacityForImportantUsage.map { UInt64($0) }
                ?? UInt64(v.volumeAvailableCapacity ?? 0)
            return VolumeInfo(name: v.volumeName ?? url.lastPathComponent, path: url.path,
                              total: UInt64(total), available: avail)
        }
    }
}

extension Double { var nonZero: Double? { self == 0 ? nil : self } }

func fmtBytes(_ b: UInt64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .memory
    f.allowedUnits = b >= 1 << 40 ? [.useTB] : [.useGB, .useMB]
    return f.string(fromByteCount: Int64(b))
}
func fmtDisk(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
}
func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
