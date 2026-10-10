import AppKit
import JavaScriptCore

struct ASCIIArtwork: Codable {
    let id: String
    let name: String
    let rows: [String]
    static let catalog: [ASCIIArtwork] = {
        guard let url = Bundle.main.url(forResource: "ASCIIArtworks", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ASCIIArtwork].self, from: data)) ?? []
    }()
}

@MainActor final class ASCIIBackgroundCanvas: NSView {
    struct Placement: Codable {
        var id: String
        var x, y, width, height: CGFloat
        var brightness: Double = 0.24
        var rect: NSRect { NSRect(x: x, y: y, width: width, height: height) }
    }
    private var profileID = UUID()
    private var placements: [Placement] = []
    private var cards: [String: ASCIIArtView] = [:]
    private var dragID: String?
    private var dragStart = NSPoint.zero
    private var original = NSRect.zero
    private enum ResizeEdge { case corner, right, bottom }
    private var resizing: ResizeEdge?
    private var selectedID: String?
    private let selection = CAShapeLayer()
    private let handles = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        selection.strokeColor = NSColor.systemTeal.cgColor
        selection.fillColor = nil; selection.lineWidth = 1.5
        handles.strokeColor = NSColor.systemTeal.cgColor
        handles.fillColor = NSColor.white.cgColor; handles.lineWidth = 1.5
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func deselect() { selectedID = nil; updateSelection() }
    private func updateSelection() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        if let id = selectedID, let card = cards[id] {
            let rect = card.frame.insetBy(dx: 1, dy: 1)
            selection.path = CGPath(rect: rect, transform: nil)
            let path = CGMutablePath()
            for point in [NSPoint(x: rect.maxX, y: rect.maxY), NSPoint(x: rect.maxX, y: rect.midY), NSPoint(x: rect.midX, y: rect.maxY)] {
                path.addEllipse(in: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8))
            }
            handles.path = path
        } else { selection.path = nil; handles.path = nil }
        CATransaction.commit()
    }
    private var renderer: JSContext?
    private var timer: Timer?
    var isDragging: Bool { dragID != nil }
    override var isFlipped: Bool { true }
    // Foreground controls always own normal hit testing. The browser's mouse
    // monitor forwards only unoccupied background gestures to this canvas.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
    private var key: String { "webbyASCIIBackgrounds.\(profileID.uuidString)" }

    func show(profile: UUID) {
        dragID = nil; selectedID = nil
        profileID = profile
        placements = UserDefaults.standard.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([Placement].self, from: $0) } ?? []
        var seen = Set<String>()
        placements = placements.filter { entry in
            ASCIIArtwork.catalog.contains { $0.id == entry.id } && seen.insert(entry.id).inserted
        }
        rebuild()
    }
    func has(_ id: String) -> Bool { placements.contains { $0.id == id } }
    func brightness(_ id: String) -> Double { placements.first { $0.id == id }?.brightness ?? 0.24 }
    func toggle(_ id: String) {
        guard ASCIIArtwork.catalog.contains(where: { $0.id == id }) else { return }
        if has(id) { placements.removeAll { $0.id == id } }
        else { placements.append(Placement(id: id, x: 40 + CGFloat(placements.count % 3) * 30, y: 70 + CGFloat(placements.count % 3) * 30, width: min(640, max(80, bounds.width - 80)), height: min(360, max(80, bounds.height - 100)))) }
        save(); rebuild()
    }
    func setBrightness(_ value: Double, for id: String) {
        guard let index = placements.firstIndex(where: { $0.id == id }) else { return }
        placements[index].brightness = min(1, max(0, value))
        cards[id]?.alphaValue = placements[index].brightness
        save()
    }
    func resetPositions() {
        for index in placements.indices {
            placements[index].x = 40 + CGFloat(index % 3) * 30
            placements[index].y = 70 + CGFloat(index % 3) * 30
            placements[index].width = min(640, max(80, bounds.width - 80))
            placements[index].height = min(360, max(80, bounds.height - 100))
        }
        save(); rebuild()
    }
    func applyTheme(_ theme: PetGradientProfile) {
        for card in cards.values { card.setTheme(theme) }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(placements) { UserDefaults.standard.set(data, forKey: key) }
    }
    private func clamped(_ rect: NSRect) -> NSRect {
        let width = min(max(80, rect.width), max(80, bounds.width))
        let height = min(max(80, rect.height), max(80, bounds.height))
        return NSRect(x: min(max(0, rect.minX), max(0, bounds.width - width)),
                      y: min(max(0, rect.minY), max(0, bounds.height - height)), width: width, height: height)
    }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for entry in placements where entry.id != dragID { cards[entry.id]?.frame = clamped(entry.rect) }
        updateSelection()
        CATransaction.commit()
    }
    private func rebuild() {
        timer?.invalidate(); timer = nil; renderer = nil
        subviews.forEach { $0.removeFromSuperview() }; cards.removeAll()
        for entry in placements {
            guard let artwork = ASCIIArtwork.catalog.first(where: { $0.id == entry.id }) else { continue }
            let card = ASCIIArtView(frame: clamped(entry.rect))
            card.alphaValue = min(1, max(0, entry.brightness))
            card.setTheme(BrowserTheme.profile(for: profileID)); card.setRows(artwork.rows, animated: entry.id == "icosahedron")
            cards[entry.id] = card; addSubview(card)
        }
        layer?.addSublayer(selection); layer?.addSublayer(handles)
        updateSelection()
        if cards["icosahedron"] != nil,
           let url = Bundle.main.url(forResource: "ASCIIEngine", withExtension: "js"),
           let code = try? String(contentsOf: url, encoding: .utf8) {
            let context = JSContext()!
            context.evaluateScript(code)
            context.evaluateScript("var backgroundIco = ico.New(94,20,50,8,1,20);")
            renderer = context
            animate()
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.window != nil, !self.isHiddenOrHasHiddenAncestor, !self.isDragging else { return }
                    self.animate()
                }
            }
        }
    }
    private func animate() {
        guard let rows = renderer?.evaluateScript("backgroundIco.RotateX(.008); backgroundIco.RotateY(.012); backgroundIco.RenderRows();")?.toArray() as? [String] else { return }
        cards["icosahedron"]?.setRows(rows, animated: true)
    }
    func handleDragEvent(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        switch event.type {
        case .leftMouseDown:
            let selected = selectedID.flatMap { id in placements.first { $0.id == id && cards[id]?.frame.insetBy(dx: -10, dy: -10).contains(point) == true } }
            guard bounds.contains(point), let entry = selected ?? placements.reversed().first(where: { brightness($0.id) > 0 && cards[$0.id]?.frame.contains(point) == true }) else { deselect(); return false }
            selectedID = entry.id
            dragID = entry.id; dragStart = point; original = cards[entry.id]!.frame
            let right = abs(point.x - original.maxX) <= 16
            let bottom = abs(point.y - original.maxY) <= 16
            resizing = right && bottom ? .corner : right ? .right : bottom ? .bottom : nil
            updateSelection()
            return true
        case .leftMouseDragged:
            guard let id = dragID else { return false }
            let dx = point.x - dragStart.x, dy = point.y - dragStart.y
            var rect = original
            switch resizing {
            case .corner:
                let scale = max(80 / min(original.width, original.height), 1 + (abs(dx / original.width) > abs(dy / original.height) ? dx / original.width : dy / original.height))
                rect.size = NSSize(width: original.width * scale, height: original.height * scale)
            case .right: rect.size.width += dx
            case .bottom: rect.size.height += dy
            case nil: rect = original.offsetBy(dx: dx, dy: dy)
            }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            cards[id]?.frame = clamped(rect)
            updateSelection()
            CATransaction.commit()
            return true
        case .leftMouseUp:
            guard let id = dragID, let rect = cards[id]?.frame, let index = placements.firstIndex(where: { $0.id == id }) else { return false }
            placements[index].x = rect.minX; placements[index].y = rect.minY
            placements[index].width = rect.width; placements[index].height = rect.height
            dragID = nil; updateSelection(); save(); return true
        default: return false
        }
    }
    deinit { timer?.invalidate() }
}

