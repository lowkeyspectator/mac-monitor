import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettings().tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            WidgetSettings().tabItem { Label("Widget", systemImage: "widget.small") }
        }
        .frame(width: 480)
    }
}

struct GeneralSettings: View {
    @AppStorage("interval") private var interval = 1.0
    @StateObject private var launchAtLogin = Box(SMAppService.mainApp.status == .enabled)
    @StateObject private var loginMessage = Box<String?>(nil)

    var body: some View {
        Form {
            Section {
                Picker("Update every", selection: $interval) {
                    Text("0.5 seconds").tag(0.5)
                    Text("1 second").tag(1.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                }
                Toggle("Open at login", isOn: $launchAtLogin.value)
                    .onChange(of: launchAtLogin.value) { _, on in setLaunchAtLogin(on) }
                if let msg = loginMessage.value {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
                LabeledContent("Source") {
                    Link("github.com/lowkeyspectator/mac-monitor",
                         destination: URL(string: "https://github.com/lowkeyspectator/mac-monitor")!)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 260)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        // Ignore changes that already match the system state, including the revert below
        // after a failure, so a failed register() isn't followed by a spurious unregister().
        let status = SMAppService.mainApp.status
        guard on != (status == .enabled || status == .requiresApproval) else { return }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginMessage.value = SMAppService.mainApp.status == .requiresApproval
                ? "Allow Mac Monitor in System Settings › General › Login Items." : nil
        } catch {
            loginMessage.value = error.localizedDescription
        }
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != launchAtLogin.value && SMAppService.mainApp.status != .requiresApproval { launchAtLogin.value = enabled }
    }
}

struct MenuBarSettings: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("mb.cpu") private var cpu = true
    @AppStorage("mb.gpu") private var gpu = true
    @AppStorage("mb.memory") private var memory = true
    @AppStorage("mb.storage") private var storage = false
    @AppStorage("mb.style") private var style = MenuStyle.icon.rawValue

    var body: some View {
        Form {
            Section("Show in the menu bar") {
                Toggle("CPU usage", isOn: $cpu)
                Toggle("GPU usage", isOn: $gpu)
                Toggle("Memory usage", isOn: $memory)
                Toggle("Storage used", isOn: $storage)
            }
            Section("Appearance") {
                Picker("Style", selection: $style) {
                    ForEach(MenuStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Preview") { preview }
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }

    @ViewBuilder private var preview: some View {
        let on: [Metric: Bool] = [.cpu: cpu, .gpu: gpu, .memory: memory, .storage: storage]
        let items = Metric.allCases.filter { on[$0] == true }
            .map { LabelItem(metric: $0, value: m.value($0), history: m.history($0)) }
        Group {
            if items.isEmpty {
                Image(systemName: "gauge.with.dots.needle.50percent")
            } else if let img = renderStatusImage(items: items, style: MenuStyle(rawValue: style) ?? .icon) {
                Image(nsImage: img).renderingMode(.template)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
    }
}

struct WidgetSettings: View {
    @AppStorage("showWidget") private var showWidget = false
    @AppStorage("widget.level") private var level = WidgetLevel.desktop.rawValue
    @AppStorage("widget.expanded") private var expanded = false
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        Form {
            Section {
                Toggle("Show desktop widget", isOn: Binding(
                    get: { showWidget },
                    set: { $0 ? openWindow(id: "widget") : dismissWindow(id: "widget") }))
                Picker("Position", selection: $level) {
                    ForEach(WidgetLevel.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Show details", isOn: $expanded)
            } footer: {
                Text("Drag the widget anywhere to move it. Hover over it for the expand, settings and close buttons. Click a ring to jump to that section's details.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(height: 240)
    }
}
