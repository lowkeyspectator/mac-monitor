import SwiftUI
import AppKit

// MARK: - Metrics

enum Metric: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, storage, network, battery
    var id: String { rawValue }

    /// The four rings on the collapsed desktop widget.
    static let ringMetrics: [Metric] = [.cpu, .gpu, .memory, .storage]
    /// Metrics that can be shown in the menu bar.
    static let menuBarMetrics: [Metric] = [.cpu, .gpu, .memory, .storage, .network, .battery]

    var title: String {
        switch self {
        case .cpu: "CPU"; case .gpu: "GPU"; case .memory: "Memory"
        case .storage: "Storage"; case .network: "Network"; case .battery: "Battery"
        }
    }
    var shortName: String {
        switch self {
        case .cpu: "CPU"; case .gpu: "GPU"; case .memory: "RAM"
        case .storage: "SSD"; case .network: "NET"; case .battery: "BAT"
        }
    }
    var symbol: String {
        switch self {
        case .cpu: "cpu"; case .gpu: "square.3.layers.3d"; case .memory: "memorychip"
        case .storage: "internaldrive"; case .network: "network"; case .battery: "battery.75percent"
        }
    }
    var tint: Color {
        switch self {
        case .cpu: .blue; case .gpu: .purple; case .memory: .green
        case .storage: .orange; case .network: .cyan; case .battery: .mint
        }
    }
}

/// Scales throughput history to 0…1 against its own recent peak (at least `floor` bytes/s).
func normalized(_ values: [Double], floor: Double = 100_000, alongside other: [Double] = []) -> [Double] {
    let peak = max(floor, values.max() ?? 0, other.max() ?? 0)
    return values.map { $0 / peak }
}

extension Monitor {
    var rootVolume: VolumeInfo? { volumes.first { $0.path == "/" } ?? volumes.first }

    /// Cards shown in the panel; Battery only on Macs that have one.
    var panelMetrics: [Metric] { Metric.allCases.filter { $0 != .battery || battery.present } }

    func value(_ k: Metric) -> Double {
        switch k {
        case .cpu: cpuTotal
        case .gpu: gpuUtil
        case .memory: memory.fraction
        case .storage: rootVolume?.fraction ?? 0
        case .network: normalized(netDownHistory, alongside: netUpHistory).last ?? 0
        case .battery: battery.level
        }
    }

    func history(_ k: Metric) -> [Double] {
        switch k {
        case .cpu: cpuHistory
        case .gpu: gpuHistory
        case .memory: memHistory
        case .network: normalized(netDownHistory, alongside: netUpHistory)
        case .storage, .battery: []
        }
    }

    var pressureName: String {
        switch memory.pressure { case 4...: "Critical"; case 2...: "Warning"; default: "Normal" }
    }

    var batteryStatus: String {
        let b = battery
        if b.charging { return "Charging" + (b.minutesToFull.map { " · \(fmtMinutes($0)) to full" } ?? "") }
        if b.onAC { return b.fullyCharged ? "Fully charged" : "On power adapter, not charging" }
        return "On battery" + (b.minutesToEmpty.map { " · \(fmtMinutes($0)) left" } ?? "")
    }
}

func pressureColor(_ p: Int) -> Color { p >= 4 ? .red : p >= 2 ? .yellow : .green }

// MARK: - Panel with expandable cards (used by the menu bar panel and the widget)

struct UsagePanel: View {
    @EnvironmentObject var m: Monitor
    let prefix: String
    var body: some View {
        VStack(spacing: 8) {
            ForEach(m.panelMetrics) { MetricCard(metric: $0, prefix: prefix) }
        }
    }

    static func setAll(_ expanded: Bool, prefix: String) {
        for m in Metric.allCases { UserDefaults.standard.set(expanded, forKey: "\(prefix).\(m.rawValue)") }
    }
}

struct MetricCard: View {
    @EnvironmentObject var m: Monitor
    let metric: Metric
    @AppStorage private var expanded: Bool