@MainActor private final class ASCIIArtView: NSView {
    private var image: NSImage?
    private var rows: [String] = []
    private var animated = false
    private var theme: PetGradientProfile?
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layerContentsRedrawPolicy = .never
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateLayer() { layer?.contents = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) }
    func setRows(_ rows: [String], animated: Bool) { self.rows = rows; self.animated = animated; render() }
    func setTheme(_ theme: PetGradientProfile) { self.theme = theme; render() }
    private func render() {
        guard !rows.isEmpty else { return }
        let font = NSFont(name: "AppleBraille", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let width = rows.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 1
        let rendered = NSImage(size: NSSize(width: max(1, width), height: max(1, lineHeight * CGFloat(rows.count))))
        rendered.lockFocusFlipped(true)
        let start = BrowserTheme.color(animated ? "#8D54FF" : (theme?.palette.primary ?? "#FFFFFF"))
        let end = BrowserTheme.color(animated ? "#FF5471" : (theme?.palette.highlight ?? "#FFFFFF"))
        for (index, row) in rows.enumerated() {
            let color = start.blended(withFraction: CGFloat(index) / CGFloat(max(1, rows.count - 1)), of: end) ?? start
            (row as NSString).draw(at: NSPoint(x: 0, y: CGFloat(index) * lineHeight), withAttributes: [.font: font, .foregroundColor: color])
        }
        rendered.unlockFocus(); image = rendered
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer?.contents = rendered.cgImage(forProposedRect: nil, context: nil, hints: nil)
        CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
