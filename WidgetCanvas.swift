import AppKit

@MainActor final class WidgetCanvasScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let canvas = documentView as? WidgetCanvas else { return }
        let wanted = NSSize(width: max(900, contentView.bounds.width),
                            height: max(680, contentView.bounds.height))
        if canvas.frame.size != wanted { canvas.setFrameSize(wanted) }
    }
}

enum WebbyWidget: String, CaseIterable, Codable {
    case calendar, gmail, drive, weather, stocks, codex, note

    var title: String {
        switch self {
        case .calendar: "Calendar"
        case .gmail: "Gmail"
        case .drive: "Drive"
        case .weather: "Weather"
        case .stocks: "Stocks"
        case .codex: "Codex"
        case .note: "Quick Note"
        }
    }

    var symbol: String {
        switch self {
        case .calendar: "calendar"
        case .gmail: "envelope.fill"
        case .drive: "externaldrive.fill"
        case .weather: "cloud.sun.fill"
        case .stocks: "chart.line.uptrend.xyaxis"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .note: "square.and.pencil"
        }
    }

    var googleService: GoogleService? {
        switch self {
        case .calendar: .calendar
        case .gmail: .gmail
        case .drive: .drive
        default: nil
        }
    }
}

private struct WidgetPlacement: Codable {
    var kind: WebbyWidget
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat
}

