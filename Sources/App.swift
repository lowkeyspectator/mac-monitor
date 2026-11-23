import SwiftUI
import AppKit

@main
struct MacMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor: Monitor
    @AppStorage("mb.visible") private var menuBarVisible = true

    init() {
        Prefs.register()
        // Before the menu bar item is created: if it would start hidden with nothing else on screen, un-hide it.
        AppDelegate.showSettingsAtLaunch = !Snapshot.isActive && MenuBarItem.unhideIfNothingVisible()
        _monitor = StateObject(wrappedValue: Monitor())
        Snapshot.runIfRequested()
    }

    var body: some Scene {
        // If the user removes the item (e.g. ⌘-dragging it out of the menu bar), SwiftUI sets this to false.
        // Only write when the value changes: SwiftUI calls this setter whenever it observes the item.
        MenuBarExtra(isInserted: Binding(get: { menuBarVisible && !Snapshot.isActive },
                                         set: { if $0 != menuBarVisible { menuBarVisible = $0 } })) {
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

/// A menu-bar-only app has no Dock icon, so if its menu bar item is hidden there would be no way back in.
/// Opening the app again (Finder, Spotlight, Launchpad) restores the item and shows Settings.
final class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var showSettingsAtLaunch = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar app must keep running with no windows open; macOS must not quit it to save resources.
        ProcessInfo.processInfo.disableAutomaticTermination("Mac Monitor lives in the menu bar")
        ProcessInfo.processInfo.disableSuddenTermination()
        if Self.showSettingsAtLaunch { showSettings() }
    }

    /// SwiftUI otherwise quits the app when its last window closes — including the menu bar panel,
    /// which closes whenever you click elsewhere. That was the "crash".
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBarItem.restore()
        showSettings()
        return false
    }

    /// Settings is opened by the menu bar label view via SwiftUI's openSettings action;
    /// the short delay lets a just-restored menu bar item come into existence first.
    private func showSettings() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NotificationCenter.default.post(name: .showMacMonitorSettings, object: nil)
        }
    }
}

enum MenuBarItem {
    private static var hiddenKeys: [String] {
        UserDefaults.standard.dictionaryRepresentation()
            .filter { $0.key.hasPrefix("NSStatusItem Visible") && ($0.value as? Bool) == false }.map(\.key)
    }

    /// At launch, before the item exists: if neither the item nor the widget would be visible,
    /// clear the hidden state so the app can't start invisible. Returns true if it did.
    static func unhideIfNothingVisible() -> Bool {
        let d = UserDefaults.standard
        let itemShown = d.bool(forKey: "mb.visible") && hiddenKeys.isEmpty
        guard !itemShown && !d.bool(forKey: "showWidget") else { return false }
        hiddenKeys.forEach { d.removeObject(forKey: $0) }
        d.set(true, forKey: "mb.visible")
        return true
    }

    /// Brings the menu bar item back even if it was hidden from the menu bar itself:
    /// clears AppKit's saved "NSStatusItem Visible…" flag, then re-creates the item.
    static func restore() {
        let d = UserDefaults.standard
        let hidden = d.dictionaryRepresentation().keys.filter { $0.hasPrefix("NSStatusItem Visible") }
        hidden.forEach { d.removeObject(forKey: $0) }
        if !hidden.isEmpty || !d.bool(forKey: "mb.visible") {
            d.set(false, forKey: "mb.visible")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { d.set(true, forKey: "mb.visible") }
        }
    }
}

extension Notification.Name {
    static let showMacMonitorSettings = Notification.Name("MacMonitorShowSettings")
}
