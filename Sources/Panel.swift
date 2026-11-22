import SwiftUI
import AppKit

// MARK: - Metrics

enum Metric: String, CaseIterable, Identifiable {
    case cpu, gpu, memory, storage
    var id: String { rawValue }

    var title: String {
        switch self { case .cpu: "CPU"; case .gpu: "GPU"; case .memory: "Memory"; case .storage: "Storage" }
    }
    var shortName: String {
        switch self { case .cpu: "CPU"; case .gpu: "GPU"; case .memory: "RAM"; case .storage: "SSD" }
    }
    var symbol: String {
        switch self { case .cpu: "cpu"; case .gpu: "square.3.layers.3d"; case .memory: "memorychip"; case .storage: "internaldrive" }
    }
    var tint: Color {
        switch self { case .cpu: .blue; case .gpu: .purple; case .memory: .green; case .storage: .orange }
    }
}

extension Monitor {
    var rootVolume: VolumeInfo? { volumes.first { $0.path == "/" } ?? volumes.first }

    func value(_ k: Metric) -> Double {
        switch k {
        case .cpu: cpuTotal
        case .gpu: gpuUtil
        case .memory: memory.fraction
        case .storage: rootVolume?.fraction ?? 0
        }
    }

    func history(_ k: Metric) -> [Double] {
        switch k {
        case .cpu: cpuHistory
        case .gpu: gpuHistory
        case .memory: memHistory
        case .storage: []
        }
    }

    var pressureName: String {
        switch memory.pressure { case 4...: "Critical"; case 2...: "Warning"; default: "Normal" }
    }
}

func pressureColor(_ p: Int) -> Color { p >= 4 ? .red : p >= 2 ? .yellow : .green }

// MARK: - Panel with expandable cards (used by the menu bar panel and the widget)

struct UsagePanel: View {
    let prefix: String
    var body: some View {
        VStack(spacing: 8) {
            ForEach(Metric.allCases) { MetricCard(metric: $0, prefix: prefix) }
        }
    }

    static func setAll(_ expanded: Bool, prefix: String) {
        for m in Metric.allCases { UserDefaults.standard.set(expanded, forKey: "\(prefix).\(m.rawValue)") }
    }
    static func allExpanded(prefix: String) -> Bool {
        Metric.allCases.allSatisfy { UserDefaults.standard.bool(forKey: "\(prefix).\($0.rawValue)") }
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
                detail.transition(.opacity.combined(with: .move(edge: .top)))
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
                Text(valueText).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
            if metric == .memory {
                MemorySplitBar(mem: m.memory).frame(height: 6)
            } else {
                UsageBar(value: m.value(metric), tint: metric == .storage && m.value(metric) > 0.9 ? .red : metric.tint)
                    .frame(height: 6)
            }
        }
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        switch metric {
        case .cpu: "User \(pct(m.cpuUser)) · System \(pct(m.cpuSystem))"
        case .gpu: m.gpuName + (m.gpuCores > 0 ? " · \(m.gpuCores) cores" : "")
        case .memory: "Pressure \(m.pressureName.lowercased())"
        case .storage: m.rootVolume.map { "\($0.name) · \(pct($0.fraction)) used" } ?? "–"
        }
    }

    private var valueText: String {
        switch metric {
        case .cpu, .gpu: pct(m.value(metric))
        case .memory: "\(fmtBytes(m.memory.used)) / \(fmtBytes(m.memory.total))"
        case .storage: m.rootVolume.map { "\(fmtDisk($0.available)) free" } ?? "–"
        }
    }

    // MARK: detail

    @ViewBuilder private var detail: some View {
        switch metric {
        case .cpu: cpuDetail
        case .gpu: gpuDetail
        case .memory: memoryDetail
        case .storage: storageDetail
        }
    }

    private var cpuDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            Text("CPU and GPU share one pool of memory on Apple Silicon. The GPU figure is what the graphics driver reports as in use.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var storageDetail: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    .animation(.easeOut(duration: 0.35), value: value)
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
            .animation(.easeOut(duration: 0.35), value: mem.used)
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
                    .animation(.easeOut(duration: 0.4), value: value)
                Text(pct(value)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
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
