import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct WebbyChromeSelection: Sendable {
    var passwords = false
    var cookies = false
}

struct WebbyChromePayload {
    let space: SavedBrowserSpace
    var passwords: [BrowserCredential] = []
    var cookies: [HTTPCookie] = []
    var issues: [String] = []
    var hasReadableData = false

    static func read(_ source: ChromeProfileSource, id: UUID) -> Self {
        var bookmarks: [BrowserLink] = []
        var history: [BrowserLink] = []
        var issues: [String] = []
        var readable = false
        do {
            bookmarks = try ChromeProfileImporter.checkedBookmarks(source.url.appendingPathComponent("Bookmarks"))
            readable = true
        } catch { issues.append("Bookmarks: " + error.localizedDescription) }
        do {
            history = try ChromeProfileImporter.checkedHistory(source.url.appendingPathComponent("History"))
            readable = true
        } catch { issues.append("History: " + error.localizedDescription) }
        return Self(space: .init(id: id, name: source.name, chromeDirectory: source.directory,
                                        bookmarks: bookmarks, history: history), issues: issues, hasReadableData: readable)
    }

    mutating func readProtected(_ source: ChromeProfileSource, selection: WebbyChromeSelection,
                                key: Result<Data, Error>) {
        do {
            let unlocked = try key.get()
            if selection.passwords {
                do { passwords = try BrowserPasswords.readChromePasswords(from: source, key: unlocked); hasReadableData = true }
                catch { issues.append("Passwords: " + error.localizedDescription) }
            }
            if selection.cookies {
                do { cookies = try ChromeSessions.readCookies(from: source, key: unlocked); hasReadableData = true }
                catch { issues.append("Cookies: " + error.localizedDescription) }
            }
        } catch { issues.append("Chrome protected data: " + error.localizedDescription) }
    }
}

struct WebbyChromeResult {
    var spaces: [WebbyOnboardingDraft.Space] = []
    var bookmarks = 0
    var history = 0
    var passwords = 0
    var cookies = 0
    var issues: [String] = []
    var retryChrome: Set<String> = []

    var summary: String {
        guard !spaces.isEmpty else { return "No profiles were imported." }
        return "\(spaces.count) profiles · \(bookmarks) bookmarks · \(history) history entries · \(passwords) passwords · \(cookies) cookies"
    }
}

extension WallpaperSettings {
    init(onboarding draft: WebbyOnboardingDraft) {
        path = draft.backgroundPath
        effect = draft.effect
        fade = draft.fade
        start = draft.fadeStart
        end = draft.fadeEnd
        blur = draft.blur
        opacity = draft.opacity
        pageOpacity = draft.pageOpacity
        homeOnly = draft.homeOnly
        soften = draft.soften
        fit = draft.fit
        motion = draft.wallpaperMotion
        normalize()
    }
}

