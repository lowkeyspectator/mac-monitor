import SwiftUI
import AppKit

// MARK: - Menu bar label

enum MenuStyle: String, CaseIterable, Identifiable {
    case percent, icon, stacked, bars, graph
    var id: String { rawValue }
    var title: String {
        switch self {
        case .percent: "Percentage only"
        case .icon: "Icon and percentage"
        case .stacked: "Label and percentage"
        case .bars: "Mini bars"
        case .graph: "Mini graphs"
        }
    }
}

struct LabelItem: Identifiable {
    var metric: Metric, value: Double, history: [Double]
    var up: Double = 0, down: Double = 0          // network only, bytes/s
    var symbol: String = ""
    var id: String { metric.rawValue }

    @MainActor static func make(_ metric: Metric, _ m: Monitor) -> LabelItem {
        LabelItem(metric: metric, value: m.value(metric), history: m.history(metric),
                  up: m.network.upRate, down: m.network.downRate, symbol: m.symbol(metric))
    }
}

/// Compact rate for the menu bar: "1.2M", "340K", "0K".
func fmtRateShort(_ bps: Double) -> String {
    switch bps {
    case 1_000_000_000...: String(format: "%.1fG", bps / 1e9)
    case 10_000_000...: "\(Int(bps / 1e6))M"
    case 1_000_000...: String(format: "%.1fM", bps / 1e6)
    default: "\(Int(bps / 1e3))K"
    }
}

struct StatusLabel: View {
    @ObservedObject var m: Monitor
    @Environment(\.openSettings) private var openSettings
    @AppStorage("mb.cpu") private var cpu = true
    @AppStorage("mb.gpu") private var gpu = true
    @AppStorage("mb.memory") private var memory = true
    @AppStorage("mb.storage") private var storage = true
    @AppStorage("mb.network") private var network = true
    @AppStorage("mb.battery") private var batteryOn = true
    @AppStorage("mb.style") private var style = MenuStyle.icon.rawValue

    var body: some View {
        let on: [Metric: Bool] = [.cpu: cpu, .gpu: gpu, .memory: memory, .storage: storage,
                                  .network: network, .battery: batteryOn]
        let items = Metric.menuBarMetrics.filter { on[$0] == true && ($0 != .battery || m.battery.present) }
            .map { LabelItem.make($0, m) }
        Group {
            if items.isEmpty {
                Image(systemName: "gauge.with.dots.needle.50percent")
            } else if let img = renderStatusImage(items: items, style: MenuStyle(rawValue: style) ?? .icon) {
                Image(nsImage: img)
            } else {
                Text(items.map { "\($0.metric.shortName) \(pct($0.value))" }.joined(separator: " "))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showMacMonitorSettings)) { _ in
            NSApp.activate()
            openSettings()
        }
    }
}

/// Draws the menu bar label as a template image (so it follows the menu bar's light/dark appearance)
/// with plain AppKit drawing on the CPU. SwiftUI's ImageRenderer kept ~200 MB of GPU memory alive.
@MainActor
func renderStatusImage(items: [LabelItem], style: MenuStyle) -> NSImage? {
    StatusLabelDrawer(items: items, style: style).image()
}

@MainActor
private struct StatusLabelDrawer {
    var items: [LabelItem], style: MenuStyle

