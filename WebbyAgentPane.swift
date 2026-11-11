import AppKit

@MainActor final class WebbyAgentPane: NSView {
    private var session = WebbyAgentSession()
    private var sessionProviderKey: String?
    private let quickChoices = AgentChoicePopover()
    private let browser: WebbyAgentListener.Handler
    private let backdrop = WebbyGlassBackdrop()
    private let pageSurface = NSView()
    private let composerSurface = NSView()
    private var pageColor: NSColor?
    private var pageIsGlass = false
    private var docked = false
    private let dockDivider = CALayer()
    private let glow = CAGradientLayer()
    private let pet = NotchIndicatorEngine()
    private let petView = NSView()
    private let avatar = NSImageView()
    private let accent = CAGradientLayer()
    var onDismiss: (() -> Void)?
    var onFloat: (() -> Void)?
    private let floatButton = NSButton()
    private var chromeButtons: [GlassButton] = []
    var onShortcut: ((String, NSEvent.ModifierFlags) throws -> Void)?
    private var profileID: UUID?
    private let controlsButton = NSButton()
    private let slashPicker = AgentSlashPicker()
    private let tabChoices = AgentChoicePopover()
    private var slashHeight: NSLayoutConstraint!
    private var slashMatch: AgentSlashMatch?
    private var slashDismissed: AgentSlashMatch?
    private var historyID: String?
    private var historyCursor: String?
    private var historyMessages: [HistoryMessage] = []
    private var historyContext: String?
    private var models: [AgentModel] = []
    private var chatLookup = UUID()
    var onReleaseTabs: (() -> Void)?
    var agentTabs: (() -> [(UUID, String)])?
    var onInspectTab: ((UUID) -> Void)?
    private let headline = NSTextField(labelWithString: "Browse together")
    private let intro = NSView()
    private let subhead = NSTextField(labelWithString: "Your page stays open while I work.")
    private let status = NSTextField(labelWithString: "Ready · works in the background")
    private let transcript = NSTextView()
    private let historyActions = NSStackView()
    private let olderButton = NSButton()
    private let continueButton = NSButton()
    private var historyActionsHeight: NSLayoutConstraint!
    private let transcriptScroll = NSScrollView()
    private let composer = AgentComposer()
    private let sendButton = NSButton()
    private let attachment = NSButton()
    private var assistantOffset = 0
    private var markdownStart: Int?
    private var markdownSource = ""
    private var assistantIntroduced = false
    private var cliEnabled = false
    private let setCLI: (Bool) throws -> Void
    private var image: NSImage?
    private var lastItem: String?
    private var threadID: String?
    private var busy = false
    private var theme: PetGradientProfile

