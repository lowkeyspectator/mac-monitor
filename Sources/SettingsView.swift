import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            MenuBarSettings().tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
            WidgetSettings().tabItem { Label("Widget", systemImage: "widget.small") }
            AlertSettings().tabItem { Label("Alerts", systemImage: "bell.badge") }
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
    @AppStorage("mb.cpu") private var cpu = true
    @AppStorage("mb.gpu") private var gpu = true
    @AppStorage("mb.memory") private var memory = true
    @AppStorage("mb.storage") private var storage = true
    @AppStorage("mb.network") private var network = true
    @AppStorage("mb.battery") private var batteryOn = true
    @AppStorage("mb.style") private var style = MenuStyle.icon.rawValue
    @AppStorage("mb.visible") private var visible = true

    var body: some View {
        Form {
            Section {
                Toggle("Show Mac Monitor in the menu bar", isOn: Binding(
                    get: { visible },
                    set: { $0 ? MenuBarItem.restore() : (visible = false) }))
            } footer: {
                Text(visible
                     ? "If the icon still doesn't appear, macOS may be hiding it: open System Settings › Menu Bar and allow Mac Monitor. Opening Mac Monitor again from Applications always brings back this window."
                     : "While hidden, open Mac Monitor again from Applications or Spotlight to get back to these settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("CPU usage", isOn: $cpu)
                Toggle("GPU usage", isOn: $gpu)
                Toggle("Memory usage", isOn: $memory)
                Toggle("Storage used", isOn: $storage)
                Toggle("Network upload and download speed", isOn: $network)
                if BatteryInfo.hasBattery { Toggle("Battery level", isOn: $batteryOn) }
            } header: {
                HStack {
                    Text("Show in the menu bar")
                    Spacer()
                    Button("Show All") { cpu = true; gpu = true; memory = true; storage = true; network = true; batteryOn = true }
                        .buttonStyle(.link).font(.caption)
                }
            }
            .disabled(!visible)
            Section("Appearance") {
                Picker("Style", selection: $style) {
                    ForEach(MenuStyle.allCases) { Text($0.title).tag($0.rawValue) }
                }
                LabeledContent("Preview") {
                    MenuBarPreview(on: [.cpu: cpu, .gpu: gpu, .memory: memory, .storage: storage,
                                        .network: network, .battery: batteryOn],
                                   style: MenuStyle(rawValue: style) ?? .icon)
                }
            }
            .disabled(!visible)
        }
        .formStyle(.grouped)
        .frame(height: 560)
    }

}

/// Only this small view observes live data, so the rest of the form doesn't redraw every tick.
struct MenuBarPreview: View {
    @EnvironmentObject var m: Monitor
    var on: [Metric: Bool], style: MenuStyle
    var body: some View {
        let items = Metric.menuBarMetrics.filter { on[$0] == true && ($0 != .battery || m.battery.present) }
            .map { LabelItem.make($0, m) }
        Group {
            if items.isEmpty {
                Image(systemName: "gauge.with.dots.needle.50percent")
            } else if let img = renderStatusImage(items: items, style: style) {
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

struct AlertSettings: View {
    @AppStorage("alerts.cpu") private var cpu = false
    @AppStorage("alerts.cpuLimit") private var cpuLimit = 0.9
    @AppStorage("alerts.cpuSeconds") private var cpuSeconds = 60.0
    @AppStorage("alerts.memory") private var memory = false
    @AppStorage("alerts.memoryLevel") private var memoryLevel = 4
    @AppStorage("alerts.disk") private var disk = false
    @AppStorage("alerts.diskGB") private var diskGB = 20.0
    @AppStorage("alerts.battery") private var battery = false
    @AppStorage("alerts.batteryLimit") private var batteryLimit = 0.2
    @AppStorage("alerts.thermal") private var thermal = false
    @StateObject private var message = Box<String?>(nil)

    var body: some View {
        Form {
            Section {
                Toggle("High CPU usage", isOn: $cpu)
                if cpu {
                    Picker("When above", selection: $cpuLimit) {
                        ForEach([0.7, 0.8, 0.9, 0.95], id: \.self) { Text(pct($0)).tag($0) }
                    }
                    Picker("For at least", selection: $cpuSeconds) {
                        Text("30 seconds").tag(30.0)
                        Text("1 minute").tag(60.0)
                        Text("5 minutes").tag(300.0)
                    }
                }
                Toggle("Memory pressure", isOn: $memory)
                if memory {
                    Picker("When pressure is", selection: $memoryLevel) {
                        Text("Warning or worse").tag(2)
                        Text("Critical").tag(4)
                    }
                }
                Toggle("Low disk space", isOn: $disk)
                if disk {
                    Picker("When free space is below", selection: $diskGB) {
                        ForEach([10.0, 20.0, 50.0, 100.0], id: \.self) { Text("\(Int($0)) GB").tag($0) }
                    }
                }
                if BatteryInfo.hasBattery {
                    Toggle("Low battery", isOn: $battery)
                    if battery {
                        Picker("When at or below", selection: $batteryLimit) {
                            ForEach([0.1, 0.2, 0.3], id: \.self) { Text(pct($0)).tag($0) }
                        }
                    }
                }
                Toggle("Mac running hot", isOn: $thermal)
            } header: {
                Text("Notify me about")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Each alert is sent once, then again only after the problem clears or 15 minutes pass.")
                    if let msg = message.value { Text(msg).foregroundStyle(.orange) }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Send Test Notification") {
                    AlertEngine.shared.requestPermission { err in
                        message.value = err
                        if err == nil {
                            AlertEngine.shared.post(id: "test", title: "Mac Monitor alerts are on",
                                                    body: "You'll be notified here when a limit is crossed.")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
        .onChange(of: [cpu, memory, disk, battery, thermal]) { _, on in
            if on.contains(true) { AlertEngine.shared.requestPermission { message.value = $0 } }
        }
    }
}
