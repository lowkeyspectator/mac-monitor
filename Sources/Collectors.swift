import Foundation
import Darwin
import IOKit

// Per-process usage for GPU, disk, network and energy. Public APIs and stock command-line tools only.

/// One row in a "top apps" list.
struct UsageRow: Identifiable {
    var pid: Int32, name: String, value: Double, text: String
    var id: Int32 { pid }
}

func processName(_ pid: Int32) -> String? {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
        let path = String(cString: buf)
        // Prefer the app name for processes inside an .app bundle ("Safari" rather than "com.apple.WebKit…").
        if let app = path.components(separatedBy: "/").last(where: { $0.hasSuffix(".app") }),
           !path.contains(".app/Contents/Frameworks/"), !path.contains(".app/Contents/XPCServices/") {
            return String(app.dropLast(4))
        }
        return (path as NSString).lastPathComponent
    }
    var name = [CChar](repeating: 0, count: 256)
    return proc_name(pid, &name, UInt32(name.count)) > 0 ? String(cString: name) : nil
}

// MARK: - GPU time per process (from the graphics driver's user clients)

enum GPUProcessReader {
    /// Accumulated GPU time in nanoseconds per process.
    static func times() -> [Int32: (name: String, ns: UInt64)] {
        var out: [Int32: (String, UInt64)] = [:]
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
        else { return [:] }
        defer { IOObjectRelease(iter) }
        var accel = IOIteratorNext(iter)
        while accel != 0 {
            var children: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(accel, kIOServicePlane, &children) == KERN_SUCCESS {
                var c = IOIteratorNext(children)
                while c != 0 {
                    if let creator = IORegistryEntryCreateCFProperty(c, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? String,
                       let usage = IORegistryEntryCreateCFProperty(c, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                        .takeRetainedValue() as? [[String: Any]],
                       let parsed = parseCreator(creator) {
                        let ns = usage.reduce(UInt64(0)) { $0 + ((($1["accumulatedGPUTime"]) as? NSNumber)?.uint64Value ?? 0) }
                        let prev = out[parsed.pid]?.1 ?? 0
                        out[parsed.pid] = (parsed.name, prev + ns)
                    }
                    IOObjectRelease(c)
                    c = IOIteratorNext(children)
                }
                IOObjectRelease(children)
            }
            IOObjectRelease(accel)
            accel = IOIteratorNext(iter)
        }
        return out.mapValues { (name: $0.0, ns: $0.1) }
    }

    /// "pid 466, WindowServer" → (466, "WindowServer")
    private static func parseCreator(_ s: String) -> (pid: Int32, name: String)? {
        guard s.hasPrefix("pid "), let comma = s.firstIndex(of: ","),
              let pid = Int32(s[s.index(s.startIndex, offsetBy: 4)..<comma]) else { return nil }
        return (pid, s[s.index(after: comma)...].trimmingCharacters(in: .whitespaces))
    }
}

// MARK: - Disk I/O per process

enum DiskProcessReader {
    /// Cumulative bytes read+written per process. Only processes running as the current user are visible.
    static func totals() -> [Int32: (read: UInt64, write: UInt64)] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [:] }
        var pids = [Int32](repeating: 0, count: Int(n) + 64)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        var out: [Int32: (UInt64, UInt64)] = [:]
        for pid in pids.prefix(Int(max(0, count))) where pid > 0 {
            var info = rusage_info_v4()
            let r = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
            }
            if r == 0 { out[pid] = (info.ri_diskio_bytesread, info.ri_diskio_byteswritten) }
        }
        return out.mapValues { (read: $0.0, write: $0.1) }
    }
}

// MARK: - Streaming collectors (nettop, top)

/// Runs a command that prints a block of lines every few seconds and hands each complete block to `onBlock`.
final class StreamCollector: @unchecked Sendable {
    private var process: Process?
    private var pipe: Pipe?
    private var buffer = ""
    private var block: [String] = []
    private let launchPath: String, args: [String]
    private let isHeader: (String) -> Bool
    private let onBlock: @Sendable ([String]) -> Void