    init(theme: PetGradientProfile, cliEnabled: Bool, setCLI: @escaping (Bool) throws -> Void,
         browser: @escaping WebbyAgentListener.Handler) {
        self.theme = theme
        self.setCLI = setCLI
        self.browser = browser
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 21
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        dockDivider.isHidden = true
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.addSublayer(glow)
        tint.layer?.addSublayer(accent)
        glow.type = .radial
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .withinWindow
        backdrop.state = .active
        pageSurface.wantsLayer = true
        pageSurface.isHidden = true
        for view in [backdrop, pageSurface, tint] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor), view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: topAnchor), view.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
        petView.wantsLayer = true
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.translatesAutoresizingMaskIntoConstraints = false
        petView.addSubview(avatar)
        petView.layer?.addSublayer(pet.layer)
        pet.layer.position = CGPoint(x: 17, y: 13)
        pet.layer.transform = CATransform3DMakeScale(0.85, 0.85, 1)
        NSLayoutConstraint.activate([
            petView.widthAnchor.constraint(equalToConstant: 40),
            petView.heightAnchor.constraint(equalToConstant: 38),
            avatar.leadingAnchor.constraint(equalTo: petView.leadingAnchor),
            avatar.trailingAnchor.constraint(equalTo: petView.trailingAnchor),
            avatar.topAnchor.constraint(equalTo: petView.topAnchor),
            avatar.bottomAnchor.constraint(equalTo: petView.bottomAnchor)
        ])

        let title = NSTextField(labelWithString: "Webby Agent")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let identity = NSStackView(views: [title, status])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 2

        let history = makeButton("clock", label: "Chat history", action: #selector(showHistory))
        let settings = makeButton("gearshape", label: "Agent settings", action: #selector(showSettings))
        let new = makeButton("plus", label: "New chat", action: #selector(newChat))
        let more = makeButton("rectangle.on.rectangle", label: "Agent tabs", action: #selector(showOptions(_:)))
        floatButton.target = self
        floatButton.action = #selector(toggleFloat)
        floatButton.isBordered = false
        floatButton.widthAnchor.constraint(equalToConstant: 23).isActive = true
        floatButton.heightAnchor.constraint(equalToConstant: 23).isActive = true
        setFloating(false, canFloat: false)
        let dismiss = makeButton("xmark", label: "Close Webby Agent", action: #selector(dismissPane))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [petView, identity, spacer, new, history, settings, more, floatButton, dismiss])
        header.spacing = 6
        header.alignment = .centerY

        headline.font = .systemFont(ofSize: 21, weight: .semibold)
        headline.alignment = .center
        subhead.font = .systemFont(ofSize: 12, weight: .medium)
        subhead.textColor = .secondaryLabelColor
        subhead.alignment = .center
        subhead.maximumNumberOfLines = 3
        subhead.lineBreakMode = .byWordWrapping
        subhead.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for label in [headline, subhead] {
            label.translatesAutoresizingMaskIntoConstraints = false
            intro.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: intro.leadingAnchor),
                label.trailingAnchor.constraint(equalTo: intro.trailingAnchor)
            ])
        }
        NSLayoutConstraint.activate([
            headline.topAnchor.constraint(equalTo: intro.topAnchor),
            subhead.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 7),
            subhead.bottomAnchor.constraint(equalTo: intro.bottomAnchor)
        ])

        configure(transcript, in: transcriptScroll, inset: NSSize(width: 14, height: 12))
        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.setAccessibilityLabel("Agent conversation")
        let content = NSView()
        olderButton.title = "Older Messages"
        olderButton.target = self
        olderButton.action = #selector(loadOlder)
        olderButton.controlSize = .small
        continueButton.title = "Continue in Webby"
        continueButton.target = self
        continueButton.action = #selector(continueHistory)
        continueButton.controlSize = .small
        historyActions.addArrangedSubview(olderButton)
        historyActions.addArrangedSubview(continueButton)
        historyActions.isHidden = true
        content.addSubview(historyActions)
        content.addSubview(transcriptScroll)
        content.addSubview(intro)
        for view in [historyActions, transcriptScroll, intro] { view.translatesAutoresizingMaskIntoConstraints = false }
        historyActionsHeight = historyActions.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            historyActionsHeight,
            historyActions.topAnchor.constraint(equalTo: content.topAnchor),
            historyActions.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            historyActions.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor),
            transcriptScroll.topAnchor.constraint(equalTo: historyActions.bottomAnchor), transcriptScroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            transcriptScroll.leadingAnchor.constraint(equalTo: content.leadingAnchor), transcriptScroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            intro.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            intro.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            intro.centerYAnchor.constraint(equalTo: content.centerYAnchor, constant: -12)
        ])

        let composerScroll = NSScrollView()
        configure(composer, in: composerScroll, inset: NSSize(width: 9, height: 7))
        composer.font = .systemFont(ofSize: 14)
        composer.textColor = .labelColor
        composer.isRichText = false
        composer.isAutomaticQuoteSubstitutionEnabled = false
        composer.placeholder = "Ask about a page or give Webby a task…"
        composer.setAccessibilityLabel("Message Webby Agent")
        composer.submit = { [weak self] in self?.submit() }
        composer.completionsChanged = { [weak self] in self?.updateSlashPicker() }
        composer.completionKey = { [weak self] in self?.handleSlashKey($0) ?? false }
        composer.addImage = { [weak self] in self?.attach($0) }
        composer.copyImage = { [weak self] cut in
            guard let self, let image = self.image else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            if cut { self.clearAttachment() }
            return true
        }
        composer.removeImage = { [weak self] in
            guard let self, self.image != nil else { return false }
            self.clearAttachment(); return true
        }
        composerScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true

        attachment.bezelStyle = .rounded
        attachment.controlSize = .small
        attachment.target = self
        attachment.action = #selector(removeAttachment)
        attachment.isHidden = true
        attachment.imagePosition = .imageLeading
        let tip = NSTextField(labelWithString: "↵ Send  ·  ⇧↵ New line")
        tip.font = .systemFont(ofSize: 10)
        tip.textColor = .secondaryLabelColor
        tip.lineBreakMode = .byTruncatingTail
        tip.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let sendSpacer = NSView()
        sendSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sendButton.isBordered = false
        sendButton.wantsLayer = true
        sendButton.layer?.cornerRadius = 9
        sendButton.widthAnchor.constraint(equalToConstant: 30).isActive = true
        sendButton.heightAnchor.constraint(equalToConstant: 26).isActive = true
        sendButton.target = self
        sendButton.action = #selector(sendOrStop)
        controlsButton.isBordered = false
        controlsButton.font = .systemFont(ofSize: 11, weight: .medium)
        controlsButton.target = self
        controlsButton.action = #selector(showSettings)
        controlsButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        controlsButton.cell?.lineBreakMode = .byTruncatingTail
        tip.stringValue = "/ commands"
        let controls = NSStackView(views: [attachment, controlsButton, sendSpacer, tip, sendButton])
        controls.alignment = .centerY
        controls.spacing = 8
        let composeStack = NSStackView(views: [composerScroll, controls])
        composeStack.orientation = .vertical
        composeStack.alignment = .width
        composeStack.spacing = 3
        let panel = composerSurface
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.045).cgColor
        panel.layer?.cornerRadius = 18
        panel.layer?.masksToBounds = true
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        panel.addSubview(composeStack)
        composeStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            composeStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            composeStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            composeStack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 6),
            composeStack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -8)
        ])
        let layout = NSView()
        layout.translatesAutoresizingMaskIntoConstraints = false
        addSubview(layout)
        for section in [header, content, panel] {
            section.translatesAutoresizingMaskIntoConstraints = false
            layout.addSubview(section)
            NSLayoutConstraint.activate([
                section.leadingAnchor.constraint(equalTo: layout.leadingAnchor),
                section.trailingAnchor.constraint(equalTo: layout.trailingAnchor)
            ])
        }
        let idealWidth = layout.widthAnchor.constraint(equalToConstant: 580)
        idealWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            idealWidth, layout.centerXAnchor.constraint(equalTo: centerXAnchor),
            layout.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 11),
            layout.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -11),
            layout.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            layout.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
            header.topAnchor.constraint(equalTo: layout.topAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 9),
            panel.topAnchor.constraint(equalTo: content.bottomAnchor, constant: 9),
            panel.bottomAnchor.constraint(equalTo: layout.bottomAnchor)
        ])
        slashPicker.translatesAutoresizingMaskIntoConstraints = false
        slashPicker.isHidden = true
        layout.addSubview(slashPicker)
        slashHeight = slashPicker.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            slashPicker.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            slashPicker.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            slashPicker.bottomAnchor.constraint(equalTo: panel.topAnchor, constant: -4),
            slashHeight
        ])
        slashPicker.onChoose = { [weak self] in self?.acceptSlashCommand($0) }
        layer?.addSublayer(dockDivider)
        updateCLI(cliEnabled)
        updateTheme(theme)
        updateButton()
        refreshControls()
        pet.hide()
    }

    static func petImage(for id: UUID) -> NSImage {
        let appearance = BrowserTheme.onboardingAppearance(for: id)
        let working = Bundle.main.url(forResource: "0", withExtension: "png", subdirectory: "PetsWorking/\(appearance.pet)")
        let still = Bundle.main.url(forResource: appearance.pet, withExtension: "png", subdirectory: "Pets")
        return (appearance.petURL ?? working ?? still).flatMap(NSImage.init(contentsOf:))
            ?? NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Webby Agent") ?? NSImage(size: .zero)
    }

    func verifyComposerCommands() throws {
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw WebbyAutomationError.message(message) }
        }
        func key(_ code: UInt16, _ characters: String) {
            guard let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code) else { return }
            composer.keyDown(with: event)
        }
        defer {
            if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
            composer.string = ""
            hideSlashPicker()
        }
        composer.string = "Keep this "
        composer.setSelectedRange(NSRange(location: composer.string.utf16.count, length: 0))
        composer.insertText("/", replacementRange: composer.selectedRange())
        try expect(!slashPicker.isHidden && slashPicker.selected == "/settings", "Slash did not open suggestions inside a draft")
        composer.insertText("mo", replacementRange: composer.selectedRange())
        try expect(slashPicker.selected == "/model" && slashPicker.count == 2, "Typing did not filter and highlight slash commands")
        key(125, "\u{f701}")
        try expect(slashPicker.selected == "/mode", "Down did not move the command highlight")
        key(53, "\u{1b}")
        try expect(slashPicker.isHidden && composer.string == "Keep this /mo", "Escape changed the draft")
        composer.string = "Keep this "
        composer.setSelectedRange(NSRange(location: composer.string.utf16.count, length: 0))
        composer.insertText("/mo", replacementRange: composer.selectedRange())
        try expect(!slashPicker.isHidden && slashPicker.selected == "/model", "Retyping a dismissed command did not reopen suggestions")
        let history = AgentHistoryPicker(search: "")
        history.fetch = { _, _, reply in reply(.success(["data": [["id": "fixture", "name": "Fixture chat"]]])) }
        history.reload()
        try expect(history.numberOfRows(in: NSTableView()) == 1, "Chat History did not display the search result")
        try expect(AgentSettingsSheet.verifiesCommandShortcut(), "The shortcut form did not accept Command plus a key")
        try expect(AgentChoicePopover.verifiesSelection(), "The custom picker did not filter and select by keyboard")
        if let image = ProcessInfo.processInfo.environment["WEBBY_AGENT_PICKER_PREVIEW"] {
            try AgentChoicePopover().captureFixture(from: self, theme: theme, path: image)
        }
        let table = formatted("| **Name** | Center | Right |\n|:---|:---:|---:|\n| A \\| B | `code` | 42 |")
        let text = table.string as NSString
        let center = text.range(of: "Center").location
        let right = text.range(of: "42").location
        let centerStyle = center == NSNotFound ? nil : table.attribute(.paragraphStyle, at: center, effectiveRange: nil) as? NSParagraphStyle
        let rightStyle = right == NSNotFound ? nil : table.attribute(.paragraphStyle, at: right, effectiveRange: nil) as? NSParagraphStyle
        try expect(centerStyle?.alignment == .center && rightStyle?.alignment == .right
                   && rightStyle?.textBlocks.first is NSTextTableBlock && table.string.contains("A | B"),
                   "Markdown table lost cells, alignment, or an escaped pipe")

        composer.string = "Keep this /setting"
        composer.setSelectedRange(NSRange(location: composer.string.utf16.count, length: 0))
        key(36, "\r")
        try expect(window?.attachedSheet?.title == "Agent Settings" && composer.string == "Keep this ",
                   "Return did not open settings or dropped surrounding text")
    }

    func updateAppearance(profileID: UUID) {
        if self.profileID != profileID {
            self.profileID = profileID
            refreshControls()
        }
        avatar.image = Self.petImage(for: profileID)
        updateTheme(BrowserTheme.profile(for: profileID))
    }

    func reveal(from offset: CGFloat) {
        guard Motion.enabled, let layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.24
        layer.add(fade, forKey: "agentAppear")
        if offset != 0 {
            let move = CABasicAnimation(keyPath: "transform.translation.x")
            move.fromValue = offset
            move.toValue = 0
            move.duration = 0.3
            move.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(move, forKey: "agentSlide")
        }
    }

    private func makeButton(_ symbol: String, label: String, action: Selector) -> NSButton {
        let button = GlassButton(symbol: symbol, label: label, target: self, action: action)
        button.widthAnchor.constraint(equalToConstant: 23).isActive = true
        button.heightAnchor.constraint(equalToConstant: 23).isActive = true
        chromeButtons.append(button)
        return button
    }

    func setFloating(_ floating: Bool, canFloat: Bool = true) {
        let title = floating ? "Dock to Tab" : "Float Agent"
        floatButton.isHidden = !canFloat
        floatButton.toolTip = title
        floatButton.setAccessibilityLabel(title)
        floatButton.image = NSImage(systemSymbolName: floating ? "rectangle.righthalf.inset.filled" : "macwindow.on.rectangle",
                                   accessibilityDescription: title)
    }

    @objc private func toggleFloat() { onFloat?() }
    func stopForClosedTab() { session.stop() }

    @objc private func dismissPane() { onDismiss?() }
    @objc private func showOptions(_ sender: NSButton) {
        let tabs = agentTabs?() ?? []
        var choices = tabs.map { id, title in
            AgentChoice(id: id.uuidString, title: title, detail: "Inspect this tab", symbol: "macwindow")
        }
        if !tabs.isEmpty {
            choices.append(.init(id: "release", title: "Release All Tabs", detail: "Clear the Agent markers", symbol: "link.badge.minus"))
        }
        tabChoices.show(from: sender, title: "Agent Tabs", choices: choices, selection: nil, theme: theme) { [weak self] id in
            if id == "release" { self?.onReleaseTabs?() }
            else if let tab = UUID(uuidString: id) { self?.onInspectTab?(tab) }
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        glow.frame = bounds
        accent.frame = CGRect(x: 0, y: bounds.maxY - 2, width: bounds.width, height: 2)
        let pixel = 1 / (window?.backingScaleFactor ?? 2)
        dockDivider.frame = CGRect(x: 0, y: 0, width: pixel, height: bounds.height)
    }

    private func configure(_ view: NSTextView, in scroll: NSScrollView, inset: NSSize) {
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = view
        view.drawsBackground = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.frame.size.width = scroll.contentSize.width
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
        view.textContainerInset = inset
    }

    func setDocked(_ value: Bool) {
        docked = value
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.cornerRadius = value ? 0 : 21
        layer?.borderWidth = value ? 0 : 1
        dockDivider.isHidden = !value
        accent.isHidden = value
        updateDockDivider()
        CATransaction.commit()
    }

    private func updateDockDivider() {
        let light = pageColor.map(Self.prefersDarkText) ?? (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        dockDivider.backgroundColor = (light ? NSColor.black : .white).withAlphaComponent(0.13).cgColor
    }

    func applyPageSurface(_ color: NSColor?, glass: Bool = false) {
        guard pageColor != color || pageIsGlass != glass else { return }
        let animate = Motion.enabled && pageColor != nil && color != nil && window?.isVisible == true
        pageColor = color
        pageIsGlass = glass
        pageSurface.isHidden = color == nil
        backdrop.isHidden = color != nil && !glass
        backdrop.material = glass ? .popover : .underWindowBackground

        let light = color.map(Self.prefersDarkText)
        appearance = light.map { NSAppearance(named: $0 ? .aqua : .darkAqua) } ?? nil
        let foreground = (light ?? (effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua))
            ? NSColor.black : .white
        composer.insertionPointColor = foreground
        if docked { updateDockDivider() }
        let tint = color?.withAlphaComponent(glass ? 0.18 : 1) ?? .clear
        Motion.color(pageSurface.layer, to: tint.cgColor, animate: animate)
        layer?.borderColor = foreground.withAlphaComponent(0.12).cgColor
        composerSurface.layer?.backgroundColor = foreground.withAlphaComponent(0.055).cgColor
        composerSurface.layer?.borderColor = foreground.withAlphaComponent(0.13).cgColor
        glow.opacity = color == nil ? 1 : 0
        accent.opacity = color == nil ? 1 : 0.36
    }

    static func prefersDarkText(on color: NSColor) -> Bool {
        let rgb = color.usingColorSpace(.sRGB) ?? .black
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent)
            + 0.0722 * linear(rgb.blueComponent) >= 0.179
    }

    func updateTheme(_ profile: PetGradientProfile) {
        theme = profile
        pet.setProfile(profile, wave: busy)
        for button in chromeButtons { button.applyTheme(profile) }
        let recipe = busy ? profile.gradients.thinking : profile.gradients.ambient
        let colors = [BrowserTheme.color(recipe.stops.first?.color ?? profile.palette.primary, alpha: busy ? 0.27 : 0.18).cgColor,
                      BrowserTheme.color(profile.palette.secondary, alpha: 0.06).cgColor, NSColor.clear.cgColor]
        if Motion.enabled, let from = glow.presentation()?.colors ?? glow.colors {
            let animation = CABasicAnimation(keyPath: "colors")
            animation.fromValue = from
            animation.toValue = colors
            animation.duration = 0.55
            glow.add(animation, forKey: "agentGlow")
        }
        glow.colors = colors
        glow.locations = [0, 0.48, 1]
        glow.startPoint = CGPoint(x: 0.18, y: 0.84)
        glow.endPoint = CGPoint(x: 1, y: 0)
        BrowserTheme.apply(recipe, to: accent, alpha: busy ? 1 : 0.55)
        let buttonColor = BrowserTheme.color(profile.palette.primary)
        let luminance = buttonColor.redComponent * 0.21 + buttonColor.greenComponent * 0.72 + buttonColor.blueComponent * 0.07
        sendButton.layer?.backgroundColor = buttonColor.cgColor
        sendButton.contentTintColor = luminance > 0.55 ? .black : .white
    }

    func focusComposer() { window?.makeFirstResponder(composer) }

    func updateCLI(_ enabled: Bool) {
        cliEnabled = enabled

    }

    @objc private func copyCLI() {
        let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/webby")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else { return }
        let quoted = "'" + cli.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(quoted, forType: .string)
        if !busy { status.stringValue = "CLI path copied" }
    }

    @objc private func openCodexApp() {
        if let url = CodexAppData.link(historyID ?? threadID) { NSWorkspace.shared.open(url) }
    }

    private func attach(_ image: NSImage) {
        self.image = image
        attachment.image = NSImage(systemSymbolName: "photo", accessibilityDescription: nil)
        attachment.title = "Image   ×"
        attachment.setAccessibilityLabel("Remove attached image")
        attachment.isHidden = false
    }

    private func clearAttachment() { image = nil; attachment.isHidden = true }
    @objc private func removeAttachment() { clearAttachment(); focusComposer() }

    private func updateButton() {
        let label = busy ? "Stop" : "Send"
        sendButton.toolTip = label
        sendButton.setAccessibilityLabel(label)
        sendButton.image = NSImage(systemSymbolName: busy ? "stop.fill" : "arrow.up", accessibilityDescription: label)
        sendButton.imagePosition = .imageOnly
    }

    @objc private func sendOrStop() {
        if busy { status.stringValue = "Stopping…"; session.stop() }
        else { submit() }
    }

    private func submit() {
        let text = composer.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") && !text.contains("\n") {
            let command = text.split(maxSplits: 1, whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
            if AgentSlashPicker.commands.contains(where: { $0.name == command }) || text == "/" {
                composer.string = ""
                composer.needsDisplay = true
                hideSlashPicker()
                runSlashCommand(text)
                return
            }
        }
        guard !busy, !text.isEmpty || image != nil else { return }
        if historyID != nil && threadID == nil {
            status.stringValue = "Use /continue to start a Webby chat from this history"
            return
        }
        let configuration = selectedConfiguration
        let external = externalProvider
        if external != nil && image != nil {
            status.stringValue = "This provider uses text prompts. Remove the image or choose Codex."
            return
        }
        if let external, external.executable == nil {
            status.stringValue = "Install and sign in to \(external.name) (\(external.binary)) first."
            return
        }
        if let sessionProviderKey, sessionProviderKey != endpointKey {
            session = WebbyAgentSession()
            threadID = nil
            historyID = nil
            historyCursor = nil
            historyContext = nil
            updateHistoryActions()
            append("Switched to \(providerName) · new conversation\n", kind: .activity)
        }
        sessionProviderKey = endpointKey
        let png: Data?
        if let image {
            guard let tiff = image.tiffRepresentation,
                  let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
                  data.count <= 10 * 1024 * 1024 else {
                status.stringValue = "Choose an image under 10 MB"
                return
            }
            png = data
        } else { png = nil }
        intro.isHidden = true
        append(transcript.string.isEmpty ? "You\n" : "\nYou\n", kind: .userHeading)
        if !text.isEmpty { append(text + "\n") }
        if png != nil { append("▧ Image attached\n") }
        composer.string = ""
        composer.needsDisplay = true
        hideSlashPicker()
        clearAttachment()
        lastItem = nil
        assistantIntroduced = false
        busy = true
        updateButton()
        updateTheme(theme)
        if Motion.enabled {
            avatar.animator().alphaValue = 0.36
            pet.showThinking()
        }
        let resolved = models.first { $0.id == modelID } ?? (modelID == nil ? models.first(where: \.isDefault) : nil)
        let receive: (WebbyAgentSession.Event) -> Void = { [weak self] in self?.receive($0) }
        if let external {
            session.sendExternal(external, text: text, model: modelID, effort: effort,
                                 plan: planMode, browser: browser, event: receive)
        } else {
            session.send(text: text, image: png, configuration: configuration, model: modelID ?? resolved?.id,
                         effort: effort ?? resolved?.defaultEffort, plan: planMode, history: historyContext,
                         browser: browser, event: receive)
        }
    }

    private func receive(_ event: WebbyAgentSession.Event) {
        switch event {
        case .connected(let threadID):
            self.threadID = threadID
            rememberThread(threadID)
        case .working(let message): status.stringValue = message
        case .activity(let message):
            formatReply()
            status.stringValue = message
            append("\n•  " + message + "\n", kind: .activity)
            lastItem = nil
        case .text(let id, let delta):
            if lastItem != id {
                formatReply()
                if !assistantIntroduced {
                    append("\n" + providerName + "\n", kind: .assistantHeading)
                    assistantIntroduced = true
                } else { append("\n") }
                lastItem = id
                assistantOffset = 0
                markdownStart = transcript.textStorage?.length
            }
            markdownSource += delta
            append(delta, kind: .assistant)
        case .completed(let result):
            if result == "completed" { historyContext = nil }
            formatReply()
            append("\n")
            finish(result == "completed" ? "Ready · works in the background" : result.capitalized)
        case .failed(let error):
            formatReply()
            append("\n\n\(error)\n")
            finish(providerName + " · Connection or turn error")
        }
    }

    private func formatReply() {
        defer { markdownSource = ""; markdownStart = nil }
        guard let start = markdownStart, let storage = transcript.textStorage,
              start <= storage.length, !markdownSource.isEmpty else { return }
        let follow = transcriptScroll.documentVisibleRect.maxY >= transcript.bounds.maxY - 45
        storage.replaceCharacters(in: NSRange(location: start, length: storage.length - start),
                                  with: formatted(markdownSource))
        if follow { transcript.scrollRangeToVisible(NSRange(location: storage.length, length: 0)) }
    }

    private func formatted(_ source: String) -> NSAttributedString {
        AgentMarkdown.render(source, colors: theme.gradients.thinking.stops.map { BrowserTheme.color($0.color) })
    }

    private func finish(_ message: String) {
        busy = false
        status.stringValue = message
        pet.hide()
        avatar.animator().alphaValue = 1
        updateTheme(theme)
        updateButton()
    }

    private enum LineKind { case body, userHeading, assistantHeading, assistant, activity }

    private func append(_ string: String, kind: LineKind = .body) {
        let follow = transcriptScroll.documentVisibleRect.maxY >= transcript.bounds.maxY - 45
        let isHeading = kind == .userHeading || kind == .assistantHeading
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let color: NSColor
        switch kind {
        case .body, .assistant: color = .labelColor
        case .userHeading, .activity: color = .secondaryLabelColor
        case .assistantHeading: color = AgentMarkdown.adaptiveTint(BrowserTheme.color(theme.palette.primary))
        }
        let text = NSMutableAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: isHeading || kind == .activity ? 11 : 13,
                                     weight: isHeading ? .semibold : .regular),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
        if kind == .assistant {
            let colors = theme.gradients.thinking.stops.map { BrowserTheme.color($0.color) }
            if !colors.isEmpty {
                // Blend theme stops with the label color so streaming text stays readable.
                var offset = 0
                while offset < text.length {
                    let index = assistantOffset / 18 % colors.count
                    let count = min(text.length - offset, 18 - assistantOffset % 18)
                    let tint = AgentMarkdown.adaptiveTint(colors[index])
                    text.addAttribute(.foregroundColor, value: tint, range: NSRange(location: offset, length: count))
                    offset += count
                    assistantOffset += count
                }
            }
        }
        guard let storage = transcript.textStorage else { return }
        storage.append(text)
        if follow { transcript.scrollRangeToVisible(NSRange(location: storage.length, length: 0)) }
    }
}

