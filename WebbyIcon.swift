import AppKit

@MainActor private final class WebbyDockTileView: NSView {
    var icon: NSImage?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        icon?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

@MainActor private final class WebbyDockAnimator {
    private let tileView = WebbyDockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    private var frames: [NSImage] = []
    private var durations: [TimeInterval] = []
    private var index = 0
    private var timer: Timer?

    func configure(profile: PetGradientProfile, petID: String, customPetURL: URL?) {
        timer?.invalidate()
        index = 0
        if customPetURL != nil {
            frames = [WebbyIcon.image(profile: profile, petID: petID, customPetURL: customPetURL)]
            durations = []
        } else {
            let allDurations: [String: [Int]] = {
                guard let url = Bundle.main.url(forResource: "durations", withExtension: "json", subdirectory: "PetsWorking"),
                      let data = try? Data(contentsOf: url) else { return [:] }
                return (try? JSONDecoder().decode([String: [Int]].self, from: data)) ?? [:]
            }()
            let millis = allDurations[petID] ?? [120]
            durations = millis.map { max(0.09, TimeInterval($0) / 1000) }
            frames = millis.indices.map { WebbyIcon.image(profile: profile, petID: petID, frameIndex: $0) }
        }
        tileView.icon = frames.first
        NSApplication.shared.applicationIconImage = frames.first
        NSApplication.shared.dockTile.contentView = tileView
        NSApplication.shared.dockTile.display()
        scheduleNext()
    }

    private func scheduleNext() {
        guard frames.count > 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        timer = Timer.scheduledTimer(withTimeInterval: durations[index], repeats: false) { [weak self] _ in
            guard let self else { return }
            self.index = (self.index + 1) % self.frames.count
            self.tileView.icon = self.frames[self.index]
            self.tileView.needsDisplay = true
            NSApplication.shared.dockTile.display()
            self.scheduleNext()
        }
    }
}

@MainActor final class WebbyMenuPetAnimator: NSObject {
    private weak var button: NSStatusBarButton?
    private var frames: [NSImage] = []
    private var durations: [TimeInterval] = []
    private var index = 0
    private var timer: Timer?
    private var sleeping = false

    init(button: NSStatusBarButton) {
        self.button = button
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(configure),
            name: .browserThemeChanged, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(sleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(wake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(motionChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        configure()
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func configure() {
        timer?.invalidate(); timer = nil; index = 0
        let petID = BrowserTheme.petID
        let custom = BrowserTheme.customPetURL
        let allDurations: [String: [Int]] = {
            guard let url = Bundle.main.url(forResource: "durations", withExtension: "json", subdirectory: "PetsWorking"),
                  let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONDecoder().decode([String: [Int]].self, from: data)) ?? [:]
        }()
        let millis = custom == nil ? (allDurations[petID] ?? [120]) : [120]
        durations = millis.map { max(0.09, TimeInterval($0) / 1000) }
        frames = millis.indices.compactMap { frame in
            let animated = Bundle.main.url(forResource: String(frame), withExtension: "png", subdirectory: "PetsWorking/\(petID)")
            let fallback = Bundle.main.url(forResource: petID, withExtension: "png", subdirectory: "Pets")
            guard let source = (custom ?? animated ?? fallback).flatMap(NSImage.init(contentsOf:)),
                  source.size.width > 0, source.size.height > 0,
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 44,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            // Rasterize once at Retina menu-bar size; each tick only swaps an image.
            let scale = min(48 / source.size.width, 44 / source.size.height)
            let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 48, height: 44))
            source.draw(in: NSRect(x: (48-size.width)/2, y: (44-size.height)/2,
                                  width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: NSSize(width: 24, height: 22))
            image.addRepresentation(bitmap); image.isTemplate = false
            return image
        }
        button?.image = frames.first
        button?.contentTintColor = nil
        scheduleNext()
    }

    @objc private func sleep() { sleeping = true; timer?.invalidate(); timer = nil }
    @objc private func wake() { sleeping = false; scheduleNext() }
    @objc private func motionChanged() {
        timer?.invalidate(); timer = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            index = 0; button?.image = frames.first
        } else { scheduleNext() }
    }

    private func scheduleNext() {
        timer?.invalidate(); timer = nil
        guard !sleeping, frames.count > 1, button != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let next = Timer(timeInterval: durations[min(index, durations.count-1)], repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.sleeping else { return }
                self.index = (self.index + 1) % self.frames.count
                self.button?.image = self.frames[self.index]
                self.scheduleNext()
            }
        }
        next.tolerance = 0.02
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
}

@MainActor enum WebbyIcon {
    private static let animator = WebbyDockAnimator()

    static func image(profile: PetGradientProfile, petID: String,
                      customPetURL: URL? = nil, frameIndex: Int = 0) -> NSImage {
        let sky = Bundle.main.url(forResource: "SkyBackground", withExtension: "png")
            .flatMap(NSImage.init(contentsOf:))
        let workingFrame = Bundle.main.url(forResource: String(frameIndex), withExtension: "png",
                                            subdirectory: "PetsWorking/\(petID)")
        let fallback = Bundle.main.url(forResource: petID, withExtension: "png", subdirectory: "Pets")
        let pet = (customPetURL ?? workingFrame ?? fallback).flatMap(NSImage.init(contentsOf:))
        return NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            // macOS app icons have a transparent safety area within the 1024-point canvas.
            context.translateBy(x: 94, y: 94)
            context.scaleBy(x: 836 / 1024, y: 836 / 1024)
            let artwork = CGRect(x: 0, y: 0, width: 1024, height: 1024)
            context.addPath(CGPath(roundedRect: artwork.insetBy(dx: 3, dy: 3),
                                   cornerWidth: 188, cornerHeight: 188, transform: nil))
            context.clip()
            sky?.draw(in: artwork, from: .zero, operation: .sourceOver, fraction: 1)
            context.setBlendMode(.color)
            context.setFillColor(BrowserTheme.color(profile.palette.primary, alpha: 0.52).cgColor)
            context.fill(artwork)
            context.setBlendMode(.normal)
            context.setFillColor(NSColor.black.withAlphaComponent(0.25).cgColor)
            context.fillEllipse(in: CGRect(x: 240, y: 18, width: 544, height: 76))
            pet?.draw(in: CGRect(x: 270, y: 58, width: 484, height: 524),
                      from: .zero, operation: .sourceOver, fraction: 1,
                      respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
            context.restoreGState()
            return true
        }
    }

    static func updateDockIcon() {
        animator.configure(profile: BrowserTheme.profile, petID: BrowserTheme.petID,
                           customPetURL: BrowserTheme.customPetURL)
    }

    static func writeDefaultPNG(to url: URL) throws {
        guard let data = image(profile: BrowserTheme.profile, petID: BrowserTheme.petID).tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WebbyIcon", code: 1)
        }
        try png.write(to: url, options: .atomic)
    }
}
