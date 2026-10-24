import AppKit

extension Notification.Name {
    static let browserWidgetGlassChanged = Notification.Name("BrowserWidgetGlassChanged")
    static let browserGlassChanged = Notification.Name("BrowserGlassChanged")
}

@MainActor enum BrowserGlass {
    private static let topKey = "webbyTopTransparency"
    private static let backgroundKey = "webbyBackgroundTransparency"
    private static let sidebarKey = "webbySidebarTransparency"
    private static let pageInjectionKey = "webbyPageGlassInjection"
    private static let matchSidebarKey = "webbyMatchPageGlassSidebar"

    private static func widgetKey(_ profile: UUID, _ kind: String? = nil) -> String {
        "webbyWidgetGlassOpacity.\(profile.uuidString)" + (kind.map { "." + $0 } ?? "")
    }
    static func widgetOpacity(profile: UUID, kind: String? = nil) -> Double {
        if let kind, let value = UserDefaults.standard.object(forKey: widgetKey(profile, kind)) as? Double {
            return value.isFinite ? min(1, max(0, value)) : 0.45
        }
        let value = (UserDefaults.standard.object(forKey: widgetKey(profile)) as? Double) ?? 0.45
        return value.isFinite ? min(1, max(0, value)) : 0.45
    }
    static func setWidgetOpacity(_ value: Double, profile: UUID, kind: String? = nil) {
        UserDefaults.standard.set(value.isFinite ? min(1, max(0, value)) : 0.45, forKey: widgetKey(profile, kind))
        NotificationCenter.default.post(name: .browserWidgetGlassChanged, object: nil)
    }
    static func resetWidgetOpacity(profile: UUID, kind: String) {
        UserDefaults.standard.removeObject(forKey: widgetKey(profile, kind))
        NotificationCenter.default.post(name: .browserWidgetGlassChanged, object: nil)
    }

    static var pageInjectionEnabled: Bool {
        get { UserDefaults.standard.object(forKey: pageInjectionKey) == nil ? true : UserDefaults.standard.bool(forKey: pageInjectionKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: pageInjectionKey)
            NotificationCenter.default.post(name: .browserGlassChanged, object: nil)
        }
    }

    static var matchPageGlassSidebar: Bool {
        get { UserDefaults.standard.bool(forKey: matchSidebarKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: matchSidebarKey)
            NotificationCenter.default.post(name: .browserGlassChanged, object: nil)
        }
    }

    static var topTransparency: Double {
        UserDefaults.standard.object(forKey: topKey) == nil ? 0.38
            : min(0.85, max(0, UserDefaults.standard.double(forKey: topKey)))
    }

    static var sidebarTransparency: Double {
        UserDefaults.standard.object(forKey: sidebarKey) == nil ? 0.58
            : min(0.85, max(0, UserDefaults.standard.double(forKey: sidebarKey)))
    }

    static var backgroundTransparency: Double {
        min(1, max(0, UserDefaults.standard.double(forKey: backgroundKey)))
    }
    static func setBackground(_ value: Double) {
        UserDefaults.standard.set(min(1, max(0, value)), forKey: backgroundKey)
        NotificationCenter.default.post(name: .browserGlassChanged, object: nil)
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