@MainActor final class WebbyAgentOutline: NSView {
    private let gradient = CAGradientLayer()
    private let stroke = CAShapeLayer()
    private var radius: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(gradient)
        gradient.mask = stroke
        stroke.fillColor = NSColor.clear.cgColor
        stroke.strokeColor = NSColor.white.cgColor
        stroke.lineWidth = 2.5
    }

    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(_ profile: PetGradientProfile, cornerRadius: CGFloat) {
        radius = max(3, cornerRadius)
        BrowserTheme.apply(profile.gradients.thinking, to: gradient)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = bounds
        stroke.frame = gradient.bounds
        stroke.path = CGPath(roundedRect: gradient.bounds.insetBy(dx: 1.5, dy: 1.5),
                             cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.commit()
    }
}

@MainActor private final class AgentComposer: NSTextView {
    var placeholder = ""
    var submit: (() -> Void)?
    var addImage: ((NSImage) -> Void)?
    var removeImage: (() -> Bool)?
    var copyImage: ((Bool) -> Bool)?
    var completionsChanged: (() -> Void)?
    var completionKey: ((UInt16) -> Bool)?

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !stillSelecting { completionsChanged?() }
    }

    override func copy(_ sender: Any?) {
        if string.isEmpty && copyImage?(false) == true { return }
        super.copy(sender)
    }

    override func cut(_ sender: Any?) {
        if string.isEmpty && copyImage?(true) == true { return }
        super.cut(sender)
    }

    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let image = NSImage(pasteboard: pasteboard), pasteboard.string(forType: .string) == nil {
            addImage?(image)
        } else { pasteAsPlainText(sender) }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if !hasMarkedText(), event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty,
           completionKey?(event.keyCode) == true { return }
        if [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.shift), !hasMarkedText() {
            submit?()
        } else if [51, 117].contains(event.keyCode), string.isEmpty, removeImage?() == true {
            needsDisplay = true
        } else {
            super.keyDown(with: event)
            needsDisplay = true
        }
    }

    override func didChangeText() { super.didChangeText(); needsDisplay = true; completionsChanged?() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                                         withAttributes: [.font: font ?? NSFont.systemFont(ofSize: 14),
                                                          .foregroundColor: NSColor.secondaryLabelColor])
        }
    }
}

@MainActor private enum AgentMarkdown {
    static func adaptiveTint(_ accent: NSColor) -> NSColor {
        let tint = accent.usingColorSpace(.sRGB) ?? .gray
        return NSColor(name: nil) { appearance in
            let base: NSColor = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .white : .black
            return base.blended(withFraction: 0.18, of: tint) ?? base
        }
    }

    static func render(_ source: String, colors: [NSColor]) -> NSAttributedString {
        let output = NSMutableAttributedString()
        var fence: String?
        var colorIndex = 0
        let lines = source.components(separatedBy: .newlines)
        var skipUntil = 0
        for (index, line) in lines.enumerated() where index >= skipUntil {
            let marker = line.trimmingCharacters(in: .whitespaces)
            if let current = fence {
                if marker.hasPrefix(current), marker.dropFirst(current.count).allSatisfy({ $0 == current.first }) {
                    fence = nil
                } else {
                    let style = NSMutableParagraphStyle()
                    style.headIndent = 9
                    style.firstLineHeadIndent = 9
                    style.lineSpacing = 2
                    style.lineBreakMode = .byCharWrapping
                    output.append(NSAttributedString(string: (line.isEmpty ? " " : line) + "\n", attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                        .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.11),
                        .paragraphStyle: style
                    ]))
                }
                continue
            }
            if marker.hasPrefix("```") || marker.hasPrefix("~~~"), let first = marker.first {
                let prefix = String(marker.prefix { $0 == first })
                fence = prefix
                let language = marker.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
                if !language.isEmpty {
                    output.append(NSAttributedString(string: language + "\n", attributes: [
                        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor
                    ]))
                }
                continue
            }
            if index + 1 < lines.count, let header = cells(line), !header.isEmpty,
               let alignment = alignments(lines[index + 1], columns: header.count) {
                var rows = [header]
                var next = index + 2
                while next < lines.count, let row = cells(lines[next]) {
                    rows.append(row)
                    next += 1
                }
                appendTable(rows, alignments: alignment, to: output)
                skipUntil = next
                continue
            }
            let heading = marker.prefix { $0 == "#" }.count
            let isHeading = (1...6).contains(heading) && marker.dropFirst(heading).first == " "
            var body = isHeading ? String(marker.dropFirst(heading + 1)) : line
            if body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ") {
                body = "•  " + body.dropFirst(2)
            }
            let font = NSFont.systemFont(ofSize: isHeading ? (heading < 3 ? 16 : 14) : 13, weight: isHeading ? .semibold : .regular)
            let tint = colors.isEmpty ? .labelColor : adaptiveTint(colors[colorIndex % colors.count])
            if !body.isEmpty { colorIndex += 1 }
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 3
            if isHeading { style.paragraphSpacingBefore = 6 }
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint, .paragraphStyle: style]
            appendInline(body, font: font, attributes: attributes, to: output)
            output.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        if output.length > 0, let style = output.attribute(.paragraphStyle, at: output.length - 1, effectiveRange: nil) as? NSParagraphStyle,
           !style.textBlocks.isEmpty {
            output.append(NSAttributedString(string: "\n"))
        }
        return output
    }

    private static func appendInline(_ text: String, font: NSFont, attributes: [NSAttributedString.Key: Any],
                                     to output: NSMutableAttributedString) {
        if let inline = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            for run in inline.runs {
                var styled = attributes
                let intents = run.inlinePresentationIntent ?? []
                var face = font
                if intents.contains(.code) {
                    face = .monospacedSystemFont(ofSize: 11.5, weight: .medium)
                    styled[.backgroundColor] = NSColor.quaternaryLabelColor.withAlphaComponent(0.13)
                }
                if intents.contains(.stronglyEmphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .boldFontMask) }
                if intents.contains(.emphasized) { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
                if intents.contains(.strikethrough) { styled[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if let link = run.link, ["https", "http", "mailto"].contains(link.scheme?.lowercased() ?? "") { styled[.link] = link }
                styled[.font] = face
                output.append(NSAttributedString(string: String(inline.characters[run.range]), attributes: styled))
            }
        } else { output.append(NSAttributedString(string: text, attributes: attributes)) }
    }

    private static func cells(_ line: String) -> [String]? {
        var fields = [""]
        var escaped = false
        var separators = 0
        let text = line.trimmingCharacters(in: .whitespaces)
        for character in text {
            if escaped {
                fields[fields.count - 1].append(character)
                escaped = false
            } else if character == "\\" {
                fields[fields.count - 1].append(character)
                escaped = true
            } else if character == "|" {
                separators += 1
                fields.append("")
            } else {
                fields[fields.count - 1].append(character)
            }
        }
        guard separators > 0 else { return nil }
        if text.hasPrefix("|") { fields.removeFirst() }
        if fields.last == "", text.hasSuffix("|") { fields.removeLast() }
        return fields.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func alignments(_ line: String, columns: Int) -> [NSTextAlignment]? {
        guard let fields = cells(line), fields.count == columns else { return nil }
        let valid = fields.allSatisfy {
            $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil
        }
        guard valid else { return nil }
        return fields.map {
            if $0.hasPrefix(":") && $0.hasSuffix(":") { return .center }
            return $0.hasSuffix(":") ? .right : .left
        }
    }

    private static func appendTable(_ rows: [[String]], alignments: [NSTextAlignment], to output: NSMutableAttributedString) {
        let table = NSTextTable()
        table.numberOfColumns = alignments.count
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        for (row, cells) in rows.enumerated() {
            for (column, alignment) in alignments.enumerated() {
                let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1,
                                             startingColumn: column, columnSpan: 1)
                block.setValue(100 / CGFloat(alignments.count), type: .percentageValueType, for: .width)
                block.setWidth(5, type: .absoluteValueType, for: .padding)
                block.setWidth(1, type: .absoluteValueType, for: .border)
                block.setBorderColor(.separatorColor)
                if row == 0 { block.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.13) }
                else if row.isMultiple(of: 2) { block.backgroundColor = NSColor.labelColor.withAlphaComponent(0.045) }
                let style = NSMutableParagraphStyle()
                style.textBlocks = [block]
                style.alignment = alignment
                style.lineBreakMode = .byCharWrapping
                let font = NSFont.systemFont(ofSize: 12, weight: row == 0 ? .semibold : .regular)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style]
                let value = cells.indices.contains(column) ? cells[column] : ""
                appendInline(value, font: font, attributes: attributes, to: output)
                output.append(NSAttributedString(string: "\n", attributes: attributes))
            }
        }
    }
}

