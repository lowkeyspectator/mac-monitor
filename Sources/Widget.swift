import SwiftUI
import AppKit

enum WidgetLevel: String, CaseIterable, Identifiable {
    case desktop, normal, floating
    var id: String { rawValue }
    var title: String {
        switch self {
        case .desktop: "On the desktop (behind windows)"
        case .normal: "With other windows"
        case .floating: "Always on top"
        }
    }
    var nsLevel: NSWindow.Level {
        switch self {
        case .desktop: NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case .normal: .normal
        case .floating: .floating
        }
    }
}

/// Desktop widget: rings when collapsed, the full expandable panel when expanded.
struct WidgetView: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("widget.expanded") private var expanded = false
    @AppStorage("widget.level") private var level = WidgetLevel.desktop.rawValue
    @AppStorage("showWidget") private var showWidget = false
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openSettings) private var openSettings
    @StateObject private var hovering = Box(false)

    var body: some View {
        VStack(spacing: 0) {
            if expanded {
                HStack {
                    Text("Mac Monitor").font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 8)
                FitScrollView(maxHeight: screenMaxHeight - 60) {
                    UsagePanel(prefix: "widget").padding(.horizontal, 10).padding(.bottom, 10)
                }
            } else {
                compact.padding(.vertical, 16)
            }
        }
        .frame(width: 340)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            controls.padding(10).opacity(hovering.value ? 1 : 0)
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering.value = h } }
        // Dragging anywhere on the widget moves it — handled by WindowConfigurator.
        .background(WindowConfigurator(level: WidgetLevel(rawValue: level) ?? .desktop))
        // showWidget is cleared by WindowConfigurator when the window actually closes,
        // not in onDisappear, so quitting the app with the widget open keeps it open next launch.
        .onAppear { showWidget = true }
    }

    private var compact: some View {
        HStack(spacing: 4) {
            ForEach(Metric.allCases) { metric in
                Ring(value: m.value(metric), label: metric.title, detail: compactDetail(metric), color: metric.tint)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !WidgetDrag.justDragged else { return }
                        UserDefaults.standard.set(true, forKey: "widget.\(metric.rawValue)")
                        withAnimation(.snappy(duration: 0.3)) { expanded = true }
                    }
                    .help("Show \(metric.title) details")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func compactDetail(_ metric: Metric) -> String {
        switch metric {
        case .cpu: "\(m.perCore.count) cores"
        case .gpu: m.gpuCores > 0 ? "\(m.gpuCores) cores" : "GPU"
        case .memory: fmtBytes(m.memory.used)
        case .storage: m.rootVolume.map { "\(fmtDisk($0.available)) free" } ?? "–"
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            CircleButton(symbol: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                         help: expanded ? "Collapse" : "Expand") {
                withAnimation(.snappy(duration: 0.3)) { expanded.toggle() }
            }
            CircleButton(symbol: "gearshape", help: "Settings…") {
                NSApp.activate()
                openSettings()
            }
            CircleButton(symbol: "xmark", help: "Close widget") { dismissWindow(id: "widget") }
        }
    }
}

struct CircleButton: View {
    var symbol: String, help: String, action: () -> Void
    var body: some View {
        Button {
            if !WidgetDrag.justDragged { action() }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .frame(width: 20, height: 20)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Remembers when a drag of the widget ended, so the mouse-up that finishes a drag
/// isn't also treated as a click on a ring or button.
enum WidgetDrag {
    nonisolated(unsafe) static var lastEnd = Date.distantPast
    static var justDragged: Bool { Date().timeIntervalSince(lastEnd) < 0.3 }
}

/// Makes the hosting window transparent, sets its level and lets the user drag it from anywhere.
/// Settings are applied only when the window or level changes, not on every data refresh.
struct WindowConfigurator: NSViewRepresentable {
    var level: WidgetLevel

    final class Coordinator {
        weak var window: NSWindow?
        var level: WidgetLevel?
        var closeObserver: NSObjectProtocol?
        var dragMonitor: Any?
        var downMouse: NSPoint?
        var downOrigin: NSPoint?
        var dragging = false

        /// Borderless SwiftUI windows don't move with isMovableByWindowBackground or
        /// WindowDragGesture, so move the window ourselves once the mouse travels 3 pt.
        func installDragMonitor() {
            guard dragMonitor == nil else { return }
            dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
                guard let self, let w = self.window, e.window === w else { return e }
                switch e.type {
                case .leftMouseDown:
                    downMouse = NSEvent.mouseLocation
                    downOrigin = w.frame.origin
                    dragging = false
                case .leftMouseDragged:
                    guard let m0 = downMouse, let o0 = downOrigin else { return e }
                    let p = NSEvent.mouseLocation
                    let dx = p.x - m0.x, dy = p.y - m0.y
                    if !dragging && hypot(dx, dy) < 3 { return e }
                    dragging = true
                    w.setFrameOrigin(NSPoint(x: o0.x + dx, y: o0.y + dy))
                    return nil
                case .leftMouseUp:
                    if dragging { WidgetDrag.lastEnd = Date() }
                    downMouse = nil
                    dragging = false
                default: break
                }
                return e
            }
        }

        deinit {
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ v: NSView, context: Context) {
        let level = level, c = context.coordinator
        DispatchQueue.main.async {
            guard let w = v.window, w !== c.window || level != c.level else { return }
            if w !== c.window {
                w.isOpaque = false
                w.backgroundColor = .clear
                w.hasShadow = true
                w.isMovableByWindowBackground = true
                // Remember where the user dragged it; restores that position on next launch.
                w.setFrameAutosaveName("MacMonitorWidget")
                if let old = c.closeObserver { NotificationCenter.default.removeObserver(old) }
                // Closing the widget (close button, ⌘W, Settings toggle) turns it off for next launch.
                c.closeObserver = NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                    UserDefaults.standard.set(false, forKey: "showWidget")
                }
                c.window = w
                c.installDragMonitor()
            }
            w.level = level.nsLevel
            w.collectionBehavior = level == .desktop
                ? [.canJoinAllSpaces, .stationary, .ignoresCycle]
                : [.canJoinAllSpaces, .fullScreenAuxiliary]
            w.invalidateShadow()
            c.level = level
        }
    }
}