    private let height: CGFloat = 22
    private let gap: CGFloat = 7
    private let big = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
    private let value = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    private let tiny = NSFont.systemFont(ofSize: 7.5, weight: .bold)
    private let rate = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)

    private func size(_ s: String, _ f: NSFont) -> CGSize { (s as NSString).size(withAttributes: [.font: f]) }
    private func draw(_ s: String, _ f: NSFont, rightAlignedIn r: CGRect) {
        let w = size(s, f).width
        (s as NSString).draw(at: CGPoint(x: r.maxX - w, y: r.minY), withAttributes: [.font: f, .foregroundColor: NSColor.black])
    }
    private func draw(_ s: String, _ f: NSFont, at p: CGPoint) {
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: NSColor.black])
    }
    private func symbol(_ name: String, _ pt: CGFloat) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: pt, weight: .medium))
    }

    // Widths of each part; every number reserves the width of its widest value ("100%", "888K ↑").
    // Fonts never change, so these are measured once rather than on every redraw.
    private static let widths: (pctBig: CGFloat, pctSmall: CGFloat, stack: CGFloat, rate: CGFloat) = {
        func w(_ s: String, _ f: NSFont) -> CGFloat { (s as NSString).size(withAttributes: [.font: f]).width }
        let big = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let value = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let tiny = NSFont.systemFont(ofSize: 7.5, weight: .bold)
        let rate = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        return (w("100%", big), w("100%", value),
                max(w("RAM", tiny), w("100%", value)), max(w("888K ↑", rate), w("888K ↓", rate)))
    }()
    private var pctSlot: CGFloat { style == .percent || style == .icon ? Self.widths.pctBig : Self.widths.pctSmall }
    private var stackWidth: CGFloat { Self.widths.stack }
    private var rateSlot: CGFloat { Self.widths.rate }

    private func width(_ item: LabelItem) -> CGFloat {
        if item.metric == .network {
            return (style == .icon ? (symbol("network", 10)?.size.width ?? 0) + 2 : 0) + rateSlot
        }
        switch style {
        case .percent: return pctSlot
        case .icon: return (symbol(item.symbol, 11)?.size.width ?? 0) + 3 + pctSlot
        case .stacked: return stackWidth
        case .bars: return 5 + 3 + stackWidth
        case .graph: return stackWidth + (item.metric == .storage || item.metric == .battery ? 0 : 3 + 30)
        }
    }

    func image() -> NSImage? {
        guard !items.isEmpty else { return nil }
        let widths = items.map(width)
        let total = ceil(widths.reduce(0, +) + gap * CGFloat(items.count - 1))
        let img = NSImage(size: NSSize(width: total, height: height), flipped: true) { _ in
            var x: CGFloat = 0
            for (item, w) in zip(items, widths) {
                drawItem(item, in: CGRect(x: x, y: 0, width: w, height: height))
                x += w + gap
            }
            return true
        }
        img.isTemplate = true
        return img
    }

    private func drawItem(_ item: LabelItem, in r: CGRect) {
        let percent = pct(item.value)
        if item.metric == .network {
            var x = r.minX
            if style == .icon, let s = symbol("network", 10) {
                s.draw(in: CGRect(x: x, y: (height - s.size.height) / 2, width: s.size.width, height: s.size.height))
                x += s.size.width + 2
            }
            let slot = CGRect(x: x, y: 0, width: rateSlot, height: height)
            draw("\(fmtRateShort(item.up)) ↑", rate, rightAlignedIn: slot.offsetBy(dx: 0, dy: 0.5))
            draw("\(fmtRateShort(item.down)) ↓", rate, rightAlignedIn: slot.offsetBy(dx: 0, dy: 10))
            return
        }
        switch style {
        case .percent:
            draw(percent, big, rightAlignedIn: r.offsetBy(dx: 0, dy: 3.5))
        case .icon:
            if let s = symbol(item.symbol, 11) {
                s.draw(in: CGRect(x: r.minX, y: (height - s.size.height) / 2, width: s.size.width, height: s.size.height))
            }
            draw(percent, big, rightAlignedIn: CGRect(x: r.maxX - pctSlot, y: 3.5, width: pctSlot, height: height))
        case .stacked:
            stacked(item, percent, CGRect(x: r.minX, y: 0, width: stackWidth, height: height))
        case .bars:
            let bar = CGRect(x: r.minX, y: 3, width: 5, height: 16)
            NSColor.black.withAlphaComponent(0.3).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            let h = max(1.5, 16 * min(max(item.value, 0), 1))
            NSColor.black.setFill()
            NSBezierPath(roundedRect: CGRect(x: bar.minX, y: bar.maxY - h, width: 5, height: h), xRadius: 1.5, yRadius: 1.5).fill()
            stacked(item, percent, CGRect(x: r.minX + 8, y: 0, width: stackWidth, height: height))
        case .graph:
            stacked(item, percent, CGRect(x: r.minX, y: 0, width: stackWidth, height: height))
            if item.metric != .storage && item.metric != .battery {
                sparkline(item.history.suffix(30), CGRect(x: r.minX + stackWidth + 3, y: 3.5, width: 30, height: 15))
            }
        }
    }

    private func stacked(_ item: LabelItem, _ percent: String, _ r: CGRect) {
        draw(item.metric.shortName, tiny, at: CGPoint(x: r.minX, y: 1))
        draw(percent, value, rightAlignedIn: CGRect(x: r.minX, y: 8, width: r.width, height: 13))
    }

    private func sparkline(_ values: ArraySlice<Double>, _ r: CGRect) {
        NSColor.black.withAlphaComponent(0.35).setStroke()
        let frame = NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2); frame.lineWidth = 0.5; frame.stroke()
        guard values.count > 1 else { return }
        let step = r.width / 29
        let x0 = r.maxX - CGFloat(values.count - 1) * step
        let pts = values.enumerated().map { i, v in
            CGPoint(x: x0 + CGFloat(i) * step, y: r.maxY - r.height * CGFloat(min(max(v, 0), 1)))
        }
        let fill = NSBezierPath(); fill.move(to: CGPoint(x: pts[0].x, y: r.maxY))
        pts.forEach { fill.line(to: $0) }; fill.line(to: CGPoint(x: pts.last!.x, y: r.maxY)); fill.close()
        NSColor.black.withAlphaComponent(0.25).setFill(); fill.fill()
        let line = NSBezierPath(); line.move(to: pts[0]); pts.dropFirst().forEach { line.line(to: $0) }
        line.lineWidth = 1; NSColor.black.setStroke(); line.stroke()
    }
}