private extension WebbyAgentPane {
    struct AgentModel {
        let id: String
        let label: String
        let efforts: [String]
        let defaultEffort: String?
        let isDefault: Bool

        init?(_ row: [String: Any]) {
            guard let id = row["model"] as? String ?? row["id"] as? String else { return nil }
            self.id = id
            label = row["displayName"] as? String ?? id
            efforts = (row["supportedReasoningEfforts"] as? [[String: Any]] ?? []).compactMap { $0["reasoningEffort"] as? String }
            defaultEffort = row["defaultReasoningEffort"] as? String
            isDefault = row["isDefault"] as? Bool ?? false
        }
    }

    struct HistoryMessage {
        let user: Bool
        let text: String
    }

    var defaults: UserDefaults { .standard }
    var profileKey: String { "webbyAgent." + (profileID?.uuidString ?? "default") }
    var endpointPath: String? { defaults.string(forKey: profileKey + ".provider") }
    var endpointKey: String { profileKey + ".endpoint." + (endpointPath ?? "shared") }
    var modelID: String? { defaults.string(forKey: endpointKey + ".model") }
    var effort: String? { defaults.string(forKey: endpointKey + ".effort") }
    var planMode: Bool { defaults.bool(forKey: profileKey + ".plan") }
    var endpoints: [[String: String]] { defaults.array(forKey: "webbyAgent.providers") as? [[String: String]] ?? [] }

    var externalProvider: WebbyExternalProvider? { endpointPath.flatMap(WebbyExternalProvider.init(rawValue:)) }

    var selectedConfiguration: CodexAppConfiguration {
        let shared = CodexAppConfiguration.agentEndpoint()
        guard let endpointPath, externalProvider == nil else { return shared }
        return .init(cli: shared.cli, socket: URL(fileURLWithPath: endpointPath), home: shared.home)
    }

    var providerName: String {
        guard let endpointPath else { return "Codex" }
        if let externalProvider { return externalProvider.name }
        return endpoints.first { $0["path"] == endpointPath }?["name"] ?? "Local provider"
    }

    func rememberThread(_ id: String) {
        let key = endpointKey + ".chats"
        var ids = defaults.stringArray(forKey: key) ?? []
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
        defaults.set(Array(ids.prefix(500)), forKey: key)
    }

    func refreshControls() {
        let modelName = modelID.map { id in models.first { $0.id == id }?.label ?? id } ?? "Auto"
        controlsButton.image = AgentBrand.image(AgentBrand.provider(endpointPath))
        controlsButton.imagePosition = .imageLeading
        controlsButton.title = [planMode ? "Plan" : "Browse", modelName, effort.map { $0.capitalized } ?? "Default"].joined(separator: "  ·  ")
        controlsButton.toolTip = "Provider: \(providerName). Change model, thinking effort, or default mode."
    }

    @objc func newChat() {
        guard !busy else { return }
        chatLookup = UUID()
        session = WebbyAgentSession()
        sessionProviderKey = endpointKey
        threadID = nil
        historyID = nil
        historyContext = nil
        historyCursor = nil
        historyMessages = []
        updateHistoryActions()
        transcript.textStorage?.setAttributedString(NSAttributedString(string: ""))
        intro.isHidden = false
        status.stringValue = "Ready · \(providerName)"
        focusComposer()
    }

    func request(_ method: String, _ params: [String: Any], completion: @escaping ([String: Any]) -> Void) {
        let endpoint = selectedConfiguration
        WebbyAgentSession.request(method, params, configuration: endpoint) { [weak self] result in
            guard let self, self.selectedConfiguration.socket == endpoint.socket, !self.busy else { return }
            switch result {
            case .success(let data): completion(data)
            case .failure(let error): self.status.stringValue = error.localizedDescription
            }
        }
    }

    @objc func showHistory() { listHistory() }

    func listHistory(search: String = "") {
        if let externalProvider {
            status.stringValue = "Open \(externalProvider.name) to browse its chat history."
            return
        }
        guard !busy, let window, window.attachedSheet == nil else { return }
        let endpoint = selectedConfiguration
        let picker = AgentHistoryPicker(search: search)
        picker.applyGlass(theme)
        picker.fetch = { query, cursor, completion in
            var parameters: [String: Any] = ["limit": 24, "sortKey": "updated_at"]
            if !query.isEmpty { parameters["searchTerm"] = query }
            parameters["cursor"] = cursor
            WebbyAgentSession.request("thread/list", parameters, configuration: endpoint, reply: completion)
        }
        picker.onOpen = { [weak self] id in self?.openHistory(id) }
        window.beginSheet(picker.window) { _ in withExtendedLifetime(picker) {} }
        picker.reload()
    }

    func openHistory(_ id: String) {
        guard !busy else { return }
        if id == threadID { focusComposer(); return }
        loadHistory(id: id, cursor: nil)
    }

    func loadHistory(id: String, cursor: String?) {
        let endpoint = selectedConfiguration
        let token = UUID()
        chatLookup = token
        status.stringValue = "Loading messages…"
        var parameters: [String: Any] = ["threadId": id, "itemsView": "full", "limit": 12, "sortDirection": "desc"]
        parameters["cursor"] = cursor
        WebbyAgentSession.request("thread/turns/list", parameters, configuration: endpoint) { [weak self] result in
            guard let self, self.chatLookup == token, self.selectedConfiguration.socket == endpoint.socket, !self.busy else { return }
            switch result {
            case .success(let response):
                let turns = (response["data"] as? [[String: Any]] ?? []).reversed()
                self.displayHistory(id: id, turns: Array(turns), older: cursor != nil, next: response["nextCursor"] as? String)
            case .failure:
                guard cursor == nil else { self.status.stringValue = "Couldn’t load older messages"; return }
                self.request("thread/read", ["threadId": id, "includeTurns": true]) { response in
                    guard self.chatLookup == token else { return }
                    let thread = response["thread"] as? [String: Any]
                    self.displayHistory(id: id, turns: thread?["turns"] as? [[String: Any]] ?? [], older: false, next: nil)
                }
            }
        }
    }

