import Foundation

/// Default preferences, registered once at launch so every view agrees on them.
enum Prefs {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "mb.visible": true,           // Mac Monitor's item is in the menu bar
            "mb.cpu": true, "mb.gpu": true, "mb.memory": true,
            "mb.storage": true, "mb.network": true, "mb.battery": true,
            "mb.style": MenuStyle.icon.rawValue,
            "interval": 1.0,
        ])
    }
}
