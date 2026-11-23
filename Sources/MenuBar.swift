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
    var id: String { metric.rawValue }

    @MainActor static func make(_ metric: Metric, _ m: Monitor) -> LabelItem {
        LabelItem(metric: metric, value: m.value(metric), history: m.history(metric),
                  up: m.network.upRate, down: m.network.downRate)
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

/// Renders the label as a template image so it follows the menu bar's light/dark appearance.
@MainActor
func renderStatusImage(items: [LabelItem], style: MenuStyle) -> NSImage? {
    let renderer = ImageRenderer(content: StatusLabelContent(items: items, style: style))
    renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
    guard let img = renderer.nsImage else { return nil }
    img.isTemplate = true
    return img
}

struct StatusLabelContent: View {
    var items: [LabelItem], style: MenuStyle

    var body: some View {
        HStack(spacing: 7) {
            ForEach(items) { cell($0) }
        }
        .foregroundStyle(.black)
        .frame(height: 22)
        .fixedSize()
    }

    @ViewBuilder private func cell(_ item: LabelItem) -> some View {
        // Every number sits in a fixed-width slot, so the menu bar doesn't shift as digits change.
        let value = FixedSlot(text: pct(item.value), widest: "100%")
        if item.metric == .network {
            // Upload over download, like Stats and iStat Menus; same in every style.
            HStack(spacing: 2) {
                if style == .icon { Image(systemName: "network").font(.system(size: 10, weight: .medium)) }
                VStack(alignment: .trailing, spacing: -2) {
                    FixedSlot(text: "\(fmtRateShort(item.up)) ↑", widest: "888K ↑")
                    FixedSlot(text: "\(fmtRateShort(item.down)) ↓", widest: "888K ↓")
                }
                .font(.system(size: 9, weight: .semibold))
            }
        } else {
            switch style {
            case .percent:
                value.font(.system(size: 12, weight: .medium))
            case .icon:
                HStack(spacing: 3) {
                    Image(systemName: item.metric.symbol).font(.system(size: 11, weight: .medium))
                    value.font(.system(size: 12, weight: .medium))
                }
            case .stacked:
                stacked(item, value)
            case .bars:
                HStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(.black.opacity(0.3))
                        RoundedRectangle(cornerRadius: 1.5).fill(.black)
                            .frame(height: max(1.5, 16 * min(max(item.value, 0), 1)))
                    }
                    .frame(width: 5, height: 16)
                    stacked(item, value)
                }
            case .graph:
                HStack(spacing: 3) {
                    stacked(item, value)
                    if item.metric != .storage {
                        Sparkline(values: item.history, color: .black, lineWidth: 1, capacity: 30)
                            .frame(width: 30, height: 15)
                            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.35), lineWidth: 0.5))
                    }
                }
            }
        }
    }

    private func stacked(_ item: LabelItem, _ value: FixedSlot) -> some View {
        VStack(alignment: .trailing, spacing: -1) {
            Text(item.metric.shortName).font(.system(size: 7.5, weight: .bold))
                .frame(maxWidth: .infinity, alignment: .leading)
            value.font(.system(size: 11, weight: .semibold))
        }
        .fixedSize()
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
                withAnimation(.snappy(duration: 0.25)) { UsagePanel.setAll(!allOpen, prefix: "popover") }
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
