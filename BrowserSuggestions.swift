import AppKit

struct BrowserSuggestion {
    enum Kind { case pinned, bookmark, history, cookie }
    let title: String
    let url: String
    let kind: Kind
    var profileID: UUID? = nil
    var profileName: String? = nil
}

// Fuse routing uses history metadata only. WebKit credentials stay in the
// destination profile's existing data store.
enum FuseHistoryRouting {
    struct Source {
        let id: UUID
        let name: String
        let history: [BrowserLink]
    }
    static func nextProfile(after current: UUID?, profiles: [UUID]) -> UUID? {
        guard let current, let index = profiles.firstIndex(of: current) else { return profiles.first }
        return index + 1 < profiles.count ? profiles[index + 1] : nil
    }
    static func profile(for url: URL, sources: [Source]) -> UUID? {
        guard let host = url.host?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        let matches = sources.flatMap { source in
            source.history.compactMap { link -> (UUID, Date, Bool)? in
                guard let visited = URL(string: link.url), visited.host?.lowercased() == host else { return nil }
                return (source.id, link.visitedAt ?? .distantPast, visited.absoluteString == url.absoluteString)
            }
        }
        // Typed websites use the account most recently used on that host.
        // Clicking a suggestion supplies its source profile explicitly instead.
        return matches.max { lhs, rhs in lhs.1 == rhs.1 ? (!lhs.2 && rhs.2) : lhs.1 < rhs.1 }?.0
    }
}

private final class SuggestionRow: NSView {
    private let icon = NSImageView()
    private let headline = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let arrow = NSImageView()
    private let selectionGlow = CAGradientLayer()
    private let separator = CALayer()
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var selected = false
    private var featured = false
    private var hasFavicon = false
    private var accent = NSColor.controlAccentColor
    var onClick: (() -> Void)?

    init(item: BrowserSuggestion, index: Int, accent: NSColor) {
        super.init(frame: .zero)
        self.accent = accent
        featured = index == 0
        setAccessibilityLabel("\(item.title), \(item.url)")
        toolTip = item.url
        wantsLayer = true
        layer?.cornerRadius = 13
        selectionGlow.cornerRadius = 13
        selectionGlow.colors = [accent.withAlphaComponent(0.24).cgColor,
                                NSColor.white.withAlphaComponent(0.07).cgColor,
                                accent.withAlphaComponent(0.10).cgColor]
        selectionGlow.locations = [0, 0.50, 1]
        selectionGlow.startPoint = CGPoint(x: 0, y: 1)
        selectionGlow.endPoint = CGPoint(x: 1, y: 0)
        layer?.addSublayer(selectionGlow)
        separator.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        layer?.addSublayer(separator)
        icon.image = NSImage(systemSymbolName: Self.symbol(for: item.kind), accessibilityDescription: nil)
        icon.contentTintColor = accent
        icon.imageScaling = .scaleProportionallyDown
        headline.stringValue = item.title
        headline.font = .systemFont(ofSize: 14, weight: featured ? .semibold : .medium)
        headline.textColor = .labelColor
        headline.lineBreakMode = .byTruncatingTail
        detail.stringValue = (URL(string: item.url)?.host ?? item.url)
            + (item.profileName.map { " · " + $0 } ?? "")
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        arrow.image = NSImage(systemSymbolName: "arrow.turn.down.left", accessibilityDescription: nil)
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        addSubview(headline)
        addSubview(detail)
        addSubview(arrow)
        restyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        selectionGlow.frame = bounds
        separator.frame = NSRect(x: 69, y: 0, width: max(0, bounds.width - 87), height: 0.5)
        icon.frame = hasFavicon
            ? NSRect(x: 17, y: 13, width: 34, height: 34)
            : NSRect(x: 21, y: 17, width: 26, height: 26)
        let textWidth = max(0, bounds.width - 126)
        detail.frame = NSRect(x: 69, y: 34, width: textWidth, height: 14)
        headline.frame = NSRect(x: 69, y: 13, width: textWidth, height: 20)
        arrow.frame = NSRect(x: bounds.width - 35, y: 21, width: 17, height: 17)
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(tracking!)
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovered = true; restyle() }
    override func mouseExited(with event: NSEvent) { hovered = false; restyle() }
    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    func setSelected(_ value: Bool, featureWhenIdle: Bool) {
        selected = value
        featured = featureWhenIdle
        restyle()
    }