@MainActor final class WidgetCanvas: NSView {
    var activate: ((WebbyWidget) -> Void)?
    var remove: ((WebbyWidget) -> Void)?
    var add: (() -> Void)?
    private var profile = UUID()
    private var placements: [WidgetPlacement] = []
    private var cards: [WebbyWidget: GlassWidgetCard] = [:]
    private let addButton = NSButton(title: "+ Add Widget", target: nil, action: nil)
    private var horizontalInset: CGFloat { max(0, (bounds.width - 900) / 2) }

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        addButton.bezelStyle = .rounded
        addButton.isBordered = false
        addButton.font = .systemFont(ofSize: 12, weight: .medium)
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addPressed)
        addSubview(addButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(profile: UUID) {
        self.profile = profile
        let key = storageKey
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([WidgetPlacement].self, from: data) {
            placements = saved
        } else {
            placements = Self.defaults()
        }
        rebuild()
    }

    func has(_ kind: WebbyWidget) -> Bool { cards[kind] != nil }

    func addWidget(_ kind: WebbyWidget) {
        guard !has(kind) else { return }
        let next = CGFloat(placements.count)
        placements.append(WidgetPlacement(kind: kind, x: 12 + (next.truncatingRemainder(dividingBy: 3)) * 28,
                                          y: 50 + next * 28, width: 260, height: 190))
        save()
        rebuild()
    }

    func removeWidget(_ kind: WebbyWidget) {
        placements.removeAll { $0.kind == kind }
        save()
        rebuild()
        remove?(kind)
    }

    func set(_ kind: WebbyWidget, subtitle: String, lines: [String], busy: Bool = false,
             connected: Bool = false, chart: [Double] = []) {
        cards[kind]?.set(subtitle: subtitle, lines: lines, busy: busy, connected: connected, chart: chart)
    }

    func applyTheme(_ profile: PetGradientProfile) {
        for card in cards.values { card.applyTheme(profile) }
    }

    private var storageKey: String { "webbyWidgetCanvas.\(profile.uuidString)" }

    private func save() {
        if let data = try? JSONEncoder().encode(placements) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    private static func defaults() -> [WidgetPlacement] {
        [
            .init(kind: .calendar, x: 12, y: 48, width: 280, height: 206),
            .init(kind: .gmail, x: 304, y: 48, width: 280, height: 206),
            .init(kind: .drive, x: 596, y: 48, width: 280, height: 206),
            .init(kind: .weather, x: 12, y: 266, width: 280, height: 190),
            .init(kind: .stocks, x: 304, y: 266, width: 280, height: 190),
            .init(kind: .codex, x: 596, y: 266, width: 280, height: 190),
            .init(kind: .note, x: 12, y: 468, width: 280, height: 190)
        ]
    }

    private func rebuild() {
        for card in cards.values { card.removeFromSuperview() }
        cards.removeAll()
        for placement in placements {
            let card = GlassWidgetCard(kind: placement.kind,
                                       frame: NSRect(x: placement.x + horizontalInset, y: placement.y,
                                                     width: placement.width, height: placement.height))
            card.activate = { [weak self] in self?.activate?(placement.kind) }
            card.remove = { [weak self] in self?.removeWidget(placement.kind) }
            card.didMoveOrResize = { [weak self] frame in
                guard let self, let index = self.placements.firstIndex(where: { $0.kind == placement.kind }) else { return }
                self.placements[index].x = frame.minX - self.horizontalInset
                self.placements[index].y = frame.minY
                self.placements[index].width = frame.width
                self.placements[index].height = frame.height
                self.save()
            }
            cards[placement.kind] = card
            addSubview(card)
            card.applyTheme(BrowserTheme.profile)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        addButton.frame = NSRect(x: horizontalInset + 8, y: 4, width: 102, height: 30)
        // Preserve user positions on resize. Keep each card reachable even when
        // the window becomes narrower than the original canvas.
        for (kind, card) in cards {
            var f = card.frame
            if let placement = placements.first(where: { $0.kind == kind }) {
                f.origin.x = placement.x + horizontalInset
            }
            card.frame = f
        }
    }

    @objc private func addPressed() { add?() }
}

@MainActor private final class GlassWidgetCard: NSVisualEffectView {
    let kind: WebbyWidget
    var activate: (() -> Void)?
    var remove: (() -> Void)?
    var didMoveOrResize: ((NSRect) -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let body = NSTextField(labelWithString: "")
    private let action = NSButton(title: "Open", target: nil, action: nil)
    private let close = NSButton(title: "×", target: nil, action: nil)
    private let grip = NSTextField(labelWithString: "◢")
    private let sparkline = WidgetSparkline()
    private let gradientTint = CAGradientLayer()
    private let topSheen = CAGradientLayer()
    private let gradientRim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private var dragStart = NSPoint.zero
    private var originalFrame = NSRect.zero
    private var resizing = false

    init(kind: WebbyWidget, frame: NSRect) {
        self.kind = kind
        super.init(frame: frame)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
        topSheen.colors = [NSColor.white.withAlphaComponent(0.13).cgColor,
                           NSColor.white.withAlphaComponent(0).cgColor]
        topSheen.locations = [0, 0.58]
        topSheen.startPoint = CGPoint(x: 0.5, y: 1)
        topSheen.endPoint = CGPoint(x: 0.5, y: 0)
        layer?.addSublayer(gradientTint)
        layer?.addSublayer(topSheen)
        gradientRim.mask = rimMask
        layer?.addSublayer(gradientRim)
        if kind == .codex,
           let codexIcon = NSImage(contentsOfFile: "/Applications/ChatGPT.app/Contents/Resources/app.icns") {
            icon.image = codexIcon
        } else {
            icon.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)
        }
        if kind.googleService != nil { loadBrandIcon() }
        icon.contentTintColor = .labelColor
        title.stringValue = kind.title
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        body.font = .systemFont(ofSize: 12)
        body.textColor = .labelColor
        body.lineBreakMode = .byTruncatingTail
        body.maximumNumberOfLines = 7
        action.isBordered = false
        action.font = .systemFont(ofSize: 11, weight: .medium)
        action.target = self
        action.action = #selector(actionPressed)
        close.isBordered = false
        close.font = .systemFont(ofSize: 17)
        close.contentTintColor = .secondaryLabelColor
        close.target = self
        close.action = #selector(closePressed)
        grip.font = .systemFont(ofSize: 13)
        grip.textColor = .tertiaryLabelColor
        for view in [icon, title, subtitle, body, action, close, grip, sparkline] { addSubview(view) }
        set(subtitle: "", lines: [])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func loadBrandIcon() {
        let address: String
        switch kind {
        case .calendar: address = "https://calendar.google.com/googlecalendar/images/favicons_2020q4/calendar_31.ico"
        case .gmail: address = "https://ssl.gstatic.com/ui/v1/icons/mail/rfr/gmail.ico"
        case .drive: address = "https://ssl.gstatic.com/docs/doclist/images/drive_2022q3_32dp.png"
        default: return
        }
        guard let url = URL(string: address) else { return }
        Task { [weak self] in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let image = NSImage(data: data) else { return }
            self?.icon.image = image
            self?.icon.contentTintColor = nil
        }
    }

    func set(subtitle text: String, lines: [String], busy: Bool = false,
             connected: Bool = false, chart: [Double] = []) {
        subtitle.stringValue = text
        body.stringValue = lines.prefix(7).joined(separator: "\n")
        action.title = busy ? "Loading…" : kind.googleService == nil ? "Open" : connected ? "Open ↗" : "Connect"
        sparkline.values = chart
        needsLayout = true
    }

    func applyTheme(_ profile: PetGradientProfile) {
        BrowserTheme.apply(profile.gradients.ambient, to: gradientTint, alpha: 0.08)
        BrowserTheme.apply(profile.gradients.ambient, to: gradientRim, alpha: 0.58)
        if kind != .codex, let first = profile.gradients.ambient.stops.first {
            icon.contentTintColor = BrowserTheme.color(first.color)
        }
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let height = bounds.height
        gradientTint.frame = bounds
        topSheen.frame = bounds
        gradientRim.frame = bounds
        rimMask.frame = bounds
        rimMask.path = CGPath(roundedRect: bounds.insetBy(dx: 0.6, dy: 0.6),
                              cornerWidth: 18, cornerHeight: 18, transform: nil)
        rimMask.fillColor = NSColor.clear.cgColor
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.lineWidth = 1.2
        let compact = width < 145 || height < 105
        let medium = width < 250 || height < 165
        if compact {
            icon.frame = NSRect(x: (width - 30) / 2, y: (height - 30) / 2, width: 30, height: 30)
            title.isHidden = true
            subtitle.isHidden = true
            body.isHidden = true
            action.isHidden = true
            close.isHidden = true
            grip.frame = NSRect(x: width - 18, y: 3, width: 13, height: 13)
            sparkline.isHidden = true
            return
        }
        title.isHidden = false
        subtitle.isHidden = false
        body.isHidden = false
        action.isHidden = false
        close.isHidden = false
        sparkline.isHidden = kind != .stocks || medium || sparkline.values.count < 2
        icon.frame = NSRect(x: 14, y: height - 38, width: 20, height: 20)
        title.frame = NSRect(x: 42, y: height - 38, width: max(30, width - 112), height: 21)
        close.frame = NSRect(x: width - 28, y: height - 39, width: 22, height: 24)
        subtitle.frame = NSRect(x: 15, y: height - 67, width: width - 30, height: 17)
        action.frame = NSRect(x: 10, y: 9, width: 72, height: 22)
        grip.frame = NSRect(x: width - 22, y: 4, width: 16, height: 16)
        body.frame = NSRect(x: 15, y: 38, width: width - 30, height: max(12, height - 110))
        body.maximumNumberOfLines = medium ? 2 : 7
        sparkline.frame = NSRect(x: 15, y: 39, width: width - 30, height: min(55, max(24, height - 150)))
        if !sparkline.isHidden {
            body.frame.origin.y = sparkline.frame.maxY + 6
            body.frame.size.height = max(20, height - 75 - body.frame.minY)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let canvas = superview else { return }
        if event.clickCount == 2 { activate?(); return }
        let point = convert(event.locationInWindow, from: nil)
        resizing = point.x >= bounds.width - 32 && point.y <= 32
        guard resizing || point.y >= bounds.height - 44 else { return super.mouseDown(with: event) }
        dragStart = canvas.convert(event.locationInWindow, from: nil)
        originalFrame = frame
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === action || hit === close { return hit }
        return hit == nil ? nil : self
    }

    override func mouseDragged(with event: NSEvent) {
        guard let canvas = superview, originalFrame != .zero else { return }
        let current = canvas.convert(event.locationInWindow, from: nil)
        let dx = current.x - dragStart.x
        let dy = current.y - dragStart.y
        if resizing {
            frame.size = NSSize(width: max(64, originalFrame.width + dx),
                                height: max(64, originalFrame.height + dy))
        } else {
            frame.origin = NSPoint(x: max(0, originalFrame.minX + dx),
                                   y: max(36, originalFrame.minY + dy))
        }
        needsLayout = true
    }

    override func mouseUp(with event: NSEvent) {
        guard originalFrame != .zero else { return }
        originalFrame = .zero
        didMoveOrResize?(frame)
    }

    @objc private func actionPressed() { activate?() }
    @objc private func closePressed() { remove?() }
}

@MainActor private final class WidgetSparkline: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard values.count > 1 else { return }
        let low = values.min() ?? 0
        let range = max(0.001, (values.max() ?? 0) - low)
        let path = NSBezierPath()
        path.lineWidth = 1.8
        for (index, value) in values.enumerated() {
            let point = NSPoint(x: CGFloat(index) / CGFloat(values.count - 1) * bounds.width,
                                y: 4 + CGFloat((value - low) / range) * (bounds.height - 8))
            if index == 0 { path.move(to: point) } else { path.line(to: point) }
        }
        NSColor.systemMint.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }
}
