import SwiftUI
import AppKit

@main
struct MacMonitorApp: App {
    @StateObject private var monitor = Monitor()

    var body: some Scene {
        Window("Mac Monitor", id: "main") {
            RootView().environmentObject(monitor)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        MenuBarExtra {
            MenuBarMenu().environmentObject(monitor)
        } label: {
            Text("CPU \(pct(monitor.cpuTotal)) · GPU \(pct(monitor.gpuUtil))").monospacedDigit()
        }
    }
}

struct MenuBarMenu: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage("compact") private var compact = true

    var body: some View {
        Text("CPU \(pct(m.cpuTotal))   GPU \(pct(m.gpuUtil))")
        Text("RAM \(fmtBytes(m.memory.used)) / \(fmtBytes(m.memory.total))")
        Divider()
        Button("Show Widget") { compact = true; show() }
        Button("Show Detailed View") { compact = false; show() }
        Divider()
        Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
    private func show() { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
}

// MARK: - Root

struct RootView: View {
    @AppStorage("compact") private var compact = true
    @AppStorage("pinned") private var pinned = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Spacer()
                Button { pinned.toggle() } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                }.help(pinned ? "Unpin (stop floating above other windows)" : "Keep on top")
                Button { withAnimation(.snappy) { compact.toggle() } } label: {
                    Image(systemName: compact ? "rectangle.expand.vertical" : "rectangle.compress.vertical")
                }.help(compact ? "Detailed view" : "Widget view")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.top, 8)

            if compact { CompactView() } else { DetailView() }
        }
        .background(.regularMaterial)
        .background(WindowConfigurator(floating: pinned))
    }
}

/// Makes the window float / be draggable by its background.
struct WindowConfigurator: NSViewRepresentable {
    var floating: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.level = floating ? .floating : .normal
            w.isMovableByWindowBackground = true
            w.collectionBehavior.insert(.canJoinAllSpaces)
        }
    }
}

// MARK: - Widget (compact) view

struct CompactView: View {
    @EnvironmentObject var m: Monitor
    var body: some View {
        let disk = m.volumes.first { $0.path == "/" } ?? m.volumes.first
        VStack(spacing: 10) {
            HStack(spacing: 18) {
                Ring(value: m.cpuTotal, label: "CPU", detail: pct(m.cpuTotal), color: .blue)
                Ring(value: m.gpuUtil, label: "GPU", detail: pct(m.gpuUtil), color: .purple)
                Ring(value: m.memory.fraction, label: "RAM", detail: fmtBytes(m.memory.used), color: pressureColor(m.memory.pressure))
                Ring(value: disk?.fraction ?? 0, label: "Disk", detail: disk.map { fmtDisk($0.available) + " free" } ?? "–", color: .orange)
            }
            MemorySplitBar(mem: m.memory).frame(height: 8)
            HStack {
                Legend(color: .blue, text: "CPU/apps \(fmtBytes(m.memory.cpuSide))")
                Spacer()
                Legend(color: .purple, text: "GPU \(fmtBytes(m.memory.gpuInUse))")
                Spacer()
                Legend(color: .gray.opacity(0.35), text: "free \(fmtBytes(m.memory.total - min(m.memory.used, m.memory.total)))")
            }.font(.caption2)
        }
        .padding(.horizontal, 16).padding(.bottom, 14).padding(.top, 2)
        .frame(width: 400)
    }
}

struct Ring: View {
    var value: Double, label: String, detail: String, color: Color
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 7)
                Circle().trim(from: 0, to: max(0.001, min(1, value)))
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.4), value: value)
                Text(pct(value)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            }.frame(width: 64, height: 64)
            Text(label).font(.caption.bold())
            Text(detail).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }.frame(width: 76)
    }
}

struct Legend: View {
    var color: Color, text: String
    var body: some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8); Text(text).monospacedDigit() }
    }
}

struct MemorySplitBar: View {
    var mem: MemoryInfo
    var body: some View {
        GeometryReader { g in
            let t = Double(max(mem.total, 1))
            HStack(spacing: 0) {
                Rectangle().fill(.blue).frame(width: g.size.width * Double(mem.cpuSide) / t)
                Rectangle().fill(.purple).frame(width: g.size.width * Double(min(mem.gpuInUse, mem.used)) / t)
                Rectangle().fill(.gray.opacity(0.25))
            }.clipShape(Capsule())
        }
    }
}

func pressureColor(_ p: Int) -> Color { p >= 4 ? .red : p >= 2 ? .yellow : .green }

// MARK: - Detailed view

