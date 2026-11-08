import AppKit
import CoreText
import WebKit

extension Notification.Name {
    static let browserThemeChanged = Notification.Name("BrowserThemeChanged")
}

@MainActor enum BrowserTheme {
    private(set) static var activeSpaceID: UUID?
    private static func key(_ name: String, space: UUID? = nil) -> String {
        name + "." + ((space ?? activeSpaceID)?.uuidString ?? "unassigned")
    }

    static func activate(_ space: UUID) {
        guard activeSpaceID != space else { return }
        activeSpaceID = space
        NotificationCenter.default.post(name: .browserThemeChanged, object: nil)
    }

    static func remove(_ space: UUID) {
        if let path = UserDefaults.standard.string(forKey: key("browserCustomIconPetURL", space: space)) {
            try? FileManager.default.removeItem(atPath: path)
        }
        for name in ["browserGradientProfile", "browserCustomGradientStops", "browserCustomPetID"] {
            UserDefaults.standard.removeObject(forKey: key(name, space: space))
        }
        UserDefaults.standard.removeObject(forKey: key("browserCustomIconPetURL", space: space))
        UserDefaults.standard.removeObject(forKey: BrowserWindowStyle.key(for: space))
    }
    private static let catalog: GradientCatalog? = {
        guard let url = Bundle.main.url(forResource: "gradient_profiles", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(GradientCatalog.self, from: data)
    }()

    static var presets: [(id: String, name: String)] {
        (catalog?.profileByPetID ?? [:]).map { id, profile in
            (id: id, name: profile.displayName ?? id)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static var selectedID: String {
        let saved = UserDefaults.standard.string(forKey: key("browserGradientProfile"))
            ?? UserDefaults.standard.string(forKey: "browserGradientProfile") ?? "aqua-wisp"
        return saved == "custom" || presets.contains(where: { $0.id == saved }) ? saved : "aqua-wisp"
    }

    static var petID: String {
        if selectedID != "custom" { return selectedID }
        let saved = UserDefaults.standard.string(forKey: key("browserCustomPetID")) ?? "aqua-wisp"
        return presets.contains(where: { $0.id == saved }) ? saved : "aqua-wisp"
    }

    static var customPetURL: URL? {
        guard selectedID == "custom",
              let path = UserDefaults.standard.string(forKey: key("browserCustomIconPetURL")),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    static func saveCustomPet(from source: URL) throws {
        guard let space = activeSpaceID, NSImage(contentsOf: source) != nil else {
            throw NSError(domain: "WebbyIcon", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Choose a readable PNG, JPEG, or WebP image."])
        }
        let folder = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Webby/ProfilePets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(space.uuidString + "." + source.pathExtension.lowercased())
        if let old = UserDefaults.standard.string(forKey: key("browserCustomIconPetURL")) {
            try? FileManager.default.removeItem(atPath: old)
        }
        try FileManager.default.copyItem(at: source, to: target)
        UserDefaults.standard.set(target.path, forKey: key("browserCustomIconPetURL"))
        select("custom")
    }

    static func clearCustomPet() {
        if let path = UserDefaults.standard.string(forKey: key("browserCustomIconPetURL")) {
            try? FileManager.default.removeItem(atPath: path)
        }
        UserDefaults.standard.removeObject(forKey: key("browserCustomIconPetURL"))
        NotificationCenter.default.post(name: .browserThemeChanged, object: nil)
    }

    static var fuseProfile: PetGradientProfile {
        let colors = ["#6989CC", "#9BC2E9", "#E1EAE9", "#F3EDCB", "#F7DF95", "#F5BD82", "#F09488"]
        let locations = [0.0, 0.18, 0.38, 0.55, 0.73, 0.88, 1.0]
        let recipe = GradientRecipe(angleDegrees: 90, cycleDurationMs: 2500,
            stops: zip(locations, colors).map { GradientStop(location: $0.0, color: $0.1) })
        return PetGradientProfile(
            palette: PetPalette(shadow: "#172A4B", primary: colors[0], secondary: colors[1],
                                accent: colors[4], highlight: colors[3], foreground: colors[2]),
            gradients: PetGradients(ambient: recipe, thinking: recipe, working: recipe,
                                   success: recipe, warning: recipe, error: recipe))
    }

    static var profile: PetGradientProfile {
        profile(for: activeSpaceID)
    }

    static func profile(for spaceID: UUID?) -> PetGradientProfile {
        let saved = UserDefaults.standard.string(forKey: key("browserGradientProfile", space: spaceID))
            ?? UserDefaults.standard.string(forKey: "browserGradientProfile") ?? "aqua-wisp"
        let selected = saved == "custom" || presets.contains(where: { $0.id == saved }) ? saved : "aqua-wisp"
        if selected == "custom", let custom = customProfile(for: spaceID) { return custom }
        return catalog?.profileByPetID[selected]
            ?? catalog?.profileByPetID["aqua-wisp"]
            ?? fallbackProfile
    }

    static func select(_ id: String) {
        guard id == "custom" || presets.contains(where: { $0.id == id }) else { return }
        if id != "custom" { UserDefaults.standard.set(id, forKey: key("browserCustomPetID")) }
        UserDefaults.standard.set(id, forKey: key("browserGradientProfile"))
        NotificationCenter.default.post(name: .browserThemeChanged, object: nil)
    }

    static func selectCustomPet(_ id: String) {
        guard presets.contains(where: { $0.id == id }) else { return }
        UserDefaults.standard.set(id, forKey: key("browserCustomPetID"))
        select("custom")
    }

    static func saveCustom(_ colors: [NSColor]) {
        guard colors.count == 3 else { return }
        UserDefaults.standard.set(colors.map(hex), forKey: key("browserCustomGradientStops"))
        select("custom")
    }

    static var customColors: [NSColor] {
        let values = UserDefaults.standard.stringArray(forKey: key("browserCustomGradientStops"))
            ?? UserDefaults.standard.stringArray(forKey: "browserCustomGradientStops")
            ?? ["#60DEE0", "#0690B3", "#DFF9F3"]
        return values.map { color($0) }
    }

    static func color(_ hex: String, alpha: CGFloat = 1) -> NSColor {
        let value = Int(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x60DEE0
        return NSColor(srgbRed: CGFloat((value >> 16) & 255) / 255,
                       green: CGFloat((value >> 8) & 255) / 255,
                       blue: CGFloat(value & 255) / 255, alpha: alpha)
    }

    static func apply(_ recipe: GradientRecipe, to layer: CAGradientLayer, alpha: CGFloat = 1) {
        let radians = recipe.angleDegrees * .pi / 180
        let dx = CGFloat(cos(radians)) * 0.5
        let dy = CGFloat(sin(radians)) * 0.5
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.colors = recipe.stops.map { color($0.color, alpha: alpha).cgColor }
        layer.locations = recipe.stops.map { NSNumber(value: $0.location) }
        layer.startPoint = CGPoint(x: 0.5 - dx, y: 0.5 - dy)
        layer.endPoint = CGPoint(x: 0.5 + dx, y: 0.5 + dy)
        CATransaction.commit()
    }

    static func hex(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        let red = min(255, max(0, Int((rgb.redComponent * 255).rounded())))
        let green = min(255, max(0, Int((rgb.greenComponent * 255).rounded())))
        let blue = min(255, max(0, Int((rgb.blueComponent * 255).rounded())))
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private static func customProfile(for spaceID: UUID?) -> PetGradientProfile? {
        let savedPet = UserDefaults.standard.string(forKey: key("browserCustomPetID", space: spaceID)) ?? "aqua-wisp"
        let chosenPet = presets.contains(where: { $0.id == savedPet }) ? savedPet : "aqua-wisp"
        guard let base = catalog?.profileByPetID[chosenPet] else { return nil }
        let values = UserDefaults.standard.stringArray(forKey: key("browserCustomGradientStops", space: spaceID))
            ?? UserDefaults.standard.stringArray(forKey: "browserCustomGradientStops")
            ?? ["#60DEE0", "#0690B3", "#DFF9F3"]
        guard values.count == 3 else { return nil }
        let stops = zip([0.0, 0.5, 1.0], values).map { GradientStop(location: $0.0, color: $0.1) }
        let ambient = GradientRecipe(angleDegrees: 35, cycleDurationMs: 2500, stops: stops)
        let working = GradientRecipe(angleDegrees: 0, cycleDurationMs: 1050, stops: stops)
        let palette = PetPalette(shadow: base.palette.shadow, primary: values[0],
                                 secondary: values[1], accent: values[1],
                                 highlight: values[2], foreground: base.palette.foreground)
        let gradients = PetGradients(ambient: ambient, thinking: working, working: working,
                                     success: ambient, warning: working, error: working)
        return PetGradientProfile(palette: palette, gradients: gradients)
    }

    private static var fallbackProfile: PetGradientProfile {
        let stops = [GradientStop(location: 0, color: "#60DEE0"),
                     GradientStop(location: 0.5, color: "#0690B3"),
                     GradientStop(location: 1, color: "#DFF9F3")]
        let recipe = GradientRecipe(angleDegrees: 35, cycleDurationMs: 2500, stops: stops)
        let palette = PetPalette(shadow: "#0B0914", primary: "#60DEE0", secondary: "#0690B3",
                                 accent: "#22C8D2", highlight: "#DFF9F3", foreground: "#000000")
        let gradients = PetGradients(ambient: recipe, thinking: recipe, working: recipe,
                                     success: recipe, warning: recipe, error: recipe)
        return PetGradientProfile(palette: palette, gradients: gradients)
    }
}

// A shared native font factory keeps weights/sizes consistent without changing
// terminal, editor, or icon fonts. Fonts are registered only in this process.
enum WebbyTypography {
    private static let registered:Bool = {
        var success=false
        for name in ["Geist-VariableFont_wght","Geist-Italic-VariableFont_wght"] {
            if let url=Bundle.main.url(forResource:name,withExtension:"ttf",subdirectory:"Fonts/Geist") {
                success = CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil) || success
            }
        }
        return success
    }()
    private static let fontCache:NSCache<NSString,NSFont> = {
        let cache=NSCache<NSString,NSFont>();cache.countLimit=512;return cache
    }()
    static func font(ofSize size:CGFloat,weight:NSFont.Weight = .regular)->NSFont {
        guard UserDefaults.standard.object(forKey:"webbyGeistEnabled")==nil || UserDefaults.standard.bool(forKey:"webbyGeistEnabled") else{return .systemFont(ofSize:size,weight:weight)}
        _ = registered
        let key="\(size):\(weight.rawValue)" as NSString
        if let cached=fontCache.object(forKey:key) {return cached}
        let descriptor=NSFontDescriptor(fontAttributes:[.family:"Geist",.traits:[NSFontDescriptor.TraitKey.weight:weight.rawValue]])
        let resolved=NSFont(descriptor:descriptor,size:size) ?? .systemFont(ofSize:size,weight:weight)
        fontCache.setObject(resolved,forKey:key);return resolved
    }
    @MainActor static func apply(to view:NSView){
        guard !(view is WKWebView) else{return}
        func converted(_ current:NSFont)->NSFont {
            guard !current.isFixedPitch,!current.fontDescriptor.symbolicTraits.contains(.monoSpace) else{return current}
            let traits=current.fontDescriptor.object(forKey:.traits) as? [NSFontDescriptor.TraitKey:Any]
            let weight=NSFont.Weight(rawValue:(traits?[.weight] as? NSNumber)?.doubleValue ?? 0)
            let next=font(ofSize:current.pointSize,weight:weight)
            return current.fontDescriptor.symbolicTraits.contains(.italic) ? NSFontManager.shared.convert(next,toHaveTrait:.italicFontMask):next
        }
        if let control=view as? NSControl,let current=control.font {let next=converted(current);if !current.isEqual(next) {control.font=next}}
        if let text=view as? NSTextView,let current=text.font {let next=converted(current);if !current.isEqual(next) {text.font=next}}
        for child in view.subviews {apply(to:child)}
    }
}

/// Window paint is separate from the profile's icon gradient and saved wallpaper.
struct BrowserWindowStyle: Codable, Equatable {
    enum Background: Int, Codable, CaseIterable {
        case wallpaper, solid, gradient

        var title: String {
            switch self {
            case .wallpaper: return "Wallpaper & Glass"
            case .solid: return "Solid Color"
            case .gradient: return "Two-Color Gradient"
            }
        }
    }

    enum Direction: Int, Codable, CaseIterable {
        case down, across, diagonal

        var title: String {
            switch self {
            case .down: return "Top to Bottom"
            case .across: return "Left to Right"
            case .diagonal: return "Diagonal"
            }
        }
    }

    var background: Background = .wallpaper
    var start = "#A4AF96"
    var end = "#C6B7A8"
    var direction: Direction = .diagonal

    static let insetKey = "webbyInsetWebsiteFrame"
    static var inset: Bool {
        UserDefaults.standard.object(forKey: insetKey) as? Bool ?? true
    }

    static func load(for profile: UUID) -> Self {
        guard let data = UserDefaults.standard.data(forKey: key(for: profile)) else { return Self() }
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }

    func save(for profile: UUID) {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key(for: profile))
        }
    }

    static func key(for profile: UUID) -> String { "webbyWindowStyle.\(profile.uuidString)" }

    var hasColor: Bool { background != .wallpaper }

    @MainActor var colors: [NSColor] {
        background == .solid ? [BrowserTheme.color(start), BrowserTheme.color(start)]
            : [BrowserTheme.color(start), BrowserTheme.color(end)]
    }

    @MainActor private var chromeColors: [NSColor] {
        colors.map { $0.blended(withFraction: 0.10, of: .black) ?? $0 }
    }

    @MainActor var representativeColor: NSColor {
        let stops = chromeColors
        return stops[0].blended(withFraction: 0.5, of: stops[1]) ?? stops[0]
    }

    @MainActor var usesDarkText: Bool {
        let rgb = representativeColor
        return rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722 > 0.55
    }

    @MainActor func paint(_ layer: CAGradientLayer) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.colors = chromeColors.map(\.cgColor)
        switch direction {
        case .down: (layer.startPoint, layer.endPoint) = (CGPoint(x: 0.5, y: 1), CGPoint(x: 0.5, y: 0))
        case .across: (layer.startPoint, layer.endPoint) = (CGPoint(x: 0, y: 0.5), CGPoint(x: 1, y: 0.5))
        case .diagonal: (layer.startPoint, layer.endPoint) = (CGPoint(x: 1, y: 1), .zero)
        }
        CATransaction.commit()
    }
}

@MainActor final class BrowserWindowStyleEditor: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 394, height: 294),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let background = NSPopUpButton()
    private let direction = NSPopUpButton()
    private let start = NSColorWell()
    private let end = NSColorWell()
    private let preview = CAGradientLayer()
    private let previewPage = CALayer()
    private let inset = NSButton(checkboxWithTitle: "Inset website frame", target: nil, action: nil)
    private var profile: UUID?
    var onApply: (() -> Void)?

    override init() {
        super.init()
        panel.isReleasedWhenClosed = false
        guard let root = panel.contentView else { return }

        let previewHost = NSView(frame: NSRect(x: 22, y: 182, width: 350, height: 90))
        previewHost.wantsLayer = true
        previewHost.layer?.cornerRadius = 12
        previewHost.layer?.masksToBounds = true
        preview.frame = previewHost.bounds
        previewHost.layer?.addSublayer(preview)
        previewPage.cornerRadius = 7
        preview.addSublayer(previewPage)
        root.addSubview(previewHost)

        func label(_ title: String, x: CGFloat, y: CGFloat) {
            let field = NSTextField(labelWithString: title)
            field.textColor = .secondaryLabelColor
            field.frame = NSRect(x: x, y: y, width: 100, height: 18)
            root.addSubview(field)
        }
        label("Background", x: 22, y: 144)
        background.frame = NSRect(x: 125, y: 137, width: 247, height: 28)
        background.addItems(withTitles: BrowserWindowStyle.Background.allCases.map(\.title))
        label("Colors", x: 22, y: 108)
        start.frame = NSRect(x: 125, y: 101, width: 55, height: 27)
        end.frame = NSRect(x: 189, y: 101, width: 55, height: 27)
        start.setAccessibilityLabel("Start color")
        end.setAccessibilityLabel("End color")
        direction.frame = NSRect(x: 249, y: 101, width: 123, height: 27)
        direction.addItems(withTitles: BrowserWindowStyle.Direction.allCases.map(\.title))
        inset.frame = NSRect(x: 22, y: 62, width: 350, height: 25)
        for control: NSControl in [background, direction, start, end, inset] {
            control.target = self
            control.action = #selector(updatePreview)
            root.addSubview(control)
        }
        let apply = NSButton(title: "Apply", target: self, action: #selector(apply))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        apply.frame = NSRect(x: 285, y: 17, width: 87, height: 30)
        root.addSubview(apply)
    }

    func open(profile: UUID, name: String) {
        self.profile = profile
        let style = BrowserWindowStyle.load(for: profile)
        background.selectItem(at: style.background.rawValue)
        direction.selectItem(at: style.direction.rawValue)
        start.color = BrowserTheme.color(style.start)
        end.color = BrowserTheme.color(style.end)
        inset.state = BrowserWindowStyle.inset ? .on : .off
        panel.title = "Window Appearance · \(name)"
        updatePreview()
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private var style: BrowserWindowStyle {
        BrowserWindowStyle(background: BrowserWindowStyle.Background(rawValue: background.indexOfSelectedItem) ?? .wallpaper,
                           start: BrowserTheme.hex(start.color), end: BrowserTheme.hex(end.color),
                           direction: BrowserWindowStyle.Direction(rawValue: direction.indexOfSelectedItem) ?? .diagonal)
    }

    @objc private func updatePreview() {
        var sample = style
        start.isEnabled = sample.hasColor
        end.isEnabled = sample.background == .gradient
        direction.isEnabled = end.isEnabled
        if !sample.hasColor {
            sample.start = "#323842"
            sample.end = "#22242C"
        }
        sample.paint(preview)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let gap: CGFloat = inset.state == .on ? 6 : 0
        previewPage.frame = CGRect(x: 64 + gap, y: gap, width: 286 - 2 * gap, height: 90 - 2 * gap)
        previewPage.cornerRadius = gap == 0 ? 0 : 7
        previewPage.backgroundColor = NSColor(white: 1, alpha: 0.86).cgColor
        CATransaction.commit()
    }

    @objc private func apply() {
        guard let profile else { return }
        style.save(for: profile)
        UserDefaults.standard.set(inset.state == .on, forKey: BrowserWindowStyle.insetKey)
        onApply?()
        panel.close()
    }
}