    func setFavicon(_ image: NSImage) {
        hasFavicon = true
        icon.image = image
        icon.contentTintColor = nil
        needsLayout = true
    }

    private func restyle() {
        let active = selected || hovered
        let emphasized = active || featured
        selectionGlow.opacity = emphasized ? 1 : 0
        layer?.backgroundColor = (emphasized ? NSColor.white.withAlphaComponent(0.05) : .clear).cgColor
        layer?.borderWidth = active ? 0.7 : 0
        layer?.borderColor = (active ? accent.withAlphaComponent(0.72)
                              : NSColor.white.withAlphaComponent(0.29)).cgColor
        separator.isHidden = emphasized
        arrow.contentTintColor = active ? accent : .tertiaryLabelColor
    }

    private static func symbol(for kind: BrowserSuggestion.Kind) -> String {
        switch kind {
        case .pinned: "pin.fill"
        case .bookmark: "bookmark.fill"
        case .history: "clock.arrow.circlepath"
        case .cookie: "globe"
        }
    }
}

/// Suggestions share the browser window and visually continue the search bar.
/// No popover window, arrow, or detached drop-down motion is involved.
@MainActor final class BrowserSuggestionPopup: NSObject {
    private weak var anchor: NSView?
    private weak var container: NSView?
    private var panel: NSVisualEffectView?
    private var scroll: NSScrollView?
    private var document: NSView?
    private var rows: [SuggestionRow] = []
    private var suggestions: [BrowserSuggestion] = []
    private var frameObserver: NSObjectProtocol?
    private var resizeObserver: NSObjectProtocol?
    private var clickMonitor: Any?
    private let outline = CAGradientLayer()
    private let outlineStroke = CAShapeLayer()
    private let entranceAura = CAGradientLayer()
    private let entranceAuraStroke = CAShapeLayer()
    private let entranceBeam = CAGradientLayer()
    private let entranceBeamStroke = CAShapeLayer()
    private let attachedClip = CAShapeLayer()
    private var iconsByHost: [String: NSImage] = [:]
    private var iconRequests: [String: URLSessionDataTask] = [:]
    private var missingIcons = Set<String>()
    var knownFavicon: ((URL) -> NSImage?)?
    var onChoose: ((BrowserSuggestion) -> Void)?
    private(set) var selectedIndex = -1

    var isShown: Bool { panel?.superview != nil }

    func applyTheme(_ profile: PetGradientProfile) {
        BrowserTheme.apply(profile.gradients.ambient, to: outline)
        BrowserTheme.apply(profile.gradients.ambient, to: entranceAura)
        BrowserTheme.apply(profile.gradients.ambient, to: entranceBeam)
    }

    func close() {
        (anchor as? GlassAddressSurface)?.setSuggestionsAttached(false)
        outline.removeFromSuperlayer()
        entranceAura.removeFromSuperlayer()
        entranceBeam.removeFromSuperlayer()
        panel?.removeFromSuperview()
        panel = nil
        scroll = nil
        document = nil
        rows.removeAll()
        suggestions.removeAll()
        selectedIndex = -1
        anchor = nil
        container = nil
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
        if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        frameObserver = nil
        resizeObserver = nil
        clickMonitor = nil
    }

    func show(_ items: [BrowserSuggestion], at anchor: NSView) {
        guard !items.isEmpty, let window = anchor.window,
              let container = window.contentView else { close(); return }
        if self.anchor !== anchor || self.container !== container { close() }
        let opening = panel == nil
        self.anchor = anchor
        self.container = container
        applyTheme(BrowserTheme.profile)
        (anchor as? GlassAddressSurface)?.setSuggestionsAttached(true)
        suggestions = Array(items.prefix(8))
        selectedIndex = 0
        if opening { makePanel(in: container, anchor: anchor, window: window) }
        rebuildRows()
        position()
        if opening && Motion.enabled, let layer = panel?.layer {
            Motion.basic(layer, key: "opacity", from: 0, to: 1, duration: 0.18)
        }
    }