struct DetailView: View {
    @EnvironmentObject var m: Monitor
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                cpuSection
                gpuSection
                memorySection
                storageSection
            }.padding(16)
        }
        .frame(width: 560, height: 720)
    }

    var cpuSection: some View {
        Card(title: "CPU", subtitle: m.cpuName + " · " + m.coreGroups.map { "\($0.count) \($0.name)" }.joined(separator: " + ")) {
            HStack(alignment: .firstTextBaseline) {
                Text(pct(m.cpuTotal)).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                Text("user \(pct(m.cpuUser)) · system \(pct(m.cpuSystem))").foregroundStyle(.secondary).monospacedDigit()
            }
            Sparkline(values: m.cpuHistory, color: .blue).frame(height: 50)
            Text("Per core").font(.caption.bold()).foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                ForEach(m.perCore.indices, id: \.self) { i in
                    CoreCell(index: i, value: m.perCore[i], history: i < m.coreHistory.count ? m.coreHistory[i] : [])
                }
            }
        }
    }

    var gpuSection: some View {
        Card(title: "GPU", subtitle: m.gpuName + (m.gpuCores > 0 ? " · \(m.gpuCores) cores" : "")) {
            HStack(alignment: .firstTextBaseline) {
                Text(pct(m.gpuUtil)).font(.system(size: 28, weight: .semibold)).monospacedDigit()
                Text("renderer \(pct(m.gpuRenderer)) · tiler \(pct(m.gpuTiler))").foregroundStyle(.secondary).monospacedDigit()
            }
            Sparkline(values: m.gpuHistory, color: .purple).frame(height: 50)
        }
    }

    var memorySection: some View {
        let mem = m.memory
        return Card(title: "Memory", subtitle: "\(fmtBytes(mem.used)) of \(fmtBytes(mem.total)) used · pressure \(["", "normal", "warning", "", "critical"][min(mem.pressure, 4)])") {
            Sparkline(values: m.memHistory, color: pressureColor(mem.pressure)).frame(height: 40)
            Text("Split by consumer (unified memory)").font(.caption.bold()).foregroundStyle(.secondary)
            MemorySplitBar(mem: mem).frame(height: 10)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row("CPU / apps / system", fmtBytes(mem.cpuSide), .blue)
                row("GPU (in use by driver)", fmtBytes(mem.gpuInUse), .purple)
                row("GPU (allocated)", fmtBytes(mem.gpuAllocated), .purple.opacity(0.5))
                Divider().gridCellColumns(2)
                row("App memory", fmtBytes(mem.app), nil)
                row("Wired", fmtBytes(mem.wired), nil)
                row("Compressed", fmtBytes(mem.compressed), nil)
                row("Cached files", fmtBytes(mem.cached), nil)
                row("Free", fmtBytes(mem.free), nil)
                row("Swap used", "\(fmtBytes(mem.swapUsed)) / \(fmtBytes(mem.swapTotal))", nil)
            }.font(.callout)
            Text("Apple Silicon shares one RAM pool between CPU and GPU. The GPU figure is what the graphics driver reports; it is already included in Wired/App memory, so the CPU figure is the remainder.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder func row(_ k: String, _ v: String, _ c: Color?) -> some View {
        GridRow {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(c ?? .clear).frame(width: 8, height: 8)
                Text(k)
            }
            Text(v).monospacedDigit().gridColumnAlignment(.trailing)
        }
    }

    var storageSection: some View {
        Card(title: "Storage", subtitle: "\(m.volumes.count) volume\(m.volumes.count == 1 ? "" : "s")") {
            ForEach(m.volumes) { v in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(v.name).bold()
                        Spacer()
                        Text("\(fmtDisk(v.used)) used · \(fmtDisk(v.available)) free of \(fmtDisk(v.total))")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }.font(.callout)
                    ProgressView(value: v.fraction).tint(v.fraction > 0.9 ? .red : .orange)
                }
            }
        }
    }
}

struct Card<Content: View>: View {
    var title: String, subtitle: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.opacity(0.6)))
    }
}

struct CoreCell: View {
    var index: Int, value: Double, history: [Double]
    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4).fill(Color.blue.opacity(0.1))
                Sparkline(values: history, color: .blue, fill: true)
            }
            .frame(height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack {
                Text("\(index + 1)").foregroundStyle(.secondary)
                Spacer()
                Text(pct(value)).monospacedDigit()
            }.font(.caption2)
        }
    }
}

struct Sparkline: View {
    var values: [Double], color: Color, fill: Bool = true
    var body: some View {
        GeometryReader { g in
            let n = Monitor.historyLength
            let step = g.size.width / CGFloat(max(n - 1, 1))
            let offset = CGFloat(n - values.count) * step
            let pts = values.enumerated().map { i, v in
                CGPoint(x: offset + CGFloat(i) * step, y: g.size.height * (1 - CGFloat(min(max(v, 0), 1))))
            }
            ZStack {
                if fill, let first = pts.first, let last = pts.last {
                    Path { p in
                        p.move(to: CGPoint(x: first.x, y: g.size.height))
                        pts.forEach { p.addLine(to: $0) }
                        p.addLine(to: CGPoint(x: last.x, y: g.size.height))
                    }.fill(color.opacity(0.25))
                }
                Path { p in p.addLines(pts) }.stroke(color, lineWidth: 1.5)
            }
        }
    }
}
