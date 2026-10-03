import AppKit

@MainActor final class WidgetCanvasScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let canvas = documentView as? WidgetCanvas else { return }
        let wanted = NSSize(width: max(1010, contentView.bounds.width),
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
    override var mouseDownCanMoveWindow: Bool { false }
    var activate: ((WebbyWidget) -> Void)?
    var remove: ((WebbyWidget) -> Void)?
    var add: (() -> Void)?
    var submitCodex: ((String) -> Void)?
    private var profile = UUID()
    private var placements: [WidgetPlacement] = []
    private var cards: [WebbyWidget: GlassWidgetCard] = [:]
    private let addButton = NSButton(title: "+ Add Widget", target: nil, action: nil)
    private var horizontalInset: CGFloat { max(0, (bounds.width - 1010) / 2) }

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
            let containedGoogle = saved.contains { $0.kind.googleService != nil }
            placements = saved.filter { $0.kind.googleService == nil }
            if containedGoogle {
                // Reclaim the row previously occupied by Google widgets.
                for index in placements.indices where placements[index].y >= 200 {
                    placements[index].y = max(52, placements[index].y - 214)
                }
                save()
            }
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

    func setWeather(_ snapshot: WeatherSnapshot) { cards[.weather]?.setWeather(snapshot) }
    func setStock(_ snapshot: StockSnapshot) { cards[.stocks]?.setStock(snapshot) }

    func applyTheme(_ profile: PetGradientProfile) {
        for card in cards.values { card.applyTheme(profile) }
    }

    private var storageKey: String { "webbyWidgetCanvas.\(profile.uuidString)" }

    private func save() {
        if let data = try? JSONEncoder().encode(placements) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    private static func defaults() -> [WidgetPlacement] {
        [
            .init(kind: .weather, x: 12, y: 52, width: 320, height: 208),
            .init(kind: .stocks, x: 345, y: 52, width: 320, height: 208),
            .init(kind: .codex, x: 678, y: 52, width: 320, height: 208),
            .init(kind: .note, x: 12, y: 276, width: 320, height: 170)
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
            card.submitCodex = { [weak self] prompt in self?.submitCodex?(prompt) }
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
            if card.isInteracting { continue }
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
    override var mouseDownCanMoveWindow: Bool { false }
    let kind: WebbyWidget
    var activate: (() -> Void)?
    var remove: (() -> Void)?
    var submitCodex: ((String) -> Void)?
    var didMoveOrResize: ((NSRect) -> Void)?
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let body = NSTextField(labelWithString: "")
    private let action = NSButton(title: "Open", target: nil, action: nil)
    private let close = NSButton(title: "×", target: nil, action: nil)
    private let sparkline = WidgetSparkline()
    private let weatherIcon = NSImageView()
    private let weatherHalo = CAGradientLayer()
    private let weatherMeta = NSTextField(labelWithString: "")
    private let value = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let hourly = NSTextField(labelWithString: "")
    private let hourSymbols: [NSImageView] = (0..<5).map { _ in NSImageView() }
    private let hourLabels: [NSTextField] = (0..<5).map { _ in NSTextField(labelWithString: "") }
    private let promptField = NSTextField(string: "")
    private let promptButton = NSButton(title: "↗", target: nil, action: nil)
    private let promptGlass = NSVisualEffectView()
    private var weather: WeatherSnapshot?
    private var stock: StockSnapshot?
    private let gradientTint = CAGradientLayer()
    private let topSheen = CAGradientLayer()
    private let gradientRim = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private var dragStart = NSPoint.zero
    private var originalFrame = NSRect.zero
    private var resizing = false
    var isInteracting: Bool { originalFrame != .zero }

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
        weatherHalo.type = .radial
        weatherHalo.startPoint = CGPoint(x: 0.5, y: 0.5)
        weatherHalo.endPoint = CGPoint(x: 1, y: 1)
        weatherHalo.locations = [0, 1]
        layer?.addSublayer(weatherHalo)
        if kind == .codex,
           let path = Bundle.main.path(forResource: "CodexWhiteIcon", ofType: "png"),
           let codexIcon = NSImage(contentsOfFile: path) {
            icon.image = codexIcon
        } else {
            icon.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: kind.title)
        }
        if kind.googleService != nil { loadBrandIcon() }
        icon.imageScaling = .scaleProportionallyUpOrDown
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
        weatherIcon.imageScaling = .scaleProportionallyUpOrDown
        weatherIcon.wantsLayer = true
        weatherMeta.font = .systemFont(ofSize: 11, weight: .medium)
        weatherMeta.textColor = .secondaryLabelColor
        value.font = .systemFont(ofSize: 34, weight: .light)
        value.textColor = .labelColor
        detail.font = .systemFont(ofSize: 12, weight: .medium)
        detail.textColor = .secondaryLabelColor
        hourly.font = .systemFont(ofSize: 11, weight: .medium)
        hourly.textColor = .secondaryLabelColor
        hourly.alignment = .center
        for label in hourLabels {
            label.font = .systemFont(ofSize: 10, weight: .medium)
            label.alignment = .center
            label.textColor = .secondaryLabelColor
        }
        for symbol in hourSymbols { symbol.imageScaling = .scaleProportionallyUpOrDown }
        promptField.placeholderString = "Ask Codex…"
        promptField.font = .systemFont(ofSize: 12)
        promptField.isBordered = false
        promptField.drawsBackground = false
        promptField.focusRingType = .none
        promptField.alignment = .center
        promptField.target = self
        promptField.action = #selector(promptPressed)
        promptButton.isBordered = false
        promptButton.font = .systemFont(ofSize: 17)
        promptButton.target = self
        promptButton.action = #selector(promptPressed)
        promptGlass.material = .hudWindow
        promptGlass.blendingMode = .withinWindow
        promptGlass.state = .active
        promptGlass.wantsLayer = true
        promptGlass.layer?.cornerRadius = 12
        promptGlass.layer?.borderColor = NSColor.white.withAlphaComponent(0.23).cgColor
        promptGlass.layer?.borderWidth = 0.7
        for view in [icon, title, subtitle, body, action, close, sparkline,
                     weatherIcon, weatherMeta, value, detail, hourly, promptGlass, promptField, promptButton] { addSubview(view) }
        for view in hourSymbols { addSubview(view) }
        for view in hourLabels { addSubview(view) }
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
        if kind == .weather { weather = nil }
        if kind == .stocks { stock = nil }
        subtitle.stringValue = text
        body.stringValue = lines.prefix(7).joined(separator: "\n")
        action.title = busy ? "Loading…" : kind.googleService == nil ? "Open" : connected ? "Open ↗" : "Connect"
        sparkline.values = chart
        needsLayout = true
    }

    func setWeather(_ snapshot: WeatherSnapshot) {
        weather = snapshot
        weatherMeta.stringValue = snapshot.city
        value.stringValue = "\(snapshot.temperature)°"
        if let high = snapshot.high, let low = snapshot.low {
            detail.stringValue = "\(snapshot.condition)  ·  H \(high)°  L \(low)°"
        } else { detail.stringValue = snapshot.condition }
        let hourText = snapshot.hours.map { "\($0.label)  \($0.temperature)°" }.joined(separator: "     ")
        hourly.stringValue = hourText
        for index in hourLabels.indices {
            let item = index < snapshot.hours.count ? snapshot.hours[index] : nil
            hourLabels[index].stringValue = item.map { "\($0.label)  \($0.temperature)°" } ?? ""
            let hourSymbol: String
            switch item?.code ?? 0 {
            case 0: hourSymbol = "sun.max.fill"
            case 1, 2: hourSymbol = "cloud.sun.fill"
            case 3: hourSymbol = "cloud.fill"
            case 45, 48: hourSymbol = "cloud.fog.fill"
            case 51...67, 80...82: hourSymbol = "cloud.rain.fill"
            case 71...77, 85, 86: hourSymbol = "cloud.snow.fill"
            case 95...99: hourSymbol = "cloud.bolt.rain.fill"
            default: hourSymbol = "cloud.fill"
            }
            hourSymbols[index].image = item == nil ? nil : NSImage(systemSymbolName: hourSymbol, accessibilityDescription: nil)
            hourSymbols[index].contentTintColor = (item?.code ?? 0) == 0 ? .systemYellow : .systemCyan
        }
        let symbol: String
        switch snapshot.code {
        case 0: symbol = snapshot.isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: symbol = snapshot.isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: symbol = "cloud.fill"
        case 45, 48: symbol = "cloud.fog.fill"
        case 51...57: symbol = "cloud.drizzle.fill"
        case 61...67, 80...82: symbol = "cloud.rain.fill"
        case 71...77, 85, 86: symbol = "cloud.snow.fill"
        case 95...99: symbol = "cloud.bolt.rain.fill"
        default: symbol = "cloud.sun.fill"
        }
        weatherIcon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: snapshot.condition)
        let weatherColor: NSColor = snapshot.code == 0 ? .systemYellow :
            (71...77).contains(snapshot.code) || snapshot.code == 85 || snapshot.code == 86 ? .white : .systemCyan
        weatherIcon.contentTintColor = weatherColor
        weatherHalo.colors = [weatherColor.withAlphaComponent(0.26).cgColor,
                              weatherColor.withAlphaComponent(0).cgColor]
        weatherHalo.isHidden = false
        weatherIcon.layer?.removeAnimation(forKey: "weatherFloat")
        let isSun = snapshot.code == 0
        let motion = CABasicAnimation(keyPath: isSun ? "transform.rotation.z" : "transform.translation.y")
        motion.fromValue = isSun ? -0.12 : -2
        motion.toValue = isSun ? 0.12 : 2
        motion.duration = isSun ? 3.6 : 2.7
        motion.autoreverses = true
        motion.repeatCount = .infinity
        motion.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        weatherIcon.layer?.add(motion, forKey: "weatherFloat")
        weatherHalo.removeAnimation(forKey: "weatherGlow")
        let glow = CABasicAnimation(keyPath: "opacity")
        glow.fromValue = 0.45
        glow.toValue = 0.9
        glow.duration = 2.4
        glow.autoreverses = true
        glow.repeatCount = .infinity
        glow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        weatherHalo.add(glow, forKey: "weatherGlow")
        needsLayout = true
    }

    func setStock(_ snapshot: StockSnapshot) {
        stock = snapshot
        weatherMeta.stringValue = snapshot.symbol
        value.stringValue = snapshot.price
        let positive = snapshot.changePercent >= 0
        detail.stringValue = String(format: "%@%.2f%%", positive ? "▲ " : "▼ ", abs(snapshot.changePercent))
        detail.textColor = positive ? .systemGreen : .systemRed
        sparkline.values = snapshot.chart
        sparkline.tint = positive ? .systemGreen : .systemRed
        hourly.stringValue = snapshot.asOf
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
        let medium = width < 270 || height < 180
        title.isHidden = true
        weatherIcon.isHidden = true
        weatherHalo.isHidden = true
        weatherMeta.isHidden = true
        value.isHidden = true
        detail.isHidden = true
        hourly.isHidden = true
        for view in hourSymbols { view.isHidden = true }
        for view in hourLabels { view.isHidden = true }
        promptField.isHidden = true
        promptButton.isHidden = true
        promptGlass.isHidden = true
        close.isHidden = compact
        close.frame = NSRect(x: width - 27, y: height - 29, width: 21, height: 21)
        if kind == .weather, weather != nil {
            icon.isHidden = true; subtitle.isHidden = true; body.isHidden = true
            action.isHidden = true; sparkline.isHidden = true
            weatherIcon.isHidden = false
            weatherHalo.isHidden = false
            if compact {
                weatherIcon.frame = NSRect(x: (width - 45)/2, y: (height - 45)/2, width: 45, height: 45)
            } else if medium {
                weatherIcon.frame = NSRect(x: 16, y: (height - 56)/2, width: 56, height: 56)
                weatherMeta.isHidden = false; value.isHidden = false; detail.isHidden = false
                weatherMeta.frame = NSRect(x: 84, y: height - 39, width: width - 114, height: 18)
                value.frame = NSRect(x: 82, y: height - 87, width: width - 98, height: 43)
                detail.frame = NSRect(x: 84, y: 19, width: width - 98, height: 20)
            } else {
                weatherIcon.frame = NSRect(x: 19, y: height - 111, width: 75, height: 75)
                weatherMeta.isHidden = false; value.isHidden = false; detail.isHidden = false
                weatherMeta.frame = NSRect(x: 105, y: height - 41, width: width - 143, height: 18)
                value.frame = NSRect(x: 103, y: height - 91, width: width - 135, height: 47)
                detail.frame = NSRect(x: 106, y: height - 109, width: width - 130, height: 18)
                if height >= 190 {
                    for index in hourLabels.indices {
                        let cell = (width - 28) / 5
                        let x = 14 + CGFloat(index) * cell
                        hourSymbols[index].isHidden = false
                        hourLabels[index].isHidden = false
                        hourSymbols[index].frame = NSRect(x: x + (cell - 17)/2, y: 46, width: 17, height: 17)
                        hourLabels[index].frame = NSRect(x: x, y: 23, width: cell, height: 17)
                    }
                }
            }
            weatherHalo.frame = weatherIcon.frame.insetBy(dx: -20, dy: -20)
            return
        }
        if kind == .stocks, stock != nil {
            icon.isHidden = true; subtitle.isHidden = true; body.isHidden = true
            action.isHidden = true; weatherMeta.isHidden = false; detail.isHidden = false
            weatherMeta.font = .systemFont(ofSize: compact ? 14 : 17, weight: .semibold)
            weatherMeta.frame = NSRect(x: 16, y: height - (compact ? 30 : 41), width: width - 48, height: 25)
            detail.textColor = (stock?.changePercent ?? 0) >= 0 ? .systemGreen : .systemRed
            if compact {
                value.isHidden = true; sparkline.isHidden = true
                detail.frame = NSRect(x: 16, y: 13, width: width - 30, height: 24)
            } else {
                value.isHidden = false; sparkline.isHidden = sparkline.values.count < 2
                value.font = .systemFont(ofSize: medium ? 25 : 33, weight: .light)
                value.frame = NSRect(x: 16, y: height - (medium ? 77 : 87), width: width - 32, height: 39)
                detail.frame = NSRect(x: width - 105, y: height - 40, width: 80, height: 22)
                detail.alignment = .right
                sparkline.frame = NSRect(x: 16, y: medium ? 13 : 30, width: width - 32,
                                         height: medium ? max(20, height - 102) : max(38, height - 130))
                if !medium && height >= 195 {
                    hourly.isHidden = false
                    hourly.frame = NSRect(x: 16, y: 10, width: width - 32, height: 16)
                    hourly.alignment = .left
                }
            }
            return
        }
        if kind == .codex {
            subtitle.isHidden = true; body.isHidden = true; action.isHidden = true
            sparkline.isHidden = true
            icon.isHidden = false
            icon.contentTintColor = nil
            let size = compact ? min(width, height) * 0.59 : medium ? min(width, height) * 0.46 : 72.0
            icon.frame = NSRect(x: (width - size)/2, y: compact ? (height - size)/2 : (height - size)/2 + 17,
                                width: size, height: size)
            if !compact {
                promptGlass.isHidden = false; promptField.isHidden = false; promptButton.isHidden = false
                promptGlass.frame = NSRect(x: 16, y: 14, width: width - 32, height: 38)
                promptField.frame = NSRect(x: 27, y: 22, width: width - 74, height: 23)
                promptButton.frame = NSRect(x: width - 48, y: 19, width: 25, height: 27)
            }
            return
        }
        icon.isHidden = false
        if compact {
            icon.frame = NSRect(x: (width - 30) / 2, y: (height - 30) / 2, width: 30, height: 30)
            subtitle.isHidden = true
            body.isHidden = true
            action.isHidden = true
            sparkline.isHidden = true
            return
        }
        subtitle.isHidden = false
        body.isHidden = false
        action.isHidden = false
        close.isHidden = false
        sparkline.isHidden = kind != .stocks || medium || sparkline.values.count < 2
        icon.frame = NSRect(x: 16, y: height - 43, width: 24, height: 24)
        subtitle.frame = NSRect(x: 48, y: height - 40, width: width - 85, height: 20)
        action.frame = NSRect(x: 10, y: 9, width: 72, height: 22)
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
        let point = convert(event.locationInWindow, from: nil)
        if kind == .codex && event.clickCount == 1 && point.y < bounds.height - 44 &&
            !(point.x >= bounds.width - 32 && point.y <= 32) {
            submitCodex?("")
            return
        }
        if event.clickCount == 2 { activate?(); return }
        resizing = point.x >= bounds.width - 32 && point.y <= 32
        guard resizing || point.y >= bounds.height - 44 else { return }
        dragStart = canvas.convert(event.locationInWindow, from: nil)
        originalFrame = frame
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        if hit === action || hit === close || hit === promptField || hit === promptButton { return hit }
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
    @objc private func promptPressed() {
        let prompt = promptField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        promptField.stringValue = ""
        submitCodex?(prompt)
    }
}

@MainActor private final class WidgetSparkline: NSView {
    var values: [Double] = [] { didSet { needsDisplay = true } }
    var tint: NSColor = .systemGreen { didSet { needsDisplay = true } }
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
        let fill = path.copy() as! NSBezierPath
        fill.line(to: NSPoint(x: bounds.width, y: 0))
        fill.line(to: .zero)
        fill.close()
        NSGradient(starting: tint.withAlphaComponent(0.23),
                   ending: tint.withAlphaComponent(0.01))?.draw(in: fill, angle: 90)
        tint.withAlphaComponent(0.95).setStroke()
        path.stroke()
    }
}
