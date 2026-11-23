import Foundation
import AppKit

/// macOS Energy Mode (System Settings › Battery › Energy Mode).
/// Reading needs no privileges; changing it runs `pmset` with administrator rights,
/// which shows the standard macOS password prompt. There is no public API for this.
enum EnergyMode: Int, CaseIterable, Identifiable {
    case automatic = 0, low = 1, high = 2
    var id: Int { rawValue }
    var title: String {
        switch self { case .automatic: "Automatic"; case .low: "Low Power"; case .high: "High Power" }
    }
}

enum EnergyModeControl {
    /// High Power Mode exists only on Max-chip MacBook Pros.
    static let supportsHighPower: Bool = {
        let chip = Sys.sysctlString("machdep.cpu.brand_string") ?? ""
        return chip.contains("Max") && BatteryReader.read().present
    }()

    private static func pmsetSettings() -> [String: Int] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        var out: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.count >= 2, let v = Int(f[1]) { out[String(f[0])] = v }
        }
        return out
    }

    /// Current mode for the active power source, or nil if this Mac has no energy modes.
    static func current() -> EnergyMode? {
        let s = pmsetSettings()
        if let v = s["powermode"] { return EnergyMode(rawValue: v) }
        if let v = s["lowpowermode"] { return v == 1 ? .low : .automatic }   // older macOS versions
        return nil
    }

    /// Applies the mode on battery and on power adapter, after the macOS administrator prompt.
    /// Returns an error message, or nil on success or if the user cancelled.
    @MainActor
    static func set(_ mode: EnergyMode) -> String? {
        let cmd = pmsetSettings()["powermode"] != nil
            ? "/usr/bin/pmset -a powermode \(mode.rawValue)"
            : "/usr/bin/pmset -a lowpowermode \(mode == .low ? 1 : 0)"
        var error: NSDictionary?
        NSApp.activate()
        NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return nil }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 { return nil }   // user cancelled
        return error[NSAppleScript.errorMessage] as? String ?? "Couldn't change the energy mode."
    }
}