extension BrowserWallpaperView {
    nonisolated static func prepareOnboardingWallpaper(_ draft: WebbyOnboardingDraft, colors: [String]) throws -> WallpaperSettings {
        var settings = WallpaperSettings(onboarding: draft)
        if draft.background == "clean" { settings.path = nil; return settings }
        let source = draft.backgroundPath.map { URL(fileURLWithPath: $0) }
        let type = try source?.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type?.conforms(to: .html) == true, let source {
            guard FileManager.default.isReadableFile(atPath: source.path) else { throw CocoaError(.fileReadNoPermission) }
            settings.kind = "html"
            return settings
        }
        settings.kind = type?.conforms(to: .movie) == true ? "video" : "image"
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebbyBackgrounds/\(draft.selectedSpace.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let source, source.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {
            return settings
        }
        let target = folder.appendingPathComponent(draft.backgroundID.uuidString)
            .appendingPathExtension(source?.pathExtension ?? "png")
        if let source {
            if !FileManager.default.fileExists(atPath: target.path) {
                let temporary = folder.appendingPathComponent(UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try FileManager.default.copyItem(at: source, to: temporary)
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        } else {
            guard let image = onboardingAtmosphere(colors, width: 900, height: 540) else { throw CocoaError(.fileWriteUnknown) }
            let data = NSMutableData()
            guard let output = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            CGImageDestinationAddImage(output, image, nil)
            guard CGImageDestinationFinalize(output) else { throw CocoaError(.fileWriteUnknown) }
            try (data as Data).write(to: target, options: .atomic)
        }
        settings.path = target.path
        return settings
    }

    static func saveOnboardingWallpaper(_ settings: WallpaperSettings, draft: WebbyOnboardingDraft) throws {
        let defaults = UserDefaults.standard
        let suffix = draft.selectedSpace.uuidString
        let encoded = try JSONEncoder().encode(settings)
        // Copy the active pair before editing so saving a new look preserves the original.
        if draft.saveLook { WallpaperSetStore.duplicate(name: "My Webby", id: draft.backgroundID) }
        defaults.set(encoded, forKey: WallpaperSetStore.prefixes[0] + suffix)
        defaults.set(draft.fullWindow, forKey: WallpaperSetStore.prefixes[1] + suffix)
        defaults.set(draft.frostScope, forKey: WallpaperSetStore.prefixes[2] + suffix)
        defaults.set(draft.frostStrength, forKey: WallpaperSetStore.prefixes[3] + suffix)
        WallpaperSetStore.update()
        NotificationCenter.default.post(name: Notification.Name("WebbyWallpaperSetChanged"), object: nil)
    }
}

extension WebbyOnboardingDraft {
    mutating func readWallpaper() {
        let defaults = UserDefaults.standard
        let suffix = selectedSpace.uuidString
        let prefixes = WallpaperSetStore.prefixes
        let settings = defaults.data(forKey: prefixes[0] + suffix)
            .flatMap { try? JSONDecoder().decode(WallpaperSettings.self, from: $0) } ?? WallpaperSettings()
        backgroundPath = settings.path
        background = settings.path == nil ? "clean" : "file"
        effect = settings.effect
        fade = settings.fade
        fadeStart = settings.start
        fadeEnd = settings.end
        blur = settings.blur
        opacity = settings.opacity
        pageOpacity = settings.pageOpacity
        fit = settings.fit
        soften = settings.soften
        homeOnly = settings.homeOnly
        wallpaperMotion = settings.motion
        fullWindow = defaults.bool(forKey: prefixes[1] + suffix)
        frostScope = defaults.object(forKey: prefixes[2] + suffix) as? Int ?? 1
        frostStrength = defaults.object(forKey: prefixes[3] + suffix) as? Double ?? 0.85
    }
}

@MainActor final class WebbyOnboarding: NSObject, ObservableObject {
    enum Asset { case wallpaper, pet, icon }
    @Published var draft: WebbyOnboardingDraft {
        didSet { if firstRun { draft.save() } }
    }
    @Published var sources: [ChromeProfileSource] = []
    @Published var scanning = false
    @Published var selectedSources: Set<String> = []
    @Published var importExpanded = false
    @Published var importOptions = WebbyChromeSelection()
    @Published var busy: String?
    @Published var feedback: String?
    @Published var importFeedback: String?
    @Published var issues: [String] = []
    @Published var linkStatus: String?
    @Published var defaultBrowser = false
    @Published var wallpaperImage: CGImage?
    @Published var editingGlass = true
    @Published var reveal = false
    @Published var demo = 0
    @Published var demoPlaying = false

    let firstRun: Bool
    private let discoverChrome: @Sendable () -> [ChromeProfileSource]
    private let importedDirectories: () -> Set<String>
    private let installImports: ([WebbyChromePayload]) async throws -> WebbyChromeResult
    private let apply: (WebbyOnboardingDraft) async throws -> Void
    private let done: (Bool) -> Void
    private weak var window: NSWindow?
    private var overlay: NSView?
    private weak var previousResponder: NSResponder?
    private var detectedChrome = false
    private var wallpaperTask: Task<Void, Never>?
    private var posterPath: String?
    private var posterImage: CGImage?

    init(draft: WebbyOnboardingDraft, firstRun: Bool,
         discoverChrome: @escaping @Sendable () -> [ChromeProfileSource] = { ChromeProfileImporter.availableProfiles() },
         importedDirectories: @escaping () -> Set<String>,
         installImports: @escaping ([WebbyChromePayload]) async throws -> WebbyChromeResult,
         apply: @escaping (WebbyOnboardingDraft) async throws -> Void,
         done: @escaping (Bool) -> Void) {
        self.draft = draft
        self.firstRun = firstRun
        self.discoverChrome = discoverChrome
        self.importedDirectories = importedDirectories
        self.installImports = installImports
        self.apply = apply
        self.done = done
        super.init()
        if firstRun { draft.save() }
        if draft.importInterrupted {
            importFeedback = "An import was interrupted. Saved profiles were kept. You can retry or continue with setup."
        }
    }

    func show(over browser: NSWindow) {
        if overlay != nil { browser.makeKeyAndOrderFront(nil); return }
        guard let content = browser.contentView else { return }
        let cover = NSView(frame: content.bounds)
        cover.wantsLayer = true
        cover.layer?.backgroundColor = BrowserTheme.color("#10121A").cgColor
        cover.autoresizingMask = [.width, .height]
        cover.setAccessibilityIdentifier("WebbyOnboarding")
        let host = NSHostingView(rootView: WebbyOnboardingView(model: self))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = cover.bounds
        host.autoresizingMask = [.width, .height]
        cover.addSubview(host)
        previousResponder = browser.firstResponder
        window = browser
        overlay = cover
        content.addSubview(cover, positioned: .above, relativeTo: nil)
        browser.makeKeyAndOrderFront(nil)
        browser.makeFirstResponder(host)
        prepareStep()
        refreshWallpaper()
    }

    var isPresented: Bool { overlay != nil }

    func next() {
        guard busy == nil else { return }
        if draft.step == .ready { finish(); return }
        if draft.step == .tour { draft.toured = true }
        feedback = nil
        draft.advance()
        prepareStep()
    }

    func back() {
        guard busy == nil else { return }
        feedback = nil
        draft.back()
        prepareStep()
    }

    func jump(to step: WebbyOnboardingStep) {
        guard !firstRun, busy == nil else { return }
        feedback = nil
        draft.step = step
        prepareStep()
    }

    func skipTour() {
        guard busy == nil else { return }
        draft.advance()
        prepareStep()
    }

    func skip() {
        guard busy == nil else { return }
        if firstRun { draft.phase = .skipped }
        dismiss(completed: false)
    }

    func selectSpace(_ id: UUID) {
        guard draft.selectedSpace != id else { return }
        draft.selectedSpace = id
        draft.search = BrowserSearchEngine.selected(for: id).rawValue
        let profileOpacity = BrowserGlass.widgetOpacity(profile: id)
        draft.originalGlass?.widgets = profileOpacity
        draft.glass?.widgets = profileOpacity
        draft.widgetFrames = WidgetCanvas.onboardingFrames(for: id)
        draft.widgetEdits = nil
        if !draft.themeChanged {
            let appearance = BrowserTheme.onboardingAppearance(for: id)
            draft.theme = appearance.pet
            draft.customColors = appearance.colors
            draft.petPath = appearance.petURL?.path
        }
        if !draft.backgroundChanged { draft.readWallpaper(); refreshWallpaper() }
        if !draft.widgetsChanged {
            draft.widgets = WidgetCanvas.onboardingWidgets(for: id)?.map(\.rawValue) ?? []
            draft.widgetPreset = draft.widgets.isEmpty ? "Minimal" : "Current canvas"
        }
    }

    func addSpace(named name: String = "Work") {
        let space = WebbyOnboardingDraft.Space(id: UUID(), name: name, isNew: true)
        draft.spaces.append(space)
    }

    func removeSpace(_ id: UUID) {
        guard draft.spaces.first(where: { $0.id == id })?.isNew == true else { return }
        if draft.selectedSpace == id, let first = draft.spaces.first(where: { $0.id != id }) {
            draft.selectedSpace = first.id
        }
        if draft.externalProfile == id { draft.externalProfile = nil }
        draft.spaces.removeAll { $0.id == id }
        if draft.spaces.count < 2 { draft.fuse = false }
    }

    private func prepareStep() {
        demoPlaying = false
        if draft.step == .links { defaultBrowser = BrowserExternalLinks.isDefault }
        guard draft.step == .migration, !detectedChrome else { return }
        detectedChrome = true
        scanning = true
        let alreadyImported = importedDirectories()
        let retry = draft.importInterrupted ? Set(draft.importIDs.keys).union(draft.retryChrome) : draft.retryChrome
        let discover = discoverChrome
        Task {
            let found = await Task.detached(priority: .utility, operation: discover).value
            sources = found.filter { !alreadyImported.contains($0.directory) || retry.contains($0.directory) }
            selectedSources = Set(sources.map(\.directory))
            scanning = false
        }
    }

    func importChrome() {
        guard busy == nil else { return }
        let selected = sources.filter { selectedSources.contains($0.directory) }
        guard !selected.isEmpty else { return }
        for source in selected where draft.importIDs[source.directory] == nil {
            draft.importIDs[source.directory] = UUID()
        }
        let ids = draft.importIDs
        let options = importOptions
        draft.importInterrupted = true
        issues = []
        importFeedback = nil
        busy = "Reading bookmarks and history"
        Task {
            let payloads = await Task.detached(priority: .userInitiated) {
                selected.compactMap { source in
                    ids[source.directory].map { WebbyChromePayload.read(source, id: $0) }
                }
            }.value
            var prepared = payloads
            if options.passwords || options.cookies {
                busy = "Accessing the Chrome data you selected"
                prepared = await Task.detached(priority: .userInitiated) {
                    let key = Result { try ChromeSessions.encryptionKey() }
                    return zip(selected, payloads).map { source, payload in
                        var result = payload
                        result.readProtected(source, selection: options, key: key)
                        return result
                    }
                }.value
            }
            busy = "Installing the selected profiles"
            do {
                let result = try await installImports(prepared)
                let known = Set(draft.spaces.map(\.id))
                draft.spaces += result.spaces.filter { !known.contains($0.id) }
                if let imported = result.spaces.first { selectSpace(imported.id) }
                draft.importInterrupted = false
                draft.retryChrome.subtract(selected.map(\.directory))
                draft.retryChrome.formUnion(result.retryChrome)
                issues = result.issues
                importFeedback = result.summary
                let imported = importedDirectories()
                sources.removeAll { imported.contains($0.directory) && !draft.retryChrome.contains($0.directory) }
            } catch {
                issues = [error.localizedDescription]
                importFeedback = "Import could not finish. You can try again or continue."
            }
            busy = nil
        }
    }

    func requestDefaultBrowser() {
        guard busy == nil, !defaultBrowser else { return }
        draft.defaultDecision = "requested"
        busy = "Waiting for macOS"
        BrowserExternalLinks.requestDefault { [weak self] error in
            guard let self else { return }
            self.busy = nil
            self.defaultBrowser = BrowserExternalLinks.isDefault
            self.draft.defaultDecision = self.defaultBrowser ? "accepted" : "later"
            self.linkStatus = self.defaultBrowser ? "Webby is your default browser." :
                (error?.localizedDescription ?? "macOS hasn’t switched the default browser.")
        }
    }

    func chooseFile(_ asset: Asset) {
        guard let window, busy == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowedContentTypes = switch asset {
        case .wallpaper: [.image, .movie, .html]
        case .pet: [.png, .jpeg, .webP]
        case .icon: [.image, .svg]
        }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task { await self.loadFile(url, asset: asset) }
        }
    }

    func selectWallpaperDesign(_ design: OnboardingWallpaperDesign) {
        if draft.background != "atmosphere" || draft.wallpaperDesign != design { draft.backgroundID = UUID() }
        draft.wallpaperDesign = design
        selectBackground("atmosphere")
    }

    func selectBackground(_ choice: String) {
        draft.background = choice
        draft.backgroundChanged = true
        if choice != "file" { draft.backgroundPath = nil }
        refreshWallpaper()
    }

    func refreshWallpaper() {
        wallpaperTask?.cancel()
        guard draft.background != "clean" else { wallpaperImage = nil; return }
        let settings = WallpaperSettings(onboarding: draft)
        let palette = BrowserTheme.onboardingProfile(draft.theme, colors: draft.customColors).palette
        let colors = (draft.wallpaperDesign ?? .profile).colors(profile: [palette.shadow, palette.secondary, palette.primary])
        let path = draft.backgroundPath
        let atmosphere = draft.background == "atmosphere"
        wallpaperTask = Task {
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled else { return }
            let source: CGImage?
            if atmosphere {
                source = await Task.detached(priority: .utility) {
                    BrowserWallpaperView.onboardingAtmosphere(colors, width: 576, height: 336)
                }.value
            } else if let path {
                if posterPath == path { source = posterImage }
                else {
                    source = try? await Self.poster(for: URL(fileURLWithPath: path))
                    guard !Task.isCancelled else { return }
                    posterPath = path
                    posterImage = source
                }
            } else { source = nil }
            let processed = await Task.detached(priority: .utility) {
                source.flatMap { BrowserWallpaperView.onboardingPreview($0, settings: settings) }
            }.value
            guard !Task.isCancelled else { return }
            wallpaperImage = processed ?? source
        }
    }

    private func loadFile(_ url: URL, asset: Asset) async {
        busy = "Checking " + url.lastPathComponent
        feedback = nil
        do {
            switch asset {
            case .wallpaper:
                let poster = try await Self.poster(for: url)
                posterPath = url.path
                posterImage = poster
                draft.backgroundPath = url.path
                draft.background = "file"
                draft.backgroundChanged = true
                draft.backgroundID = UUID()
                refreshWallpaper()
            case .pet, .icon:
                let valid = await Task.detached(priority: .utility) { () -> Bool in
                    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size <= 32 * 1024 * 1024 else { return false }
                    return NSImage(contentsOf: url)?.isValid == true
                }.value
                guard valid else { throw CocoaError(.fileReadCorruptFile) }
                if asset == .pet { draft.petPath = url.path; draft.themeChanged = true }
                else { draft.iconPath = url.path; draft.iconMode = "image" }
            }
        } catch { feedback = "Couldn’t use that file. " + error.localizedDescription }
        busy = nil
    }

    nonisolated private static func poster(for url: URL) async throws -> CGImage? {
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let type = values.contentType else { throw CocoaError(.fileReadUnsupportedScheme) }
        if type.conforms(to: .html) {
            guard (values.fileSize ?? 0) > 0, FileManager.default.isReadableFile(atPath: url.path) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return nil // Do not execute local HTML inside the preview.
        }
        if type.conforms(to: .movie) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 720, height: 480)
            return try await generator.image(at: .zero).image
        }
        guard type.conforms(to: .image), (values.fileSize ?? 0) <= 32 * 1024 * 1024,
              let image = await Task.detached(priority: .utility, operation: {
                  CGImageSourceCreateWithURL(url as CFURL, nil).flatMap {
                      CGImageSourceCreateThumbnailAtIndex($0, 0, [
                          kCGImageSourceCreateThumbnailFromImageAlways: true,
                          kCGImageSourceCreateThumbnailWithTransform: true,
                          kCGImageSourceThumbnailMaxPixelSize: 720
                      ] as CFDictionary)
                  }
              }).value else { throw CocoaError(.fileReadCorruptFile) }
        return image
    }

    private func finish() {
        busy = "Applying your choices"
        feedback = nil
        Task {
            do {
                try await apply(draft)
                if firstRun { draft.phase = .completed }
                reveal = true
                if draft.animatedDetails && Motion.enabled {
                    try? await Task.sleep(for: .milliseconds(420))
                }
                dismiss(completed: true)
            } catch {
                feedback = error.localizedDescription
                busy = nil
            }
        }
    }

    private func dismiss(completed: Bool) {
        wallpaperTask?.cancel()
        overlay?.removeFromSuperview()
        overlay = nil
        if let previousResponder { window?.makeFirstResponder(previousResponder) }
        window = nil
        done(completed)
    }
}