    func displayHistory(id: String, turns: [[String: Any]], older: Bool, next: String?) {
        let messages = turns.flatMap { turn in
            (turn["items"] as? [[String: Any]] ?? []).compactMap { item -> HistoryMessage? in
                switch item["type"] as? String {
                case "userMessage":
                    let parts = (item["content"] as? [[String: Any]] ?? []).map { content in
                        content["text"] as? String ?? ((content["type"] as? String)?.lowercased().contains("image") == true ? "▧ Image attached" : "")
                    }
                    let text = parts.filter { !$0.isEmpty }.joined(separator: "\n")
                    return text.isEmpty ? nil : HistoryMessage(user: true, text: text)
                case "agentMessage":
                    return (item["text"] as? String).flatMap { $0.isEmpty ? nil : HistoryMessage(user: false, text: $0) }
                default: return nil
                }
            }
        }
        if !older {
            let owned = defaults.stringArray(forKey: endpointKey + ".chats")?.contains(id) == true
            session = WebbyAgentSession(threadID: owned ? id : nil)
            sessionProviderKey = endpointKey
            threadID = owned ? id : nil
            historyMessages = []
            historyContext = nil
        }
        historyID = id
        historyCursor = next
        updateHistoryActions()
        historyMessages.insert(contentsOf: messages, at: 0)
        guard let storage = transcript.textStorage else { return }
        let previous = storage.length
        let page = NSMutableAttributedString()
        for message in older ? messages : historyMessages {
            page.append(NSAttributedString(string: (message.user ? "You" : "Webby") + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor
            ]))
            if message.user {
                page.append(NSAttributedString(string: message.text + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor
                ]))
            } else { page.append(formatted(message.text)) }
            page.append(NSAttributedString(string: "\n"))
        }
        if older {
            storage.insert(page, at: 0)
            if previous > 0 { transcript.scrollRangeToVisible(NSRange(location: page.length, length: 0)) }
        } else {
            storage.setAttributedString(page)
            transcript.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
        }
        intro.isHidden = true
        status.stringValue = threadID == nil ? "History · /continue starts a Webby chat" : "Ready · \(providerName)"
        focusComposer()
    }

    func updateHistoryActions() {
        olderButton.isHidden = historyCursor == nil
        continueButton.isHidden = historyID == nil || threadID != nil
        let shown = !olderButton.isHidden || !continueButton.isHidden
        historyActions.isHidden = !shown
        historyActionsHeight.constant = shown ? 26 : 0
    }

    @objc func loadOlder() {
        guard let historyID, let historyCursor, !busy else { return }
        loadHistory(id: historyID, cursor: historyCursor)
    }

    @objc func continueHistory() {
        guard !busy, historyID != nil, threadID == nil else { return }
        let context = historyMessages.map { ($0.user ? "User: " : "Assistant: ") + $0.text }.joined(separator: "\n\n")
        historyContext = String(context.suffix(18_000))
        historyID = nil
        historyCursor = nil
        updateHistoryActions()
        append("Starting a Webby chat with the loaded history.\n", kind: .activity)
        status.stringValue = "Ready · \(providerName)"
        focusComposer()
    }

    @objc func showCommands() {
        intro.isHidden = true
        let help = """
        **Webby commands**
        `/new` Start a chat · `/stop` Stop the current turn
        `/history [search]` Browse chats · `/older` Load older messages
        `/continue` Start a Webby chat from the loaded history
        `/settings` · `/provider` · `/model` · `/effort` · `/mode` · `/shortcut`
        """
        guard let storage = transcript.textStorage else { return }
        if busy { formatReply(); lastItem = nil }
        storage.append(formatted(help))
        transcript.scrollRangeToVisible(NSRange(location: storage.length, length: 0))
    }

    func runSlashCommand(_ input: String) {
        let words = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        let command = words.first?.lowercased() ?? "/"
        if busy && command != "/stop" && command != "/help" && command != "/" {
            status.stringValue = "Finish or stop this turn first"
            return
        }
        switch command {
        case "/new": newChat()
        case "/history": listHistory(search: words.count == 2 ? String(words[1]) : "")
        case "/older": loadOlder()
        case "/continue": continueHistory()
        case "/settings": openSettings(section: nil)
        case "/provider", "/agents": chooseProvider()
        case "/model": chooseModel()
        case "/effort": chooseEffort()
        case "/mode": chooseMode()
        case "/tabs": showOptions(controlsButton)
        case "/shortcut": openSettings(section: .shortcut)
        case "/stop": if busy { sendOrStop() }
        case "/", "/help": showCommands()
        default: status.stringValue = "Unknown command. Use /help."
        }
    }

    func updateSlashPicker() {
        let match = AgentSlashMatch.find(in: composer.string, selection: composer.selectedRange())
        guard let match else { slashDismissed = nil; hideSlashPicker(); return }
        guard match != slashDismissed else { hideSlashPicker(); return }
        slashDismissed = nil
        if match == slashMatch && !slashPicker.isHidden { return }
        slashMatch = match
        slashPicker.filter(match.prefix, busy: busy)
        slashPicker.isHidden = slashPicker.count == 0
        slashHeight.constant = CGFloat(min(slashPicker.count, 6) * 26 + 8)
    }

    func hideSlashPicker() {
        slashMatch = nil
        slashPicker.isHidden = true
    }

    func handleSlashKey(_ code: UInt16) -> Bool {
        guard !slashPicker.isHidden else { return false }
        switch code {
        case 53: slashDismissed = slashMatch; hideSlashPicker()
        case 125: slashPicker.move(by: 1)
        case 126: slashPicker.move(by: -1)
        case 36, 76, 48: if let selected = slashPicker.selected { acceptSlashCommand(selected) }
        default: return false
        }
        return true
    }

    func acceptSlashCommand(_ command: String) {
        guard let match = slashMatch else { return }
        hideSlashPicker()
        let text = composer.string as NSString
        composer.string = text.replacingCharacters(in: match.range, with: "")
        composer.setSelectedRange(NSRange(location: match.range.location, length: 0))
        composer.needsDisplay = true
        runSlashCommand(command)
    }

    func fetchCatalog(_ path: String?, completion: @escaping (Result<[AgentModel], Error>) -> Void) {
        if let provider = path.flatMap(WebbyExternalProvider.init(rawValue:)) {
            WebbyAgentSession.externalCatalog(provider) { completion($0.map { $0.compactMap(AgentModel.init) }) }
        } else {
            let base = CodexAppConfiguration.agentEndpoint()
            let configuration = path.map {
                CodexAppConfiguration(cli: base.cli, socket: URL(fileURLWithPath: $0), home: base.home)
            } ?? base
            WebbyAgentSession.request("model/list", ["limit": 100, "includeHidden": false], configuration: configuration) { result in
                completion(result.map { ($0["data"] as? [[String: Any]] ?? []).compactMap(AgentModel.init) })
            }
        }
    }

    func chooseProvider() {
        let choices = AgentBrand.providers(endpoints)
        quickChoices.show(from: controlsButton, title: "Agents", choices: choices, selection: endpointPath ?? "", theme: theme) { [weak self] id in
            guard let self else { return }
            let endpoint = id.isEmpty ? nil : id
            guard self.endpointPath != endpoint else { return }
            self.defaults.set(endpoint, forKey: self.profileKey + ".provider")
            self.models = []
            self.newChat()
            self.refreshControls()
        }
    }

    func loadQuickCatalog(_ use: @escaping ([AgentModel]) -> Void) {
        let endpoint = endpointPath
        status.stringValue = "Loading \(providerName) models…"
        fetchCatalog(endpoint) { [weak self] result in
            guard let self, self.endpointPath == endpoint, !self.busy, self.window?.attachedSheet == nil else { return }
            switch result {
            case .success(let catalog):
                self.models = catalog
                self.status.stringValue = "Ready · " + self.providerName
                self.refreshControls()
                use(catalog)
            case .failure(let error): self.status.stringValue = error.localizedDescription
            }
        }
    }

    func chooseModel() {
        loadQuickCatalog { [weak self] catalog in
            guard let self else { return }
            let options = AgentBrand.models(catalog, provider: self.endpointPath)
            self.quickChoices.show(from: self.controlsButton, title: "Models", choices: options, selection: self.modelID ?? "", theme: self.theme) { [weak self] id in
                guard let self else { return }
                let model = id.isEmpty ? nil : id
                if self.modelID != model { self.defaults.removeObject(forKey: self.endpointKey + ".effort") }
                self.defaults.set(model, forKey: self.endpointKey + ".model")
                self.refreshControls()
            }
        }
    }

    func chooseEffort() {
        loadQuickCatalog { [weak self] catalog in
            guard let self else { return }
            let selected = catalog.first { $0.id == self.modelID } ?? catalog.first(where: \.isDefault)
            let options = AgentBrand.efforts(selected?.efforts ?? [])
            self.quickChoices.show(from: self.controlsButton, title: "Thinking Effort", choices: options,
                                   selection: self.effort ?? "", theme: self.theme) { [weak self] id in
                guard let self else { return }
                self.defaults.set(id.isEmpty ? nil : id, forKey: self.endpointKey + ".effort")
                self.refreshControls()
            }
        }
    }

    func chooseMode() {
        quickChoices.show(from: controlsButton, title: "Default Mode", choices: AgentBrand.modes,
                          selection: planMode ? "plan" : "browse", theme: theme) { [weak self] id in
            guard let self else { return }
            self.defaults.set(id == "plan", forKey: self.profileKey + ".plan")
            self.refreshControls()
        }
    }

    @objc func showSettings() { openSettings(section: nil) }

    func openSettings(section: AgentSettingsSheet.Section?) {
        guard !busy, let window, window.attachedSheet == nil else { return }
        let sheet = AgentSettingsSheet(endpoints: endpoints, endpoint: endpointPath, model: modelID,
                                       effort: effort, plan: planMode, cli: cliEnabled, section: section)
        sheet.applyGlass(theme)
        sheet.fetchModels = { [weak self] path, completion in self?.fetchCatalog(path, completion: completion) }
        sheet.preferences = { [weak self] path in
            guard let self else { return (nil, nil) }
            let key = self.profileKey + ".endpoint." + (path ?? "shared")
            return (self.defaults.string(forKey: key + ".model"), self.defaults.string(forKey: key + ".effort"))
        }
        sheet.copyCLI = { [weak self] in self?.copyCLI() }
        sheet.openCodex = { [weak self] in self?.openCodexApp() }
        sheet.save = { [weak self] path, entries, catalog, model, effort, plan, cli, key, mask in
            guard let self else { return }
            try self.onShortcut?(key, mask)
            if section == .shortcut { return }
            if cli != self.cliEnabled { try self.setCLI(cli) }
            if self.endpointPath != path {
                self.defaults.set(path, forKey: self.profileKey + ".provider")
                self.newChat()
            }
            self.defaults.set(entries, forKey: "webbyAgent.providers")
            self.models = catalog
            self.defaults.set(model, forKey: self.endpointKey + ".model")
            self.defaults.set(effort, forKey: self.endpointKey + ".effort")
            self.defaults.set(plan, forKey: self.profileKey + ".plan")
            self.refreshControls()
        }
        window.beginSheet(sheet.window) { _ in withExtendedLifetime(sheet) {} }
        if section != .shortcut { sheet.reloadModels() }
    }
}

private struct AgentSlashMatch: Equatable {
    let range: NSRange
    let prefix: String

    static func find(in text: String, selection: NSRange) -> Self? {
        let source = text as NSString
        let caret = selection.location
        guard selection.length == 0, caret <= source.length, caret > 0 else { return nil }
        let before = source.substring(to: caret)
        guard let slash = before.lastIndex(of: "/") else { return nil }
        if slash != before.startIndex {
            let previous = before[before.index(before: slash)]
            guard previous.isWhitespace || "([{".contains(previous) else { return nil }
        }
        let word = before[slash...]
        guard word.dropFirst().allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") }) else { return nil }
        let remaining = source.substring(from: caret)
        let tail = remaining.prefix { $0.isASCII && ($0.isLetter || $0 == "-") }
        return .init(range: NSRange(location: caret - word.utf16.count, length: word.utf16.count + tail.utf16.count),
                     prefix: word.lowercased())
    }
}

@MainActor private final class AgentSlashPicker: NSVisualEffectView {
    struct Command {
        let name: String
        let hint: String
    }
    static let commands: [Command] = [
        .init(name: "/settings", hint: "Open Agent settings"),
        .init(name: "/history", hint: "Find an older chat"),
        .init(name: "/new", hint: "Start a chat"),
        .init(name: "/model", hint: "Pick a model"),
        .init(name: "/effort", hint: "Change thinking effort"),
        .init(name: "/provider", hint: "Change provider"),
        .init(name: "/agents", hint: "Choose an agent runtime"),
        .init(name: "/tabs", hint: "Find agent-controlled tabs"),
        .init(name: "/mode", hint: "Choose Browse or Plan"),
        .init(name: "/shortcut", hint: "Change the summon shortcut"),
        .init(name: "/older", hint: "Load earlier messages"),
        .init(name: "/continue", hint: "Continue a chat in Webby"),
        .init(name: "/stop", hint: "Stop this turn"),
        .init(name: "/help", hint: "Show command help")
    ]
    var onChoose: ((String) -> Void)?
    private var matches: [Command] = []
    private var index = 0
    private var buttons: [NSButton] = []
    private let scroll = NSScrollView()
    private let rows = AgentSlashRows()
    var selected: String? { matches.indices.contains(index) ? matches[index].name : nil }
    var count: Int { matches.count }

    override init(frame: NSRect) {
        super.init(frame: frame)
        material = .popover
        state = .active
        blendingMode = .withinWindow
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.23).cgColor
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = rows
        rows.autoresizingMask = [.width]
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { nil }

