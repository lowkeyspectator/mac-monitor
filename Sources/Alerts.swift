import Foundation
import UserNotifications

/// Posts a macOS notification when a metric stays past a user-set limit.
/// Each alert fires once, then waits until the condition clears (or 15 minutes pass) before firing again.
@MainActor
final class AlertEngine: NSObject, UNUserNotificationCenterDelegate {
    static let shared = AlertEngine()

    enum Kind: String, CaseIterable {
        case cpu, memory, disk, battery, thermal
    }

    private struct State { var since: Date?; var firedAt: Date? }
    private var states: [Kind: State] = [:]
    private var cpuSamples: [(at: Date, value: Double)] = []   // for the moving average
    private let cooldown: TimeInterval = 15 * 60
    private let d = UserDefaults.standard

    func attach(_ monitor: Monitor) {
        monitor.onSample = { [weak self] m in self?.evaluate(m) }
        UNUserNotificationCenter.current().delegate = self
    }

    private func evaluate(_ m: Monitor) {
        let now = Date()
        let cpuLimit = d.object(forKey: "alerts.cpuLimit") as? Double ?? 0.9
        let cpuFor = d.object(forKey: "alerts.cpuSeconds") as? Double ?? 60
        let pressureLevel = d.object(forKey: "alerts.memoryLevel") as? Int ?? 4
        let diskGB = d.object(forKey: "alerts.diskGB") as? Double ?? 20
        let batteryLimit = d.object(forKey: "alerts.batteryLimit") as? Double ?? 0.2

        // Average over the whole window, so normal fluctuation around the limit doesn't reset it.
        cpuSamples.append((now, m.cpuTotal))
        cpuSamples.removeAll { now.timeIntervalSince($0.at) > cpuFor }
        let covered = (cpuSamples.first.map { now.timeIntervalSince($0.at) } ?? 0) >= cpuFor * 0.9
        let average = cpuSamples.isEmpty ? 0 : cpuSamples.map(\.value).reduce(0, +) / Double(cpuSamples.count)
        check(.cpu, covered && average >= cpuLimit, sustain: 0, now: now,
              title: "High CPU usage",
              body: "CPU has averaged \(pct(average)) over the last \(fmtDuration(cpuFor))." + topProcess(m))
        check(.memory, m.memory.pressure >= pressureLevel, sustain: 10, now: now,
              title: "Memory pressure is \(m.pressureName.lowercased())",
              body: "\(fmtBytes(m.memory.used)) of \(fmtBytes(m.memory.total)) in use. Quitting apps will free memory.")
        if let root = m.rootVolume {
            check(.disk, Double(root.available) < diskGB * 1e9, sustain: 0, now: now,
                  title: "Low disk space",
                  body: "Only \(fmtDisk(root.available)) left on \(root.name).")
        }
        if m.battery.present {
            check(.battery, !m.battery.onAC && m.battery.level <= batteryLimit, sustain: 0, now: now,
                  title: "Battery low",
                  body: "Battery is at \(pct(m.battery.level)). Connect a power adapter.")
        }
        check(.thermal, m.system.thermal == .serious || m.system.thermal == .critical, sustain: 5, now: now,
              title: "Your Mac is running hot",
              body: "macOS reports a \(m.system.thermalName.lowercased()) thermal state and may slow down to cool off.")
    }

    private func topProcess(_ m: Monitor) -> String {
        m.topCPU.first.map { " Top process: \($0.name) (\($0.text))." } ?? ""
    }

    private func check(_ kind: Kind, _ active: Bool, sustain: TimeInterval, now: Date, title: String, body: String) {
        guard d.bool(forKey: "alerts.\(kind.rawValue)") else { states[kind] = nil; return }
        var s = states[kind] ?? State()
        if !active {
            s.since = nil
            s.firedAt = nil          // condition cleared: allow the next occurrence to alert
        } else {
            if s.since == nil { s.since = now }
            let held = now.timeIntervalSince(s.since!) >= sustain
            let cooled = s.firedAt.map { now.timeIntervalSince($0) >= cooldown } ?? true
            if held && cooled {
                s.firedAt = now
                post(id: kind.rawValue, title: title, body: body)
            }
        }
        states[kind] = s
    }

    func post(id: String, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "macmonitor.\(id)", content: c, trigger: nil))
    }

    /// Asks for permission. Calls back with an error message, or nil when allowed.
    func requestPermission(_ done: @escaping @MainActor (String?) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            let msg: String? = granted ? nil
                : (error?.localizedDescription
                   ?? "Notifications are turned off for Mac Monitor. Turn them on in System Settings › Notifications.")
            DispatchQueue.main.async { MainActor.assumeIsolated { done(msg) } }
        }
    }

    // Show banners even while the app is frontmost (e.g. Settings is open).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
