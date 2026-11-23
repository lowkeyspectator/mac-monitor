import SwiftUI
import AppKit

/// Developer aid: `MacMonitor.app/Contents/MacOS/MacMonitor --snapshot <dir>` renders the
/// main views to PNG files (light and dark) and exits. Handy for README screenshots.
enum Snapshot {
    @MainActor static var monitor: Monitor?
    /// True when launched with --snapshot; the app then shows no menu bar item or widget.
    static let isActive = CommandLine.arguments.contains("--snapshot")

    static func runIfRequested() {
        let args = CommandLine.arguments
        guard isActive, let i = args.firstIndex(of: "--snapshot") else { return }
        let dir = URL(fileURLWithPath: i + 1 < args.count ? args[i + 1] : ".")
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let m = Monitor()
                monitor = m
                for k in Metric.allCases { m.setDetailVisible(k, true) }   // fill the per-app lists
                // Let a few samples accumulate so graphs have data.
                DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                    MainActor.assumeIsolated { render(m, to: dir); m.stopStreams(); exit(0) }
                }
            }
        }
    }

    @MainActor static func render(_ m: Monitor, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for scheme in [ColorScheme.light, .dark] {
            let suffix = scheme == .dark ? "dark" : "light"
            let bg = scheme == .dark ? Color(white: 0.16) : Color(white: 0.95)

            UsagePanel.setAll(false, prefix: "snap.collapsed")
            save(PanelPreview(prefix: "snap.collapsed"), m, scheme, bg,
                 dir.appendingPathComponent("panel-collapsed-\(suffix).png"))

            UsagePanel.setAll(true, prefix: "snap.expanded")
            save(PanelPreview(prefix: "snap.expanded"), m, scheme, bg,
                 dir.appendingPathComponent("panel-expanded-\(suffix).png"))

            save(HStack(spacing: 4) {
                ForEach(Metric.ringMetrics) { k in
                    Ring(value: m.value(k), label: k.title, detail: "", color: k.tint)
                }
            }.padding(16).frame(width: 340), m, scheme, bg, dir.appendingPathComponent("widget-compact-\(suffix).png"))
        }
        // Menu bar label styles
        let items = Metric.menuBarMetrics.map { LabelItem.make($0, m) }
        save(VStack(alignment: .leading, spacing: 8) {
            ForEach(MenuStyle.allCases) { style in
                HStack {
                    Text(style.title).font(.caption).frame(width: 130, alignment: .leading)
                    StatusLabelContent(items: items, style: style)
                }
            }
        }.padding(12), m, .light, .white, dir.appendingPathComponent("menubar-styles.png"))
        // Leave no snapshot-only keys behind in the user's preferences.
        for prefix in ["snap.collapsed", "snap.expanded"] {
            for k in Metric.allCases { UserDefaults.standard.removeObject(forKey: "\(prefix).\(k.rawValue)") }
        }
        print("Snapshots written to \(dir.path)")
    }

    @MainActor static func save<V: View>(_ view: V, _ m: Monitor, _ scheme: ColorScheme, _ bg: Color, _ url: URL) {
        let content = view
            .environmentObject(m)
            .environment(\.colorScheme, scheme)
            .padding(12)
            .background(bg)
        let r = ImageRenderer(content: content)
        r.scale = 2
        guard let img = r.nsImage, let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

/// The menu bar panel's content without the ScrollView (ImageRenderer can't draw scroll views).
private struct PanelPreview: View {
    @EnvironmentObject var m: Monitor
    let prefix: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac Monitor").font(.system(size: 13, weight: .semibold))
                Text("\(m.cpuName) · \(fmtBytes(m.memory.total))").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
            UsagePanel(prefix: prefix)
        }
        .frame(width: 320)
    }
}
