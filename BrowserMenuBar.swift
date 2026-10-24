import AppKit
import UniformTypeIdentifiers

extension Notification.Name {
    static let browserSearchEngineChanged = Notification.Name("BrowserSearchEngineChanged")
}

enum BrowserSearchEngine: String, CaseIterable {
    case google, duckDuckGo, bing, brave, ecosia

    var name: String {
        switch self {
        case .google: "Google"
        case .duckDuckGo: "DuckDuckGo"
        case .bing: "Bing"
        case .brave: "Brave Search"
        case .ecosia: "Ecosia"
        }
    }

    var searchBase: String {
        switch self {
        case .google: "https://www.google.com/search"
        case .duckDuckGo: "https://duckduckgo.com/"
        case .bing: "https://www.bing.com/search"
        case .brave: "https://search.brave.com/search"
        case .ecosia: "https://www.ecosia.org/search"
        }
    }

    static func selected(for profile: UUID) -> Self {
        Self(rawValue: UserDefaults.standard.string(forKey: "webbySearchEngine.\(profile.uuidString)") ?? "google") ?? .google
    }

    static func set(_ engine: Self, for profile: UUID) {
        UserDefaults.standard.set(engine.rawValue, forKey: "webbySearchEngine.\(profile.uuidString)")
    }
}

@MainActor enum BrowserTabPlacement: String {
    case top, bottom, horizontal
    static var current: Self {
        get { Self(rawValue: UserDefaults.standard.string(forKey: "webbyTabStackPlacement") ?? "top") ?? .top }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "webbyTabStackPlacement") }
    }
}

@MainActor enum BrowserExperiment {
    static var cyclesNewTabProfiles: Bool {
        get { UserDefaults.standard.bool(forKey: "webbyExperimentalProfileCycle") }
        set { UserDefaults.standard.set(newValue, forKey: "webbyExperimentalProfileCycle") }
    }

    static var fuseScene: String {
        let saved = UserDefaults.standard.string(forKey: "webbyFuseIndicator") ?? "agents"
        return IndicatorScenes.all[saved] == nil ? "agents" : saved
    }
    static func setFuseScene(_ scene: String) {
        guard IndicatorScenes.all[scene] != nil else { return }
        UserDefaults.standard.set(scene, forKey: "webbyFuseIndicator")
    }

    static func scene(for spaceID: UUID, index: Int = 0) -> String {
        let fallback = index == 0 ? "search" : IndicatorScenes.cycleIDs[(index * 3) % IndicatorScenes.cycleIDs.count]
        let saved = UserDefaults.standard.string(forKey: "webbyIndicator.\(spaceID.uuidString)") ?? fallback
        return IndicatorScenes.all[saved] == nil ? "search" : saved
    }

    static func setScene(_ scene: String, for spaceID: UUID) {
        guard IndicatorScenes.all[scene] != nil else { return }
        UserDefaults.standard.set(scene, forKey: "webbyIndicator.\(spaceID.uuidString)")
    }
}

