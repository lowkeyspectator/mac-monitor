import Foundation
import Darwin
import IOKit
import IOKit.ps
import SystemConfiguration

// Additional readers: network, disk I/O, processes, battery, system. Public APIs only.

// MARK: - Network

struct NetworkInfo {
    var interface = ""          // e.g. "en0"
    var localIP = ""
    var upRate: Double = 0      // bytes/s
    var downRate: Double = 0
    var totalUp: UInt64 = 0     // since boot, on the primary interface
    var totalDown: UInt64 = 0
    var connected: Bool { !interface.isEmpty }
}

enum NetReader {
    nonisolated(unsafe) private static let store = SCDynamicStoreCreate(nil, "MacMonitor" as CFString, nil, nil)
    nonisolated(unsafe) private static var cachedInterface: (name: String?, at: Date) = (nil, .distantPast)

    /// The interface macOS currently routes traffic through (Wi-Fi, Ethernet, …).
    /// Re-read every 5 s from one long-lived configd session rather than a new session per sample.
    /// Called from the main thread only.
    static func primaryInterface() -> String? {
        if Date().timeIntervalSince(cachedInterface.at) < 5 { return cachedInterface.name }
        var name: String?
        if let store, let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
            name = dict["PrimaryInterface"] as? String
        }
        cachedInterface = (name, Date())
        return name
    }

    /// Byte counters per interface. Unprivileged apps only get the low 32 bits,
    /// so take deltas with UInt32 wrap-around arithmetic.
    static func counters() -> [String: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
        var out: [String: (UInt64, UInt64)] = [:]
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                guard hdr.ifm_msglen > 0 else { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(h2.ifm_index), &name) != nil {
                        out[String(cString: name)] = (h2.ifm_data.ifi_ibytes, h2.ifm_data.ifi_obytes)
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        return out.mapValues { (rx: $0.0, tx: $0.1) }
    }

    /// Full 64-bit totals from `netstat`; the sysctl counters above are truncated to 32 bits
    /// for unprivileged apps, so they're only good for short-interval rates.
    static func totals(of interface: String) -> (rx: UInt64, tx: UInt64)? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
        p.arguments = ["-ibn", "-I", interface]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.runHelper() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // Columns: Name Mtu Network [Address] Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
        guard let line = String(data: data, encoding: .utf8)?.split(separator: "\n").first(where: { $0.contains("<Link#") })
        else { return nil }
        let f = line.split(separator: " ", omittingEmptySubsequences: true)
        guard f.count >= 10, let rx = UInt64(f[f.count - 5]), let tx = UInt64(f[f.count - 2]) else { return nil }
        return (rx, tx)
    }

    static func ipv4(of interface: String) -> String {
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return "" }
        defer { freeifaddrs(ifap) }
        for p in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let a = p.pointee
            guard let sa = a.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  String(cString: a.ifa_name) == interface else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return ""
    }
}

// MARK: - Disk I/O

enum DiskIOReader {
    /// Cumulative bytes read/written by all physical disks.
    static func totals() -> (read: UInt64, write: UInt64) {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iter) }
        var r: UInt64 = 0, w: UInt64 = 0
        var s = IOIteratorNext(iter)
        while s != 0 {
            if let stats = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] {
                r += (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                w += (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(s)
            s = IOIteratorNext(iter)
        }
        return (r, w)
    }
}

// MARK: - Processes

struct ProcessEntry: Identifiable {
    var pid: Int32, name: String
    var cpuTime: Double        // total CPU seconds used so far (user + system)
    var memory: UInt64         // physical footprint where readable, else resident size
    var id: Int32 { pid }
}

/// True for the short-lived helper processes Mac Monitor itself launches (ps, top, nettop, netstat, pmset),
/// so they never show up in its own "top apps" lists.
func isOwnHelper(_ pid: Int32) -> Bool {
    if Helpers.contains(pid) { return true }      // also covers privileged tools like nettop
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
    return Int32(info.pbi_ppid) == getpid()
}

/// PIDs of helper processes Mac Monitor has launched recently.
enum Helpers {
    nonisolated(unsafe) private static var pids: [Int32] = []
    private static let lock = NSLock()
    static func add(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        pids.append(p.processIdentifier)
        if pids.count > 64 { pids.removeFirst(pids.count - 64) }
    }
    static func contains(_ pid: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; return pids.contains(pid) }
}

extension Process {
    /// Runs the process and remembers it as one of Mac Monitor's own helpers.
    func runHelper() throws { try run(); Helpers.add(self) }
}

enum ProcessReader {
    /// Uses `ps`, which (unlike proc_pidinfo) can see every user's processes without root.
    /// CPU is returned as cumulative CPU time; callers turn two snapshots into a percentage,
    /// the way Activity Monitor does, rather than using ps's slowly decaying %CPU.
    static func snapshot() -> [ProcessEntry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pid=,ppid=,time=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.runHelper() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let own = getpid()
        return text.split(separator: "\n").compactMap { line in
            let f = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard f.count == 5, let pid = Int32(f[0]), let ppid = Int32(f[1]), ppid != own,
                  let time = parseCPUTime(f[2]), let rssKB = UInt64(f[3]) else { return nil }
            return ProcessEntry(pid: pid, name: String(f[4]), cpuTime: time,
                                memory: footprint(pid) ?? rssKB * 1024)
        }
    }