    func playEntranceBeam() {
        guard isShown, Motion.enabled else { return }
        entranceAuraStroke.removeAllAnimations()
        entranceBeamStroke.removeAllAnimations()
        for stroke in [entranceAuraStroke, entranceBeamStroke] {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            stroke.opacity = 0
            stroke.strokeStart = 0
            stroke.strokeEnd = 0
            CATransaction.commit()
            let start = CAKeyframeAnimation(keyPath: "strokeStart")
            start.values = [0, 0, 0.69, 1]
            start.keyTimes = [0, 0.20, 0.77, 1]
            let end = CAKeyframeAnimation(keyPath: "strokeEnd")
            end.values = [0.02, 0.28, 0.91, 1]
            end.keyTimes = [0, 0.20, 0.77, 1]
            let opacity = CAKeyframeAnimation(keyPath: "opacity")
            let peak: Float = stroke === entranceAuraStroke ? 0.68 : 1
            opacity.values = [0, peak, peak, 0]
            opacity.keyTimes = [0, 0.08, 0.78, 1]
            let sweep = CAAnimationGroup()
            sweep.animations = [start, end, opacity]
            sweep.duration = 0.92
            sweep.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 0.72, 0.28, 1)
            stroke.add(sweep, forKey: "entranceBeam")
        }
    }

    func move(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        selectedIndex = min(suggestions.count - 1, max(0, selectedIndex + delta))
        for (index, row) in rows.enumerated() {
            row.setSelected(index == selectedIndex, featureWhenIdle: selectedIndex < 0 && index == 0)
        }
        if rows.indices.contains(selectedIndex) {
            rows[selectedIndex].scrollToVisible(rows[selectedIndex].bounds)
        }
    }

    func selected() -> BrowserSuggestion? {
        suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
    }

    func rememberFavicon(_ image: NSImage, for pageURL: URL) {
        guard let host = pageURL.host?.lowercased() else { return }
        iconsByHost[host] = image
        missingIcons.remove(host)
        updateVisibleIcons(for: host, image: image)
    }

    func containsMouse() -> Bool {
        guard let panel, let window = panel.window else { return false }
        return panel.bounds.contains(panel.convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    private func makePanel(in container: NSView, anchor: NSView, window: NSWindow) {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        view.appearance = anchor.effectiveAppearance
        view.wantsLayer = true
        view.layer?.mask = attachedClip
        view.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        let profile = BrowserTheme.profile
        BrowserTheme.apply(profile.gradients.ambient, to: outline)
        BrowserTheme.apply(profile.gradients.ambient, to: entranceAura)
        BrowserTheme.apply(profile.gradients.ambient, to: entranceBeam)
        outlineStroke.fillColor = nil
        outlineStroke.strokeColor = NSColor.white.cgColor
        outlineStroke.lineWidth = 1.5
        outline.mask = outlineStroke
        outline.zPosition = 1000
        entranceAuraStroke.fillColor = nil
        entranceAuraStroke.strokeColor = NSColor.white.cgColor
        entranceAuraStroke.lineWidth = 11
        entranceAuraStroke.lineCap = .round
        entranceAuraStroke.opacity = 0
        entranceAura.mask = entranceAuraStroke
        entranceAura.zPosition = 1001
        entranceBeamStroke.fillColor = nil
        entranceBeamStroke.strokeColor = NSColor.white.cgColor
        entranceBeamStroke.lineWidth = 3
        entranceBeamStroke.lineCap = .round
        entranceBeamStroke.opacity = 0
        entranceBeam.mask = entranceBeamStroke
        entranceBeam.zPosition = 1002
        let list = NSScrollView()
        list.drawsBackground = false
        list.hasVerticalScroller = true
        list.autohidesScrollers = true
        list.verticalScrollElasticity = .allowed
        view.addSubview(list)
        container.addSubview(view)
        container.layer?.addSublayer(outline)
        container.layer?.addSublayer(entranceAura)
        container.layer?.addSublayer(entranceBeam)
        panel = view
        scroll = list
        anchor.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification,
                                                               object: anchor, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.position() }
        }
        resizeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification,
                                                                object: window, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.position() }
        }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, event.window === window,
                  let panel = self.panel, let anchor = self.anchor else { return event }
            let point = event.locationInWindow
            if !panel.bounds.contains(panel.convert(point, from: nil)) &&
               !anchor.bounds.contains(anchor.convert(point, from: nil)) {
                self.close()
            }
            return event
        }
    }

    private func rebuildRows() {
        let accent = BrowserTheme.color(BrowserTheme.profile.palette.accent)
        rows = suggestions.enumerated().map { index, item in
            let row = SuggestionRow(item: item, index: index, accent: accent)
            row.setSelected(index == selectedIndex, featureWhenIdle: false)
            row.onClick = { [weak self] in self?.choose(at: index) }
            if let url = URL(string: item.url), let host = url.host?.lowercased() {
                if let icon = knownFavicon?(url) ?? iconsByHost[host] {
                    row.setFavicon(icon)
                    iconsByHost[host] = icon
                } else { requestFavicon(for: host, scheme: url.scheme ?? "https") }
            }
            return row
        }
        let content = NSView()
        for row in rows { content.addSubview(row) }
        document = content
        scroll?.documentView = content
    }

    private func updateVisibleIcons(for host: String, image: NSImage) {
        for (index, item) in suggestions.enumerated() where
            URL(string: item.url)?.host?.lowercased() == host && rows.indices.contains(index) {
            rows[index].setFavicon(image)
        }
    }

    private func requestFavicon(for host: String, scheme: String) {
        guard !missingIcons.contains(host), iconRequests[host] == nil else { return }
        fetchFavicon(host: host, scheme: scheme, pathIndex: 0)
    }

    private func fetchFavicon(host: String, scheme: String, pathIndex: Int) {
        let paths = ["/favicon.ico", "/apple-touch-icon.png"]
        guard paths.indices.contains(pathIndex) else { missingIcons.insert(host); return }
        var parts = URLComponents()
        parts.scheme = scheme == "http" ? "http" : "https"
        parts.host = host
        parts.path = paths[pathIndex]
        guard let url = parts.url else { missingIcons.insert(host); return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        request.cachePolicy = .returnCacheDataElseLoad
        let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.iconRequests.removeValue(forKey: host)
                if error == nil, let response = response as? HTTPURLResponse,
                   (200..<300).contains(response.statusCode), let data,
                   data.count <= 1_000_000, let image = NSImage(data: data) {
                    self.rememberFavicon(image, for: url)
                } else {
                    self.fetchFavicon(host: host, scheme: scheme, pathIndex: pathIndex + 1)
                }
            }
        }
        iconRequests[host] = task
        task.resume()
    }

    private func position() {
        guard let anchor, let container, let panel, let scroll, let document,
              anchor.window != nil else { return }
        let bar = anchor.convert(anchor.bounds, to: container)
        let below = container.isFlipped
            ? container.bounds.maxY - bar.maxY : bar.minY - container.bounds.minY
        let total = CGFloat(rows.count) * 60 + 12
        let height = min(total, max(90, below - 10), 432)
        let width = min(bar.width, container.bounds.width - 20)
        let x = min(max(10, bar.minX), container.bounds.maxX - width - 10)
        let y = container.isFlipped ? bar.maxY - 1 : bar.minY - height + 1
        panel.frame = NSRect(x: x, y: y, width: width, height: height)
        attachedClip.frame = panel.bounds
        attachedClip.path = attachedShapePath(in: panel.bounds)
        let combined = bar.union(panel.frame)
        outline.frame = combined
        outlineStroke.frame = CGRect(origin: .zero, size: combined.size)
        let radius = (anchor as? GlassAddressSurface)?.expandedCornerRadius ?? 21
        outlineStroke.path = CGPath(roundedRect: CGRect(origin: .zero, size: combined.size).insetBy(dx: 0.7, dy: 0.7),
                                    cornerWidth: max(0, radius - 0.7),
                                    cornerHeight: max(0, radius - 0.7), transform: nil)
        entranceAura.frame = combined
        entranceAuraStroke.frame = CGRect(origin: .zero, size: combined.size)
        entranceAuraStroke.path = outlineStroke.path
        entranceBeam.frame = combined
        entranceBeamStroke.frame = CGRect(origin: .zero, size: combined.size)
        entranceBeamStroke.path = outlineStroke.path
        scroll.frame = panel.bounds.insetBy(dx: 6, dy: 6)
        let rowWidth = max(0, scroll.contentSize.width - 2)
        let documentHeight = max(CGFloat(rows.count) * 60, scroll.contentSize.height)
        document.frame = NSRect(x: 0, y: 0, width: rowWidth, height: documentHeight)
        for (index, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: documentHeight - CGFloat(index + 1) * 60,
                               width: rowWidth, height: 60)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, documentHeight - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func attachedShapePath(in rect: CGRect) -> CGPath {
        let radius = min((anchor as? GlassAddressSurface)?.expandedCornerRadius ?? 21,
                         rect.width / 2, rect.height)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.minY),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.minY + radius),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }

    private func choose(at index: Int) {
        guard suggestions.indices.contains(index) else { return }
        let item = suggestions[index]
        close()
        onChoose?(item)
    }
}