@MainActor final class BrowserMenuBar: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private var petAnimator: WebbyMenuPetAnimator?
    private let showBrowser: () -> Void
    private let addWidget: () -> Void
    private let resetWidgets: () -> Void
    private let asciiCanvas: () -> ASCIIBackgroundCanvas?
    private let openWallpaper: () -> Void
    private let miniMenu: () -> NSMenu
    private let currentSpaceName: () -> String
    private let currentSpaceID: () -> UUID
    private let importChrome: () -> Void
    private let deleteProfile: () -> Void
    private let openBookmarks: () -> Void
    private let openHistory: () -> Void
    private let importPasswords: () -> Void
    private let showPasswords: () -> Void
    private let importSignIns: () -> Void
    private let fillPassword: () -> Void
    private let profiles: () -> [(UUID, String)]
    private let openTerminal: () -> Void
    private let experimentChanged: () -> Void
    private let tabPlacementChanged: () -> Void
    private let chooseGoogleClient: () -> Void
    private let connectGoogle: (GoogleService) -> Void
    private let disconnectGoogle: (GoogleService) -> Void
    private let googleConnected: (GoogleService) -> Bool
    private var settingsWindow: NSWindow?
    private var colorWells: [NSColorWell] = []
    private var preview = CAGradientLayer()

    init(showBrowser: @escaping () -> Void, addWidget: @escaping () -> Void,
         resetWidgets: @escaping () -> Void,
         currentSpaceName: @escaping () -> String, currentSpaceID: @escaping () -> UUID,
         importChrome: @escaping () -> Void,
         deleteProfile: @escaping () -> Void,
         openBookmarks: @escaping () -> Void, openHistory: @escaping () -> Void,
         importPasswords: @escaping () -> Void, showPasswords: @escaping () -> Void,
         importSignIns: @escaping () -> Void, fillPassword: @escaping () -> Void,
         profiles: @escaping () -> [(UUID, String)], openTerminal: @escaping () -> Void,
         experimentChanged: @escaping () -> Void,
         tabPlacementChanged: @escaping () -> Void,
         chooseGoogleClient: @escaping () -> Void,
         connectGoogle: @escaping (GoogleService) -> Void,
         disconnectGoogle: @escaping (GoogleService) -> Void,
         googleConnected: @escaping (GoogleService) -> Bool,
         asciiCanvas: @escaping () -> ASCIIBackgroundCanvas? = { nil },
         openWallpaper: @escaping () -> Void = {},
         miniMenu: @escaping () -> NSMenu = { NSMenu(title:"Mini Webby") }) {
        self.showBrowser = showBrowser
        self.addWidget = addWidget
        self.resetWidgets = resetWidgets
        self.asciiCanvas = asciiCanvas
        self.openWallpaper = openWallpaper
        self.miniMenu = miniMenu
        self.currentSpaceName = currentSpaceName
        self.currentSpaceID = currentSpaceID
        self.importChrome = importChrome
        self.deleteProfile = deleteProfile
        self.openBookmarks = openBookmarks
        self.openHistory = openHistory
        self.importPasswords = importPasswords
        self.showPasswords = showPasswords
        self.importSignIns = importSignIns
        self.fillPassword = fillPassword
        self.profiles = profiles
        self.openTerminal = openTerminal
        self.experimentChanged = experimentChanged
        self.tabPlacementChanged = tabPlacementChanged
        self.chooseGoogleClient = chooseGoogleClient
        self.connectGoogle = connectGoogle
        self.disconnectGoogle = disconnectGoogle
        self.googleConnected = googleConnected
        statusItem = NSStatusBar.system.statusItem(withLength: 30)
        super.init()
        if let button = statusItem.button { petAnimator = WebbyMenuPetAnimator(button: button) }
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "Webby Settings"
        let menu = NSMenu(title: "Webby")
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu(menu)
    }

    @objc private func toggleSounds() { WebbySounds.enabled.toggle() }

    func menuWillOpen(_ menu: NSMenu) { rebuildMenu(menu) }

    func makeTabSettingsMenu() -> NSMenu {
        // Reuse the real settings/actions so both entry points stay in sync.
        let source = NSMenu(); buildSettingsItems(source)
        let menu = NSMenu(title: "Tab Settings")
        let titles: Set<String> = ["Tab Layout", "Restore Tabs After Restart", "Offload Idle Tabs",
            "Glass Effect on Web Pages", "Match Tab Pane to Page Glass"]
        for item in source.items where titles.contains(item.title) || item.view?.subviews.contains(where: { $0 is NSSlider }) == true {
            source.removeItem(item); menu.addItem(item)
        }
        return menu
    }

    private func rebuildMenu(_ menu: NSMenu) { buildSettingsItems(menu, grouped:true) }

    private func buildSettingsItems(_ menu: NSMenu, grouped: Bool = false) {
        menu.removeAllItems()
        let sounds = menu.addItem(withTitle: "Subtle Action Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self; sounds.state = WebbySounds.enabled ? .on : .off
        menu.addItem(.separator())
        let show = menu.addItem(withTitle: "Show Browser", action: #selector(showBrowserAction), keyEquivalent: "")
        show.target = self
        let widget = menu.addItem(withTitle: "Add Widget…", action: #selector(addWidgetAction), keyEquivalent: "")
        widget.target = self
        let reset = menu.addItem(withTitle: "Reset Widget Positions", action: #selector(resetWidgetsAction), keyEquivalent: "")
        reset.target = self
        let wallpaper = menu.addItem(withTitle: "Background & Effects…", action: #selector(openWallpaperAction), keyEquivalent: "")
        wallpaper.target = self
        let backgrounds = NSMenuItem(title: "ASCII Backgrounds", action: nil, keyEquivalent: "")
        let artMenu = NSMenu(title: "ASCII Backgrounds")
        for art in ASCIIArtwork.catalog {
            let entry = NSMenuItem(title: art.name, action: nil, keyEquivalent: "")
            let options = NSMenu(title: art.name)
            let toggle = options.addItem(withTitle: "Show Background", action: #selector(toggleASCII(_:)), keyEquivalent: "")
            toggle.target = self; toggle.representedObject = art.id
            toggle.state = asciiCanvas()?.has(art.id) == true ? .on : .off
            if asciiCanvas()?.has(art.id) == true {
                let control = NSView(frame: NSRect(x: 0, y: 0, width: 230, height: 54))
                let label = NSTextField(labelWithString: "Brightness")
                label.frame = NSRect(x: 14, y: 32, width: 200, height: 18)
                let slider = NSSlider(value: asciiCanvas()?.brightness(art.id) ?? 0.24, minValue: 0, maxValue: 1,
                                      target: self, action: #selector(asciiBrightnessChanged(_:)))
                slider.identifier = NSUserInterfaceItemIdentifier(art.id)
                slider.isContinuous = true; slider.frame = NSRect(x: 14, y: 8, width: 200, height: 20)
                control.addSubview(label); control.addSubview(slider)
                let item = NSMenuItem(); item.view = control; options.addItem(item)
            }
            entry.submenu = options; artMenu.addItem(entry)
        }
        backgrounds.submenu = artMenu; menu.addItem(backgrounds)
        menu.addItem(.separator())

        let profileItem = NSMenuItem(title: "Gradient for \(currentSpaceName())", action: nil, keyEquivalent: "")
        let profiles = NSMenu(title: "Gradient Profile")
        for preset in BrowserTheme.presets {
            let item = profiles.addItem(withTitle: preset.name, action: #selector(selectProfile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.state = BrowserTheme.selectedID == preset.id ? .on : .off
        }
        profiles.addItem(.separator())
        let custom = profiles.addItem(withTitle: "Custom", action: #selector(selectProfile(_:)), keyEquivalent: "")
        custom.target = self
        custom.representedObject = "custom"
        custom.state = BrowserTheme.selectedID == "custom" ? .on : .off
        profileItem.submenu = profiles
        menu.addItem(profileItem)

        let petItem = NSMenuItem(title: "Pet for Custom Gradient", action: nil, keyEquivalent: "")
        let petMenu = NSMenu(title: "Pet for Custom Gradient")
        for preset in BrowserTheme.presets {
            let item = petMenu.addItem(withTitle: preset.name, action: #selector(selectCustomPet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = preset.id
            item.state = BrowserTheme.selectedID == "custom" && BrowserTheme.petID == preset.id ? .on : .off
        }
        petItem.submenu = petMenu
        menu.addItem(petItem)
        let choosePet = menu.addItem(withTitle: "Choose Custom Pet Image…", action: #selector(chooseCustomPet), keyEquivalent: "")
        choosePet.target = self
        var resetPet: NSMenuItem?
        if BrowserTheme.customPetURL != nil {
            let clearPet = menu.addItem(withTitle: "Use Profile Pet Image", action: #selector(clearCustomPet), keyEquivalent: "")
            clearPet.target = self
            resetPet = clearPet
        }

        let edit = menu.addItem(withTitle: "Customize Gradient…", action: #selector(showSettings), keyEquivalent: "")
        edit.target = self
        menu.addItem(.separator())
        let experiment = menu.addItem(withTitle: "Fuse All Profile Tabs",
                                      action: #selector(toggleExperiment), keyEquivalent: "F")
        experiment.target = self
        experiment.keyEquivalentModifierMask = [.command, .shift]
        experiment.state = BrowserExperiment.cyclesNewTabProfiles ? .on : .off
        let tabPosition = NSMenuItem(title: "Tab Layout", action: nil, keyEquivalent: "")
        let positionMenu = NSMenu(title: "Tab Layout")
        for placement in [BrowserTabPlacement.top, .bottom, .horizontal] {
            let item = positionMenu.addItem(withTitle: placement == .horizontal ? "Horizontal" : (placement == .top ? "Vertical · Top" : "Vertical · Bottom"),
                                            action: #selector(selectTabPlacement(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = placement.rawValue
            item.state = BrowserTabPlacement.current == placement ? .on : .off
        }
        tabPosition.submenu = positionMenu
        menu.addItem(tabPosition)
        let searchRoot = NSMenuItem(title: "Search Engine for \(currentSpaceName())", action: nil, keyEquivalent: "")
        let searchMenu = NSMenu(title: "Search Engine")
        for engine in BrowserSearchEngine.allCases {
            let item = searchMenu.addItem(withTitle: engine.name, action: #selector(selectSearchEngine(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = engine.rawValue
            item.state = BrowserSearchEngine.selected(for: currentSpaceID()) == engine ? .on : .off
        }
        searchRoot.submenu = searchMenu
        menu.addItem(searchRoot)
        let restore = menu.addItem(withTitle: "Restore Tabs After Restart", action: #selector(toggleRestoreTabs), keyEquivalent: "")
        restore.target = self
        restore.state = UserDefaults.standard.bool(forKey: "webbyRestoreTabs") ? .on : .off
        let offload = NSMenuItem(title: "Offload Idle Tabs", action: nil, keyEquivalent: "")
        let offloadMenu = NSMenu(title: "Offload Idle Tabs")
        for minutes in [0, 5, 15, 30, 60] {
            let item = offloadMenu.addItem(withTitle: minutes == 0 ? "Never" : "After \(minutes) Minutes",
                                           action: #selector(selectOffloadTime(_:)), keyEquivalent: "")
            item.target = self
            item.tag = minutes
            item.state = UserDefaults.standard.integer(forKey: "webbyOffloadMinutes") == minutes ? .on : .off
        }
        offload.submenu = offloadMenu
        menu.addItem(offload)
        let miniRoot=NSMenuItem(title:"Mini Webby",action:nil,keyEquivalent:"");miniRoot.submenu=miniMenu();menu.addItem(miniRoot)
        let terminal = menu.addItem(withTitle: "Open Terminal in This Tab",
                                    action: #selector(openTerminalAction), keyEquivalent: "")
        terminal.target = self
        let indicatorRoot = NSMenuItem(title: "Notch Indicators by Profile", action: nil, keyEquivalent: "")
        let indicatorMenu = NSMenu(title: "Notch Indicators by Profile")
        let fuseItem = NSMenuItem(title: "Fuse", action: nil, keyEquivalent: "")
        let fuseScenes = NSMenu(title: "Fuse Symbol")
        for scene in IndicatorScenes.cycleIDs {
            let item = fuseScenes.addItem(withTitle: scene.capitalized, action: #selector(selectFuseIndicator(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = scene
            item.state = BrowserExperiment.fuseScene == scene ? .on : .off
        }
        fuseItem.submenu = fuseScenes
        indicatorMenu.addItem(fuseItem)
        indicatorMenu.addItem(.separator())
        for (index, profile) in self.profiles().enumerated() {
            let (id, name) = profile
            let profileItem = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            let scenes = NSMenu(title: name)
            for scene in IndicatorScenes.cycleIDs {
                let item = scenes.addItem(withTitle: scene.capitalized,
                                          action: #selector(selectIndicator(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [id.uuidString, scene]
                item.state = BrowserExperiment.scene(for: id, index: index) == scene ? .on : .off
            }
            profileItem.submenu = scenes
            indicatorMenu.addItem(profileItem)
        }
        indicatorRoot.submenu = indicatorMenu
        menu.addItem(indicatorRoot)
        menu.addItem(.separator())
        let glassStart = menu.items.count
        let glassHeading = menu.addItem(withTitle: "Glass Transparency", action: nil, keyEquivalent: "")
        glassHeading.isEnabled = false
        addGlassSlider(to: menu, title: "Widget Glass Opacity", value: BrowserGlass.widgetOpacity(profile: currentSpaceID()), tag: 4)
        addGlassSlider(to: menu, title: "Main Background", value: BrowserGlass.backgroundTransparency, tag: 3)
        addGlassSlider(to: menu, title: "Top Bar", value: BrowserGlass.topTransparency, tag: 1)
        addGlassSlider(to: menu, title: "Sidebar", value: BrowserGlass.sidebarTransparency, tag: 2)
        let pageGlass = menu.addItem(withTitle: "Glass Effect on Web Pages", action: #selector(togglePageGlass), keyEquivalent: "")
        pageGlass.target = self
        pageGlass.state = BrowserGlass.pageInjectionEnabled ? .on : .off
        let matchGlass = menu.addItem(withTitle: "Match Tab Pane to Page Glass", action: #selector(toggleMatchGlass), keyEquivalent: "")
        matchGlass.target = self
        matchGlass.state = BrowserGlass.matchPageGlassSidebar ? .on : .off
        let glassItems = Array(menu.items[glassStart...])
        menu.addItem(.separator())
        let googleRoot = NSMenuItem(title: "Google Widgets for \(currentSpaceName())", action: nil, keyEquivalent: "")
        let googleMenu = NSMenu(title: "Google Widgets")
        let client = googleMenu.addItem(withTitle: "Choose Desktop OAuth Client…", action: #selector(chooseGoogleClientAction), keyEquivalent: "")
        client.target = self
        googleMenu.addItem(.separator())
        for service in GoogleService.allCases {
            let connected = googleConnected(service)
            let serviceTitle: String
            switch service { case .calendar: serviceTitle = "Calendar"; case .gmail: serviceTitle = "Gmail"; case .drive: serviceTitle = "Drive" }
            let title = service == .calendar ? (connected ? "Disconnect Calendar Feed" : "Connect Calendar iCal Feed…")
                : "\(connected ? "Disconnect" : "Connect") \(serviceTitle)"
            let item = googleMenu.addItem(withTitle: title,
                                          action: connected ? #selector(disconnectGoogleAction(_:)) : #selector(connectGoogleAction(_:)),
                                          keyEquivalent: "")
            item.target = self
            item.representedObject = service.rawValue
        }
        googleRoot.submenu = googleMenu
        menu.addItem(googleRoot)
        menu.addItem(.separator())
        let importItem = menu.addItem(withTitle: "Import Chrome Profiles…", action: #selector(importChromeAction), keyEquivalent: "")
        importItem.target = self
        let deleteItem = menu.addItem(withTitle: "Delete Browser Profile…", action: #selector(deleteProfileAction), keyEquivalent: "")
        deleteItem.target = self
        let importPasswordsItem = menu.addItem(withTitle: "Import Chrome Passwords…", action: #selector(importPasswordsAction), keyEquivalent: "")
        importPasswordsItem.target = self
        let signIns = menu.addItem(withTitle: "Import Chrome Sign-ins…", action: #selector(importSignInsAction), keyEquivalent: "")
        signIns.target = self
        let passwords = menu.addItem(withTitle: "Saved Passwords…", action: #selector(showPasswordsAction), keyEquivalent: "")
        passwords.target = self
        let fill = menu.addItem(withTitle: "Fill Password for This Site…", action: #selector(fillPasswordAction), keyEquivalent: "")
        fill.target = self
        let bookmarks = menu.addItem(withTitle: "Open Bookmarks", action: #selector(openBookmarksAction), keyEquivalent: "")
        bookmarks.target = self
        let history = menu.addItem(withTitle: "Open History", action: #selector(openHistoryAction), keyEquivalent: "")
        history.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Webby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApplication.shared
        guard grouped else { return }

        // Reparent the original controls so selectors, checkmarks and sliders stay identical.
        func section(_ title: String, symbol: String, items: [NSMenuItem]) -> NSMenuItem {
            let root = NSMenuItem(title:title,action:nil,keyEquivalent:"")
            root.image = NSImage(systemSymbolName:symbol,accessibilityDescription:nil)
            let children = NSMenu(title:title)
            for item in items { item.menu?.removeItem(item); children.addItem(item) }
            root.submenu = children
            return root
        }
        let transparency = section("Glass & Transparency",symbol:"square.on.square",items:glassItems)
        let tabs = section("Tabs & Search",symbol:"rectangle.topthird.inset.filled",
                           items:[tabPosition,searchRoot,.separator(),restore,offload,.separator(),miniRoot,terminal])
        let accounts = section("Profiles & Fuse",symbol:"person.2",
                               items:[experiment,.separator(),importItem,signIns,.separator(),deleteItem])
        let appearance = section("Appearance",symbol:"paintpalette",
                                 items:[profileItem,edit,.separator(),transparency,.separator(),sounds])
        let widgets = section("Widgets & Backgrounds",symbol:"square.grid.2x2",
                              items:[reset,.separator(),wallpaper,backgrounds,.separator(),googleRoot])
        var petItems = [petItem,choosePet]
        if let resetPet { petItems.append(resetPet) }
        petItems += [.separator(),indicatorRoot]
        let pets = section("Pets & Indicators",symbol:"pawprint",items:petItems)
        let library = section("History & Passwords",symbol:"clock.arrow.circlepath",
                              items:[history,bookmarks,.separator(),passwords,fill,importPasswordsItem])
        // Keep daily actions immediately accessible; everything else has one clear home.
        menu.removeAllItems()
        for item in [show,widget,NSMenuItem.separator(),tabs,accounts,appearance,widgets,pets,library,
                     NSMenuItem.separator(),quit] { menu.addItem(item) }
    }

    @objc private func showBrowserAction() { showBrowser() }
    @objc private func addWidgetAction() { addWidget() }
    @objc private func toggleASCII(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        asciiCanvas()?.toggle(id)
    }
    @objc private func asciiBrightnessChanged(_ sender: NSSlider) {
        guard let id = sender.identifier?.rawValue else { return }
        asciiCanvas()?.setBrightness(sender.doubleValue, for: id)
    }
    @objc private func resetWidgetsAction() { resetWidgets() }
    @objc private func chooseGoogleClientAction() { chooseGoogleClient() }
    @objc private func connectGoogleAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let service = GoogleService(rawValue: raw) else { return }
        connectGoogle(service)
    }
    @objc private func disconnectGoogleAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let service = GoogleService(rawValue: raw) else { return }
        disconnectGoogle(service)
    }
    @objc private func toggleExperiment() {
        BrowserExperiment.cyclesNewTabProfiles.toggle()
        experimentChanged()
    }
    @objc private func selectTabPlacement(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let placement = BrowserTabPlacement(rawValue: raw) else { return }
        BrowserTabPlacement.current = placement
        tabPlacementChanged()
    }
    @objc private func selectSearchEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let engine = BrowserSearchEngine(rawValue: raw) else { return }
        BrowserSearchEngine.set(engine, for: currentSpaceID())
        NotificationCenter.default.post(name: .browserSearchEngineChanged, object: nil)
    }
    @objc private func toggleRestoreTabs() {
        let enabled = !UserDefaults.standard.bool(forKey: "webbyRestoreTabs")
        UserDefaults.standard.set(enabled, forKey: "webbyRestoreTabs")
        if !enabled { UserDefaults.standard.removeObject(forKey: "webbySessionTabs") }
    }
    @objc private func selectOffloadTime(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.tag, forKey: "webbyOffloadMinutes")
    }
    @objc private func openTerminalAction() { openTerminal() }
    @objc private func selectIndicator(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2,
              let id = UUID(uuidString: pair[0]) else { return }
        BrowserExperiment.setScene(pair[1], for: id)
        NotificationCenter.default.post(name: .browserThemeChanged, object: nil)
    }

    @objc private func selectFuseIndicator(_ sender: NSMenuItem) {
        guard let scene = sender.representedObject as? String else { return }
        BrowserExperiment.setFuseScene(scene)
        NotificationCenter.default.post(name: .browserThemeChanged, object: nil)
    }

    private func addGlassSlider(to menu: NSMenu, title: String, value: Double, tag: Int) {
        let item = NSMenuItem()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 255, height: 43))
        let label = NSTextField(labelWithString: "\(title)  \(Int((value * 100).rounded()))%")
        label.frame = NSRect(x: 16, y: 24, width: 220, height: 16)
        label.font = .systemFont(ofSize: 11, weight: .medium)
        let slider = NSSlider(frame: NSRect(x: 13, y: 2, width: 222, height: 22))
        slider.minValue = 0
        slider.maxValue = tag >= 3 ? 1 : 0.85
        slider.doubleValue = value
        slider.isContinuous = true
        slider.tag = tag
        slider.target = self
        slider.action = #selector(glassSliderChanged(_:))
        host.addSubview(label)
        host.addSubview(slider)
        item.view = host
        menu.addItem(item)
    }

    @objc private func glassSliderChanged(_ slider: NSSlider) {
        let value = slider.doubleValue
        if slider.tag == 1 { BrowserGlass.setTop(value) }
        else if slider.tag == 2 { BrowserGlass.setSidebar(value) }
        else if slider.tag == 4 { BrowserGlass.setWidgetOpacity(value, profile: currentSpaceID()) }
        else { BrowserGlass.setBackground(value) }
        let name = slider.tag == 1 ? "Top Bar" : (slider.tag == 2 ? "Sidebar" : (slider.tag == 4 ? "Widget Glass Opacity" : "Main Background"))
        (slider.superview?.subviews.first { $0 is NSTextField } as? NSTextField)?
            .stringValue = "\(name)  \(Int((value * 100).rounded()))%"
    }
    @objc private func togglePageGlass() { BrowserGlass.pageInjectionEnabled.toggle() }
    @objc private func toggleMatchGlass() { BrowserGlass.matchPageGlassSidebar.toggle() }
    @objc private func importChromeAction() { importChrome() }
    @objc private func deleteProfileAction() { deleteProfile() }
    @objc private func openBookmarksAction() { openBookmarks() }
    @objc private func openHistoryAction() { openHistory() }
    @objc private func importPasswordsAction() { importPasswords() }
    @objc private func showPasswordsAction() { showPasswords() }
    @objc private func importSignInsAction() { importSignIns() }
    @objc private func fillPasswordAction() { fillPassword() }

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        BrowserTheme.select(id)
    }

    @objc private func selectCustomPet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        BrowserTheme.selectCustomPet(id)
    }

    @objc private func chooseCustomPet() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.canChooseDirectories = false
        panel.message = "Choose an image to sit on Webby's icon for this browser profile."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try BrowserTheme.saveCustomPet(from: url) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Could not use that pet image"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    @objc private func clearCustomPet() { BrowserTheme.clearCustomPet() }

    @objc private func openWallpaperAction() { openWallpaper() }
    @objc private func showSettings() {
        if settingsWindow == nil { makeSettingsWindow() }
        settingsWindow?.title = "Webby Gradient • \(currentSpaceName())"
        let colors = BrowserTheme.customColors
        for (well, color) in zip(colorWells, colors) { well.color = color }
        updatePreview()
        NSApplication.shared.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged() { updatePreview() }

    @objc private func applyCustom() {
        BrowserTheme.saveCustom(colorWells.map(\.color))
        settingsWindow?.orderOut(nil)
    }

    private func makeSettingsWindow() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Webby Gradient • \(currentSpaceName())"
        window.center()
        window.isReleasedWhenClosed = false
        let root = NSVisualEffectView(frame: window.contentView?.bounds ?? .zero)
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        root.autoresizingMask = [.width, .height]
        window.contentView = root

        let title = NSTextField(labelWithString: "Your browser, in three colors")
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.frame = NSRect(x: 24, y: 197, width: 360, height: 25)
        root.addSubview(title)
        let detail = NSTextField(labelWithString: "Changes the search beam, globe, tabs, toolbar, and terminal.")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 24, y: 173, width: 372, height: 18)
        root.addSubview(detail)

        let previewHost = NSView(frame: NSRect(x: 24, y: 124, width: 372, height: 32))
        previewHost.wantsLayer = true
        previewHost.layer?.cornerRadius = 9
        previewHost.layer?.masksToBounds = true
        preview.frame = previewHost.bounds
        previewHost.layer?.addSublayer(preview)
        root.addSubview(previewHost)

        for (index, name) in ["Start", "Middle", "End"].enumerated() {
            let x = 24 + CGFloat(index) * 124
            let label = NSTextField(labelWithString: name)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: x, y: 93, width: 55, height: 18)
            root.addSubview(label)
            let well = NSColorWell(frame: NSRect(x: x + 58, y: 86, width: 52, height: 30))
            well.target = self
            well.action = #selector(colorChanged)
            colorWells.append(well)
            root.addSubview(well)
        }

        let apply = NSButton(title: "Apply Custom Gradient", target: self, action: #selector(applyCustom))
        apply.bezelStyle = .rounded
        apply.keyEquivalent = "\r"
        apply.frame = NSRect(x: 222, y: 24, width: 174, height: 32)
        root.addSubview(apply)
        settingsWindow = window
    }

    private func updatePreview() {
        preview.colors = colorWells.map { $0.color.cgColor }
        preview.locations = [0, 0.5, 1]
        preview.startPoint = CGPoint(x: 0, y: 0.5)
        preview.endPoint = CGPoint(x: 1, y: 0.5)
    }


}