    func filter(_ prefix: String, busy: Bool) {
        matches = Self.commands.filter {
            $0.name.hasPrefix(prefix) && (!busy || ["/stop", "/help"].contains($0.name))
        }
        index = matches.firstIndex { $0.name == prefix } ?? 0
        buttons.forEach { $0.removeFromSuperview() }
        rows.frame.size = NSSize(width: scroll.contentSize.width, height: CGFloat(count * 26))
        buttons = matches.enumerated().map { offset, command in
            let button = NSButton(title: command.name + "    " + command.hint, target: self, action: #selector(pick(_:)))
            button.setAccessibilityLabel(command.name + ", " + command.hint)
            button.image = AgentBrand.image(AgentBrand.command(command.name))
            button.imagePosition = .imageLeading
            button.tag = offset
            button.isBordered = false
            button.alignment = .left
            button.lineBreakMode = .byTruncatingTail
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.frame = NSRect(x: 0, y: offset * 26, width: Int(rows.bounds.width), height: 26)
            button.autoresizingMask = [.width]
            rows.addSubview(button)
            return button
        }
        highlight()
    }

    func move(by offset: Int) {
        guard count > 0 else { return }
        index = (index + offset + count) % count
        highlight()
    }

    private func highlight() {
        for (offset, button) in buttons.enumerated() {
            let highlighted = offset == index
            button.layer?.backgroundColor = highlighted ? NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor : NSColor.clear.cgColor
            button.contentTintColor = highlighted ? .labelColor : .secondaryLabelColor
        }
        if buttons.indices.contains(index) { rows.scrollToVisible(buttons[index].frame) }
    }

    @objc private func pick(_ sender: NSButton) {
        guard matches.indices.contains(sender.tag) else { return }
        onChoose?(matches[sender.tag].name)
    }
}

private final class AgentSlashRows: NSView {
    override var isFlipped: Bool { true }
}

@MainActor private final class AgentHistoryPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: 374), styleMask: [.titled], backing: .buffered, defer: false)
    private let search = NSSearchField()
    private let table = NSTableView()
    private let info = NSTextField(labelWithString: "")
    private let more = NSButton()
    private let open = NSButton()
    private var rows: [(id: String, title: String)] = []
    private var cursor: String?
    private var generation = UUID()
    private var searchWork: DispatchWorkItem?
    var fetch: ((String, String?, @escaping (Result<[String: Any], Error>) -> Void) -> Void)?
    var onOpen: ((String) -> Void)?

    init(search query: String) {
        super.init()
        window.title = "Chat History"
        window.isReleasedWhenClosed = false
        search.stringValue = query
        search.placeholderString = "Search chat titles"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        search.target = self
        search.action = #selector(searchNow)
        let column = NSTableColumn(identifier: .init("chat"))
        column.width = 408
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 28
        table.usesAlternatingRowBackgroundColors = true
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.doubleAction = #selector(openChat)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = table
        scroll.heightAnchor.constraint(equalToConstant: 242).isActive = true
        more.title = "Load More"
        more.target = self
        more.action = #selector(loadMore)
        more.bezelStyle = .rounded
        open.title = "Open Chat"
        open.target = self
        open.action = #selector(openChat)
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        let close = NSButton(title: "Cancel", target: self, action: #selector(dismiss))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [more, spacer, close, open])
        info.font = .systemFont(ofSize: 11)
        info.textColor = .secondaryLabelColor
        let content = NSView()
        window.contentView = content
        let stack = NSStackView(views: [search, scroll, info, buttons])
        stack.orientation = .vertical
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in [search, scroll, info, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 15),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -15)
        ])
        window.initialFirstResponder = search
    }

    func controlTextDidChange(_ notification: Notification) {
        generation = UUID()
        searchWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reload() }
        searchWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
    }
    func applyGlass(_ theme: PetGradientProfile) {
        AgentSheetGlass.install(in: window, theme: theme)
        search.focusRingType = .default
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
    }

    @objc private func searchNow() { reload() }
    func reload() {
        searchWork?.cancel()
        rows = []
        cursor = nil
        table.reloadData()
        request(cursor: nil)
    }
    @objc private func loadMore() { if let cursor { request(cursor: cursor) } }
    private func request(cursor: String?) {
        let id = UUID()
        generation = id
        more.isEnabled = false
        open.isEnabled = false
        info.stringValue = "Loading chats…"
        fetch?(search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), cursor) { [weak self] result in
            guard let self, self.generation == id else { return }
            switch result {
            case .success(let response):
                let entries = (response["data"] as? [[String: Any]] ?? []).compactMap { row -> (String, String)? in
                    guard let id = row["id"] as? String else { return nil }
                    let title = [row["name"], row["preview"]].compactMap { $0 as? String }.first { !$0.isEmpty } ?? "Untitled chat"
                    return (id, String(title.replacingOccurrences(of: "\n", with: " ").prefix(160)))
                }
                var seen = Set(self.rows.map(\.id))
                self.rows.append(contentsOf: entries.filter { seen.insert($0.0).inserted })
                self.cursor = response["nextCursor"] as? String
                self.info.stringValue = self.rows.isEmpty ? "No chats found" : "\(self.rows.count) chats"
                self.table.reloadData()
                if !self.rows.isEmpty { self.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
            case .failure(let error): self.info.stringValue = error.localizedDescription
            }
            self.more.isEnabled = self.cursor != nil
            self.open.isEnabled = self.table.selectedRow >= 0
        }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: rows[row].title)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
    func tableViewSelectionDidChange(_ notification: Notification) { open.isEnabled = table.selectedRow >= 0 }
    @objc private func openChat() {
        let index = table.selectedRow
        guard rows.indices.contains(index) else { return }
        dismiss()
        onOpen?(rows[index].id)
    }
    @objc private func dismiss() { window.sheetParent?.endSheet(window) }
}