/// Text that always takes the width of `widest`, right-aligned, with fixed-width digits —
/// so values like 9% → 10% → 100% don't make the layout jump.
struct FixedSlot: View {
    var text: String, widest: String
    var alignment: Alignment = .trailing
    var body: some View {
        ZStack(alignment: alignment) {
            Text(widest).hidden()
            Text(text)
        }
        .monospacedDigit()
        .lineLimit(1)
    }
}

// MARK: - Panel shown when the menu bar item is clicked

struct MenuPanel: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("showWidget") private var showWidget = false
    // Observed so the expand/collapse-all icon updates as soon as a card changes.
    @AppStorage("popover.cpu") private var cpuOpen = false
    @AppStorage("popover.gpu") private var gpuOpen = false
    @AppStorage("popover.memory") private var memoryOpen = false
    @AppStorage("popover.storage") private var storageOpen = false
    @AppStorage("popover.network") private var networkOpen = false
    @AppStorage("popover.battery") private var batteryOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
            FitScrollView(maxHeight: screenMaxHeight - 110) {
                UsagePanel(prefix: "popover").padding(.horizontal, 10)
            }
            Divider().padding(.top, 10)
            footer.padding(.horizontal, 8).padding(.vertical, 6)
        }
        .frame(width: 340)
    }

    private var header: some View {
        let open: [Metric: Bool] = [.cpu: cpuOpen, .gpu: gpuOpen, .memory: memoryOpen,
                                    .storage: storageOpen, .network: networkOpen, .battery: batteryOpen]
        let allOpen = m.panelMetrics.allSatisfy { open[$0] == true }
        return HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac Monitor").font(.system(size: 13, weight: .semibold))
                Text("\(m.cpuName) · \(fmtBytes(m.memory.total))")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(motion(.snappy(duration: 0.25))) { UsagePanel.setAll(!allOpen, prefix: "popover") }
            } label: {
                Image(systemName: allOpen ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
            }
            .buttonStyle(.borderless)
            .help(allOpen ? "Collapse all" : "Show all details")
            .accessibilityLabel(allOpen ? "Collapse all" : "Show all details")
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: showWidget ? "Hide Widget" : "Show Widget", symbol: "widget.small") {
                if showWidget { dismissWindow(id: "widget") } else { openWindow(id: "widget") }
            }
            FooterButton(title: "Activity Monitor", symbol: "waveform.path.ecg") { openActivityMonitor() }
            Spacer()
            FooterButton(title: nil, symbol: "gearshape") {
                NSApp.activate()
                openSettings()
            }
            .help("Settings…")
            .accessibilityLabel("Settings")
            FooterButton(title: nil, symbol: "power") { NSApp.terminate(nil) }
                .help("Quit Mac Monitor")
                .accessibilityLabel("Quit Mac Monitor")
        }
    }
}

struct FooterButton: View {
    var title: String?, symbol: String, action: () -> Void
    @StateObject private var hover: Box<Bool>

    init(title: String?, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
        _hover = StateObject(wrappedValue: Box(false))
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                if let title { Text(title) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(hover.value ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
    }
}
