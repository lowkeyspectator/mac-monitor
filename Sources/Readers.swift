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
    /// The interface macOS currently routes traffic through (Wi-Fi, Ethernet, …).
    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "MacMonitor" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return dict["PrimaryInterface"] as? String
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
        do { try p.run() } catch { return nil }
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
    var pid: Int32, name: String, cpu: Double, memory: UInt64
    var id: Int32 { pid }
}

enum ProcessReader {
    /// Uses `ps`, which (unlike proc_pidinfo) can see every user's processes without root.
    static func snapshot() -> [ProcessEntry] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-Aceo", "pid=,pcpu=,rss=,comm="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        let own = getpid()
        return text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4, let pid = Int32(parts[0]), pid != own,
                  let cpu = Double(parts[1]), let rssKB = UInt64(parts[2]) else { return nil }
            return ProcessEntry(pid: pid, name: String(parts[3]), cpu: cpu / 100, memory: rssKB * 1024)
        }
    }
}

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
    return "\(m)m"
}

func fmtMinutes(_ m: Int) -> String { m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m" }
