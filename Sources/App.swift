import SwiftUI
import AppKit

@main
struct MacMonitorApp: App {
    @StateObject private var monitor = Monitor()

    init() { Snapshot.runIfRequested() }

    var body: some Scene {
        MenuBarExtra {
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
        .defaultPosition(.topTrailing)
        .restorationBehavior(.disabled)
        .defaultLaunchBehavior(UserDefaults.standard.bool(forKey: "showWidget") ? .presented : .suppressed)

        Settings {
            SettingsView().environmentObject(monitor)
        }
    }
}
