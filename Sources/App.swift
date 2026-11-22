import SwiftUI
import AppKit

@main
struct MacMonitorApp: App {
    @StateObject private var monitor = Monitor()

    init() { Snapshot.runIfRequested() }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(!Snapshot.isActive)) {
            MenuPanel().environmentObject(monitor)
        } label: {
            StatusLabel(m: monitor)
        }
        .menuBarExtraStyle(.window)

        Window("Mac Monitor Widget", id: "widget") {
            WidgetView().environmentObject(monitor)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        .windowBackgroundDragBehavior(.enabled)
        .defaultPosition(.topTrailing)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(!Snapshot.isActive && UserDefaults.standard.bool(forKey: "showWidget") ? .presented : .suppressed)

        Settings {
            SettingsView().environmentObject(monitor)
        }
    }
}