    init(metric: Metric, prefix: String) {
        self.metric = metric
        _expanded = AppStorage(wrappedValue: false, "\(prefix).\(metric.rawValue)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.25)) { expanded.toggle() }
            } label: { header }
            .buttonStyle(.plain)
            .accessibilityLabel("\(metric.title), \(valueText). \(expanded ? "Collapse" : "Expand") details")

            if expanded {
                detail
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    // Per-app collection runs only while these details are on screen.
                    .onAppear { m.setDetailVisible(metric, true) }
                    .onDisappear { m.setDetailVisible(metric, false) }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: header

    private var header: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                IconTile(symbol: metric.symbol, tint: metric.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(metric.title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                // The value always shows in full; the subtitle truncates first.
                Group {
                    if [.cpu, .gpu, .battery].contains(metric) {
                        FixedSlot(text: valueText, widest: "100%")
                    } else {
                        Text(valueText).monospacedDigit().lineLimit(1)
                    }
                }
                .font(.system(size: 13, weight: .semibold)).fixedSize()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            switch metric {
            case .memory:
                MemorySplitBar(mem: m.memory).frame(height: 6)
            case .network:
                DualSparkline(a: m.netDownHistory, b: m.netUpHistory, colorA: .cyan, colorB: .orange, capacity: 45)
                    .frame(height: 16)
            default:
                UsageBar(value: m.value(metric), tint: barTint).frame(height: 6)
            }
        }
        .contentShape(Rectangle())
    }

    private var barTint: Color {
        switch metric {
        case .storage where m.value(metric) > 0.9: .red
        case .battery where !m.battery.charging && m.battery.level < 0.2: .red
        default: metric.tint
        }
    }

    private var subtitle: String {
        switch metric {
        case .cpu: "User \(pct(m.cpuUser)) · System \(pct(m.cpuSystem))"
        case .gpu: m.gpuName + (m.gpuCores > 0 ? " · \(m.gpuCores) cores" : "")
        case .memory: "Pressure \(m.pressureName.lowercased())"
        case .storage: "Read \(fmtRate(m.diskReadRate)) · Write \(fmtRate(m.diskWriteRate))"
        case .network: m.network.connected
            ? (["↑ \(fmtRate(m.network.upRate))", m.network.interface, m.network.localIP]
                .filter { !$0.isEmpty }.joined(separator: " · "))
            : "Not connected"
        case .battery: m.batteryStatus
        }
    }

    private var valueText: String {
        switch metric {
        case .cpu, .gpu, .battery: pct(m.value(metric))
        case .memory: "\(fmtBytes(m.memory.used)) / \(fmtBytes(m.memory.total))"
        case .storage: m.rootVolume.map { "\(fmtDisk($0.available)) free" } ?? "–"
        case .network: "↓ \(fmtRate(m.network.downRate))"
        }
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        switch metric {
        case .cpu: cpuDetail
        case .gpu: gpuDetail
        case .memory: memoryDetail
        case .storage: storageDetail
        case .network: networkDetail
        case .battery: batteryDetail
        }
    }

    private var cpuDetail: some View {
        let s = m.system
        return VStack(alignment: .leading, spacing: 8) {
            Sparkline(values: m.cpuHistory, color: metric.tint).frame(height: 40)
            HStack {
                Text("Per core").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(m.coreGroups.map { "\($0.count) \($0.name)" }.joined(separator: " + "))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(m.perCore.indices, id: \.self) { i in
                    CoreCell(index: i, value: m.perCore[i],
                             history: i < m.coreHistory.count ? m.coreHistory[i] : [])
                }
            }
            Divider()
            DetailGrid(rows: [
                ("Load average", String(format: "%.2f  %.2f  %.2f", s.load.0, s.load.1, s.load.2), nil),
                ("Uptime", fmtDuration(s.uptime), nil),
                ("Thermal state", s.thermalName,
                 s.thermal == .nominal ? nil : (s.thermal == .fair ? .yellow : .red)),
            ])
            ProcessList(title: "Top apps by CPU", rows: m.topCPU, note: "% of one core")
        }
    }

    private var gpuDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            Sparkline(values: m.gpuHistory, color: metric.tint).frame(height: 40)
            DetailGrid(rows: [
                ("Renderer", pct(m.gpuRenderer), nil),
                ("Tiler", pct(m.gpuTiler), nil),
                ("Memory in use", fmtBytes(m.memory.gpuInUse), nil),
                ("Memory allocated", fmtBytes(m.memory.gpuAllocated), nil),
            ])
            ProcessList(title: "Top apps by GPU time", rows: m.topGPU, empty: "No app is using the GPU")
        }
    }