@MainActor private final class AgentSettingsSheet: NSObject {
    enum Section: Equatable { case provider, model, effort, mode, shortcut }
    let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 492, height: 432), styleMask: [.titled], backing: .buffered, defer: false)
    var fetchModels: ((String?, @escaping (Result<[WebbyAgentPane.AgentModel], Error>) -> Void) -> Void)?
    var save: ((String?, [[String: String]], [WebbyAgentPane.AgentModel], String?, String?, Bool, Bool, String, NSEvent.ModifierFlags) throws -> Void)?
    var preferences: ((String?) -> (String?, String?))?
    var copyCLI: (() -> Void)?
    var openCodex: (() -> Void)?
    private let providers = AgentGlassPicker(label: "Provider", symbol: "point.3.connected.trianglepath.dotted")
    private let model = AgentGlassPicker(label: "Model", symbol: "cpu")
    private let effort = AgentGlassPicker(label: "Thinking Effort", symbol: "waveform.path")
    private let mode = AgentGlassPicker(label: "Default Mode", symbol: "scope")
    private let modifier = AgentGlassPicker(label: "Shortcut Modifiers", symbol: "command", compact: true)
    private let key = NSTextField()
    private let cli = NSButton(checkboxWithTitle: "Enable Local CLI", target: nil, action: nil)
    private let info = NSTextField(labelWithString: "")
    private let providerName = NSTextField()
    private let providerPath = NSTextField()
    private let connect = NSButton()
    private var entries: [[String: String]]
    private var endpoint: String?
    private var pendingModel: String?
    private var pendingEffort: String?
    private var catalog: [WebbyAgentPane.AgentModel] = []
    private var generation = UUID()
    private static let shortcuts: [(String, NSEvent.ModifierFlags)] = [
        ("⌘", [.command]), ("⌘⇧", [.command, .shift]), ("⌘⌥", [.command, .option]), ("⌘⌃", [.command, .control]),
        ("⌃⌥", [.control, .option]), ("⌃⇧", [.control, .shift]), ("⌥⇧", [.option, .shift]),
        ("⌘⌥⇧", [.command, .option, .shift]), ("⌘⌃⇧", [.command, .control, .shift]),
        ("⌘⌃⌥", [.command, .control, .option]), ("⌃⌥⇧", [.control, .option, .shift])
    ]

    init(endpoints: [[String: String]], endpoint: String?, model: String?, effort: String?,
         plan: Bool, cli: Bool, section: Section?) {
        entries = endpoints.filter { $0["path"] != nil }
        self.endpoint = endpoint
        pendingModel = model
        pendingEffort = effort
        super.init()
        window.title = "Agent Settings"
        window.isReleasedWhenClosed = false
        providers.onChange = { [weak self] in self?.providerChanged() }
        self.model.onChange = { [weak self] in self?.modelChanged() }
        fillProviders()
        fillModels()
        mode.setChoices(AgentBrand.modes, selection: plan ? "plan" : "browse")
        self.cli.state = cli ? .on : .off
        let defaults = UserDefaults.standard
        let storedMask = UInt(clamping: defaults.integer(forKey: "webbyAgent.summonModifiers"))
        modifier.setChoices(Self.shortcuts.map {
            .init(id: String($0.1.rawValue), title: $0.0, detail: nil, symbol: "command")
        }, selection: String(Self.shortcuts.first { $0.1.rawValue == storedMask }?.1.rawValue ?? Self.shortcuts[1].1.rawValue))
        key.stringValue = defaults.string(forKey: "webbyAgent.summonKey") ?? "j"
        key.placeholderString = "Key"
        key.setAccessibilityLabel("Shortcut key")
        key.widthAnchor.constraint(equalToConstant: 52).isActive = true
        let restore = button("Restore Default", #selector(restoreShortcut))
        providerName.placeholderString = "Provider name"
        providerName.widthAnchor.constraint(equalToConstant: 104).isActive = true
        providerPath.placeholderString = "/path/to/app-server.sock"
        providerPath.widthAnchor.constraint(greaterThanOrEqualToConstant: 168).isActive = true
        connect.title = "Add"
        connect.bezelStyle = .rounded
        connect.target = self
        connect.action = #selector(addProvider)
        info.textColor = .secondaryLabelColor
        info.font = .systemFont(ofSize: 11)
        info.lineBreakMode = .byTruncatingTail
        let close = button("Cancel", #selector(dismiss))
        close.keyEquivalent = "\u{1b}"
        let apply = button("Save", #selector(applySettings))
        apply.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let bottom = NSStackView(views: [spacer, close, apply])
        let caption = NSTextField(labelWithString: "Plan can inspect pages. Browse can act in background tabs.")
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        let shortcut = row("Summon shortcut", [modifier, key, restore])
        let rows = section == .shortcut ? [shortcut, row("", [info]), bottom] : [
            row("Provider", [providers]),
            row("Add local server", [providerName, providerPath, connect]),
            row("Model", [self.model]),
            row("Thinking effort", [self.effort]),
            row("Default mode", [mode]),
            row("", [caption]),
            shortcut,
            row("Local access", [self.cli, button("Copy CLI Path", #selector(copyPath))]),
            row("Codex", [button("Open in Codex", #selector(openDesktop))]),
            row("", [info]), bottom
        ]
        let content = NSView()
        window.contentView = content
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        for view in rows { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16)
        ])
        if section == .shortcut {
            window.title = "Summon Shortcut"
            window.setContentSize(NSSize(width: 492, height: 123))
        }
        switch section {
        case .provider: window.initialFirstResponder = providers
        case .model: window.initialFirstResponder = self.model
        case .effort: window.initialFirstResponder = self.effort
        case .mode: window.initialFirstResponder = mode
        case .shortcut: window.initialFirstResponder = key
        case nil: window.initialFirstResponder = providers
        }
    }

    func applyGlass(_ theme: PetGradientProfile) {
        AgentSheetGlass.install(in: window, theme: theme)
        for picker in [providers, model, effort, mode, modifier] { picker.applyTheme(theme) }
    }

    private func row(_ title: String, _ controls: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.widthAnchor.constraint(equalToConstant: 111).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [label] + controls + [spacer])
        row.alignment = .centerY
        row.spacing = 6
        if !title.isEmpty {
            row.edgeInsets = NSEdgeInsets(top: 3, left: 5, bottom: 3, right: 5)
            row.wantsLayer = true
            row.layer?.cornerRadius = 8
            row.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.28).cgColor
        }
        return row
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func fillProviders() {
        let choices = AgentBrand.providers(entries)
        providers.setChoices(choices, selection: endpoint ?? "")
    }

    private func providerChanged() {
        endpoint = providers.selectedID.flatMap { $0.isEmpty ? nil : $0 }
        (pendingModel, pendingEffort) = preferences?(endpoint) ?? (nil, nil)
        catalog = []
        fillModels()
        reloadModels()
    }

    func reloadModels() {
        let token = UUID()
        generation = token
        info.stringValue = "Loading models…"
        fetchModels?(endpoint) { [weak self] result in
            guard let self, self.generation == token else { return }
            switch result {
            case .success(let models):
                self.catalog = models
                self.fillModels()
                self.info.stringValue = models.isEmpty ? "This provider returned no models" : ""
            case .failure(let error): self.info.stringValue = error.localizedDescription
            }
        }
    }

    private func fillModels() {
        var choices = AgentBrand.models(catalog, provider: endpoint)
        if let pendingModel, !catalog.contains(where: { $0.id == pendingModel }) {
            choices.append(.init(id: pendingModel, title: pendingModel, detail: "Saved selection", symbol: "cpu"))
        }
        model.setChoices(choices, selection: pendingModel ?? "")
        fillEfforts()
    }

    private func modelChanged() {
        pendingModel = model.selectedID.flatMap { $0.isEmpty ? nil : $0 }
        pendingEffort = nil
        fillEfforts()
    }

    private func fillEfforts() {
        let selected = catalog.first { $0.id == pendingModel } ?? catalog.first(where: \.isDefault)
        var values = selected?.efforts ?? []
        if let pendingEffort, !values.contains(pendingEffort) { values.append(pendingEffort) }
        let choices = AgentBrand.efforts(values)
        effort.setChoices(choices, selection: pendingEffort ?? "")
    }

    @objc private func addProvider() {
        let path = (providerPath.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard path.hasPrefix("/") else { info.stringValue = "Enter the absolute path to a local server socket"; return }
        let name = providerName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = UUID()
        generation = token
        connect.isEnabled = false
        info.stringValue = "Checking local server…"
        fetchModels?(path) { [weak self] result in
            guard let self else { return }
            self.connect.isEnabled = true
            guard self.generation == token else { return }
            switch result {
            case .success(let models):
                self.entries.removeAll { $0["path"] == path }
                self.entries.append(["name": name.isEmpty ? "Local provider" : name, "path": path])
                self.endpoint = path
                self.catalog = models
                self.pendingModel = nil
                self.pendingEffort = nil
                self.fillProviders()
                self.fillModels()
                self.providerName.stringValue = ""
                self.providerPath.stringValue = ""
                self.info.stringValue = "Provider added. Save to use it."
            case .failure(let error): self.info.stringValue = error.localizedDescription
            }
        }
    }

    @objc private func restoreShortcut() { modifier.select(String(Self.shortcuts[1].1.rawValue)); key.stringValue = "j" }
    @objc private func copyPath() { copyCLI?(); info.stringValue = "CLI path copied" }
    @objc private func openDesktop() { openCodex?() }
    @objc private func dismiss() { window.sheetParent?.endSheet(window) }

    static func verifiesCommandShortcut() -> Bool {
        let sheet = AgentSettingsSheet(endpoints: [], endpoint: nil, model: nil, effort: nil,
                                       plan: false, cli: false, section: .shortcut)
        var accepted = false
        sheet.modifier.select(String(Self.shortcuts[0].1.rawValue))
        sheet.save = { _, _, _, _, _, _, _, key, mask in accepted = key == "k" && mask == .command }
        sheet.key.stringValue = ""
        sheet.applySettings()
        guard !accepted, !sheet.info.stringValue.isEmpty else { return false }
        sheet.key.stringValue = "k"
        sheet.applySettings()
        return accepted
    }

    @objc private func applySettings() {
        let value = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.utf16.count == 1, value.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && $0.value > 31 }),
              let modifierID = modifier.selectedID,
              let mask = Self.shortcuts.first(where: { String($0.1.rawValue) == modifierID })?.1 else {
            info.stringValue = "Enter one letter, number, or punctuation key for the shortcut."
            return
        }
        do {
            try save?(endpoint, entries, catalog, model.selectedID.flatMap { $0.isEmpty ? nil : $0 },
                      effort.selectedID.flatMap { $0.isEmpty ? nil : $0 }, mode.selectedID == "plan",
                      cli.state == .on, value, mask)
            dismiss()
        } catch { info.stringValue = error.localizedDescription }
    }
}

@MainActor final class WebbyFloatingAgentPanel: NSPanel {
    var onClose: (() -> Void)?
    override func close() {
        let completion = onClose
        onClose = nil
        super.close()
        completion?()
    }
}

@MainActor private enum AgentSheetGlass {
    static func install(in window: NSWindow, theme: PetGradientProfile) {
        guard let content = window.contentView else { return }
        let glass = WebbyGlassBackdrop()
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(glass, positioned: .below, relativeTo: nil)
        let highlight = NSView()
        highlight.wantsLayer = true
        highlight.translatesAutoresizingMaskIntoConstraints = false
        let gradient = CAGradientLayer()
        BrowserTheme.apply(theme.gradients.ambient, to: gradient, alpha: 0.65)
        highlight.layer = gradient
        content.addSubview(highlight, positioned: .above, relativeTo: glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            glass.topAnchor.constraint(equalTo: content.topAnchor),
            glass.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            highlight.topAnchor.constraint(equalTo: content.topAnchor),
            highlight.heightAnchor.constraint(equalToConstant: 2)
        ])
    }
}

private struct AgentChoice {
    let id: String
    let title: String
    let detail: String?
    let symbol: String

    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query) || id.localizedCaseInsensitiveContains(query)
            || detail?.localizedCaseInsensitiveContains(query) == true
    }
}

@MainActor private final class AgentGlassPicker: NSButton {
    var onChange: (() -> Void)?
    private(set) var selectedID: String?
    private let label: String
    private let picker = AgentChoicePopover()
    private let glyph = NSImageView()
    private let value = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var choices: [AgentChoice] = []
    private var tint = NSColor.controlAccentColor
    private var profile: PetGradientProfile?
    private var hovered = false
    private var area: NSTrackingArea?

    init(label: String, symbol: String, compact: Bool = false) {
        self.label = label
        super.init(frame: .zero)
        title = ""
        target = self
        action = #selector(openPicker)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        toolTip = label
        setAccessibilityLabel(label)
        let contents = AgentChoiceDecoration()
        contents.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contents)
        glyph.image = AgentBrand.image(symbol)
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down", accessibilityDescription: nil)
        value.font = .systemFont(ofSize: 12, weight: .medium)
        value.lineBreakMode = .byTruncatingTail
        for view in [glyph, value, chevron] { view.translatesAutoresizingMaskIntoConstraints = false; contents.addSubview(view) }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: compact ? 94 : 240),
            heightAnchor.constraint(equalToConstant: 28),
            contents.leadingAnchor.constraint(equalTo: leadingAnchor),
            contents.trailingAnchor.constraint(equalTo: trailingAnchor),
            contents.topAnchor.constraint(equalTo: topAnchor),
            contents.bottomAnchor.constraint(equalTo: bottomAnchor),
            glyph.leadingAnchor.constraint(equalTo: contents.leadingAnchor, constant: 8),
            glyph.widthAnchor.constraint(equalToConstant: 13),
            glyph.centerYAnchor.constraint(equalTo: contents.centerYAnchor),
            value.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 6),
            value.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -5),
            value.centerYAnchor.constraint(equalTo: contents.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 9),
            chevron.trailingAnchor.constraint(equalTo: contents.trailingAnchor, constant: -8),
            chevron.centerYAnchor.constraint(equalTo: contents.centerYAnchor)
        ])
        refresh()
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    func applyTheme(_ theme: PetGradientProfile) {
        profile = theme
        tint = BrowserTheme.color(theme.palette.primary)
        refresh()
    }

    func setChoices(_ choices: [AgentChoice], selection: String?) {
        picker.close()
        self.choices = choices
        select(selection)
    }

    func select(_ id: String?) {
        selectedID = choices.first(where: { $0.id == id })?.id ?? choices.first?.id
        refresh()
    }

    @objc private func openPicker() {
        if picker.isShown { picker.close(); return }
        picker.show(from: self, title: label, choices: choices, selection: selectedID, theme: profile) { [weak self] id in
            guard let self, self.selectedID != id else { return }
            self.select(id)
            self.onChange?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if [36, 49, 76, 125, 126].contains(event.keyCode) { openPicker() }
        else { super.keyDown(with: event) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; refresh() }
    override func mouseExited(with event: NSEvent) { hovered = false; refresh() }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh() }

    private func refresh() {
        let selected = choices.first { $0.id == selectedID }
        value.stringValue = selected?.title ?? "Choose…"
        setAccessibilityValue(value.stringValue)
        glyph.contentTintColor = .secondaryLabelColor
        chevron.contentTintColor = .tertiaryLabelColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (hovered ? tint : NSColor.labelColor).withAlphaComponent(hovered ? 0.13 : 0.05).cgColor
            layer?.borderColor = (hovered ? tint : NSColor.separatorColor).withAlphaComponent(hovered ? 0.46 : 0.32).cgColor
        }
    }
}

