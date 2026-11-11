import CoreGraphics
import Foundation

enum WebbyOnboardingStep: Int, Codable, CaseIterable {
    case welcome, migration, spaces, signature, layout, background, canvas, tour, links, ready

    var title: String {
        switch self {
        case .welcome: "Make the web yours."
        case .migration: "Bring your browser."
        case .spaces: "Your profiles."
        case .signature: "Make it yours."
        case .layout: "Choose your layout."
        case .background: "Glass & wallpaper."
        case .canvas: "Your widgets."
        case .tour: "Explore Webby."
        case .links: "Make Webby your default?"
        case .ready: "Your Webby is ready."
        }
    }

    var action: String {
        switch self {
        case .welcome: "Get started"
        case .signature: "Use this theme"
        case .background: "Looks good"
        case .canvas: "Build my canvas"
        case .ready: "Open Webby"
        default: "Continue"
        }
    }
}

struct OnboardingGlassSettings: Codable, Equatable {
    var background = 0.0
    var toolbar = 0.38
    var sidebar = 0.58
    var widgets = 0.45
    var pages = true
}

struct OnboardingWidgetFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect, in size: CGSize) {
        x = rect.minX / max(1, size.width)
        y = rect.minY / max(1, size.height)
        width = rect.width / max(1, size.width)
        height = rect.height / max(1, size.height)
    }

    func rect(in size: CGSize) -> CGRect {
        let w = min(1, max(0.08, width))
        let h = min(1, max(0.08, height))
        return CGRect(x: min(max(0, x), 1 - w) * size.width, y: min(max(0, y), 1 - h) * size.height,
                      width: w * size.width, height: h * size.height)
    }
}

enum OnboardingWallpaperDesign: String, CaseIterable, Codable {
    case profile, blueHour, ember, forest, graphite

    var name: String {
        switch self {
        case .profile: "Profile Gradient"
        case .blueHour: "Blue Hour"
        case .ember: "Ember"
        case .forest: "Forest"
        case .graphite: "Graphite"
        }
    }

    func colors(profile: [String]) -> [String] {
        switch self {
        case .profile: profile
        case .blueHour: ["#090F29", "#344DAB", "#A191E2"]
        case .ember: ["#241028", "#A53443", "#FFAE76"]
        case .forest: ["#0B2225", "#276C56", "#B4D490"]
        case .graphite: ["#12151B", "#424B60", "#A2B3CF"]
        }
    }
}

struct WebbyOnboardingDraft: Codable {
    struct Space: Identifiable, Codable {
        let id: UUID
        var name: String
        var isNew: Bool = false
    }

    enum Phase: String, Codable { case inProgress, completed, skipped }
    static let storageKey = "webbyOnboarding.v1"
    var version = 1
    var phase = Phase.inProgress
    var step = WebbyOnboardingStep.welcome
    var spaces: [Space]
    var selectedSpace: UUID
    var importIDs: [String: UUID] = [:]
    var importInterrupted = false
    var retryChrome: Set<String> = []
    var theme = "aqua-wisp"
    var themeChanged = false
    var customColors: [String]?
    var petPath: String?
    var iconMode: String?
    var iconPath: String?
    var animatedDetails = true
    var layout = "top"
    var address = "strip"
    var search = "google"
    var fuse = false
    var restoreTabs = false
    var offloadMinutes = 0
    var glances = true
    var sounds = true
    var glass: OnboardingGlassSettings?
    var originalGlass: OnboardingGlassSettings?
    var wallpaperDesign: OnboardingWallpaperDesign?
    var widgetFrames: [String: OnboardingWidgetFrame]?
    var widgetEdits: [String: OnboardingWidgetFrame]?
    var background = "clean"
    var backgroundChanged = false
    var backgroundPath: String?
    var backgroundID = UUID()
    var effect = 0
    var fade = 1
    var fadeStart = 0.0
    var fadeEnd = 0.92
    var blur = 0.0
    var opacity = 0.4
    var pageOpacity = 0.28
    var fit = 0
    var soften = true
    var homeOnly = true
    var fullWindow = false
    var frostScope = 1
    var frostStrength = 0.85
    var wallpaperMotion = true
    var saveLook = false
    var widgetPreset = "Minimal"
    var widgets: [String] = []
    var widgetsChanged = false
    var toured = false
    var defaultDecision = "later"
    var externalProfile: UUID?

    var currentSpace: Space? { spaces.first { $0.id == selectedSpace } }

    static func load(from defaults: UserDefaults = .standard) -> Self? {
        guard let data = defaults.data(forKey: storageKey),
              let state = try? JSONDecoder().decode(Self.self, from: data),
              state.version == 1, state.currentSpace != nil else { return nil }
        return state
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }

    static func shouldPresent(existingProfiles: Bool, saved: Self?) -> Bool {
        if let saved { return saved.phase == .inProgress }
        return !existingProfiles
    }

    mutating func advance() {
        if let next = WebbyOnboardingStep(rawValue: step.rawValue + 1) { step = next }
    }

    mutating func back() {
        if let previous = WebbyOnboardingStep(rawValue: step.rawValue - 1) { step = previous }
    }
}