    /// ps "time": "M:SS.cc", "MM:SS.cc" or "H:MM:SS.cc" → seconds.
    static func parseCPUTime(_ s: Substring) -> Double? {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    /// Activity Monitor's "Memory" column. Readable for the current user's processes only.
    static func footprint(_ pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 && info.ri_phys_footprint > 0 ? info.ri_phys_footprint : nil
    }
}

/// Percent text that never shows a misleading "0%" for small non-zero values.
func pctSmall(_ v: Double) -> String { v > 0 && v < 0.005 ? "<1%" : pct(v) }

// MARK: - Battery

struct BatteryInfo {
    var present = false
    var level: Double = 0               // 0…1
    var charging = false
    var onAC = false
    var fullyCharged = false
    var minutesToEmpty: Int?            // nil while calculating / on AC
    var minutesToFull: Int?
    var cycleCount: Int?
    var health: Double?                 // max capacity / design capacity
    var condition: String?
    var temperature: Double?            // °C
    var adapterWatts: Int?

    /// Whether this Mac has a built-in battery (doesn't change while running).
    static let hasBattery = BatteryReader.read().present
}

enum BatteryReader {
    static func read() -> BatteryInfo {
        var b = BatteryInfo()
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return b }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            b.present = true
            let cur = (d[kIOPSCurrentCapacityKey] as? Int) ?? 0
            let max = (d[kIOPSMaxCapacityKey] as? Int) ?? 100
            b.level = max > 0 ? Double(cur) / Double(max) : 0
            b.charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
            b.onAC = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            b.fullyCharged = (d[kIOPSIsChargedKey] as? Bool) ?? false
            if let t = d[kIOPSTimeToEmptyKey] as? Int, t > 0 { b.minutesToEmpty = t }
            if let t = d[kIOPSTimeToFullChargeKey] as? Int, t > 0 { b.minutesToFull = t }
            b.condition = d[kIOPSBatteryHealthKey] as? String
        }
        guard b.present else { return b }

        // Details from the battery controller in the IORegistry.
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if svc != 0 {
            defer { IOObjectRelease(svc) }
            // Some Macs publish these at the top level, others only inside "BatteryData".
            let nested = IORegistryEntryCreateCFProperty(svc, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
            func num(_ k: String) -> Int? {
                (IORegistryEntryCreateCFProperty(svc, k as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
                    ?? (nested?[k] as? NSNumber)?.intValue
            }
            b.cycleCount = num("CycleCount")
            if let design = num("DesignCapacity"), design > 0,
               let full = num("AppleRawMaxCapacity") ?? num("NominalChargeCapacity") {
                b.health = min(1, Double(full) / Double(design))
            }
            if let t = num("Temperature") ?? num("VirtualTemperature"), t > 0 { b.temperature = Double(t) / 100 }
        }
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            b.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
        }
        return b
    }
}

// MARK: - System

struct SystemInfo {
    var load: (Double, Double, Double) = (0, 0, 0)
    var uptime: TimeInterval = 0
    var thermal: ProcessInfo.ThermalState = .nominal
    var thermalName: String {
        switch thermal {
        case .nominal: "Normal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        @unknown default: "Unknown"
        }
    }
}

enum SystemReader {
    static func read() -> SystemInfo {
        var s = SystemInfo()
        var l = [Double](repeating: 0, count: 3)
        if getloadavg(&l, 3) == 3 { s.load = (l[0], l[1], l[2]) }
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        if sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 {
            s.uptime = Date().timeIntervalSince1970 - (Double(boot.tv_sec) + Double(boot.tv_usec) / 1e6)
        }
        s.thermal = ProcessInfo.processInfo.thermalState
        return s
    }
}

// MARK: - Formatting

/// "1.2 MB/s", "340 KB/s", "0 KB/s"
func fmtRate(_ bps: Double) -> String {
    let units = ["B/s", "KB/s", "MB/s", "GB/s"]
    var v = max(0, bps), i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
    if i == 0 { return String(format: "%.1f KB/s", v / 1000) }   // keep small rates in KB/s
    return v < 10 ? String(format: "%.1f %@", v, units[i]) : "\(Int(v.rounded())) \(units[i])"
}

func fmtDuration(_ seconds: TimeInterval) -> String {
    let m = Int(seconds) / 60, h = m / 60, d = h / 24
    if d > 0 { return "\(d)d \(h % 24)h" }
    if h > 0 { return "\(h)h \(m % 60)m" }
    if m > 0 { return "\(m)m" }
    return "\(Int(seconds))s"
}

func fmtMinutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