@MainActor private final class AgentChoiceDecoration: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor private final class AgentChoicePopover: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    private let popover = NSPopover()
    private let search = NSTextField(string: "")
    private let searchShell = NSView()
    private let searchIcon = NSImageView()
    private let scroll = NSScrollView()
    private let document = AgentSlashRows()
    private let empty = NSTextField(labelWithString: "")
    private var monitor: Any?
    private var choices: [AgentChoice] = []
    private var matches: [AgentChoice] = []
    private var rows: [AgentChoiceRow] = []
    private var selectedID: String?
    private var index = 0
    private var tint = NSColor.controlAccentColor
    private var onSelect: ((String) -> Void)?
    private let rowHeight: CGFloat = 39
    var isShown: Bool { popover.isShown }

    override init() {
        super.init()
        popover.behavior = .transient
        popover.animates = Motion.enabled
        popover.delegate = self
        search.delegate = self
        search.placeholderAttributedString = NSAttributedString(string: "Filter options", attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.secondaryLabelColor
        ])
        search.textColor = .labelColor
        search.font = .systemFont(ofSize: 12)
        search.isBordered = false
        search.drawsBackground = false
        searchShell.wantsLayer = true
        searchShell.layer?.cornerRadius = 7
        searchShell.addSubview(search)
        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchShell.addSubview(searchIcon)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        document.autoresizingMask = [.width]
        empty.alignment = .center
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
    }

    func show(from anchor: NSView, title: String, choices: [AgentChoice], selection: String?,
              theme: PetGradientProfile?, onSelect: @escaping (String) -> Void) {
        guard anchor.window != nil else { return }
        close()
        self.choices = choices
        selectedID = selection
        self.onSelect = onSelect
        tint = theme.map { BrowserTheme.color($0.palette.primary) } ?? .controlAccentColor
        let searchable = choices.count > 6
        let width: CGFloat = 302
        let height = CGFloat(max(1, min(7, choices.count))) * rowHeight + (searchable ? 76 : 43)
        let root = WebbyGlassBackdrop(frame: NSRect(x: 0, y: 0, width: width, height: height))
        root.appearance = anchor.effectiveAppearance
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .active
        if let theme {
            root.wantsLayer = true
            let line = CAGradientLayer()
            BrowserTheme.apply(theme.gradients.ambient, to: line, alpha: 0.67)
            line.frame = NSRect(x: 0, y: height - 2, width: width, height: 2)
            root.layer?.addSublayer(line)
        }
        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        let hint = NSTextField(labelWithString: "↑↓  Move   ↵  Select")
        hint.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .right
        heading.frame = NSRect(x: 12, y: height - 27, width: 155, height: 18)
        hint.frame = NSRect(x: 167, y: height - 27, width: 123, height: 16)
        root.addSubview(heading)
        root.addSubview(hint)
        if searchable {
            search.stringValue = ""
            searchShell.frame = NSRect(x: 9, y: height - 58, width: width - 18, height: 25)
            root.effectiveAppearance.performAsCurrentDrawingAppearance {
                searchShell.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.075).cgColor
            }
            searchIcon.frame = NSRect(x: 8, y: 6, width: 13, height: 13)
            search.frame = NSRect(x: 26, y: 4, width: width - 51, height: 18)
            root.addSubview(searchShell)
        } else {
            searchShell.removeFromSuperview()
            search.stringValue = ""
        }
        let heightForRows = height - (searchable ? 65 : 32)
        scroll.frame = NSRect(x: 6, y: 7, width: width - 12, height: heightForRows - 7)
        root.addSubview(scroll)
        empty.frame = NSRect(x: 6, y: 10, width: width - 12, height: 24)
        root.addSubview(empty)
        let controller = NSViewController()
        controller.view = root
        popover.contentViewController = controller
        popover.contentSize = root.frame.size
        filter("")
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        if searchable {
            DispatchQueue.main.async { [weak self, weak root] in
                guard let self, self.popover.isShown else { return }
                root?.window?.makeFirstResponder(self.search)
            }
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak root, weak anchor] event in
            guard let self, self.popover.isShown, let window = event.window,
                  window === root?.window || window === anchor?.window,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return event }
            if self.handleKey(event.keyCode) { return nil }
            if searchable, window !== root?.window, self.typeIntoFilter(event) { return nil }
            return event
        }
    }

    private func typeIntoFilter(_ event: NSEvent) -> Bool {
        if event.keyCode == 51 {
            if !search.stringValue.isEmpty { search.stringValue.removeLast() }
        } else if let text = event.characters, !text.isEmpty, text.allSatisfy({ !$0.isNewline && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " ") }) {
            search.stringValue += text
        } else { return false }
        filter(search.stringValue)
        return true
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        if popover.isShown { popover.close() }
    }

    func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown else { return }
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        onSelect = nil
    }

    func controlTextDidChange(_ notification: Notification) { filter(search.stringValue) }

    func filter(_ query: String) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        matches = choices.filter { $0.matches(query) }
        index = matches.firstIndex { $0.id == selectedID } ?? 0
        rows.forEach { $0.removeFromSuperview() }
        document.frame = NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: CGFloat(matches.count) * rowHeight)
        rows = matches.enumerated().map { offset, choice in
            let row = AgentChoiceRow(choice: choice, selected: choice.id == selectedID, tint: tint,
                                     target: self, action: #selector(chooseRow(_:)))
            row.tag = offset
            row.frame = NSRect(x: 0, y: CGFloat(offset) * rowHeight, width: document.bounds.width, height: rowHeight - 2)
            row.autoresizingMask = [.width]
            document.addSubview(row)
            return row
        }
        empty.stringValue = choices.isEmpty ? "No options yet" : "No matching options"
        empty.isHidden = !matches.isEmpty
        updateHighlight()
    }

    private func updateHighlight() {
        for (offset, row) in rows.enumerated() { row.keyboardHighlighted = offset == index }
        if rows.indices.contains(index) { document.scrollToVisible(rows[index].frame) }
    }

    private func handleKey(_ key: UInt16) -> Bool {
        switch key {
        case 53: close()
        case 36, 76: choose(at: index)
        case 125, 126:
            guard !matches.isEmpty else { return true }
            index = (index + (key == 125 ? 1 : -1) + matches.count) % matches.count
            updateHighlight()
        default: return false
        }
        return true
    }

    func captureFixture(from anchor: NSView, theme: PetGradientProfile, path: String) throws {
        let sample = AgentBrand.providers([["path": "/fixture.sock", "name": "Local terminal"]])
        show(from: anchor, title: "Agents", choices: sample, selection: "", theme: theme) { _ in }
        defer { close() }
        guard let view = popover.contentViewController?.view else { return }
        view.layoutSubtreeIfNeeded()
        guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: image)
        try image.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    static func verifiesSelection() -> Bool {
        let picker = AgentChoicePopover()
        picker.choices = [
            .init(id: "fast", title: "Fast", detail: "Latency", symbol: "bolt"),
            .init(id: "think", title: "Deep", detail: "Analysis", symbol: "waveform.path"),
            .init(id: "max", title: "Maximum", detail: "Analysis", symbol: "sparkles")
        ]
        var chosen: String?
        picker.onSelect = { chosen = $0 }
        picker.filter("analysis")
        guard picker.matches.map(\.id) == ["think", "max"], picker.handleKey(125), picker.handleKey(36) else { return false }
        return chosen == "max"
    }

    @objc private func chooseRow(_ sender: NSButton) { choose(at: sender.tag) }
    private func choose(at index: Int) {
        guard matches.indices.contains(index) else { return }
        let id = matches[index].id
        let action = onSelect
        close()
        action?(id)
    }
}

@MainActor private final class AgentChoiceRow: NSButton {
    private let tint: NSColor
    private let selected: Bool
    private var hover = false
    private var area: NSTrackingArea?
    var keyboardHighlighted = false { didSet { refresh() } }

    init(choice: AgentChoice, selected: Bool, tint: NSColor, target: AnyObject, action: Selector) {
        self.selected = selected
        self.tint = tint
        super.init(frame: .zero)
        title = ""
        self.target = target
        self.action = action
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 7
        setAccessibilityLabel(choice.title)
        setAccessibilityValue(selected ? "Selected" : "")
        let contents = AgentChoiceDecoration()
        contents.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contents)
        let image = NSImageView()
        image.image = AgentBrand.image(choice.symbol)
        image.contentTintColor = .secondaryLabelColor
        let check = NSImageView()
        check.image = selected ? NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) : nil
        check.contentTintColor = tint
        let title = NSTextField(labelWithString: choice.title)
        title.font = .systemFont(ofSize: 12, weight: selected ? .semibold : .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: choice.detail ?? "")
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: choice.detail == nil ? [title] : [title, detail])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        for view in [image, text, check] { view.translatesAutoresizingMaskIntoConstraints = false; contents.addSubview(view) }
        NSLayoutConstraint.activate([
            contents.leadingAnchor.constraint(equalTo: leadingAnchor), contents.trailingAnchor.constraint(equalTo: trailingAnchor),
            contents.topAnchor.constraint(equalTo: topAnchor), contents.bottomAnchor.constraint(equalTo: bottomAnchor),
            image.leadingAnchor.constraint(equalTo: contents.leadingAnchor, constant: 9),
            image.widthAnchor.constraint(equalToConstant: 15),
            image.centerYAnchor.constraint(equalTo: contents.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 8),
            text.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor, constant: -5),
            text.centerYAnchor.constraint(equalTo: contents.centerYAnchor),
            title.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            check.trailingAnchor.constraint(equalTo: contents.trailingAnchor, constant: -8),
            check.widthAnchor.constraint(equalToConstant: 14),
            check.centerYAnchor.constraint(equalTo: contents.centerYAnchor)
        ])
        if choice.detail != nil { detail.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor).isActive = true }
        refresh()
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .inVisibleRect, .activeAlways], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { hover = true; refresh() }
    override func mouseExited(with event: NSEvent) { hover = false; refresh() }

    private func refresh() {
        layer?.backgroundColor = tint.withAlphaComponent(hover || keyboardHighlighted ? 0.21 : selected ? 0.10 : 0).cgColor
    }
}

@MainActor private enum AgentBrand {
    static var cache: [String: NSImage] = [:]

    static func image(_ symbol: String) -> NSImage? {
        guard symbol.hasPrefix("brand:") else { return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        if let image = cache[symbol] { return image }
        let name = String(symbol.dropFirst(6))
        let url = Bundle.main.url(forResource: name == "Codex" ? "CodexWhiteIcon" : name, withExtension: "png",
                                  subdirectory: name == "Codex" ? nil : "WidgetBrands")
        guard let url, let image = NSImage(contentsOf: url) else { return NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil) }
        image.size = NSSize(width: 15, height: 15)
        image.isTemplate = name == "Codex"
        cache[symbol] = image
        return image
    }

    static func provider(_ key: String?) -> String {
        if let external = key.flatMap(WebbyExternalProvider.init(rawValue:)) {
            switch external {
            case .antigravity: return "brand:Antigravity"
            case .cursor: return "brand:Cursor"
            case .claude: return "brand:Claude"
            }
        }
        return key == nil || key == "" ? "brand:Codex" : "brand:Terminal"
    }

    static func providers(_ entries: [[String: String]]) -> [AgentChoice] {
        [.init(id: "", title: "Codex", detail: "Shared local Codex app server", symbol: "brand:Codex")]
            + WebbyExternalProvider.allCases.map {
                .init(id: $0.rawValue, title: $0.name,
                      detail: $0.executable == nil ? "Install and sign in to the local CLI" : "Local CLI · \($0.binary)",
                      symbol: provider($0.rawValue))
            }
            + entries.compactMap { entry in
                guard let path = entry["path"] else { return nil }
                return .init(id: path, title: entry["name"] ?? "Local provider", detail: "Codex-compatible socket", symbol: "brand:Terminal")
            }
    }

    static func models(_ catalog: [WebbyAgentPane.AgentModel], provider key: String?) -> [AgentChoice] {
        [.init(id: "", title: "Provider default", detail: "Use the recommended model", symbol: provider(key))]
            + catalog.filter { !$0.id.isEmpty }.map {
                let name = $0.id.lowercased()
                let symbol = name.contains("claude") || ["sonnet", "opus", "haiku"].contains(name)
                    ? "brand:Claude" : name.contains("codex") ? "brand:Codex" : provider(key)
                return .init(id: $0.id, title: $0.label, detail: $0.id == $0.label ? nil : $0.id, symbol: symbol)
            }
    }

    static func efforts(_ values: [String]) -> [AgentChoice] {
        [.init(id: "", title: "Model default", detail: "Use the model’s recommended effort", symbol: "sparkles")]
            + values.map { .init(id: $0, title: $0.capitalized, detail: nil, symbol: "waveform.path") }
    }

    static let modes: [AgentChoice] = [
        .init(id: "browse", title: "Browse", detail: "Act in background tabs", symbol: "safari"),
        .init(id: "plan", title: "Plan", detail: "Inspect pages and outline steps", symbol: "list.bullet.rectangle")
    ]

    static func command(_ name: String) -> String {
        switch name {
        case "/provider", "/agents": "brand:Codex"
        case "/model": "cpu"
        case "/effort": "waveform.path"
        case "/mode": "scope"
        case "/shortcut": "command"
        case "/settings": "gearshape"
        case "/history", "/older": "clock"
        case "/new": "plus.bubble"
        case "/tabs": "macwindow"
        case "/continue": "arrow.turn.down.right"
        case "/stop": "stop.fill"
        default: "questionmark.circle"
        }
    }
}