    private var memoryDetail: some View {
        let mem = m.memory
        return VStack(alignment: .leading, spacing: 8) {
            Sparkline(values: m.memHistory, color: pressureColor(mem.pressure)).frame(height: 40)
            DetailGrid(rows: [
                ("CPU, apps & system", fmtBytes(mem.cpuSide), .blue),
                ("GPU (in use)", fmtBytes(mem.gpuInUse), .purple),
                ("Free", fmtBytes(mem.total - min(mem.used, mem.total)), .gray.opacity(0.4)),
            ])
            Divider()
            DetailGrid(rows: [
                ("App memory", fmtBytes(mem.app), nil),
                ("Wired", fmtBytes(mem.wired), nil),
                ("Compressed", fmtBytes(mem.compressed), nil),
                ("Cached files", fmtBytes(mem.cached), nil),
                ("Swap used", mem.swapUsed == 0 ? "None" : fmtBytes(mem.swapUsed), nil),
                ("Pressure", m.pressureName, pressureColor(mem.pressure)),
            ])
            ProcessList(title: "Top apps by memory", rows: m.topMemory)
            Text("CPU and GPU share one pool of memory on Apple Silicon. The GPU figure is what the graphics driver reports as in use.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var storageDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
            DualSparkline(a: m.diskReadHistory, b: m.diskWriteHistory, colorA: .orange, colorB: .pink)
                .frame(height: 40)
            DetailGrid(rows: [
                ("Read", fmtRate(m.diskReadRate), .orange),
                ("Write", fmtRate(m.diskWriteRate), .pink),
            ])
            ProcessList(title: "Top apps by disk activity", rows: m.topDisk, empty: "No disk activity from your apps",
                        note: "your apps only")
            Divider()
            ForEach(m.volumes) { v in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(v.name).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        Text("\(fmtDisk(v.available)) free of \(fmtDisk(v.total))")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                    UsageBar(value: v.fraction, tint: v.fraction > 0.9 ? .red : metric.tint).frame(height: 5)
                }
            }
        }
    }

    private var networkDetail: some View {
        let n = m.network
        return VStack(alignment: .leading, spacing: 8) {
            DualSparkline(a: m.netDownHistory, b: m.netUpHistory, colorA: .cyan, colorB: .orange)
                .frame(height: 40)
            DetailGrid(rows: [
                ("Download", fmtRate(n.downRate), .cyan),
                ("Upload", fmtRate(n.upRate), .orange),
            ])
            Divider()
            DetailGrid(rows: [
                ("Interface", n.connected ? n.interface : "Not connected", nil),
                ("Local IP", n.localIP.isEmpty ? "–" : n.localIP, nil),
                ("Downloaded since boot", fmtDisk(n.totalDown), nil),
                ("Uploaded since boot", fmtDisk(n.totalUp), nil),
            ])
            ProcessList(title: "Top apps by network", rows: m.topNetwork, empty: "No network activity",
                        note: "2-second average")
        }
    }

    private var batteryDetail: some View {
        let b = m.battery
        var rows: [(String, String, Color?)] = [
            ("Level", pct(b.level), nil),
            ("Status", m.batteryStatus, nil),
        ]
        if let c = b.cycleCount { rows.append(("Cycle count", "\(c)", nil)) }
        if let h = b.health { rows.append(("Maximum capacity", pct(h), h < 0.8 ? .orange : nil)) }
        if let c = b.condition { rows.append(("Condition", c, c == "Good" ? nil : .orange)) }
        if let t = b.temperature { rows.append(("Temperature", String(format: "%.1f °C", t), nil)) }
        if let w = b.adapterWatts { rows.append(("Power adapter", "\(w) W", nil)) }
        return VStack(alignment: .leading, spacing: 8) {
            if let mode = m.energyMode {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Energy mode").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Picker("Energy mode", selection: Binding(get: { mode }, set: { m.setEnergyMode($0) })) {
                        ForEach(EnergyMode.allCases.filter { $0 != .high || EnergyModeControl.supportsHighPower }) {
                            Text($0.title).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    Text(m.energyModeError ?? "Applies on battery and on power adapter. Changing it asks for your administrator password.")
                        .font(.caption2)
                        .foregroundStyle(m.energyModeError == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.orange))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
            }
            DetailGrid(rows: rows)
            ProcessList(title: "Top apps by energy impact", rows: m.topEnergy, note: "same scale as Activity Monitor")
        }
    }
}

/// Top-N app list with a right-aligned value, like Activity Monitor's columns.
struct ProcessList: View {
    var title: String, rows: [UsageRow]
    var empty: String = "Measuring…"
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let note { Text(note).font(.caption2).foregroundStyle(.tertiary) }
            }
            if rows.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundStyle(.tertiary)
            }
            ForEach(rows) { r in
                HStack(spacing: 6) {
                    AppIcon(pid: r.pid)
                    Text(r.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text(r.text).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                .font(.system(size: 12))
                .help("\(r.name) (PID \(r.pid))")
            }
        }
    }
}

/// The app's own icon when the process belongs to an app, otherwise a generic one — as in Activity Monitor.
struct AppIcon: View {
    var pid: Int32
    var body: some View {
        Image(nsImage: AppIconCache.icon(for: pid))
            .resizable().interpolation(.high)
            .frame(width: 14, height: 14)
    }
}

@MainActor
enum AppIconCache {
    private static var cache: [Int32: NSImage] = [:]
    private static let generic: NSImage = {
        NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
    }()
    static func icon(for pid: Int32) -> NSImage {
        if let i = cache[pid] { return i }
        var img = generic
        if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon {
            img = icon
        } else {
            var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
                let path = String(cString: buf)
                if let r = path.range(of: ".app/") {
                    img = NSWorkspace.shared.icon(forFile: String(path[..<r.lowerBound]) + ".app")
                } else {
                    img = NSWorkspace.shared.icon(forFile: path)
                }
            }
        }
        if cache.count > 300 { cache.removeAll() }
        cache[pid] = img
        return img
    }
}