    init(_ launchPath: String, _ args: [String], isHeader: @escaping (String) -> Bool,
         onBlock: @escaping @Sendable ([String]) -> Void) {
        self.launchPath = launchPath; self.args = args; self.isHeader = isHeader; self.onBlock = onBlock
    }

    var isRunning: Bool { process?.isRunning == true }

    func start() {
        guard !isRunning else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            self.consume(s)
        }
        do { try p.runHelper(); process = p; self.pipe = pipe } catch { process = nil }
    }

    func stop() {
        pipe?.fileHandleForReading.readabilityHandler = nil   // no more callbacks before clearing state
        process?.terminate()
        process = nil; pipe = nil
        buffer = ""; block = []
    }

    private func consume(_ s: String) {
        buffer += s
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl])
            buffer.removeSubrange(...nl)
            if isHeader(line) {
                if !block.isEmpty { onBlock(block) }
                block = []
            } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
                block.append(line)
            }
        }
    }

    deinit { process?.terminate() }
}

/// Runs a short command over and over on a background thread while started, handing each run's
/// output lines to `onOutput`. Used for `nettop`, which buffers its output when not on a terminal
/// and so can't be streamed.
final class RepeatingCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var generation = 0
    private let launchPath: String, args: [String]
    private let onOutput: @Sendable ([String]) -> Void

    init(_ launchPath: String, _ args: [String], onOutput: @escaping @Sendable ([String]) -> Void) {
        self.launchPath = launchPath; self.args = args; self.onOutput = onOutput
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        generation += 1
        let gen = generation
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.loop(gen) }
    }

    func stop() { lock.lock(); running = false; lock.unlock() }

    private func isCurrent(_ gen: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return running && gen == generation }

    private func loop(_ gen: Int) {
        while isCurrent(gen) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: launchPath)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.runHelper()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if isCurrent(gen), let text = String(data: data, encoding: .utf8) {
                onOutput(text.components(separatedBy: "\n"))
            }
        }
    }
}

enum NetProcessParser {
    /// Lines after the last ",bytes_in,bytes_out," header of a `nettop -d -L 2` run (the delta block).
    static func lastBlock(_ lines: [String]) -> [String] {
        guard let i = lines.lastIndex(where: { $0.hasPrefix(",bytes_in") }) else { return [] }
        return Array(lines[(i + 1)...])
    }

    /// nettop delta lines "name.pid,bytes_in,bytes_out," over `seconds` → per-process rates.
    static func parse(_ lines: [String], seconds: Double) -> [UsageRow] {
        lines.compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let dot = f[0].lastIndex(of: "."),
                  let pid = Int32(f[0][f[0].index(after: dot)...]),
                  let rx = Double(f[1]), let tx = Double(f[2]), (rx + tx) / seconds >= 100 else { return nil }
            let down = rx / seconds, up = tx / seconds
            guard !isOwnHelper(pid) else { return nil }
            let name = processName(pid) ?? String(f[0][..<dot])
            return UsageRow(pid: pid, name: name, value: down + up, text: "↓ \(fmtRate(down))  ↑ \(fmtRate(up))")
        }
        .sorted { $0.value > $1.value }
    }
}

enum EnergyParser {
    /// top rows "PID COMMAND… POWER" → energy impact per process.
    static func parse(_ lines: [String]) -> [UsageRow] {
        var rows: [UsageRow] = []
        var inTable = false
        for line in lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.first == "PID" { inTable = true; continue }
            guard inTable, f.count >= 3, let pid = Int32(f[0]), let power = Double(f[f.count - 1]), power > 0,
                  !isOwnHelper(pid) else { continue }
            let name = processName(pid) ?? f[1..<(f.count - 1)].joined(separator: " ")
            rows.append(UsageRow(pid: pid, name: name, value: power, text: String(format: "%.1f", power)))
        }
        return rows.sorted { $0.value > $1.value }
    }
}
