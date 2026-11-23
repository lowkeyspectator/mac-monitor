import Foundation
import Darwin
import IOKit

// MARK: - Raw readers (no private APIs, no root needed)

/// Raw 32-bit kernel tick counters. Deltas must be taken in UInt32 (`&-`) so a counter
/// that wraps past 2^32 still gives the right difference.
struct CPUTicks { var user, system, idle, nice: UInt32 }

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
            func t(_ s: Int32) -> UInt32 { UInt32(bitPattern: info[i * n + Int(s)]) }
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
    @Published var diskReadRate: Double = 0      // bytes/s
    @Published var diskWriteRate: Double = 0
    @Published var diskReadHistory: [Double] = []
    @Published var diskWriteHistory: [Double] = []
    @Published var network = NetworkInfo()
    @Published var netDownHistory: [Double] = []
    @Published var netUpHistory: [Double] = []
    // Per-app usage, collected only while that card's details are expanded and on screen.
    @Published var topCPU: [UsageRow] = []
    @Published var topMemory: [UsageRow] = []
    @Published var topGPU: [UsageRow] = []
    @Published var topDisk: [UsageRow] = []
    @Published var topNetwork: [UsageRow] = []
    @Published var topEnergy: [UsageRow] = []
    @Published var battery = BatteryInfo()
    @Published var system = SystemInfo()
    @Published var energyMode: EnergyMode?
    @Published var energyModeError: String?

    /// Called after every sample (used by the alert engine).
    var onSample: ((Monitor) -> Void)?

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
    private var lastVolumeRefresh = Date.distantPast
    private var lastSampleTime = Date()
    private var lastNet: (iface: String, rx: UInt64, tx: UInt64)?
    private var lastDisk: (read: UInt64, write: UInt64)?
    private var lastSlowRefresh = Date.distantPast     // battery, processes, IP
    private var processesInFlight = false
    private var detailRefs: [Metric: Int] = [:]
    private var lastGPUTimes: [Int32: (name: String, ns: UInt64)] = [:]
    private var lastGPUAt = Date()
    private var lastDiskTotals: [Int32: (read: UInt64, write: UInt64)] = [:]
    private var lastDiskAt = Date()
    private var lastCPUTimes: [Int32: Double] = [:]
    private var lastCPUTimesAt = Date.distantPast
    // nettop: two samples 2 s apart, delta mode; repeated while the Network card is open.
    private lazy var netStream = RepeatingCommand(
        "/usr/bin/nettop", ["-P", "-d", "-x", "-L", "2", "-s", "2", "-J", "bytes_in,bytes_out"],
        onOutput: { [weak self] lines in
            let rows = Array(NetProcessParser.parse(NetProcessParser.lastBlock(lines), seconds: 2).prefix(5))
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.topNetwork = rows } }
        })
    private lazy var energyStream = StreamCollector(
        "/usr/bin/top", ["-l", "0", "-s", "3", "-n", "8", "-o", "power", "-stats", "pid,command,power"],
        isHeader: { $0.hasPrefix("Processes:") },
        onBlock: { [weak self] lines in
            let rows = Array(EnergyParser.parse(lines).prefix(5))
            DispatchQueue.main.async { MainActor.assumeIsolated { if !rows.isEmpty { self?.topEnergy = rows } } }
        })

    /// Cards call this as their details appear and disappear. Per-app collection runs only while visible.
    func setDetailVisible(_ metric: Metric, _ visible: Bool) {
        let n = max(0, (detailRefs[metric] ?? 0) + (visible ? 1 : -1))
        detailRefs[metric] = n
        switch metric {
        case .network: n > 0 ? netStream.start() : netStream.stop()
        case .battery: n > 0 ? energyStream.start() : energyStream.stop()
        default: break
        }
        if visible { lastSlowRefresh = .distantPast }     // load the list right away
        if visible && metric == .battery { refreshEnergyMode() }
        if n == 0 {
            switch metric {
            case .network: topNetwork = []
            case .battery: topEnergy = []
            case .gpu: lastGPUTimes = [:]; topGPU = []
            case .storage: lastDiskTotals = [:]; topDisk = []
            default: break
            }
        }
    }

    private func detailVisible(_ m: Metric) -> Bool { (detailRefs[m] ?? 0) > 0 }

    func stopStreams() { netStream.stop(); energyStream.stop() }

    private func resetBaselines() {
        lastTicks = Sys.cpuTicks()
        lastNet = nil; lastDisk = nil
        lastSampleTime = Date()
        lastCPUTimes = [:]; lastGPUTimes = [:]; lastDiskTotals = [:]
        lastSlowRefresh = .distantPast; lastVolumeRefresh = .distantPast
    }

    func refreshEnergyMode() {
        DispatchQueue.global(qos: .utility).async {
            let mode = EnergyModeControl.current()
            DispatchQueue.main.async { MainActor.assumeIsolated { self.energyMode = mode } }
        }
    }

    /// Changes the energy mode (shows the macOS administrator prompt), then re-reads it.
    func setEnergyMode(_ mode: EnergyMode) {
        guard mode != energyMode else { return }
        energyModeError = EnergyModeControl.set(mode)
        refreshEnergyMode()
    }

    private var interval: Double = 0

    init() {
        memory.total = UInt64(ProcessInfo.processInfo.physicalMemory)
        lastTicks = Sys.cpuTicks()
        sample()
        reschedule()
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        }
        if !Snapshot.isActive { AlertEngine.shared.attach(self) }
        // After sleep, start rates and per-app deltas fresh instead of averaging over the time asleep.
        NSWorkspaceNotifications.observeWake { [weak self] in self?.resetBaselines() }
        // Stop the nettop/top helpers when the app quits so they don't outlive it.
        NotificationCenter.default.addObserver(forName: Notification.Name("NSApplicationWillTerminateNotification"),
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopStreams() }
        }
    }

    /// Restarts the timer when the "interval" preference changes.
    private func reschedule() {
        let wanted = max(0.5, UserDefaults.standard.double(forKey: "interval").nonZero ?? 1)
        guard wanted != interval else { return }
        interval = wanted
        timer?.invalidate()
        let t = Timer(timeInterval: wanted, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        t.tolerance = wanted * 0.1
        // .common keeps sampling while menus or pickers are open (the default mode pauses during tracking).
        RunLoop.main.add(t, forMode: .common)
        timer = t
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
                let u = UInt64(b.user &- a.user) + UInt64(b.nice &- a.nice)
                let s = UInt64(b.system &- a.system)
                let all = u + s + UInt64(b.idle &- a.idle)
                cores.append(all > 0 ? Double(u + s) / Double(all) : 0)
                tu += u; ts += s; tAll += all
            }
            perCore = cores
            cpuUser = tAll > 0 ? Double(tu) / Double(tAll) : 0
            cpuSystem = tAll > 0 ? Double(ts) / Double(tAll) : 0
            cpuTotal = cpuUser + cpuSystem
            // Build per-core history locally and publish it once (not once per core).
            var history = coreHistory.count == cores.count ? coreHistory : Array(repeating: [], count: cores.count)
            for i in cores.indices { push(cores[i], to: &history[i]) }
            coreHistory = history
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

        // Storage: every 10 seconds of wall-clock time, whatever the sample interval.
        if Date().timeIntervalSince(lastVolumeRefresh) >= 10 {
            volumes = Self.readVolumes()
            lastVolumeRefresh = Date()
        }

        let now0 = Date()
        let dt = max(0.1, now0.timeIntervalSince(lastSampleTime))
        lastSampleTime = now0

        // Disk throughput
        let disk = DiskIOReader.totals()
        if let last = lastDisk {
            diskReadRate = Double(disk.read &- last.read) / dt
            diskWriteRate = Double(disk.write &- last.write) / dt
            if disk.read < last.read || disk.write < last.write { diskReadRate = 0; diskWriteRate = 0 }
        }
        lastDisk = disk
        push(diskReadRate, to: &diskReadHistory)
        push(diskWriteRate, to: &diskWriteHistory)

        // Network throughput on the primary interface
        var net = network
        let iface = NetReader.primaryInterface() ?? ""
        net.interface = iface
        if let c = NetReader.counters()[iface] {
            if let last = lastNet, last.iface == iface {
                // Counters are 32-bit for unprivileged apps and wrap every 4 GB.
                let drx = UInt32(truncatingIfNeeded: c.rx) &- UInt32(truncatingIfNeeded: last.rx)
                let dtx = UInt32(truncatingIfNeeded: c.tx) &- UInt32(truncatingIfNeeded: last.tx)
                net.downRate = Double(drx) / dt
                net.upRate = Double(dtx) / dt
            } else {
                net.downRate = 0; net.upRate = 0
            }
            lastNet = (iface, c.rx, c.tx)
        } else {
            net.downRate = 0; net.upRate = 0; lastNet = nil
        }
        push(net.downRate, to: &netDownHistory)
        push(net.upRate, to: &netUpHistory)

        // Slower things every 3 s: IP, battery, system, processes
        if now0.timeIntervalSince(lastSlowRefresh) >= 3 {
            lastSlowRefresh = now0
            net.localIP = iface.isEmpty ? "" : NetReader.ipv4(of: iface)
            battery = BatteryReader.read()
            system = SystemReader.read()
            refreshPerProcess(interface: iface)
        }
        network = net

        onSample?(self)
    }

    /// Per-app lists for whichever cards are expanded, gathered off the main thread:
    /// `ps` for CPU and memory, the GPU driver for GPU time, rusage for disk I/O, and
    /// `netstat` for 64-bit network totals. Network and energy lists come from streams.
    private func refreshPerProcess(interface: String) {
        let wantPS = detailVisible(.cpu) || detailVisible(.memory)
        let wantGPU = detailVisible(.gpu), wantDisk = detailVisible(.storage)
        let wantTotals = detailVisible(.network) && !interface.isEmpty
        guard wantPS || wantGPU || wantDisk || wantTotals, !processesInFlight else { return }
        processesInFlight = true
        let prevGPU = lastGPUTimes, prevGPUAt = lastGPUAt, prevDisk = lastDiskTotals, prevDiskAt = lastDiskAt
        let prevCPU = lastCPUTimes, prevCPUAt = lastCPUTimesAt
        DispatchQueue.global(qos: .utility).async {
            let totals = wantTotals ? NetReader.totals(of: interface) : nil
            var byCPU: [UsageRow] = [], byMem: [UsageRow] = []
            var cpuTimes: [Int32: Double] = [:], cpuAt = Date()
            if wantPS {
                // CPU % = CPU time used between two samples ÷ wall time, like Activity Monitor.
                var before = prevCPU, beforeAt = prevCPUAt
                if before.isEmpty || Date().timeIntervalSince(beforeAt) > 15 {
                    before = Dictionary(ProcessReader.snapshot().map { ($0.pid, $0.cpuTime) }, uniquingKeysWith: { a, _ in a })
                    beforeAt = Date()
                    Thread.sleep(forTimeInterval: 1)
                }
                let list = ProcessReader.snapshot()
                cpuAt = Date()
                let wall = max(0.2, cpuAt.timeIntervalSince(beforeAt))
                cpuTimes = Dictionary(list.map { ($0.pid, $0.cpuTime) }, uniquingKeysWith: { a, _ in a })
                byCPU = list.compactMap { e -> UsageRow? in
                    guard let old = before[e.pid] else { return nil }
                    let share = max(0, e.cpuTime - old) / wall
                    return share > 0 ? UsageRow(pid: e.pid, name: e.name, value: share, text: pctSmall(share)) : nil
                }
                .sorted { $0.value > $1.value }.prefix(5).map { $0 }
                byMem = list.sorted { $0.memory > $1.memory }.prefix(5)
                    .map { UsageRow(pid: $0.pid, name: $0.name, value: Double($0.memory), text: fmtBytes($0.memory)) }
            }
            var gpuTimes: [Int32: (name: String, ns: UInt64)] = [:], gpuRows: [UsageRow] = [], gpuAt = Date()
            if wantGPU {
                gpuTimes = GPUProcessReader.times()
                gpuAt = Date()
                let elapsed = max(0.2, gpuAt.timeIntervalSince(prevGPUAt))
                if !prevGPU.isEmpty {
                    gpuRows = gpuTimes.compactMap { pid, cur in
                        guard let old = prevGPU[pid], cur.ns > old.ns else { return nil }
                        let share = min(1, Double(cur.ns - old.ns) / (elapsed * 1e9))
                        return share >= 0.001 ? UsageRow(pid: pid, name: processName(pid) ?? cur.name,
                                                         value: share, text: pctSmall(share)) : nil
                    }
                    .sorted { $0.value > $1.value }.prefix(5).map { $0 }
                }
            }
            var diskTotals: [Int32: (read: UInt64, write: UInt64)] = [:], diskRows: [UsageRow] = [], diskAt = Date()
            if wantDisk {
                diskTotals = DiskProcessReader.totals()
                diskAt = Date()
                let elapsed = max(0.2, diskAt.timeIntervalSince(prevDiskAt))
                if !prevDisk.isEmpty {
                    diskRows = diskTotals.compactMap { pid, cur in
                        guard let old = prevDisk[pid], cur.read >= old.read, cur.write >= old.write else { return nil }
                        let r = Double(cur.read - old.read) / elapsed, w = Double(cur.write - old.write) / elapsed
                        guard r + w >= 1000, let name = processName(pid) else { return nil }
                        return UsageRow(pid: pid, name: name, value: r + w, text: "R \(fmtRate(r))  W \(fmtRate(w))")
                    }
                    .sorted { $0.value > $1.value }.prefix(5).map { $0 }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if wantPS {
                        self.topCPU = byCPU; self.topMemory = byMem
                        self.lastCPUTimes = cpuTimes; self.lastCPUTimesAt = cpuAt
                    }
                    if wantGPU && self.detailVisible(.gpu) {
                        self.lastGPUTimes = gpuTimes; self.lastGPUAt = gpuAt
                        if !prevGPU.isEmpty { self.topGPU = gpuRows }
                    }
                    if wantDisk && self.detailVisible(.storage) {
                        self.lastDiskTotals = diskTotals; self.lastDiskAt = diskAt
                        if !prevDisk.isEmpty { self.topDisk = diskRows }
                    }
                    if let totals, self.network.interface == interface {
                        self.network.totalDown = totals.rx
                        self.network.totalUp = totals.tx
                    }
                    self.processesInFlight = false
                }
            }
        }
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

/// Formatters are reused (creating one per call showed up on every redraw); a lock keeps them
/// safe to call from the background per-app refresh as well.
private enum Formatters {
    static let lock = NSLock()
    nonisolated(unsafe) static let gbmb: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .memory; f.allowedUnits = [.useGB, .useMB]; return f
    }()
    nonisolated(unsafe) static let tb: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .memory; f.allowedUnits = [.useTB]; return f
    }()
}

func fmtBytes(_ b: UInt64) -> String {
    Formatters.lock.lock(); defer { Formatters.lock.unlock() }
    return (b >= 1 << 40 ? Formatters.tb : Formatters.gbmb).string(fromByteCount: Int64(b))
}
func fmtDisk(_ b: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .file)
}
func pct(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

import AppKit

enum NSWorkspaceNotifications {
    static func observeWake(_ handler: @escaping @MainActor () -> Void) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
    }
}