/// Two throughput series on one scale (e.g. download vs upload).
struct DualSparkline: View {
    var a: [Double], b: [Double], colorA: Color, colorB: Color, capacity: Int = Monitor.historyLength
    var body: some View {
        ZStack {
            Sparkline(values: normalized(a, alongside: b), color: colorA, capacity: capacity)
            Sparkline(values: normalized(b, alongside: a), color: colorB, fill: false, capacity: capacity)
        }
    }
}

// MARK: - Building blocks

struct IconTile: View {
    var symbol: String, tint: Color, size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
    }
}

struct UsageBar: View {
    var value: Double, tint: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint.gradient)
                    .frame(width: max(g.size.height, g.size.width * min(max(value, 0), 1)))
            }
        }
    }
}

struct MemorySplitBar: View {
    var mem: MemoryInfo
    var body: some View {
        GeometryReader { g in
            let t = Double(max(mem.total, 1))
            HStack(spacing: 1) {
                Rectangle().fill(Color.blue.gradient).frame(width: g.size.width * Double(mem.cpuSide) / t)
                Rectangle().fill(Color.purple.gradient).frame(width: g.size.width * Double(min(mem.gpuInUse, mem.used)) / t)
                Rectangle().fill(.quaternary)
            }
            .clipShape(Capsule())
        }
    }
}

struct DetailGrid: View {
    var rows: [(String, String, Color?)]
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows.indices, id: \.self) { i in
                GridRow {
                    HStack(spacing: 6) {
                        if let c = rows[i].2 { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 8, height: 8) }
                        Text(rows[i].0).foregroundStyle(.secondary)
                    }
                    Text(rows[i].1).monospacedDigit().gridColumnAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .font(.system(size: 12))
    }
}

struct CoreCell: View {
    var index: Int, value: Double, history: [Double]
    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                Rectangle().fill(Color.blue.opacity(0.08))
                Sparkline(values: history, color: .blue)
            }
            .frame(height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            HStack(spacing: 0) {
                Text("\(index + 1)").foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(pct(value)).monospacedDigit()
            }
            .font(.system(size: 9))
        }
        .help("Core \(index + 1): \(pct(value))")
    }
}

struct Sparkline: View {
    var values: [Double], color: Color, fill: Bool = true, lineWidth: CGFloat = 1.5
    var capacity: Int = Monitor.historyLength
    var body: some View {
        GeometryReader { g in
            let step = g.size.width / CGFloat(max(capacity - 1, 1))
            let shown = values.suffix(capacity)
            let offset = CGFloat(capacity - shown.count) * step
            let pts = shown.enumerated().map { i, v in
                CGPoint(x: offset + CGFloat(i) * step, y: g.size.height * (1 - CGFloat(min(max(v, 0), 1))))
            }
            ZStack {
                if fill, let first = pts.first, let last = pts.last {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: last.x, y: g.size.height))
                    }.fill(color.opacity(0.22))
                }
                Path { p in p.addLines(pts) }
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineJoin: .round))
            }
        }
    }
}

struct Ring: View {
    var value: Double, label: String, detail: String, color: Color, size: CGFloat = 60
    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 7)
                Circle().trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(color.gradient, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                FixedSlot(text: pct(value), widest: "100%", alignment: .center)
                    .font(.system(size: 13, weight: .semibold))
            }
            .frame(width: size, height: size)
            Text(label).font(.system(size: 11, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .frame(width: size + 14)
    }
}

/// A ScrollView that is only as tall as its content, up to `maxHeight`.
struct FitScrollView<Content: View>: View {
    var maxHeight: CGFloat
    var content: Content
    @StateObject private var height: Box<CGFloat>

    init(maxHeight: CGFloat, @ViewBuilder content: () -> Content) {
        self.maxHeight = maxHeight
        self.content = content()
        _height = StateObject(wrappedValue: Box<CGFloat>(0))
    }

    var body: some View {
        ScrollView(.vertical) {
            content.background(GeometryReader { g in
                Color.clear.preference(key: HeightKey.self, value: g.size.height)
            })
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height.value, 1), maxHeight))
        .onPreferenceChange(HeightKey.self) { h in if height.value != h { height.value = h } }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

var screenMaxHeight: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) - 140 }

func openActivityMonitor() {
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                       configuration: .init())
}

/// Minimal view-local state holder. Used instead of @State, whose macro plugin
/// ships only with full Xcode and not with the Command Line Tools.
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ value: T) { self.value = value }
}
