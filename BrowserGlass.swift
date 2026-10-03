import AppKit

extension Notification.Name {
    static let browserGlassChanged = Notification.Name("BrowserGlassChanged")
}

@MainActor enum BrowserGlass {
    private static let topKey = "webbyTopTransparency"
    private static let sidebarKey = "webbySidebarTransparency"

    static var topTransparency: Double {
        UserDefaults.standard.object(forKey: topKey) == nil ? 0.38
            : min(0.85, max(0, UserDefaults.standard.double(forKey: topKey)))
    }

    static var sidebarTransparency: Double {
        UserDefaults.standard.object(forKey: sidebarKey) == nil ? 0.58
            : min(0.85, max(0, UserDefaults.standard.double(forKey: sidebarKey)))
    }

    static func setTop(_ value: Double) {
        UserDefaults.standard.set(min(0.85, max(0, value)), forKey: topKey)
        NotificationCenter.default.post(name: .browserGlassChanged, object: nil)
    }

    static func setSidebar(_ value: Double) {
        UserDefaults.standard.set(min(0.85, max(0, value)), forKey: sidebarKey)
        NotificationCenter.default.post(name: .browserGlassChanged, object: nil)
    }
}
