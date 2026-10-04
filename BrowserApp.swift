import AppKit
import WebKit
import LocalAuthentication
import Security

final class BrowserTab {
    let id = UUID()
    // The tab may be displayed in another profile; its WebKit data and credentials
    // always belong to the profile where it was created.
    var ownerSpaceID: UUID?
    var title = "New Tab"
    var searchDraft = ""
    var pendingSearchInput: String?
    var showsSearchView = false
    var navigationInProgress = false
    var loadError: String?
    var isTerminal = false
    var isPinned = false
    var pinWidthFraction: CGFloat = 0.5
    var pinHeight: CGFloat = 72
    var isFloating = false
    var terminalView: NativeTerminalPane?
    var webView: WKWebView?
    var progressObservation: NSKeyValueObservation?
    var pageConstraints: [NSLayoutConstraint] = []
    var terminalConstraints: [NSLayoutConstraint] = []
    var favicon: NSImage?
    var previewImage: NSImage?
    var previewCapturedAt: TimeInterval = 0
    var previewGeneration = 0
    var faviconGeneration = 0
    var faviconTask: URLSessionDataTask?
    var prefersDarkGlass = true
}

private struct PinnedTabRecord: Codable {
    let title: String
    let url: String
    let ownerSpaceID: UUID?
    let widthFraction: Double?
    let height: Double?
}

private struct ClosedTabRecord {
    let title: String
    let address: String?
    let searchDraft: String
    let ownerSpaceID: UUID
    let displaySpaceID: UUID
    let wasPinned: Bool
    let wasTerminal: Bool
    let pinWidthFraction: CGFloat
    let pinHeight: CGFloat
}

@MainActor private final class TerminalTabIconView: NSView {
    private let engine = NotchIndicatorEngine()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(engine.layer)
        engine.setProfile(BrowserTheme.profile, wave: false)
        engine.showScene("terminal")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        engine.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        engine.layer.setAffineTransform(CGAffineTransform(scaleX: 0.57, y: 0.57))
        engine.layout()
        CATransaction.commit()
    }

    func setVisible(_ visible: Bool) {
        isHidden = !visible
        if visible && engine.mode == .off { engine.showScene("terminal") }
        else if !visible { engine.hide() }
    }

    func applyTheme(_ profile: PetGradientProfile) { engine.setProfile(profile, wave: true) }
}

private final class TabActionButton: NSButton, NSDraggingSource {
    let tabID: UUID
    var allowsTabDrag = false
    private(set) var physicalDoubleClick = false

    init(tabID: UUID, title: String, target: AnyObject, action: Selector) {
        self.tabID = tabID
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func menu(for event: NSEvent) -> NSMenu? {
        (superview as? TabRow)?.menu(for: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let row = superview as? TabRow, row.superview is PinnedTabGrid else { return }
        addCursorRect(NSRect(x: 0, y: 0, width: bounds.width, height: 12), cursor: .resizeUpDown)
        if row.pinHeight > 52 {
            addCursorRect(NSRect(x: max(0, bounds.width - 12), y: 0,
                                 width: 12, height: bounds.height), cursor: .resizeLeftRight)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if (superview as? TabRow)?.beginPinResize(with: event) == true { return }
        guard allowsTabDrag, let window else {
            super.mouseDown(with: event)
            return
        }
        physicalDoubleClick = event.clickCount == 2
        defer { physicalDoubleClick = false }
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                guard bounds.contains(convert(next.locationInWindow, from: nil)) else { return }
                _ = NSApp.sendAction(action ?? #selector(BrowserApp.selectTabAction(_:)),
                                     to: target, from: self)
                return
            }
            guard hypot(next.locationInWindow.x - start.x,
                        next.locationInWindow.y - start.y) >= 7 else { continue }
            physicalDoubleClick = false
            startTabDrag(with: next)
            return
        }
    }

    private func startTabDrag(with event: NSEvent) {
        guard let row = superview as? TabRow else { return }
        row.cancelHoverPreview()
        let item = NSDraggingItem(pasteboardWriter: tabID.uuidString as NSString)
        let image = NSImage(size: row.bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: row.bounds.size),
                     xRadius: 8, yRadius: 8).fill()
        NSString(string: row.titleButton.title).draw(at: NSPoint(x: 34, y: 10),
                                                      withAttributes: [.foregroundColor: NSColor.labelColor,
                                                                       .font: NSFont.systemFont(ofSize: 12)])
        image.unlockFocus()
        item.setDraggingFrame(row.bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        (superview as? TabRow)?.draggingEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        (superview as? TabRow)?.draggingUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        (superview as? TabRow)?.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        (superview as? TabRow)?.performDragOperation(sender) ?? false
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
}

private final class PinnedTabGrid: NSView {
    var rows: [TabRow] = [] { didSet { needsLayout = true } }
    var onResize: ((UUID, CGFloat, CGFloat, Bool) -> Void)?
    override var isFlipped: Bool { true }

    private func groups() -> [[TabRow]] {
        var result: [[TabRow]] = []
        var index = 0
        while index < rows.count {
            let first = rows[index]
            var group = [first]
            index += 1
            if first.pinHeight > 52 {
                var fraction = min(1, max(0.22, first.pinWidthFraction))
                while index < rows.count, rows[index].pinHeight > 52, group.count < 4 {
                    let next = min(1, max(0.22, rows[index].pinWidthFraction))
                    guard fraction + next <= 1.001 else { break }
                    group.append(rows[index])
                    fraction += next
                    index += 1
                }
            }
            result.append(group)
        }
        return result
    }

    var requiredHeight: CGFloat {
        guard !rows.isEmpty else { return 0 }
        var height: CGFloat = 8
        for group in groups() {
            height += (group[0].pinHeight <= 52 ? 39 : group.map(\.pinHeight).max() ?? 72) + 8
        }
        return height
    }

    override func layout() {
        super.layout()
        let available = max(72, bounds.width - 16)
        var y: CGFloat = 8
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for group in groups() {
            if group[0].pinHeight <= 52 {
                let row = group[0]
                row.setTileMode(false)
                row.frame = NSRect(x: 8, y: y, width: available, height: 39)
                y += 47
            } else {
                let gaps = CGFloat(group.count - 1) * 8
                let fractions = group.map { min(1, max(0.22, $0.pinWidthFraction)) }
                let desired = fractions.reduce(0, +) * available
                let scale = min(1, (available - gaps) / desired)
                var x: CGFloat = 8
                for (row, fraction) in zip(group, fractions) {
                    let width = fraction * available * scale
                    row.setTileMode(true)
                    row.frame = NSRect(x: x, y: y, width: width, height: row.pinHeight)
                    row.setTileIconSize(width < 70 ? 22 : 32)
                    x += width + 8
                }
                y += (group.map(\.pinHeight).max() ?? 72) + 8
            }
        }
        CATransaction.commit()
    }

    func beginResize(_ row: TabRow, event: NSEvent, resizeWidth: Bool, resizeHeight: Bool) {
        guard let window, rows.contains(row) else { return }
        let start = event.locationInWindow
        let initialWidth = row.pinWidthFraction
        let initialHeight = row.pinHeight
        let neighbors = groups().first(where: { $0.contains(row) })?.filter { $0 !== row } ?? []
        let initialNeighborWidths = neighbors.map(\.pinWidthFraction)
        var changed = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let dx = next.locationInWindow.x - start.x
            let dy = start.y - next.locationInWindow.y
            if abs(dx) < 2 && abs(dy) < 2 && !changed { continue }
            changed = true
            if resizeWidth {
                let span = max(72, bounds.width - 16)
                let target = min(1, max(0.22, initialWidth + dx / span))
                let neighborTotal = initialNeighborWidths.reduce(0, +)
                let free = max(0, 1 - initialWidth - neighborTotal)
                var shortage = max(0, target - initialWidth - free)
                for (neighbor, original) in zip(neighbors, initialNeighborWidths) {
                    let reduction = min(shortage, max(0, original - 0.22))
                    neighbor.pinWidthFraction = original - reduction
                    shortage -= reduction
                    onResize?(neighbor.tabID, neighbor.pinWidthFraction, neighbor.pinHeight, false)
                }
                row.pinWidthFraction = target - shortage
            }
            if resizeHeight { row.pinHeight = min(240, max(39, initialHeight + dy)) }
            onResize?(row.tabID, row.pinWidthFraction, row.pinHeight, false)
            needsLayout = true
            superview?.layoutSubtreeIfNeeded()
            layoutSubtreeIfNeeded()
        }
        if changed { onResize?(row.tabID, row.pinWidthFraction, row.pinHeight, true) }
    }
}

private final class TabRow: NSView {
    let tabID: UUID
    var pinWidthFraction: CGFloat = 0.5
    var pinHeight: CGFloat = 72
    let titleButton: TabActionButton
    private let selectButton: TabActionButton
    private let closeButton: TabActionButton
    private let iconContainer = NSView()
    private let siteIcon = NSImageView()
    private let pinIcon = NSImageView()
    private let fallbackIcon = GradientSymbolView(symbol: "globe", size: 14)
    private let closeIcon = GradientSymbolView(symbol: "xmark", size: 12)
    private var terminalIcon: TerminalTabIconView?
    private let selectionGradient = CAGradientLayer()
    private let loadingTrack = CAShapeLayer()
    private let loadingBeam = CAShapeLayer()
    private let loadingGradient = CAGradientLayer()
    private var loadingActive = false
    private var loadingFraction: CGFloat = 0
    private var hovered = false
    private var selected = false
    private var tileMode = false
    private var rowHeight: NSLayoutConstraint!
    private var iconLeading: NSLayoutConstraint!
    private var iconCenterX: NSLayoutConstraint!
    private var iconWidth: NSLayoutConstraint!
    private var iconHeight: NSLayoutConstraint!
    private let profileRim = CAGradientLayer()
    private let profileRimMask = CAShapeLayer()
    private let faviconRim = CAGradientLayer()
    private let faviconRimMask = CAShapeLayer()
    private var rimFavicon: NSImage?
    private var hoverArea: NSTrackingArea?
    private var hoverPreviewWork: DispatchWorkItem?
    private var hoverGeneration = 0
    private weak var owner: BrowserApp?
    private var pinned = false
    var themeSpaceID: UUID?

    init(tabID: UUID, target: AnyObject) {
        self.tabID = tabID
        owner = target as? BrowserApp
        titleButton = TabActionButton(tabID: tabID, title: "New Tab", target: target,
                                      action: #selector(BrowserApp.selectTabAction(_:)))
        selectButton = TabActionButton(tabID: tabID, title: "", target: target,
                                       action: #selector(BrowserApp.selectTabAction(_:)))
        selectButton.allowsTabDrag = true
        closeButton = TabActionButton(tabID: tabID, title: "", target: target,
                                      action: #selector(BrowserApp.closeTabAction(_:)))
        super.init(frame: .zero)
        registerForDraggedTypes([.string])
        wantsLayer = false
        profileRim.mask = profileRimMask
        faviconRim.mask = faviconRimMask
        translatesAutoresizingMaskIntoConstraints = false
        selectButton.toolTip = "Hover to preview • Click to select • Double-click for Floating or profile options"
        selectButton.focusRingType = .none
        titleButton.alignment = .left
        titleButton.cell?.lineBreakMode = .byTruncatingTail
        iconContainer.translatesAutoresizingMaskIntoConstraints = false
        siteIcon.translatesAutoresizingMaskIntoConstraints = false
        siteIcon.imageScaling = .scaleProportionallyDown
        iconContainer.addSubview(siteIcon)
        pinIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
        pinIcon.contentTintColor = .secondaryLabelColor
        pinIcon.translatesAutoresizingMaskIntoConstraints = false
        pinIcon.isHidden = true
        iconContainer.addSubview(pinIcon)
        fallbackIcon.translatesAutoresizingMaskIntoConstraints = false
        iconContainer.addSubview(fallbackIcon)
        closeIcon.translatesAutoresizingMaskIntoConstraints = false
        closeButton.wantsLayer = true
        closeButton.addSubview(closeIcon)
        closeButton.toolTip = "Close Tab"
        loadingTrack.fillColor = nil
        loadingTrack.strokeColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
        loadingTrack.lineWidth = 1.5
        loadingTrack.shadowColor = NSColor.controlAccentColor.cgColor
        loadingTrack.shadowOpacity = 0.55
        loadingTrack.shadowRadius = 5
        loadingTrack.opacity = 0
        loadingBeam.fillColor = nil
        loadingBeam.strokeColor = NSColor.white.cgColor
        loadingBeam.lineWidth = 2.25
        loadingBeam.lineCap = .round
        loadingBeam.shadowColor = NSColor.controlAccentColor.cgColor
        loadingBeam.shadowOpacity = 0.85
        loadingBeam.shadowRadius = 7
        loadingBeam.strokeEnd = 0
        loadingBeam.opacity = 0
        loadingGradient.mask = loadingBeam
        addSubview(selectButton)
        selectButton.registerForDraggedTypes([.string])
        addSubview(iconContainer)
        addSubview(titleButton)
        addSubview(closeButton)
        applyTheme(BrowserTheme.profile)
        rowHeight = heightAnchor.constraint(equalToConstant: 39)
        iconLeading = iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        iconCenterX = iconContainer.centerXAnchor.constraint(equalTo: centerXAnchor)
        iconWidth = iconContainer.widthAnchor.constraint(equalToConstant: 18)
        iconHeight = iconContainer.heightAnchor.constraint(equalToConstant: 18)
        NSLayoutConstraint.activate([
            rowHeight,
            selectButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectButton.topAnchor.constraint(equalTo: topAnchor),
            selectButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconLeading,
            iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconWidth, iconHeight,
            siteIcon.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            siteIcon.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
            siteIcon.topAnchor.constraint(equalTo: iconContainer.topAnchor),
            siteIcon.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
            pinIcon.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 4),
            pinIcon.topAnchor.constraint(equalTo: iconContainer.topAnchor, constant: -2),
            pinIcon.widthAnchor.constraint(equalToConstant: 10),
            pinIcon.heightAnchor.constraint(equalToConstant: 10),
            fallbackIcon.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
            fallbackIcon.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
            fallbackIcon.topAnchor.constraint(equalTo: iconContainer.topAnchor),
            fallbackIcon.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor),
            titleButton.leadingAnchor.constraint(equalTo: iconContainer.trailingAnchor, constant: 7),
            titleButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -3),
            titleButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 25),
            closeButton.heightAnchor.constraint(equalToConstant: 25),
            closeIcon.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            closeIcon.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            closeIcon.widthAnchor.constraint(equalToConstant: 15),
            closeIcon.heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func beginPinResize(with event: NSEvent) -> Bool {
        guard let grid = superview as? PinnedTabGrid else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let bottom = point.y <= 12
        let right = pinHeight > 52 && point.x >= bounds.width - 12
        guard bottom || right else { return false }
        cancelHoverPreview()
        grid.beginResize(self, event: event, resizeWidth: right || bottom, resizeHeight: bottom)
        return true
    }

    func setTileMode(_ enabled: Bool) {
        rowHeight.isActive = !(superview is PinnedTabGrid)
        guard tileMode != enabled else { return }
        tileMode = enabled
        iconLeading.isActive = !enabled
        iconCenterX.isActive = enabled
        iconWidth.constant = enabled ? 32 : 18
        iconHeight.constant = enabled ? 32 : 18
        rowHeight.constant = enabled ? 72 : 39
        titleButton.isHidden = enabled
        closeButton.isHidden = enabled
        pinIcon.isHidden = enabled || !pinned
        layer?.cornerRadius = enabled ? 16 : 8
        selectionGradient.cornerRadius = enabled ? 16 : 8
        needsLayout = true
        updateBackground()
    }

    func setTileIconSize(_ size: CGFloat) {
        guard iconWidth.constant != size || iconHeight.constant != size else { return }
        iconWidth.constant = size
        iconHeight.constant = size
    }

    private func applyFaviconRim(_ favicon: NSImage?) {
        if rimFavicon === favicon { return }
        rimFavicon = favicon
        guard let favicon, let data = favicon.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data) else {
            faviconRim.colors = nil
            return
        }
        var samples: [(color: NSColor, saturation: CGFloat)] = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 5)) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 5)) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.55 else { continue }
                var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
                color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                if saturation > 0.20 && brightness > 0.18 && brightness < 0.98 {
                    samples.append((color, saturation))
                }
            }
        }
        let strongest = samples.sorted { $0.saturation > $1.saturation }
        guard let first = strongest.first?.color else { faviconRim.colors = nil; return }
        let second = strongest.dropFirst().first(where: { abs($0.color.hueComponent - first.hueComponent) > 0.12 })?.color
            ?? first.blended(withFraction: 0.5, of: .white) ?? first
        faviconRim.colors = [first.cgColor, second.cgColor, first.cgColor]
        faviconRim.startPoint = CGPoint(x: 0, y: 0)
        faviconRim.endPoint = CGPoint(x: 1, y: 1)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        hoverArea = NSTrackingArea(rect: .zero,
                                   options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                   owner: self)
        if let hoverArea { addTrackingArea(hoverArea) }
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        hoverGeneration += 1
        let generation = hoverGeneration
        updateBackground()
        hoverPreviewWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.hovered, self.hoverGeneration == generation,
                  let window = self.window, window.isKeyWindow else { return }
            let point = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard self.bounds.contains(point), !self.closeButton.frame.contains(point) else { return }
            self.owner?.showTabPreview(for: self.tabID, from: self)
        }
        hoverPreviewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        hoverGeneration += 1
        hoverPreviewWork?.cancel()
        hoverPreviewWork = nil
        owner?.hideTabPreview(for: tabID)
        updateBackground()
    }

    func cancelHoverPreview() {
        hoverGeneration += 1
        hoverPreviewWork?.cancel()
        hoverPreviewWork = nil
        owner?.hideTabPreview(for: tabID)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let pin = menu.addItem(withTitle: pinned ? "Unpin Tab" : "Pin Tab",
                               action: #selector(BrowserApp.togglePinTabAction(_:)), keyEquivalent: "")
        pin.target = owner
        pin.representedObject = tabID
        if pinned {
            let arrangement = NSMenuItem(title: "Pins Per Row", action: nil, keyEquivalent: "")
            let choices = NSMenu(title: "Pins Per Row")
            for count in 2...4 {
                let choice = choices.addItem(withTitle: "\(count)",
                                             action: #selector(BrowserApp.arrangePinsAction(_:)), keyEquivalent: "")
                choice.target = owner
                choice.tag = count
            }
            arrangement.submenu = choices
            menu.addItem(arrangement)
        }
        owner?.appendFloatingItem(for: tabID, to: menu)
        owner?.appendSplitItem(for: tabID, to: menu)
        owner?.appendMoveItems(for: tabID, to: menu)
        let close = menu.addItem(withTitle: "Close Tab", action: #selector(BrowserApp.closeTabMenuAction(_:)), keyEquivalent: "")
        close.target = owner
        close.representedObject = tabID
        return menu
    }

    private func updateBackground() {
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        selectionGradient.opacity = 0
        profileRim.opacity = 0
        faviconRim.opacity = 0
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionGradient.frame = bounds
        let radius: CGFloat = tileMode ? 16 : 7
        let path = CGPath(roundedRect: bounds.insetBy(dx: 1.25, dy: 1.25),
                          cornerWidth: radius, cornerHeight: radius, transform: nil)
        profileRim.frame = bounds
        faviconRim.frame = bounds
        profileRimMask.frame = bounds
        faviconRimMask.frame = bounds
        profileRimMask.path = path
        profileRimMask.fillColor = NSColor.clear.cgColor
        profileRimMask.strokeColor = NSColor.white.cgColor
        profileRimMask.lineWidth = tileMode ? 2.4 : 0
        faviconRimMask.path = CGPath(roundedRect: bounds.insetBy(dx: 3.2, dy: 3.2),
                                     cornerWidth: max(1, radius - 2), cornerHeight: max(1, radius - 2), transform: nil)
        faviconRimMask.fillColor = NSColor.clear.cgColor
        faviconRimMask.strokeColor = NSColor.white.cgColor
        faviconRimMask.lineWidth = tileMode ? 2.3 : 0
        loadingTrack.frame = bounds
        loadingTrack.path = path
        loadingBeam.frame = bounds
        loadingBeam.path = path
        loadingGradient.frame = bounds
        CATransaction.commit()
    }

    func applyTheme(_ profile: PetGradientProfile) {
        BrowserTheme.apply(profile.gradients.ambient, to: selectionGradient, alpha: 0.28)
        BrowserTheme.apply(profile.gradients.working, to: loadingGradient)
        BrowserTheme.apply(profile.gradients.working, to: profileRim, alpha: 0.92)
        let accent = BrowserTheme.color(profile.palette.accent)
        loadingTrack.strokeColor = accent.withAlphaComponent(0.25).cgColor
        loadingTrack.shadowColor = accent.cgColor
        loadingBeam.shadowColor = accent.cgColor
        fallbackIcon.applyTheme(profile)
        closeIcon.applyTheme(profile)
        terminalIcon?.applyTheme(profile)
        updateBackground()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if hit === closeButton || hit.isDescendant(of: closeButton) { return hit }
        return selectButton
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let string = sender.draggingPasteboard.string(forType: .string),
              let source = UUID(uuidString: string), source != tabID else { return [] }
        layer?.borderWidth = 2
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { layer?.borderWidth = 0 }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        guard let string = sender.draggingPasteboard.string(forType: .string),
              let source = UUID(uuidString: string) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        if point.y < bounds.height * 0.27 || point.y > bounds.height * 0.73 {
            return owner?.reorderTab(sourceID: source, targetID: tabID,
                                     before: point.y > bounds.midY) ?? false
        }
        if owner?.splitTabs(sourceID: source, targetID: tabID) == true { return true }
        return owner?.reorderTab(sourceID: source, targetID: tabID,
                                 before: point.y > bounds.midY) ?? false
    }

    func setLoadingProgress(_ progress: Double?) {
        guard let progress else {
            guard loadingActive else { return }
            loadingActive = false
            loadingFraction = 0
            let trackOpacity = loadingTrack.presentation()?.opacity ?? loadingTrack.opacity
            let beamOpacity = loadingBeam.presentation()?.opacity ?? loadingBeam.opacity
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            loadingTrack.opacity = 0
            loadingBeam.opacity = 0
            loadingBeam.strokeEnd = 0
            CATransaction.commit()
            Motion.basic(loadingTrack, key: "opacity", from: trackOpacity, to: 0, duration: 0.20)
            Motion.basic(loadingBeam, key: "opacity", from: beamOpacity, to: 0, duration: 0.20)
            return
        }
        if !loadingActive {
            loadingActive = true
            loadingFraction = 0
            loadingBeam.removeAnimation(forKey: "strokeEnd")
            loadingBeam.strokeEnd = 0
            loadingTrack.opacity = 1
            loadingBeam.opacity = 1
        }
        let next = max(loadingFraction, CGFloat(min(1, max(0, progress))))
        guard next > loadingFraction else { return }
        let current = loadingBeam.presentation()?.strokeEnd ?? loadingBeam.strokeEnd
        loadingFraction = next
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        loadingBeam.strokeEnd = next
        CATransaction.commit()
        Motion.basic(loadingBeam, key: "strokeEnd", from: current, to: next, duration: 0.16)
    }

    func update(title: String, selected: Bool, favicon: NSImage?, isTerminal: Bool, isPinned: Bool,
                loadingProgress: Double?) {
        titleButton.title = title
        titleButton.font = .systemFont(ofSize: 13, weight: selected ? .semibold : .regular)
        selectButton.toolTip = superview is PinnedTabGrid
            ? "\(title) • Drag the bottom or right edge to resize" : title
        if self.selected != selected {
            self.selected = selected
            updateBackground()
        }
        siteIcon.image = favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")
        siteIcon.contentTintColor = favicon == nil && tileMode ? .secondaryLabelColor : nil
        siteIcon.isHidden = isTerminal || (favicon == nil && !tileMode)
        fallbackIcon.isHidden = isTerminal || favicon != nil || tileMode
        if isTerminal && terminalIcon == nil {
            let icon = TerminalTabIconView(frame: .zero)
            icon.translatesAutoresizingMaskIntoConstraints = false
            iconContainer.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: iconContainer.leadingAnchor),
                icon.trailingAnchor.constraint(equalTo: iconContainer.trailingAnchor),
                icon.topAnchor.constraint(equalTo: iconContainer.topAnchor),
                icon.bottomAnchor.constraint(equalTo: iconContainer.bottomAnchor)
            ])
            terminalIcon = icon
        }
        terminalIcon?.setVisible(isTerminal)
        pinned = isPinned
        pinIcon.isHidden = !isPinned || tileMode
        if tileMode { applyFaviconRim(favicon); updateBackground() }
        setLoadingProgress(loadingProgress)
    }
}

@MainActor private final class AnimatedGlobeView: NSView {
    let engine = NotchIndicatorEngine()
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(engine.layer)
        engine.setProfile(BrowserTheme.profile, wave: false)
        engine.showScene("search")
        toolTip = "Open Terminal"
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        engine.layer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        engine.layer.setAffineTransform(CGAffineTransform(scaleX: 4, y: 4))
        engine.layout()
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private final class HomeSearchGroup: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor final class BrowserApp: NSObject, NSApplicationDelegate, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var window: NSWindow!
    private var content: NSView!
    private var sidebar: NSView!
    private var sidebarBackdrop: NSVisualEffectView!
    private var sidebarWidth: NSLayoutConstraint!
    private var mainArea: NSVisualEffectView!
    private var pageArea: NSView!
    private var toolbar: GlassPanel!
    private var toolbarLeading: NSLayoutConstraint!
    private var topAddressSurface: GlassAddressSurface!
    private var addressField: NSTextField!
    private var homeSearchField: NSTextField!
    private var loadErrorLabel: NSTextField!
    private var homeView: NSView!
    private var homeCenter: NSView!
    private var homeCenterTop: NSLayoutConstraint!
    private var homeSearchDragMonitor: Any?
    private var widgetDragMonitor: Any?
    private var homeSearchDragOrigin: NSPoint?
    private var homeSearchDragTop: CGFloat = 10
    private var homeSearchIsDragging = false
    private var widgetCanvas: WidgetCanvas!
    private var terminalCommandOnOpen: [UUID: String] = [:]
    private var lastWidgetRefresh: [UUID: Date] = [:]
    private var widgetTimer: Timer?
    private var previousCPUTicks: [UInt64]?
    private var cpuHistory: [Double] = []
    private var previousNetworkBytes: (received: UInt64, sent: UInt64)?
    private var previousNetworkTime: Date?
    private var clipboardChangeCount = -1
    private var clipboardHistory: [String] = []
    private var spotifyPollInFlight = false
    private var globe: AnimatedGlobeView!
    private var homeSearchSurface: GlassAddressSurface!
    private var chromeToggle: GlassButton!
    private var sidebarToggleButton: GlassButton!
    private var newTerminalButton: GlassButton!
    private var sidebarToggleLeading: NSLayoutConstraint!
    private var sidebarToggleTerminalTrailing: NSLayoutConstraint!
    private var terminalButtonLeading: NSLayoutConstraint!
    private var terminalButtonTrailing: NSLayoutConstraint!
    private var tabStack: NSStackView!
    private var pinGrid: PinnedTabGrid!
    private var pinGridHeight: NSLayoutConstraint!
    private var tabSpacer: NSView!
    private var spaceLabel: FusedProfileLabel!
    private var tabRows = [UUID: TabRow]()
    private var floatingWindows = [UUID: FloatingTabWindow]()
    private var floatingContentConstraints = [UUID: [NSLayoutConstraint]]()
    private var tabWidthConstraints = [UUID: NSLayoutConstraint]()
    private var splitView: NSSplitView?
    private var splitTabIDs: (UUID, UUID)?
    private var faviconCache = [URL: NSImage]()
    private var backButton: GlassButton!
    private var forwardButton: GlassButton!
    private var spaces: [BrowserSpace] = []
    private let spaceSaveQueue = DispatchQueue(label: "WebKitBrowser.SpaceSave", qos: .utility)
    private var pendingSpaceSave: DispatchWorkItem?
    private var importInProgress = false
    private var activeSpaceIndex = 0
    private var fusedTabOrder: [UUID] = []
    private var fusedActiveTabID: UUID?
    private var recentlyClosedTabs: [ClosedTabRecord] = []
    private var swipeDistance: CGFloat = 0
    private var lastSwipeAt: TimeInterval = 0
    private var lastScrollAt: TimeInterval = 0
    private var activeSpace: BrowserSpace { spaces[activeSpaceIndex] }
    private var tabs: [BrowserTab] {
        get {
            guard BrowserExperiment.cyclesNewTabProfiles else { return activeSpace.tabs }
            let all = spaces.flatMap(\.tabs)
            let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
            let ordered = fusedTabOrder.compactMap { byID[$0] }
            let seen = Set(ordered.map(\.id))
            return ordered + all.filter { !seen.contains($0.id) }
        }
        set {
            guard BrowserExperiment.cyclesNewTabProfiles else {
                activeSpace.tabs = newValue
                return
            }
            let newIDs = Set(newValue.map(\.id))
            let removed = Set(spaces.flatMap(\.tabs).map(\.id)).subtracting(newIDs)
            for space in spaces { space.tabs.removeAll { removed.contains($0.id) } }
            for tab in newValue where !spaces.contains(where: { $0.tabs.contains { $0.id == tab.id } }) {
                ownerSpace(for: tab).tabs.append(tab)
            }
            let rank = Dictionary(uniqueKeysWithValues: newValue.enumerated().map { ($0.element.id, $0.offset) })
            for space in spaces { space.tabs.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) } }
            fusedTabOrder = newValue.map(\.id)
        }
    }
    private var activeTabID: UUID? {
        get { BrowserExperiment.cyclesNewTabProfiles ? fusedActiveTabID : activeSpace.activeTabID }
        set {
            if BrowserExperiment.cyclesNewTabProfiles { fusedActiveTabID = newValue }
            else { activeSpace.activeTabID = newValue }
        }
    }
    private var sidebarVisible = true
    private var sidebarTransitionToken = 0
    private var terminalMode = false
    private var terminalTransitionToken = 0
    private var toolbarVisible = false
    private var toolbarTransitionToken = 0
    private var toolbarHideTimer: Timer?
    private var eventMonitor: Any?
    private var fastRule: WKContentRuleList?
    private var fastModeEnabled = true
    private var fastModeItem: NSMenuItem?
    private weak var fuseMenuItem: NSMenuItem?
    private var menuBar: BrowserMenuBar?
    private let suggestions = BrowserSuggestionPopup()
    private let tabPreview = TabPreviewPopover()
    private var linkPreview: NSPopover?
    private var linkPreviewWebView: WKWebView?
    private var linkPreviewOwnerID: UUID?
    private var linkPreviewURL: URL?
    private var cookieHosts = [UUID: [String]]()
    private weak var editingSearchField: NSTextField?
    private var downloads: BrowserDownloads!
    private let launchedAt = ProcessInfo.processInfo.systemUptime
    private var windowShownAt: TimeInterval?
    private var webViewReadyAt: TimeInterval?
    private var navigationStartedAt: TimeInterval?
    private var navigationCommittedAt: TimeInterval?
    private var navigationFinishedAt: TimeInterval?
    private var lastHost: String?
    private var navigationToken = 0

    private var activeTab: BrowserTab? { tabs.first { $0.id == activeTabID } }
    private var activeWebView: WKWebView? { activeTab?.webView }
    private func ownerSpace(for tab: BrowserTab) -> BrowserSpace {
        spaces.first { $0.saved.id == tab.ownerSpaceID }
            ?? spaces.first { $0.tabs.contains { $0.id == tab.id } } ?? activeSpace
    }

    private func displaySpace(for tab: BrowserTab) -> BrowserSpace {
        spaces.first { $0.tabs.contains { $0.id == tab.id } } ?? ownerSpace(for: tab)
    }

    private func experimentalModeChanged() {
        fuseMenuItem?.state = BrowserExperiment.cyclesNewTabProfiles ? .on : .off
        tabPreview.hide()
        linkPreview?.close()
        let enabled = BrowserExperiment.cyclesNewTabProfiles
        let selectedID = enabled ? activeSpace.activeTabID : fusedActiveTabID
        newTerminalButton.isHidden = !enabled
        toolbarLeading.constant = enabled ? 92 : 51
        updateSpaceLabel(animated: true)
        if enabled {
            fusedTabOrder = spaces.flatMap(\.tabs).map(\.id)
            fusedActiveTabID = nil
        } else {
            if let pair = splitTabIDs, let left = tab(id: pair.0), let right = tab(id: pair.1),
               displaySpace(for: left) !== displaySpace(for: right) { endSplit() }
            if let selectedID,
               let index = spaces.firstIndex(where: { $0.tabs.contains { $0.id == selectedID } }) {
                activeSpaceIndex = index
            }
            activeSpace.activeTabID = nil
            fusedTabOrder.removeAll()
            fusedActiveTabID = nil
            BrowserTheme.activate(activeSpace.saved.id)
        }
        for tab in spaces.flatMap(\.tabs) {
            if !tab.isFloating {
                tab.webView?.isHidden = true
                tab.terminalView?.isHidden = true
            }
        }
        if let selectedID, let selected = tab(id: selectedID), !selected.isFloating { selectTab(selected) }
        else if let first = tabs.first(where: { !$0.isFloating }) { selectTab(first) }
        else { addTab(select: true) }
        refreshTabs()
    }

    private func updateSpaceLabel(animated: Bool = false) {
        if BrowserExperiment.cyclesNewTabProfiles {
            spaceLabel.showFuse(animated: animated)
            spaceLabel.toolTip = "Fuse: all profiles together · Current tab belongs to \(activeSpace.saved.name)"
        } else {
            spaceLabel.showProfile(activeSpace.saved.name, animated: animated)
            spaceLabel.toolTip = "\(activeSpace.saved.name) • \(activeSpaceIndex + 1) of \(spaces.count) • Click or swipe to switch"
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let saved = BrowserSpaceStore.load()
        if saved.isEmpty {
            let personal = SavedBrowserSpace(id: UUID(), name: "Personal", chromeDirectory: nil,
                                             bookmarks: [], history: [])
            spaces = [BrowserSpace(personal)]
            try? BrowserSpaceStore.save([personal])
        } else { spaces = saved.map(BrowserSpace.init) }
        activeSpaceIndex = min(max(0, UserDefaults.standard.integer(forKey: "browserActiveSpace")), spaces.count - 1)
        BrowserTheme.activate(activeSpace.saved.id)
        installMenus()
        makeWindow()
        downloads = BrowserDownloads()
        makeSidebar()
        makeMainArea()
        makeHome()
        widgetTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollRealtimeWidgets() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .browserThemeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(glassChanged),
                                               name: .browserGlassChanged, object: nil)
        addTab(select: true)
        _ = restorePinnedTabs()
        if BrowserExperiment.cyclesNewTabProfiles {
            let originalIndex = activeSpaceIndex
            for index in spaces.indices where index != originalIndex && spaces[index].tabs.isEmpty {
                activeSpaceIndex = index
                _ = restorePinnedTabs()
            }
            activeSpaceIndex = originalIndex
            updateSpaceLabel()
        }
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.sizeWidgetCanvas() }
        menuBar = BrowserMenuBar(showBrowser: { [weak self] in self?.showBrowserWindow() },
                                 addWidget: { [weak self] in self?.showAddWidget() },
                                 resetWidgets: { [weak self] in self?.widgetCanvas?.resetPositions() },
                                 currentSpaceName: { [weak self] in self?.activeSpace.saved.name ?? "Profile" },
                                 importChrome: { [weak self] in self?.showChromeImport() },
                                 deleteProfile: { [weak self] in self?.showDeleteProfile() },
                                 openBookmarks: { [weak self] in self?.showLibrary(history: false) },
                                 openHistory: { [weak self] in self?.showLibrary(history: true) },
                                 importPasswords: { [weak self] in self?.importChromePasswords() },
                                 showPasswords: { [weak self] in self?.showSavedPasswords() },
                                 importSignIns: { [weak self] in self?.importChromeSignIns() },
                                 fillPassword: { [weak self] in self?.fillSavedPasswordForCurrentSite() },
                                 profiles: { [weak self] in self?.spaces.map { ($0.saved.id, $0.saved.name) } ?? [] },
                                 openTerminal: { [weak self] in self?.toggleTerminal() },
                                 experimentChanged: { [weak self] in self?.experimentalModeChanged() },
                                 tabPlacementChanged: { [weak self] in self?.applyTabPlacement() },
                                 chooseGoogleClient: { [weak self] in self?.chooseGoogleClient() },
                                 connectGoogle: { [weak self] service in self?.connectGoogle(service) },
                                 disconnectGoogle: { [weak self] service in self?.disconnectGoogle(service) },
                                 googleConnected: { [weak self] service in
                                     guard let self else { return false }
                                     return GoogleWorkspace.shared.isConnected(service, profile: self.activeSpace.saved.id)
                                 })
        hideTrafficLights()
        themeChanged()
        windowShownAt = ProcessInfo.processInfo.systemUptime
        app.activate(ignoringOtherApps: true)
        installChromeMonitor()
        DispatchQueue.main.async { [weak self] in self?.loadRules() }
        if saved.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showChromeImport()
            }
        }
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 770),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.delegate = self
        window.title = "Webby"
        window.styleMask.insert(.fullSizeContentView)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        // Background window dragging steals drag gestures from widgets and the
        // movable home search surface. The title bar remains draggable.
        window.isMovableByWindowBackground = false
        window.acceptsMouseMovedEvents = true
        window.minSize = NSSize(width: 750, height: 430)
        window.center()
        content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = NSColor.clear.cgColor
        window.contentView = content
        if let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: false)
        }
    }

    private func hideTrafficLights() {
        for kind: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(kind)?.isHidden = true
        }
    }

    func windowDidEnterFullScreen(_ notification: Notification) { hideTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) { hideTrafficLights() }
    func windowDidResize(_ notification: Notification) {
        sizeWidgetCanvas()
        restoreHomeSearchPosition()
    }

    private func sizeWidgetCanvas() {
        widgetCanvas?.enclosingScrollView?.needsLayout = true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: .browserThemeChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .browserGlassChanged, object: nil)
        suggestions.close()
        tabPreview.hide()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let homeSearchDragMonitor { NSEvent.removeMonitor(homeSearchDragMonitor) }
        if let widgetDragMonitor { NSEvent.removeMonitor(widgetDragMonitor) }
        for space in spaces { for tab in space.tabs { tab.terminalView?.stop() } }
        pendingSpaceSave?.cancel()
        let snapshot = spaces.map(\.saved)
        spaceSaveQueue.sync { try? BrowserSpaceStore.save(snapshot) }
    }

    private func showBrowserWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        hideTrafficLights()
    }

    @objc private func themeChanged() {
        let profile = BrowserTheme.profile
        if spaceLabel != nil { updateSpaceLabel() }
        WebbyIcon.updateDockIcon()
        globe.engine.setProfile(profile, wave: true)
        homeSearchSurface.applyTheme(profile)
        topAddressSurface.applyTheme(profile)
        suggestions.applyTheme(profile)
        toolbar.applyTheme(profile)
        downloads.applyTheme(profile)
        widgetCanvas?.applyTheme(profile)
        for (id, row) in tabRows {
            let ownerID = tab(id: id).map { ownerSpace(for: $0).saved.id }
            let rowProfile = ownerID.map { BrowserTheme.profile(for: $0) } ?? profile
            row.applyTheme(rowProfile)
            row.themeSpaceID = ownerID
        }
        for tab in tabs {
            tab.terminalView?.applyTheme(BrowserTheme.profile(for: ownerSpace(for: tab).saved.id))
        }
        func refreshButtons(in view: NSView) {
            if let button = view as? GlassButton { button.applyTheme(profile) }
            for child in view.subviews { refreshButtons(in: child) }
        }
        refreshButtons(in: content)
    }

    @objc private func glassChanged() {
        sidebarBackdrop.alphaValue = 1 - BrowserGlass.sidebarTransparency * 0.86
        toolbar.applyGlassTransparency()
        topAddressSurface.applyGlassTransparency()
        homeSearchSurface.applyGlassTransparency()
    }

    private func makeSidebar() {
        sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.masksToBounds = true
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: 238)
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor), sidebarWidth
        ])

        sidebarBackdrop = NSVisualEffectView()
        sidebarBackdrop.material = .sidebar
        sidebarBackdrop.appearance = NSAppearance(named: .darkAqua)
        sidebarBackdrop.blendingMode = .behindWindow
        sidebarBackdrop.state = .active
        sidebarBackdrop.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarBackdrop)
        NSLayoutConstraint.activate([
            sidebarBackdrop.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarBackdrop.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            sidebarBackdrop.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarBackdrop.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])
        sidebarBackdrop.alphaValue = 1 - BrowserGlass.sidebarTransparency * 0.86

        // Keep the contents at their full width while the glass viewport closes.
        // Constraining children directly to a zero-width sidebar breaks layout.
        let sidebarInner = NSView()
        sidebarInner.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarInner)
        NSLayoutConstraint.activate([
            sidebarInner.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarInner.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarInner.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarInner.widthAnchor.constraint(equalToConstant: 238)
        ])

        let newTab = GlassButton(symbol: "plus", label: "New Tab", target: self, action: #selector(newTabAction))
        newTab.translatesAutoresizingMaskIntoConstraints = false
        spaceLabel = FusedProfileLabel(frame: .zero)
        spaceLabel.showProfile(activeSpace.saved.name, animated: false)
        spaceLabel.translatesAutoresizingMaskIntoConstraints = false
        spaceLabel.toolTip = "Click to choose a profile, or swipe left or right with two fingers"
        spaceLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showSpaceMenu(_:))))
        let downloadButton = downloads.button
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        tabStack = NSStackView()
        tabStack.orientation = .vertical
        tabStack.alignment = .leading
        tabStack.distribution = .fill
        tabStack.spacing = 0
        tabStack.wantsLayer = false
        tabStack.translatesAutoresizingMaskIntoConstraints = false
        pinGrid = PinnedTabGrid()
        pinGrid.translatesAutoresizingMaskIntoConstraints = false
        pinGrid.onResize = { [weak self] id, width, height, finished in
            guard let self, let tab = self.tab(id: id) else { return }
            tab.pinWidthFraction = width
            tab.pinHeight = height
            self.pinGridHeight.constant = self.pinGrid.requiredHeight
            self.tabStack.needsLayout = true
            if finished { self.savePinnedTabs(for: self.displaySpace(for: tab)) }
        }
        pinGridHeight = pinGrid.heightAnchor.constraint(equalToConstant: 0)
        tabSpacer = NSView()
        tabSpacer.translatesAutoresizingMaskIntoConstraints = false
        tabSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        tabSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        tabStack.addArrangedSubview(pinGrid)
        tabStack.addArrangedSubview(tabSpacer)
        let scroll = WidgetCanvasScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.contentView.wantsLayer = false
        scroll.documentView = tabStack
        scroll.translatesAutoresizingMaskIntoConstraints = false
        sidebarInner.addSubview(newTab)
        sidebarInner.addSubview(spaceLabel)
        sidebarInner.addSubview(downloadButton)
        sidebarInner.addSubview(separator)
        sidebarInner.addSubview(scroll)
        NSLayoutConstraint.activate([
            newTab.leadingAnchor.constraint(equalTo: sidebarInner.leadingAnchor, constant: 14),
            newTab.topAnchor.constraint(equalTo: sidebarInner.topAnchor, constant: 18),
            newTab.widthAnchor.constraint(equalToConstant: 30), newTab.heightAnchor.constraint(equalToConstant: 30),
            spaceLabel.leadingAnchor.constraint(equalTo: newTab.trailingAnchor, constant: 4),
            spaceLabel.trailingAnchor.constraint(equalTo: downloadButton.leadingAnchor, constant: -4),
            spaceLabel.centerYAnchor.constraint(equalTo: newTab.centerYAnchor),
            downloadButton.trailingAnchor.constraint(equalTo: sidebarInner.trailingAnchor, constant: -14),
            downloadButton.centerYAnchor.constraint(equalTo: newTab.centerYAnchor),
            downloadButton.widthAnchor.constraint(equalToConstant: 34),
            downloadButton.heightAnchor.constraint(equalToConstant: 30),
            separator.leadingAnchor.constraint(equalTo: sidebarInner.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: sidebarInner.trailingAnchor, constant: -12),
            separator.topAnchor.constraint(equalTo: newTab.bottomAnchor, constant: 13),
            scroll.leadingAnchor.constraint(equalTo: sidebarInner.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: sidebarInner.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: sidebarInner.bottomAnchor, constant: -10),
            tabStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            tabStack.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            pinGrid.widthAnchor.constraint(equalTo: tabStack.widthAnchor),
            pinGridHeight,
            tabSpacer.widthAnchor.constraint(equalTo: tabStack.widthAnchor),
            tabSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        applyTabPlacement()
        sidebarVisible = !UserDefaults.standard.bool(forKey: "sidebarHidden")
        if !sidebarVisible { sidebarWidth.constant = 0; sidebar.isHidden = true }
    }

    private func applyTabPlacement() {
        guard tabStack != nil, tabSpacer != nil else { return }
        tabStack.removeArrangedSubview(tabSpacer)
        tabSpacer.removeFromSuperview()
        let index = BrowserTabPlacement.current == .bottom ? min(1, tabStack.arrangedSubviews.count)
            : tabStack.arrangedSubviews.count
        tabStack.insertArrangedSubview(tabSpacer, at: index)
        refreshTabs()
    }

    private func makeMainArea() {
        mainArea = NSVisualEffectView()
        mainArea.material = .popover
        mainArea.appearance = NSAppearance(named: .darkAqua)
        mainArea.blendingMode = .behindWindow
        mainArea.state = .active
        mainArea.wantsLayer = true
        mainArea.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(mainArea)
        NSLayoutConstraint.activate([
            mainArea.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            mainArea.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainArea.topAnchor.constraint(equalTo: content.topAnchor),
            mainArea.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        pageArea = NSView()
        pageArea.wantsLayer = true
        pageArea.layer?.backgroundColor = NSColor.clear.cgColor
        pageArea.translatesAutoresizingMaskIntoConstraints = false
        mainArea.addSubview(pageArea)
        NSLayoutConstraint.activate([
            pageArea.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor),
            pageArea.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor),
            pageArea.topAnchor.constraint(equalTo: mainArea.topAnchor),
            pageArea.bottomAnchor.constraint(equalTo: mainArea.bottomAnchor)
        ])

        sidebarToggleButton = GlassButton(symbol: "sidebar.left", label: "Toggle Tabs", target: self, action: #selector(toggleSidebar))
        sidebarToggleButton.translatesAutoresizingMaskIntoConstraints = false
        newTerminalButton = GlassButton(symbol: "terminal", label: "New Terminal Tab", target: self, action: #selector(newTerminalTabAction))
        newTerminalButton.translatesAutoresizingMaskIntoConstraints = false
        newTerminalButton.isHidden = !BrowserExperiment.cyclesNewTabProfiles
        chromeToggle = GlassButton(symbol: "magnifyingglass", label: "Show Address Bar", target: self, action: #selector(toggleToolbar))
        chromeToggle.translatesAutoresizingMaskIntoConstraints = false
        let back = GlassButton(symbol: "chevron.left", label: "Back", target: self, action: #selector(goBack))
        let forward = GlassButton(symbol: "chevron.right", label: "Forward", target: self, action: #selector(goForward))
        let reload = GlassButton(symbol: "arrow.clockwise", label: "Reload", target: self, action: #selector(reloadPage))
        let dismiss = GlassButton(symbol: "chevron.up", label: "Hide Address Bar", target: self, action: #selector(toggleToolbar))
        backButton = back; forwardButton = forward
        addressField = NSTextField(string: "")
        addressField.placeholderString = "Search Google or enter a URL"
        addressField.target = self
        addressField.action = #selector(openAddress)
        let addressSurface = GlassAddressSurface(field: addressField)
        topAddressSurface = addressSurface
        configureSuggestions(for: addressSurface)
        addressSurface.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [back, forward, reload, addressSurface, dismiss])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 5
        controls.translatesAutoresizingMaskIntoConstraints = false
        toolbar = GlassPanel(radius: 14)
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(controls)
        mainArea.addSubview(toolbar)
        mainArea.addSubview(sidebarToggleButton)
        mainArea.addSubview(newTerminalButton)
        mainArea.addSubview(chromeToggle)
        toolbar.isHidden = true
        chromeToggle.isHidden = true
        toolbarLeading = toolbar.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor,
                                                          constant: BrowserExperiment.cyclesNewTabProfiles ? 92 : 51)
        sidebarToggleLeading = sidebarToggleButton.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor, constant: 10)
        sidebarToggleTerminalTrailing = sidebarToggleButton.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor, constant: -55)
        terminalButtonLeading = newTerminalButton.leadingAnchor.constraint(equalTo: sidebarToggleButton.trailingAnchor, constant: 7)
        terminalButtonTrailing = newTerminalButton.trailingAnchor.constraint(equalTo: sidebarToggleButton.leadingAnchor, constant: -7)
        NSLayoutConstraint.activate([
            toolbarLeading,
            toolbar.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor, constant: -10),
            toolbar.topAnchor.constraint(equalTo: mainArea.topAnchor, constant: 5),
            toolbar.heightAnchor.constraint(equalToConstant: 52),
            sidebarToggleLeading,
            sidebarToggleButton.topAnchor.constraint(equalTo: mainArea.topAnchor, constant: 14),
            sidebarToggleButton.widthAnchor.constraint(equalToConstant: 34),
            sidebarToggleButton.heightAnchor.constraint(equalToConstant: 34),
            terminalButtonLeading,
            newTerminalButton.centerYAnchor.constraint(equalTo: sidebarToggleButton.centerYAnchor),
            newTerminalButton.widthAnchor.constraint(equalToConstant: 34),
            newTerminalButton.heightAnchor.constraint(equalToConstant: 34),
            chromeToggle.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor, constant: -10),
            chromeToggle.topAnchor.constraint(equalTo: mainArea.topAnchor, constant: 14),
            chromeToggle.widthAnchor.constraint(equalToConstant: 34),
            chromeToggle.heightAnchor.constraint(equalToConstant: 34),
            controls.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 9),
            controls.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -9),
            controls.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: 34), back.heightAnchor.constraint(equalToConstant: 34),
            forward.widthAnchor.constraint(equalToConstant: 34), forward.heightAnchor.constraint(equalToConstant: 34),
            reload.widthAnchor.constraint(equalToConstant: 34), reload.heightAnchor.constraint(equalToConstant: 34),
            dismiss.widthAnchor.constraint(equalToConstant: 34), dismiss.heightAnchor.constraint(equalToConstant: 34),
            addressSurface.heightAnchor.constraint(equalToConstant: 34),
            addressSurface.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
    }

    private func makeHome() {
        homeView = NSView()
        homeView.wantsLayer = true
        homeView.layer?.backgroundColor = NSColor.clear.cgColor
        homeView.translatesAutoresizingMaskIntoConstraints = false
        pageArea.addSubview(homeView)
        NSLayoutConstraint.activate([
            homeView.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            homeView.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            homeView.topAnchor.constraint(equalTo: pageArea.topAnchor),
            homeView.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor)
        ])
        globe = AnimatedGlobeView(frame: .zero)
        globe.translatesAutoresizingMaskIntoConstraints = false
        globe.onClick = { [weak self] in self?.globeClicked() }
        homeSearchField = NSTextField(string: "")
        homeSearchField.placeholderString = "Search the web or enter a URL"
        homeSearchField.font = .systemFont(ofSize: 19, weight: .regular)
        homeSearchField.target = self
        homeSearchField.action = #selector(openHomeSearch)
        let searchSurface = GlassAddressSurface(field: homeSearchField)
        homeSearchSurface = searchSurface
        configureSuggestions(for: searchSurface)
        searchSurface.translatesAutoresizingMaskIntoConstraints = false
        searchSurface.wantsLayer = true
        searchSurface.layer?.cornerRadius = 33
        let center = HomeSearchGroup()
        homeCenter = center
        center.translatesAutoresizingMaskIntoConstraints = false
        homeView.addSubview(center)
        center.addSubview(globe)
        center.addSubview(searchSurface)
        loadErrorLabel = NSTextField(labelWithString: "")
        loadErrorLabel.alignment = .center
        loadErrorLabel.font = .systemFont(ofSize: 12)
        loadErrorLabel.textColor = .secondaryLabelColor
        loadErrorLabel.maximumNumberOfLines = 3
        loadErrorLabel.lineBreakMode = .byWordWrapping
        loadErrorLabel.isHidden = true
        loadErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        center.addSubview(loadErrorLabel)
        let preferredWidth = center.widthAnchor.constraint(equalToConstant: 660)
        preferredWidth.priority = .defaultHigh
        homeCenterTop = center.topAnchor.constraint(equalTo: homeView.topAnchor, constant: 10)
        NSLayoutConstraint.activate([
            center.centerXAnchor.constraint(equalTo: homeView.centerXAnchor),
            homeCenterTop,
            preferredWidth,
            center.widthAnchor.constraint(lessThanOrEqualTo: homeView.widthAnchor, constant: -44),
            center.heightAnchor.constraint(equalToConstant: 208),
            globe.centerXAnchor.constraint(equalTo: center.centerXAnchor),
            globe.topAnchor.constraint(equalTo: center.topAnchor),
            globe.widthAnchor.constraint(equalToConstant: 112),
            globe.heightAnchor.constraint(equalToConstant: 102),
            searchSurface.leadingAnchor.constraint(equalTo: center.leadingAnchor),
            searchSurface.trailingAnchor.constraint(equalTo: center.trailingAnchor),
            searchSurface.topAnchor.constraint(equalTo: globe.bottomAnchor, constant: 18),
            searchSurface.heightAnchor.constraint(equalToConstant: 66),
            loadErrorLabel.leadingAnchor.constraint(equalTo: center.leadingAnchor, constant: 12),
            loadErrorLabel.trailingAnchor.constraint(equalTo: center.trailingAnchor, constant: -12),
            loadErrorLabel.topAnchor.constraint(equalTo: searchSurface.bottomAnchor, constant: 12)
        ])
        let scroll = WidgetCanvasScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        widgetCanvas = WidgetCanvas(frame: NSRect(x: 0, y: 0, width: 900, height: 680))
        widgetCanvas.activate = { [weak self] kind in self?.activateWidget(kind) }
        widgetCanvas.submitCodex = { [weak self] prompt in self?.launchCodexWidget(prompt: prompt) }
        widgetCanvas.musicCommand = { [weak self] command in self?.controlSpotify(command) }
        widgetCanvas.calculatorCalculated = { [weak self] line in self?.recordCalculation(line) }
        scroll.documentView = widgetCanvas
        homeView.addSubview(scroll, positioned: .below, relativeTo: center)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: homeView.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: homeView.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: homeView.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: homeView.bottomAnchor, constant: -8)
        ])
        widgetCanvas.show(profile: activeSpace.saved.id)
        widgetDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window, !self.homeView.isHidden else { return event }
            return self.widgetCanvas.handleDragEvent(event) ? nil : event
        }
        installHomeSearchDragMonitor()
        DispatchQueue.main.async { [weak self] in self?.restoreHomeSearchPosition() }
        refreshGoogleWidgets()
    }

    private var homeSearchPositionKey: String {
        "webbyHomeSearchPosition.\(activeSpace.saved.id.uuidString)"
    }

    private var homeSearchMaximumTop: CGFloat {
        guard homeView != nil, homeCenter != nil else { return 10 }
        return max(10, homeView.bounds.height - max(208, homeCenter.bounds.height) - 12)
    }

    private func restoreHomeSearchPosition() {
        guard homeCenterTop != nil, !homeSearchIsDragging else { return }
        let fraction = min(1, max(0, UserDefaults.standard.double(forKey: homeSearchPositionKey)))
        homeCenterTop.constant = 10 + CGFloat(fraction) * (homeSearchMaximumTop - 10)
    }

    private func installHomeSearchDragMonitor() {
        homeSearchDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window, self.homeSearchSurface != nil else { return event }
            switch event.type {
            case .leftMouseDown:
                let point = self.homeSearchSurface.convert(event.locationInWindow, from: nil)
                if !self.homeView.isHidden && self.homeSearchSurface.bounds.contains(point) {
                    self.homeSearchDragOrigin = event.locationInWindow
                    self.homeSearchDragTop = self.homeCenterTop.constant
                } else { self.homeSearchDragOrigin = nil }
                self.homeSearchIsDragging = false
            case .leftMouseDragged:
                guard let origin = self.homeSearchDragOrigin else { return event }
                let dx = event.locationInWindow.x - origin.x
                let dy = event.locationInWindow.y - origin.y
                if !self.homeSearchIsDragging {
                    guard abs(dy) > 6, abs(dy) > abs(dx) * 1.15 else { return event }
                    self.homeSearchIsDragging = true
                    self.suggestions.close()
                    let draft = self.homeSearchField.currentEditor()?.string ?? self.homeSearchField.stringValue
                    self.homeSearchField.abortEditing()
                    self.homeSearchField.stringValue = draft
                    self.window.makeFirstResponder(nil)
                }
                // AppKit window coordinates increase upward; the top constraint increases downward.
                self.homeCenterTop.constant = min(self.homeSearchMaximumTop,
                                                  max(10, self.homeSearchDragTop - dy))
                self.homeView.layoutSubtreeIfNeeded()
                return nil
            case .leftMouseUp:
                defer {
                    self.homeSearchDragOrigin = nil
                    self.homeSearchIsDragging = false
                }
                guard self.homeSearchIsDragging else { return event }
                let travel = max(1, self.homeSearchMaximumTop - 10)
                let fraction = (self.homeCenterTop.constant - 10) / travel
                UserDefaults.standard.set(Double(fraction), forKey: self.homeSearchPositionKey)
                return nil
            default: break
            }
            return event
        }
    }

    private func chooseGoogleClient() {
        let panel = NSOpenPanel()
        panel.allowedFileTypes = ["json"]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Desktop OAuth client JSON downloaded from Google Cloud. Webby stores only its client ID."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try GoogleWorkspace.shared.configureClient(from: url)
            refreshGoogleWidgets(force: true)
        } catch { showGoogleError(error) }
    }

    private func connectGoogle(_ service: GoogleService) {
        if !GoogleWorkspace.shared.hasClient {
            chooseGoogleClient()
            guard GoogleWorkspace.shared.hasClient else { return }
        }
        let profile = activeSpace.saved.id
        widgetCanvas?.set(widgetKind(service), subtitle: "Connecting in your browser…", lines: [], busy: true)
        GoogleWorkspace.shared.connect(service, profile: profile) { [weak self] result in
            guard let self else { return }
            if case .failure(let error) = result { self.showGoogleError(error) }
            if self.activeSpace.saved.id == profile { self.refreshGoogleWidgets(force: true) }
        }
    }

    private func disconnectGoogle(_ service: GoogleService) {
        GoogleWorkspace.shared.disconnect(service, profile: activeSpace.saved.id)
        refreshGoogleWidgets(force: true)
    }

    private func refreshGoogleWidgets(force: Bool = false) {
        guard widgetCanvas != nil else { return }
        let profile = activeSpace.saved.id
        if !force, let last = lastWidgetRefresh[profile], Date().timeIntervalSince(last) < 120 { return }
        lastWidgetRefresh[profile] = Date()
        for service in GoogleService.allCases {
            let kind = widgetKind(service)
            guard widgetCanvas.has(kind) else { continue }
            let connected = GoogleWorkspace.shared.isConnected(service, profile: profile)
            widgetCanvas.set(kind, subtitle: connected ? "Loading…" : "Connect this profile", lines: [], connected: connected)
            guard connected else { continue }
            GoogleWorkspace.shared.load(service, profile: profile) { [weak self] result in
                guard let self, self.activeSpace.saved.id == profile else { return }
                switch result {
                case .success(let data): self.widgetCanvas.set(kind, subtitle: "\(data.account) · \(data.headline)", lines: data.lines, connected: true)
                case .failure(let error): self.widgetCanvas.set(kind, subtitle: error.localizedDescription, lines: [], connected: true)
                }
            }
        }
        refreshLocalWidgets(profile: profile)
    }

    private func widgetKind(_ service: GoogleService) -> WebbyWidget {
        switch service { case .calendar: .calendar; case .gmail: .gmail; case .drive: .drive }
    }

    private func openGoogleService(_ service: GoogleService) {
        addTab(select: true)
        let address: String
        switch service {
        case .calendar: address = "https://calendar.google.com/calendar/"
        case .gmail: address = "https://mail.google.com/mail/"
        case .drive: address = "https://drive.google.com/drive/"
        }
        navigate(address)
    }

    private func showGoogleError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Could not connect Google"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func refreshLocalWidgets(profile: UUID) {
        if widgetCanvas.has(.note) {
            let note = UserDefaults.standard.string(forKey: "webbyNote.\(profile.uuidString)") ?? ""
            widgetCanvas.set(.note, subtitle: "Saved in this profile", lines: note.isEmpty ? ["Click Open to write a note"] : [note])
        }
        if widgetCanvas.has(.weather) {
            let city = UserDefaults.standard.string(forKey: "webbyWeatherCity.\(profile.uuidString)") ?? "San Francisco"
            widgetCanvas.set(.weather, subtitle: city, lines: ["Loading forecast…"], busy: true)
            Task { [weak self] in
                do {
                    let feed = try await WidgetFeeds.weather(city: city)
                    guard let self, self.activeSpace.saved.id == profile else { return }
                    if let snapshot = feed.weather { self.widgetCanvas.setWeather(snapshot) }
                } catch {
                    guard let self, self.activeSpace.saved.id == profile else { return }
                    self.widgetCanvas.set(.weather, subtitle: city, lines: [error.localizedDescription])
                }
            }
        }
        if widgetCanvas.has(.stocks) {
            let symbol = UserDefaults.standard.string(forKey: "webbyStockSymbol.\(profile.uuidString)") ?? "AAPL"
            widgetCanvas.set(.stocks, subtitle: symbol, lines: ["Loading quote…"], busy: true)
            Task { [weak self] in
                do {
                    let feed = try await WidgetFeeds.stock(symbol: symbol)
                    guard let self, self.activeSpace.saved.id == profile else { return }
                    if let snapshot = feed.stock { self.widgetCanvas.setStock(snapshot) }
                } catch {
                    guard let self, self.activeSpace.saved.id == profile else { return }
                    self.widgetCanvas.set(.stocks, subtitle: symbol, lines: [error.localizedDescription])
                }
            }
        }
        pollRealtimeWidgets()
    }

    private func pollRealtimeWidgets() {
        guard widgetCanvas != nil, !homeView.isHidden else { return }
        if widgetCanvas.has(.music), !spotifyPollInFlight {
            spotifyPollInFlight = true
            Task.detached(priority: .utility) { [weak self] in
                let track = SpotifyBridge.read()
                await self?.updateSpotifyWidget(track)
            }
        }
        if widgetCanvas.has(.battery), let battery = WidgetSystemData.battery() {
            widgetCanvas.setBattery(battery)
        }
        if widgetCanvas.has(.systemMonitor) {
            var cpu = 0.0
            if let ticks = WidgetSystemData.cpuTicks() {
                if let previousCPUTicks, ticks.count == previousCPUTicks.count {
                    let changes = zip(ticks, previousCPUTicks).map { Double($0 >= $1 ? $0 - $1 : 0) }
                    let total = changes.reduce(0, +)
                    if total > 0 { cpu = 100 * (total - changes[2]) / total }
                }
                previousCPUTicks = ticks
            }
            cpuHistory.append(cpu)
            if cpuHistory.count > 40 { cpuHistory.removeFirst() }
            let network = WidgetSystemData.networkBytes()
            let now = Date()
            var networkLine = "Network  —"
            if let previousNetworkBytes, let previousNetworkTime {
                let interval = max(0.1, now.timeIntervalSince(previousNetworkTime))
                let down = Double(network.received >= previousNetworkBytes.received ? network.received - previousNetworkBytes.received : 0) / interval / 1_000_000
                let up = Double(network.sent >= previousNetworkBytes.sent ? network.sent - previousNetworkBytes.sent : 0) / interval / 1_000_000
                networkLine = String(format: "Network  ↓ %.1f  ↑ %.1f MB/s", down, up)
            }
            previousNetworkBytes = network
            previousNetworkTime = now
            widgetCanvas.set(.systemMonitor, subtitle: "CPU  \(Int(cpu))%",
                             lines: ["Memory   \(WidgetSystemData.memory())", networkLine,
                                     "Disk        \(WidgetSystemData.disk())"],
                             chart: cpuHistory)
        }
        if widgetCanvas.has(.downloads) {
            let recent = WidgetSystemData.recentDownloads().map { "↓ \($0.lastPathComponent)" }
            widgetCanvas.set(.downloads, subtitle: "Recent Downloads",
                             lines: downloads.widgetLines.isEmpty ? recent : downloads.widgetLines)
        }
        if widgetCanvas.has(.clipboard) {
            let pasteboard = NSPasteboard.general
            if pasteboard.changeCount != clipboardChangeCount {
                clipboardChangeCount = pasteboard.changeCount
                if let content = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !content.isEmpty, clipboardHistory.first != content {
                    clipboardHistory.insert(content, at: 0)
                    clipboardHistory = Array(clipboardHistory.prefix(12))
                }
            }
            widgetCanvas.set(.clipboard, subtitle: "Recent Copies",
                             lines: clipboardHistory.prefix(4).map { String($0.prefix(80)).replacingOccurrences(of: "\n", with: " ") })
        }
        if widgetCanvas.has(.calculator) {
            widgetCanvas.setCalculatorHistory(UserDefaults.standard.stringArray(forKey: "webbyCalculations.\(activeSpace.saved.id.uuidString)") ?? [])
        }
    }

    private func updateSpotifyWidget(_ track: SpotifySnapshot?) {
        spotifyPollInFlight = false
        widgetCanvas.setMusic(track)
    }

    private func controlSpotify(_ command: MusicCommand) {
        Task.detached(priority: .userInitiated) { [weak self] in
            SpotifyBridge.send(command)
            try? await Task.sleep(nanoseconds: 400_000_000)
            await self?.pollRealtimeWidgets()
        }
    }

    private func recordCalculation(_ line: String) {
        let key = "webbyCalculations.\(activeSpace.saved.id.uuidString)"
        var history = UserDefaults.standard.stringArray(forKey: key) ?? []
        history.insert(line, at: 0)
        history = Array(history.prefix(12))
        UserDefaults.standard.set(history, forKey: key)
        widgetCanvas.setCalculatorHistory(history)
    }

    private func activateWidget(_ kind: WebbyWidget) {
        if let service = kind.googleService {
            if GoogleWorkspace.shared.isConnected(service, profile: activeSpace.saved.id) { openGoogleService(service) }
            else { connectGoogle(service) }
            return
        }
        switch kind {
        case .weather:
            if let city = widgetTextPrompt(title: "Weather city", value: UserDefaults.standard.string(forKey: "webbyWeatherCity.\(activeSpace.saved.id.uuidString)") ?? "San Francisco") {
                UserDefaults.standard.set(city, forKey: "webbyWeatherCity.\(activeSpace.saved.id.uuidString)")
                refreshLocalWidgets(profile: activeSpace.saved.id)
            }
        case .stocks:
            if let symbol = widgetTextPrompt(title: "Stock symbol", value: UserDefaults.standard.string(forKey: "webbyStockSymbol.\(activeSpace.saved.id.uuidString)") ?? "AAPL") {
                UserDefaults.standard.set(symbol.uppercased(), forKey: "webbyStockSymbol.\(activeSpace.saved.id.uuidString)")
                refreshLocalWidgets(profile: activeSpace.saved.id)
            }
        case .note:
            if let note = widgetNotePrompt(value: UserDefaults.standard.string(forKey: "webbyNote.\(activeSpace.saved.id.uuidString)") ?? "") {
                UserDefaults.standard.set(note, forKey: "webbyNote.\(activeSpace.saved.id.uuidString)")
                refreshLocalWidgets(profile: activeSpace.saved.id)
            }
        case .codex:
            launchCodexWidget(prompt: "")
        case .music:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Spotify.app"))
        case .downloads:
            if let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first {
                NSWorkspace.shared.open(folder)
            }
        case .clipboard:
            guard !clipboardHistory.isEmpty else { break }
            let alert = NSAlert()
            alert.messageText = "Clipboard History"
            alert.addButton(withTitle: "Copy")
            alert.addButton(withTitle: "Cancel")
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
            picker.addItems(withTitles: clipboardHistory.map { String($0.prefix(90)).replacingOccurrences(of: "\n", with: " ") })
            alert.accessoryView = picker
            if alert.runModal() == .alertFirstButtonReturn {
                let selected = clipboardHistory[picker.indexOfSelectedItem]
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(selected, forType: .string)
            }
        case .systemMonitor:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        case .battery, .calculator:
            break
        default: break
        }
    }

    private func launchCodexWidget(prompt: String) {
        addTab(select: true)
        guard let tab = activeTab else { return }
        let quoted = "'" + prompt.replacingOccurrences(of: "'", with: "'\\''") + "'"
        terminalCommandOnOpen[tab.id] = prompt.isEmpty ? "codex" : "codex \(quoted)"
        toggleTerminal()
    }

    private func widgetTextPrompt(title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func widgetNotePrompt(value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Quick Note"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 380, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let editor = NSTextView(frame: scroll.bounds)
        editor.font = .systemFont(ofSize: 13)
        editor.string = value
        scroll.documentView = editor
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return editor.string
    }

    private func showAddWidget() {
        showBrowserWindow()
        let missing = WebbyWidget.allCases.filter { $0.googleService == nil && !widgetCanvas.has($0) }
        guard !missing.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Add a widget"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        picker.addItems(withTitles: missing.map(\.title))
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        widgetCanvas.addWidget(missing[picker.indexOfSelectedItem])
        refreshGoogleWidgets(force: true)
    }

    private func configureSuggestions(for surface: GlassAddressSurface) {
        surface.onExpandedEntranceBeam = { [weak self] in self?.suggestions.playEntranceBeam() }
        suggestions.knownFavicon = { [weak self] url in
            guard let self, let host = url.host?.lowercased() else { return nil }
            return self.spaces.flatMap(\.tabs).first {
                $0.webView?.url?.host?.lowercased() == host && $0.favicon != nil
            }?.favicon
        }
        suggestions.onChoose = { [weak self] item in
            guard let self else { return }
            self.editingSearchField = nil
            self.navigate(item.url)
        }
        surface.onBeginEditing = { [weak self] field in
            guard let self else { return }
            self.editingSearchField = field
            self.presentSuggestions(for: field)
            self.loadCookieHosts(for: self.activeSpace)
        }
        surface.onChange = { [weak self] field in self?.presentSuggestions(for: field) }
        surface.onEndEditing = { [weak self] field in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self, field.currentEditor() == nil else { return }
                if self.suggestions.containsMouse() { return }
                self.suggestions.close()
                if self.editingSearchField === field { self.editingSearchField = nil }
            }
        }
        surface.onCommand = { [weak self] field, selector in
            guard let self else { return false }
            if selector == #selector(NSResponder.moveDown(_:)) {
                self.suggestions.move(1)
                return self.suggestions.isShown
            }
            if selector == #selector(NSResponder.moveUp(_:)) {
                self.suggestions.move(-1)
                return self.suggestions.isShown
            }
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                self.suggestions.close()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)), let choice = self.suggestions.selected() {
                self.suggestions.close()
                self.editingSearchField = nil
                self.navigate(choice.url)
                return true
            }
            return false
        }
    }

    private func loadCookieHosts(for space: BrowserSpace) {
        let id = space.saved.id
        guard cookieHosts[id] == nil else { return }
        cookieHosts[id] = []
        space.dataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.cookieHosts[id] = Array(Set(cookies.map { $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
                    .filter { !$0.isEmpty })).sorted()
                if self.activeSpace.saved.id == id, let field = self.editingSearchField {
                    self.presentSuggestions(for: field)
                }
            }
        }
    }

    private func presentSuggestions(for field: NSTextField) {
        guard !terminalMode, let surface = field.superview else { return }
        let query = (field.currentEditor()?.string ?? field.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if field === homeSearchField && query.isEmpty {
            suggestions.close()
            return
        }
        var seen = Set<String>()
        var items: [BrowserSuggestion] = []
        func append(_ title: String, _ url: String, _ kind: BrowserSuggestion.Kind) {
            let key = url.lowercased()
            guard !seen.contains(key), let parsed = URL(string: url),
                  ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { return }
            if !query.isEmpty && !title.lowercased().contains(query) && !key.contains(query) { return }
            seen.insert(key)
            items.append(BrowserSuggestion(title: title, url: url, kind: kind))
        }
        for tab in tabs where tab.isPinned {
            if let url = tab.webView?.url?.absoluteString ?? destination(for: tab.searchDraft)?.absoluteString {
                append(tab.title, url, .pinned)
            }
        }
        for link in activeSpace.saved.bookmarks { append(link.title, link.url, .bookmark) }
        for link in activeSpace.saved.history { append(link.title, link.url, .history) }
        if !query.isEmpty {
            for host in cookieHosts[activeSpace.saved.id] ?? [] {
                append(host, "https://\(host)", .cookie)
            }
        }
        if query.isEmpty { items = Array(items.prefix(8)) }
        else {
            items.sort { lhs, rhs in
                func rank(_ item: BrowserSuggestion) -> Int {
                    let host = URL(string: item.url)?.host?.lowercased() ?? ""
                    let title = item.title.lowercased()
                    let match = host == query ? 0 : (host.hasPrefix(query) ? 1 : (title.hasPrefix(query) ? 2 : 3))
                    let kind: Int
                    switch item.kind { case .pinned: kind = 0; case .bookmark: kind = 1; case .history: kind = 2; case .cookie: kind = 3 }
                    return match * 10 + kind
                }
                return rank(lhs) < rank(rhs)
            }
        }
        suggestions.show(items, at: surface)
    }

    private func terminalPane(for tab: BrowserTab) -> NativeTerminalPane {
        if let existing = tab.terminalView { return existing }
        let pane = NativeTerminalPane(target: self, action: #selector(returnToSearch))
        pane.translatesAutoresizingMaskIntoConstraints = false
        pageArea.addSubview(pane)
        pane.isHidden = true
        let constraints = [
            pane.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            pane.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            pane.topAnchor.constraint(equalTo: pageArea.topAnchor),
            pane.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor)
        ]
        tab.terminalConstraints = constraints
        NSLayoutConstraint.activate(constraints)
        tab.terminalView = pane
        return pane
    }

    private func showCurrentIndicator() {
        guard let tab = activeTab, tab.webView == nil, !tab.isTerminal else { return }
        let id = tab.ownerSpaceID ?? activeSpace.saved.id
        let index = spaces.firstIndex { $0.saved.id == id } ?? activeSpaceIndex
        globe.engine.showScene(BrowserExperiment.scene(for: id, index: index))
        let name = spaces.first(where: { $0.saved.id == id })?.saved.name ?? activeSpace.saved.name
        homeSearchField.placeholderString = BrowserExperiment.cyclesNewTabProfiles
            ? "Search in \(name) or enter a URL" : "Search Google or enter a URL"
        globe.toolTip = BrowserExperiment.cyclesNewTabProfiles
            ? "Switch this empty tab to the next profile" : "Open Terminal"
    }

    private func globeClicked() {
        guard BrowserExperiment.cyclesNewTabProfiles,
              let tab = activeTab, tab.webView == nil, !tab.isTerminal,
              spaces.count > 1 else { toggleTerminal(); return }
        let current = spaces.firstIndex { $0.saved.id == tab.ownerSpaceID } ?? activeSpaceIndex
        let next = (current + 1) % spaces.count
        let oldDisplay = displaySpace(for: tab)
        oldDisplay.tabs.removeAll { $0.id == tab.id }
        tab.ownerSpaceID = spaces[next].saved.id
        spaces[next].tabs.append(tab)
        spaces[next].activeTabID = tab.id
        if oldDisplay !== spaces[next], oldDisplay.activeTabID == tab.id {
            oldDisplay.activeTabID = oldDisplay.tabs.first?.id
        }
        activeSpaceIndex = next
        BrowserTheme.activate(activeSpace.saved.id)
        widgetCanvas?.show(profile: activeSpace.saved.id)
        restoreHomeSearchPosition()
        lastWidgetRefresh.removeValue(forKey: activeSpace.saved.id)
        updateSpaceLabel()
        showCurrentIndicator()
        refreshTabs()
    }

    private func toggleTerminal() {
        guard let tab = activeTab, tab.webView == nil else { return }
        terminalTransitionToken += 1
        let token = terminalTransitionToken
        tab.isTerminal.toggle()
        terminalMode = tab.isTerminal
        positionSidebarToggle(forTerminal: terminalMode)
        tab.title = terminalMode ? "Terminal" : "New Tab"
        refreshTabs()
        if terminalMode {
            let pane = terminalPane(for: tab)
            hideToolbar(animated: false)
            globe.engine.showScene("terminal")
            homeSearchSurface.isHidden = true
            let scene = IndicatorScenes.terminal
            let sceneDuration = Motion.enabled ? scene.transition + scene.duration : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + sceneDuration) { [weak self] in
                guard let self, self.terminalTransitionToken == token,
                      self.activeTabID == tab.id, tab.isTerminal else { return }
                if Motion.enabled { Motion.basic(self.homeView.layer, key: "opacity", from: 1, to: 0, duration: 0.16) }
                DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.enabled ? 0.16 : 0)) { [weak self] in
                    guard let self, self.terminalTransitionToken == token,
                          self.activeTabID == tab.id, tab.isTerminal else { return }
                    self.homeView.isHidden = true
                    self.globe.engine.hide()
                    pane.isHidden = false
                    if Motion.enabled { Motion.basic(pane.layer, key: "opacity", from: 0, to: 1, duration: 0.18) }
                    pane.open()
                    if let command = self.terminalCommandOnOpen.removeValue(forKey: tab.id) {
                        pane.sendCommand(command)
                    }
                }
            }
        } else {
            tab.terminalView?.isHidden = true
            homeView.isHidden = false
            homeSearchSurface.isHidden = false
            globe.engine.showScene("search")
            if Motion.enabled { Motion.basic(homeView.layer, key: "opacity", from: 0, to: 1, duration: 0.20) }
            window.makeFirstResponder(homeSearchField)
        }
    }

    @objc private func returnToSearch() { toggleTerminal() }

    private func positionSidebarToggle(forTerminal terminal: Bool) {
        guard sidebarToggleLeading.isActive == terminal else { return }
        mainArea.layoutSubtreeIfNeeded()
        sidebarToggleLeading.isActive = !terminal
        sidebarToggleTerminalTrailing.isActive = terminal
        terminalButtonLeading.isActive = !terminal
        terminalButtonTrailing.isActive = terminal
        if Motion.enabled {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
                mainArea.animator().layoutSubtreeIfNeeded()
            }
        } else { mainArea.layoutSubtreeIfNeeded() }
    }

    private func addTab(select: Bool) {
        let tab = BrowserTab()
        tab.ownerSpaceID = activeSpace.saved.id
        tabs.append(tab)
        if select {
            selectTab(tab)
            DispatchQueue.main.async { [weak self, weak tab] in
                guard let self, let tab, self.activeTabID == tab.id,
                      tab.webView == nil, !tab.isTerminal else { return }
                self.homeView.layoutSubtreeIfNeeded()
                self.homeSearchSurface.playEntranceBeam()
            }
        } else { refreshTabs() }
    }

    private func pinnedKey(for space: BrowserSpace) -> String { "webbyPinnedTabs.\(space.saved.id.uuidString)" }

    private func savePinnedTabs(for space: BrowserSpace) {
        let records = space.tabs.filter { $0.isPinned && !$0.isTerminal }.compactMap { tab -> PinnedTabRecord? in
            guard let url = tab.webView?.url?.absoluteString ?? destination(for: tab.searchDraft)?.absoluteString,
                  let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { return nil }
            return PinnedTabRecord(title: tab.title, url: url, ownerSpaceID: tab.ownerSpaceID,
                                   widthFraction: Double(tab.pinWidthFraction), height: Double(tab.pinHeight))
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: pinnedKey(for: space))
    }

    @discardableResult private func restorePinnedTabs() -> BrowserTab? {
        guard let data = UserDefaults.standard.data(forKey: pinnedKey(for: activeSpace)),
              var records = try? JSONDecoder().decode([PinnedTabRecord].self, from: data) else { return nil }
        let layoutKey = "webbyPinLayoutV3.\(activeSpace.saved.id.uuidString)"
        if !UserDefaults.standard.bool(forKey: layoutKey) {
            if (3...4).contains(records.count) {
                let width = 1 / Double(records.count)
                records = records.map {
                    PinnedTabRecord(title: $0.title, url: $0.url, ownerSpaceID: $0.ownerSpaceID,
                                    widthFraction: width, height: $0.height)
                }
                UserDefaults.standard.set(try? JSONEncoder().encode(records), forKey: pinnedKey(for: activeSpace))
            }
            UserDefaults.standard.set(true, forKey: layoutKey)
        }
        for record in records.prefix(20) {
            guard let url = URL(string: record.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let tab = BrowserTab()
            tab.ownerSpaceID = record.ownerSpaceID.flatMap { owner in
                spaces.contains { $0.saved.id == owner } ? owner : nil
            } ?? activeSpace.saved.id
            tab.isPinned = true
            tab.pinWidthFraction = min(1, max(0.22, CGFloat(record.widthFraction ?? 0.5)))
            tab.pinHeight = min(240, max(39, CGFloat(record.height ?? 72)))
            tab.title = record.title
            tab.searchDraft = record.url
            tab.navigationInProgress = true
            if BrowserExperiment.cyclesNewTabProfiles {
                activeSpace.tabs.insert(tab, at: activeSpace.tabs.prefix { $0.isPinned }.count)
                fusedTabOrder.insert(tab.id, at: fusedTabOrder.prefix { id in
                    self.tab(id: id)?.isPinned == true
                }.count)
            } else {
                tabs.insert(tab, at: tabs.prefix { $0.isPinned }.count)
            }
            let view = makeWebView(for: tab)
            view.isHidden = true
            view.load(URLRequest(url: url))
        }
        refreshTabs()
        return tabs.first(where: { $0.isPinned })
    }

    @objc private func newTabAction() { addTab(select: true) }

    @objc private func newTerminalTabAction() {
        addTab(select: true)
        toggleTerminal()
    }

    @objc private func showSpaceMenu(_ sender: NSClickGestureRecognizer) {
        let menu = NSMenu(title: "Profiles")
        if BrowserExperiment.cyclesNewTabProfiles {
            let fused = menu.addItem(withTitle: "All profile tabs are fused", action: nil, keyEquivalent: "")
            fused.isEnabled = false
        } else {
            for (index, space) in spaces.enumerated() {
                let item = menu.addItem(withTitle: space.saved.name, action: #selector(chooseSpace(_:)), keyEquivalent: "")
                item.target = self
                item.tag = index
                item.state = index == activeSpaceIndex ? .on : .off
            }
        }
        menu.addItem(.separator())
        let history = menu.addItem(withTitle: "History (\(activeSpace.saved.history.count))", action: #selector(openHistoryMenu), keyEquivalent: "")
        history.target = self
        let bookmarks = menu.addItem(withTitle: "Bookmarks (\(activeSpace.saved.bookmarks.count))", action: #selector(openBookmarksMenu), keyEquivalent: "")
        bookmarks.target = self
        let passwords = menu.addItem(withTitle: "Saved Passwords…", action: #selector(showSavedPasswords), keyEquivalent: "")
        passwords.target = self
        if activeSpace.saved.chromeDirectory != nil {
            let sessions = menu.addItem(withTitle: "Import Chrome Sign-ins…", action: #selector(importChromeSignIns), keyEquivalent: "")
            sessions.target = self
        }
        menu.addItem(.separator())
        let delete = menu.addItem(withTitle: "Delete Profile…", action: #selector(showDeleteProfile), keyEquivalent: "")
        delete.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -5), in: spaceLabel)
    }

    @objc private func showDeleteProfile() {
        guard !importInProgress else { return }
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 28), pullsDown: false)
        for space in spaces { picker.addItem(withTitle: space.saved.name) }
        picker.selectItem(at: activeSpaceIndex)
        let alert = NSAlert()
        alert.messageText = "Delete browser profile?"
        alert.informativeText = "Choose a profile. This removes its tabs, copied bookmarks and history, website data, and saved passwords from Webby. Your Chrome data stays in Chrome."
        alert.accessoryView = picker
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let index = picker.indexOfSelectedItem
        guard spaces.indices.contains(index) else { return }
        let name = spaces[index].saved.name
        let confirm = NSAlert()
        confirm.alertStyle = .warning
        confirm.messageText = "Delete \(name)?"
        confirm.informativeText = "The Webby copy of this profile and its saved passwords will be removed."
        confirm.addButton(withTitle: "Delete Profile")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        deleteProfile(at: index)
    }

    private func deleteProfile(at index: Int) {
        guard spaces.indices.contains(index), !importInProgress else { return }
        if BrowserExperiment.cyclesNewTabProfiles {
            BrowserExperiment.cyclesNewTabProfiles = false
            experimentalModeChanged()
        }
        linkPreview?.close()
        pendingSpaceSave?.cancel()
        let target = spaces[index]
        GoogleWorkspace.shared.deleteProfile(target.saved.id)
        UserDefaults.standard.removeObject(forKey: "webbyWidgetCanvas.\(target.saved.id.uuidString)")
        for key in ["webbyNote", "webbyWeatherCity", "webbyStockSymbol"] {
            UserDefaults.standard.removeObject(forKey: "\(key).\(target.saved.id.uuidString)")
        }
        lastWidgetRefresh.removeValue(forKey: target.saved.id)
        let store = target.dataStore
        if spaces.count == 1 {
            let blank = SavedBrowserSpace(id: UUID(), name: "New Profile", chromeDirectory: nil,
                                          bookmarks: [], history: [])
            spaces.append(BrowserSpace(blank))
        }
        if index == activeSpaceIndex {
            let replacement = index == 0 ? 1 : 0
            switchToSpace(replacement, direction: replacement > index ? 1 : -1)
        }
        let ownedTabs = spaces.flatMap(\.tabs).filter { tab in
            tab.ownerSpaceID == target.saved.id || target.tabs.contains { $0.id == tab.id }
        }
        for tab in ownedTabs {
            discardFloatingWindow(for: tab.id)
            tab.progressObservation?.invalidate()
            tab.progressObservation = nil
            tab.faviconTask?.cancel()
            tab.webView?.stopLoading()
            tab.webView?.navigationDelegate = nil
            tab.webView?.uiDelegate = nil
            tab.webView?.removeFromSuperview()
            tab.webView = nil
            tab.terminalView?.stop()
            tab.terminalView?.removeFromSuperview()
            tab.terminalView = nil
        }
        target.tabs.removeAll()
        for space in spaces where space !== target {
            space.tabs.removeAll { tab in ownedTabs.contains { $0.id == tab.id } }
            if let selected = space.activeTabID, ownedTabs.contains(where: { $0.id == selected }) {
                space.activeTabID = nil
            }
        }
        spaces.remove(at: index)
        BrowserTheme.remove(target.saved.id)
        UserDefaults.standard.removeObject(forKey: "webbyPinnedTabs.\(target.saved.id.uuidString)")
        cookieHosts.removeValue(forKey: target.saved.id)
        if index < activeSpaceIndex { activeSpaceIndex -= 1 }
        UserDefaults.standard.set(activeSpaceIndex, forKey: "browserActiveSpace")
        updateSpaceLabel()
        if activeTabID == nil {
            if let survivor = tabs.first { selectTab(survivor) }
            else { addTab(select: true) }
        }
        refreshTabs()
        scheduleSpaceSave()
        let passwordStatus = BrowserPasswords.deleteAll(in: target.saved.id)
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        if passwordStatus != errSecSuccess {
            let warning = NSAlert()
            warning.messageText = "Profile deleted, but some passwords remain"
            warning.informativeText = "macOS Keychain returned error \(passwordStatus). You can remove entries for \(target.saved.name) in Keychain Access."
            warning.runModal()
        }
    }

    @objc private func openHistoryMenu() { showLibrary(history: true) }
    @objc private func openBookmarksMenu() { showLibrary(history: false) }

    @objc private func chooseSpace(_ sender: NSMenuItem) {
        guard !BrowserExperiment.cyclesNewTabProfiles else { return }
        switchToSpace(sender.tag, direction: sender.tag >= activeSpaceIndex ? 1 : -1)
    }

    private func switchSpace(_ direction: Int) {
        guard !BrowserExperiment.cyclesNewTabProfiles, spaces.count > 1 else { return }
        let destination = (activeSpaceIndex + direction + spaces.count) % spaces.count
        switchToSpace(destination, direction: direction)
    }

    private func switchToSpace(_ index: Int, direction: Int = 1) {
        guard !BrowserExperiment.cyclesNewTabProfiles, spaces.indices.contains(index) else { return }
        if index == activeSpaceIndex {
            updateSpaceLabel()
            return
        }
        tabPreview.hide()
        linkPreview?.close()
        if Motion.enabled {
            let transition = CATransition()
            transition.type = .push
            transition.subtype = direction > 0 ? .fromRight : .fromLeft
            transition.duration = 0.24
            transition.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
            pageArea.layer?.add(transition, forKey: "spaceSwitch")
        }
        for tab in tabs where tab.id == activeTabID {
            captureTabPreview(tab)
            tab.webView?.evaluateJavaScript("window.__webbyFollowPlayingVideo?.()", in: nil,
                                            in: WKContentWorld.world(name: "WebbyVideo"), completionHandler: nil)
        }
        for tab in tabs {
            if !tab.isFloating {
                tab.webView?.isHidden = true
                tab.terminalView?.isHidden = true
            }
        }
        splitView?.isHidden = true
        activeSpaceIndex = index
        BrowserTheme.activate(activeSpace.saved.id)
        widgetCanvas?.show(profile: activeSpace.saved.id)
        restoreHomeSearchPosition()
        lastWidgetRefresh.removeValue(forKey: activeSpace.saved.id)
        if tabs.isEmpty { _ = restorePinnedTabs() }
        for tab in tabs { tab.terminalView?.applyTheme(BrowserTheme.profile) }
        UserDefaults.standard.set(index, forKey: "browserActiveSpace")
        updateSpaceLabel()
        let selected = activeSpace.activeTabID.flatMap { id in tabs.first { $0.id == id && !$0.isFloating } }
            ?? tabs.first(where: { !$0.isFloating })
        activeTabID = nil
        if let selected { selectTab(selected) }
        else { addTab(select: true) }
    }

    private func scheduleSpaceSave() {
        guard !importInProgress else { return }
        pendingSpaceSave?.cancel()
        let snapshot = spaces.map(\.saved)
        let work = DispatchWorkItem { try? BrowserSpaceStore.save(snapshot) }
        pendingSpaceSave = work
        spaceSaveQueue.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func showChromeImport() {
        guard !importInProgress else { return }
        let sources = ChromeProfileImporter.availableProfiles()
        guard !sources.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No Chrome profiles found"
            alert.informativeText = "Install or open Google Chrome once, then try again."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Import Chrome profiles"
        alert.informativeText = "Choose the Chrome profiles to bring over. Each becomes its own browser space with bookmarks, history, saved passwords, and website cookies. macOS may ask to unlock Chrome Safe Storage."
        alert.addButton(withTitle: "Import Selected")
        alert.addButton(withTitle: "Cancel")
        let list = NSStackView(frame: NSRect(x: 0, y: 0, width: 300,
                                              height: CGFloat(sources.count) * 27))
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 7
        let buttons = sources.map { source -> NSButton in
            let button = NSButton(checkboxWithTitle: source.name, target: nil, action: nil)
            button.state = .on
            list.addArrangedSubview(button)
            return button
        }
        alert.accessoryView = list
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let selected = zip(sources, buttons).compactMap { $0.1.state == .on ? $0.0 : nil }
        guard !selected.isEmpty else { return }
        let encryptionKey: Data
        do { encryptionKey = try ChromeSessions.encryptionKey() }
        catch {
            let failure = NSAlert()
            failure.messageText = "Chrome protected data is locked"
            failure.informativeText = "No profiles were imported. \(error.localizedDescription)"
            failure.runModal()
            return
        }
        importInProgress = true
        pendingSpaceSave?.cancel()
        let oldSpaces = spaces.map(\.saved)
        let progress = NSAlert()
        progress.messageText = "Importing Chrome profiles…"
        progress.informativeText = "Reading bookmarks, history, saved passwords, and website cookies."
        let progressWindow = progress.window
        progressWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { () throws -> [(SavedBrowserSpace, [BrowserCredential], [HTTPCookie])] in
                var updated = oldSpaces
                var payloads: [(SavedBrowserSpace, [BrowserCredential], [HTTPCookie])] = []
                for source in selected {
                    let existing = updated.first { $0.chromeDirectory == source.directory }
                    let imported = ChromeProfileImporter.import(source, reusing: existing?.id)
                    let credentials = try BrowserPasswords.readChromePasswords(from: source, key: encryptionKey)
                    let cookies = try ChromeSessions.readCookies(from: source, key: encryptionKey)
                    payloads.append((imported, credentials, cookies))
                    if let index = updated.firstIndex(where: { $0.chromeDirectory == source.directory }) {
                        updated[index] = imported
                    } else { updated.append(imported) }
                }
                try BrowserSpaceStore.save(updated)
                return payloads
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch result {
                case .success(let payloads):
                    var passwordCount = 0
                    var passwordFailures = 0
                    var cookieCount = 0
                    let group = DispatchGroup()
                    for (saved, credentials, cookies) in payloads {
                        self.cookieHosts.removeValue(forKey: saved.id)
                        if let existing = self.spaces.first(where: { $0.saved.id == saved.id }) {
                            existing.saved = saved
                        } else {
                            let space = BrowserSpace(saved)
                            self.spaces.append(space)
                            _ = space.dataStore
                        }
                        for credential in credentials {
                            if BrowserPasswords.save(credential, in: saved.id) == errSecSuccess { passwordCount += 1 }
                            else { passwordFailures += 1 }
                        }
                        guard let space = self.spaces.first(where: { $0.saved.id == saved.id }) else { continue }
                        cookieCount += cookies.count
                        for cookie in cookies {
                            group.enter()
                            space.dataStore.httpCookieStore.setCookie(cookie) { group.leave() }
                        }
                    }
                    progress.informativeText = "Installing \(cookieCount) website cookies."
                    group.notify(queue: .main) {
                        progressWindow.orderOut(nil)
                        self.updateSpaceLabel()
                        if let first = selected.first,
                           let index = self.spaces.firstIndex(where: { $0.saved.chromeDirectory == first.directory }) {
                            self.switchToSpace(index)
                        }
                        self.importInProgress = false
                        self.scheduleSpaceSave()
                        self.showBrowserWindow()
                        let summary = NSAlert()
                        let readablePasswordCount = payloads.reduce(0) {
                            $0 + BrowserPasswords.credentials(in: $1.0.id).count
                        }
                        summary.messageText = "Imported \(selected.count) Chrome profile\(selected.count == 1 ? "" : "s")"
                        summary.informativeText = "Imported \(passwordCount) passwords, verified \(readablePasswordCount) are readable, and installed \(cookieCount) website cookies alongside bookmarks and history. \(passwordFailures) passwords could not be saved. Some sites may still require a fresh sign-in."
                        summary.runModal()
                    }
                case .failure(let error):
                    progressWindow.orderOut(nil)
                    self.importInProgress = false
                    self.scheduleSpaceSave()
                    let failure = NSAlert()
                    failure.messageText = "Chrome import failed"
                    failure.informativeText = error.localizedDescription
                    failure.runModal()
                }
            }
        }
    }

    @objc private func importChromePasswords() {
        guard let target = chooseImportedChromeSpace(for: "passwords") else { return }
        let panel = NSOpenPanel()
        panel.title = "Import passwords into \(target.saved.name)"
        panel.message = "Select the password CSV exported from Chrome profile “\(target.saved.name)”. Website URLs in the file determine which sites can autofill."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let result = Result { try BrowserPasswords.importChromeCSV(url, into: target.saved.id) }
        let alert = NSAlert()
        switch result {
        case .success(let counts):
            alert.messageText = "Saved \(counts.saved) passwords to \(target.saved.name)"
            alert.informativeText = "Stored in the macOS Keychain for this browser profile. \(counts.skipped) entries were skipped. Passwords on matching HTTPS sites with one account fill automatically. Delete the plaintext CSV after import."
        case .failure(let error):
            alert.messageText = "Password import failed"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    private func chooseImportedChromeSpace(for data: String) -> BrowserSpace? {
        let imported = spaces.filter { $0.saved.chromeDirectory != nil }
        guard !imported.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Import a Chrome profile first"
            alert.informativeText = "The \(data) need a destination profile. Import your Chrome profiles, then choose the matching name here."
            alert.runModal()
            return nil
        }
        let alert = NSAlert()
        alert.messageText = "Which Chrome profile owns these \(data)?"
        alert.informativeText = "Each imported profile keeps its own history, passwords, and sign-ins. Choose the same Chrome profile the data came from."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28), pullsDown: false)
        for space in imported {
            picker.addItem(withTitle: "\(space.saved.name) (\(space.saved.chromeDirectory ?? ""))")
        }
        if let index = imported.firstIndex(where: { $0.saved.id == activeSpace.saved.id }) {
            picker.selectItem(at: index)
        }
        alert.accessoryView = picker
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              imported.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return imported[picker.indexOfSelectedItem]
    }

    @objc private func importChromeSignIns() {
        guard let target = chooseImportedChromeSpace(for: "sign-ins"),
              let directory = target.saved.chromeDirectory,
              let source = ChromeProfileImporter.availableProfiles().first(where: { $0.directory == directory }) else {
            let alert = NSAlert()
            alert.messageText = "That Chrome profile is unavailable"
            alert.informativeText = "Check that Chrome still has the profile on this Mac, then retry."
            alert.runModal()
            return
        }
        let confirmation = NSAlert()
        confirmation.messageText = "Import website sign-ins from \(source.name)?"
        confirmation.informativeText = "This reads Chrome's encrypted cookies using its macOS Keychain key and copies valid website cookies into this browser space. macOS may ask you to allow Keychain access. Some sites can still require a fresh login."
        confirmation.addButton(withTitle: "Import Sign-ins")
        confirmation.addButton(withTitle: "Cancel")
        guard confirmation.runModal() == .alertFirstButtonReturn else { return }
        let key: Data
        do { key = try ChromeSessions.encryptionKey() }
        catch {
            let alert = NSAlert()
            alert.messageText = "Could not access Chrome sign-ins"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        let progress = NSAlert()
        progress.messageText = "Importing sign-ins from \(source.name)…"
        progress.informativeText = "Reading Chrome's encrypted cookies."
        let progressWindow = progress.window
        progressWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ChromeSessions.readCookies(from: source, key: key) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { progressWindow.orderOut(nil); return }
                switch result {
                case .failure(let error):
                    progressWindow.orderOut(nil)
                    let alert = NSAlert()
                    alert.messageText = "Sign-in import failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                case .success(let cookies):
                    progress.informativeText = "Installing \(cookies.count) valid cookies into \(source.name)."
                    let group = DispatchGroup()
                    for cookie in cookies {
                        group.enter()
                        target.dataStore.httpCookieStore.setCookie(cookie) { group.leave() }
                    }
                    group.notify(queue: .main) {
                        self.cookieHosts.removeValue(forKey: target.saved.id)
                        progressWindow.orderOut(nil)
                        let alert = NSAlert()
                        alert.messageText = "Imported \(cookies.count) website cookies"
                        alert.informativeText = "Refresh a site to use the imported sign-in. Some sites bind sessions to Chrome or require a fresh login."
                        alert.runModal()
                        if self.activeSpace.saved.id == target.saved.id { self.activeWebView?.reload() }
                    }
                }
            }
        }
    }

    @objc private func showSavedPasswords() {
        guard let target = chooseImportedChromeSpace(for: "saved passwords") else { return }
        let spaceID = target.saved.id
        while true {
            let credentials = BrowserPasswords.credentials(in: spaceID)
            let alert = NSAlert()
            alert.messageText = "Saved passwords — \(target.saved.name)"
            if credentials.isEmpty {
                alert.informativeText = "No passwords are saved in this browser space. Import a Chrome password CSV from the menu bar."
                alert.addButton(withTitle: "Import Chrome CSV…")
                alert.addButton(withTitle: "Done")
                if alert.runModal() == .alertFirstButtonReturn { importChromePasswords() }
                return
            }
            alert.informativeText = "\(credentials.count) accounts are stored in the macOS Keychain. Choose one to reveal or delete."
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 370, height: 28), pullsDown: false)
            for credential in credentials { picker.addItem(withTitle: "\(credential.host) — \(credential.username)") }
            alert.accessoryView = picker
            alert.addButton(withTitle: "Reveal")
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Done")
            let choice = alert.runModal()
            if choice == .alertThirdButtonReturn { return }
            let index = max(0, picker.indexOfSelectedItem)
            guard credentials.indices.contains(index) else { return }
            let credential = credentials[index]
            if choice == .alertSecondButtonReturn {
                _ = BrowserPasswords.delete(credential, in: spaceID)
                continue
            }
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                let unavailable = NSAlert()
                unavailable.messageText = "Mac authentication is required"
                unavailable.informativeText = error?.localizedDescription ?? "Set a Mac login password to reveal saved passwords."
                unavailable.runModal()
                continue
            }
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Reveal a saved browser password") { [weak self] approved, _ in
                guard approved else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.spaces.contains(where: { $0.saved.id == spaceID }) else { return }
                    let reveal = NSAlert()
                    reveal.messageText = "\(credential.host)"
                    reveal.informativeText = "Username: \(credential.username)\nPassword: \(credential.password)"
                    reveal.runModal()
                }
            }
            return
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "browserVideoFloat" {
            guard message.body as? String == "video-pip-fallback",
                  let webView = message.webView,
                  let tab = tab(for: webView), !tab.isFloating else { return }
            floatTab(tab)
            return
        }
        if message.name == "browserLinkPreview" {
            showLinkPreview(message)
            return
        }
        guard message.name == "browserPasswordField", message.frameInfo.isMainFrame,
              let host = message.body as? String,
              let webView = message.webView, let url = webView.url,
              url.scheme?.lowercased() == "https", url.host?.lowercased() == host.lowercased(),
              message.frameInfo.securityOrigin.host.lowercased() == host.lowercased(),
              let tab = tab(for: webView),
              let space = spaces.first(where: { $0.saved.id == tab.ownerSpaceID })
                  ?? spaces.first(where: { $0.tabs.contains { $0.id == tab.id } }) else { return }
        let matches = BrowserPasswords.credentials(in: space.saved.id, host: host.lowercased())
        if matches.count == 1 { fill(matches[0], in: webView) }
    }

    private func showLinkPreview(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let source = message.webView, let tab = tab(for: source), tab.id == activeTabID,
              let body = message.body as? [String: Any],
              let raw = body["url"] as? String, raw.count < 4096,
              let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let x = body["x"] as? Double, let y = body["y"] as? Double,
              x.isFinite, y.isFinite else { return }
        let ownerID = ownerSpace(for: tab).saved.id
        if linkPreviewOwnerID != ownerID {
            linkPreview?.close()
            let config = WKWebViewConfiguration()
            config.websiteDataStore = ownerSpace(for: tab).dataStore
            GlassPageInjector.install(into: config)
            let view = WKWebView(frame: .zero, configuration: config)
            GlassPageInjector.makeWebViewTransparent(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            let backdrop = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 470, height: 335))
            backdrop.material = .popover
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            let host = NSViewController()
            host.view = backdrop
            let title = NSTextField(labelWithString: "Link Preview")
            title.translatesAutoresizingMaskIntoConstraints = false
            title.font = .systemFont(ofSize: 12, weight: .medium)
            title.textColor = .secondaryLabelColor
            backdrop.addSubview(title)
            let open = NSButton(title: "Open Tab", target: self, action: #selector(openPreviewTab))
            open.translatesAutoresizingMaskIntoConstraints = false
            open.isBordered = false
            backdrop.addSubview(open)
            backdrop.addSubview(view)
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 14),
                title.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 9),
                open.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -10),
                open.centerYAnchor.constraint(equalTo: title.centerYAnchor),
                view.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                view.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
                view.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor)
            ])
            let popover = NSPopover()
            popover.contentSize = backdrop.frame.size
            popover.behavior = .transient
            popover.contentViewController = host
            linkPreview = popover
            linkPreviewWebView = view
            linkPreviewOwnerID = ownerID
        }
        linkPreviewURL = url
        if linkPreviewWebView?.url != url { linkPreviewWebView?.load(URLRequest(url: url)) }
        let width = min(max(body["width"] as? Double ?? 1, 1), 200)
        let anchorY = source.isFlipped ? y : Double(source.bounds.height) - y
        if linkPreview?.isShown != true {
            linkPreview?.show(relativeTo: NSRect(x: x, y: anchorY, width: width, height: 2),
                              of: source, preferredEdge: .maxY)
        }
    }

    @objc private func openPreviewTab() {
        guard let url = linkPreviewURL, let source = activeTab else { return }
        let tab = BrowserTab()
        tab.ownerSpaceID = ownerSpace(for: source).saved.id
        tab.title = url.host ?? "New Tab"
        tab.navigationInProgress = true
        tabs.append(tab)
        linkPreview?.close()
        selectTab(tab)
        makeWebView(for: tab).load(URLRequest(url: url))
    }

    @objc private func fillSavedPasswordForCurrentSite() {
        guard let webView = activeWebView, let url = webView.url,
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            let alert = NSAlert()
            alert.messageText = "Open a secure website first"
            alert.informativeText = "Saved passwords can only fill on an HTTPS site with a matching website address."
            alert.runModal()
            return
        }
        let matches = BrowserPasswords.credentials(in: activeTab.map { ownerSpace(for: $0).saved.id }
                                                   ?? activeSpace.saved.id, host: host)
        guard !matches.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No password for \(host)"
            alert.informativeText = "Import a password CSV into \(activeSpace.saved.name). The URL in each entry determines its website."
            alert.runModal()
            return
        }
        if matches.count == 1 { fill(matches[0], in: webView); return }
        let alert = NSAlert()
        alert.messageText = "Choose an account for \(host)"
        alert.informativeText = "\(matches.count) saved accounts match this exact website."
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 28), pullsDown: false)
        for credential in matches { picker.addItem(withTitle: credential.username) }
        alert.accessoryView = picker
        alert.addButton(withTitle: "Fill")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              matches.indices.contains(picker.indexOfSelectedItem) else { return }
        fill(matches[picker.indexOfSelectedItem], in: webView)
    }

    private func fill(_ credential: BrowserCredential, in webView: WKWebView) {
        guard let url = webView.url, url.scheme?.lowercased() == "https",
              url.host?.lowercased() == credential.host,
              let json = try? JSONSerialization.data(withJSONObject: [credential.username, credential.password]),
              let values = String(data: json, encoding: .utf8) else { return }
        webView.evaluateJavaScript("""
        (() => {
          if (location.protocol !== 'https:' || location.hostname !== \(String(reflecting: credential.host))) return;
          const [username,password] = \(values);
          const pass = [...document.querySelectorAll('input[type=password]')].find(e => !e.disabled && !e.value);
          const user = [...document.querySelectorAll('input')].find(e =>
            !e.disabled && !e.value && (e.autocomplete === 'username' ||
            (e.type === 'email' && e.name === 'identifier') ||
            (pass && (e.type === 'email' || /user|email|login/i.test(e.name || e.id || '')))));
          if (!pass && !user) return;
          const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set;
          if (user && username) { setter.call(user, username); user.dispatchEvent(new Event('input',{bubbles:true})); }
          if (pass) {
            setter.call(pass, password); pass.dispatchEvent(new Event('input',{bubbles:true}));
            pass.dispatchEvent(new Event('change',{bubbles:true}));
          }
        })();
        """, completionHandler: nil)
    }

    private func showLibrary(history: Bool) {
        showBrowserWindow()
        let links = history ? activeSpace.saved.history : activeSpace.saved.bookmarks
        let title = history ? "History" : "Bookmarks"
        let heading = "\(title) — \(activeSpace.saved.name)"
        addTab(select: true)
        guard let tab = activeTab else { return }
        tab.title = heading
        tab.showsSearchView = false
        let view = makeWebView(for: tab)
        homeView.isHidden = true
        view.isHidden = false
        view.alphaValue = 1
        view.loadHTMLString(libraryHTML(title: heading, links: links), baseURL: nil)
        refreshTabs()
    }

    private func libraryHTML(title: String, links: [BrowserLink]) -> String {
        func escaped(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;")
        }
        let data = (try? JSONEncoder().encode(links)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let safeJSON = data.replacingOccurrences(of: "<", with: "\\u003C")
        return """
        <!doctype html><meta charset='utf-8'><title>\(escaped(title))</title>
        <style>html{background:#15191d;color:#eef2f2;font:14px -apple-system,BlinkMacSystemFont,sans-serif}body{max-width:850px;margin:60px auto;padding:0 28px}h1{font-size:30px;font-weight:600}input{box-sizing:border-box;width:100%;padding:13px 16px;border:1px solid #ffffff2b;border-radius:10px;background:#ffffff10;color:inherit;font:inherit;outline:none}.row{display:block;padding:13px 8px;border-bottom:1px solid #ffffff16;text-decoration:none;color:inherit}.row:hover{background:#ffffff0d}.row b,.row small{display:block;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.row small{color:#9eaeb7;margin-top:3px}</style>
        <h1>\(escaped(title))</h1><input id='search' type='search' placeholder='Search \(escaped(title.lowercased()))' autofocus><main></main>
        <script type='application/json' id='data'>\(safeJSON)</script>
        <script>
        const all=JSON.parse(document.getElementById('data').textContent),main=document.querySelector('main');
        let filtered=all,shown=0;
        function more(){let batch=filtered.slice(shown,shown+120),frag=document.createDocumentFragment();
          for(let item of batch){let a=document.createElement('a'),b=document.createElement('b'),s=document.createElement('small');
            a.className='row';a.href=item.url;b.textContent=item.title;s.textContent=item.url;a.append(b,s);frag.append(a)}
          main.append(frag);shown+=batch.length}
        more();
        document.getElementById('search').oninput=e=>{let q=e.target.value.toLowerCase();
          filtered=q?all.filter(x=>(x.title+' '+x.url).toLowerCase().includes(q)):all;
          main.replaceChildren();shown=0;more()};
        addEventListener('scroll',()=>{if(innerHeight+scrollY>document.body.scrollHeight-450&&shown<filtered.length)more()});
        </script>
        """
    }

    private func selectTab(_ tab: BrowserTab) {
        tabPreview.hide()
        if tab.isFloating {
            floatingWindows[tab.id]?.makeKeyAndOrderFront(nil)
            return
        }
        guard tabs.contains(where: { $0.id == tab.id }), activeTabID != tab.id else { return }
        suggestions.close()
        linkPreview?.close()
        if let previous = activeTab, previous.id != tab.id {
            captureTabPreview(previous)
            previous.webView?.evaluateJavaScript("window.__webbyFollowPlayingVideo?.()", in: nil,
                                                 in: WKContentWorld.world(name: "WebbyVideo"), completionHandler: nil)
        }
        if let previous = activeTab, (previous.webView == nil || previous.showsSearchView) && !previous.isTerminal {
            previous.searchDraft = homeSearchField.currentEditor()?.string ?? homeSearchField.stringValue
        }
        // NSTextField shares the window's field editor. End its edit session before
        // displaying another tab, or the old query can reappear in a fresh tab.
        if homeSearchField.currentEditor() != nil || addressField.currentEditor() != nil {
            homeSearchField.abortEditing()
            addressField.abortEditing()
            window.makeFirstResponder(nil)
        }
        navigationToken += 1
        terminalTransitionToken += 1
        toolbar.resetProgress()
        activeTabID = tab.id
        if BrowserExperiment.cyclesNewTabProfiles {
            displaySpace(for: tab).activeTabID = tab.id
            if let index = spaces.firstIndex(where: { $0.saved.id == ownerSpace(for: tab).saved.id }) {
                let changedProfile = activeSpaceIndex != index
                activeSpaceIndex = index
                BrowserTheme.activate(activeSpace.saved.id)
                if changedProfile {
                    widgetCanvas?.show(profile: activeSpace.saved.id)
                    restoreHomeSearchPosition()
                    lastWidgetRefresh.removeValue(forKey: activeSpace.saved.id)
                }
            }
            updateSpaceLabel()
        }
        applyGlassTone(for: tab)
        if let view = tab.webView { updateGlassTone(for: view) }
        terminalMode = tab.isTerminal
        positionSidebarToggle(forTerminal: terminalMode)
        hideToolbar(animated: false)
        let showsSplit = splitTabIDs.map { $0.0 == tab.id || $0.1 == tab.id } ?? false
        splitView?.isHidden = !showsSplit
        for item in tabs {
            if item.isFloating { continue }
            let inSplit = splitTabIDs.map { $0.0 == item.id || $0.1 == item.id } ?? false
            item.webView?.isHidden = inSplit ? !showsSplit : item.id != tab.id
            item.webView?.alphaValue = item.id == tab.id && item.showsSearchView ? 0.001 : 1
        }
        homeView.isHidden = (tab.webView != nil && !tab.showsSearchView) || tab.isTerminal
        if !homeView.isHidden { refreshGoogleWidgets() }
        for item in tabs { item.terminalView?.isHidden = item.id != tab.id || !tab.isTerminal }
        homeSearchSurface.isHidden = false
        loadErrorLabel.stringValue = tab.loadError ?? ""
        loadErrorLabel.isHidden = tab.loadError == nil
        if (tab.webView == nil || tab.showsSearchView) && !tab.isTerminal { showCurrentIndicator() }
        else { globe.engine.hide() }
        chromeToggle.isHidden = tab.webView == nil || tab.showsSearchView
        if let view = tab.webView, view.isLoading { toolbar.setProgress(min(view.estimatedProgress, 0.96)) }
        addressField.stringValue = tab.webView?.url.map(displayAddress) ?? ""
        homeSearchField.stringValue = tab.searchDraft
        if tab.showsSearchView, let view = tab.webView, view.isLoading {
            homeSearchSurface.startLoading()
            homeSearchSurface.setLoadingProgress(view.estimatedProgress)
        } else { homeSearchSurface.stopLoading() }
        updateNavigation()
        refreshTabs()
        if let view = tab.webView { window.makeFirstResponder(view) }
        else if tab.isTerminal {
            let pane = terminalPane(for: tab)
            pane.isHidden = false
            pane.open()
        }
        else { window.makeFirstResponder(homeSearchField) }
        if tab.webView != nil && !tab.navigationInProgress {
            let id = tab.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.activeTabID == id, let current = self.tab(id: id) else { return }
                self.captureTabPreview(current)
            }
        }
    }

    fileprivate func showTabPreview(for id: UUID, from row: NSView) {
        guard let tab = tab(id: id), row.window === window else { return }
        let address = tab.isTerminal ? "Terminal" :
            (tab.webView?.url.map(displayAddress) ?? (tab.searchDraft.isEmpty ? "New Tab" : tab.searchDraft))
        tabPreview.show(tabID: id, title: tab.title, address: address,
                        image: tab.previewImage, from: row)
        if tab.id == activeTabID { captureTabPreview(tab) }
    }

    fileprivate func hideTabPreview(for id: UUID) { tabPreview.hide(for: id) }

    private func captureTabPreview(_ tab: BrowserTab) {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - tab.previewCapturedAt > 2,
              !tab.showsSearchView, !tab.navigationInProgress,
              let webView = tab.webView, !webView.isHidden, webView.alphaValue > 0.5,
              webView.bounds.width >= 100, webView.bounds.height >= 80 else { return }
        tab.previewCapturedAt = now
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0,
                                    width: min(webView.bounds.width, 850),
                                    height: min(webView.bounds.height, 500))
        let capturedURL = webView.url
        let tabID = tab.id
        let generation = tab.previewGeneration
        webView.takeSnapshot(with: configuration) { [weak self, weak webView] image, _ in
            DispatchQueue.main.async {
                guard let self, let image, let webView,
                      let current = self.tab(id: tabID), current.webView === webView,
                      current.previewGeneration == generation,
                      webView.url == capturedURL else { return }
                current.previewImage = image
                self.tabPreview.updateImage(image, for: tabID)
            }
        }
    }

    private var visibleSidebarTabs: [BrowserTab] {
        let visible = tabs.filter { $0.id != splitTabIDs?.1 }
        return visible.filter(\.isPinned) + visible.filter { !$0.isPinned }
    }

    private func discardTabRow(_ id: UUID) {
        guard let row = tabRows.removeValue(forKey: id) else { return }
        row.cancelHoverPreview()
        row.layer?.removeAllAnimations()
        row.isHidden = true
        tabWidthConstraints.removeValue(forKey: id)?.isActive = false
        if tabStack.arrangedSubviews.contains(row) { tabStack.removeArrangedSubview(row) }
        row.removeFromSuperview()
    }

    private func refreshTabs() {
        let visibleTabs = visibleSidebarTabs
        let pinnedTabs = visibleTabs.filter(\.isPinned)
        let regularTabs = visibleTabs.filter { !$0.isPinned }
        let validIDs = Set(visibleTabs.map(\.id))
        tabStack.layer?.removeAnimation(forKey: "spaceSwitch")
        tabStack.layer?.removeAnimation(forKey: "pinTab")
        pinGrid.rows = []
        for id in Array(tabRows.keys) where !validIDs.contains(id) { discardTabRow(id) }
        var tileRows: [TabRow] = []
        for tab in pinnedTabs {
            if let existing = tabRows[tab.id], existing.superview !== pinGrid {
                discardTabRow(tab.id)
            }
            let row = tabRows[tab.id] ?? TabRow(tabID: tab.id, target: self)
            tabRows[tab.id] = row
            row.pinWidthFraction = tab.pinWidthFraction
            row.pinHeight = tab.pinHeight
            if row.superview !== pinGrid {
                row.translatesAutoresizingMaskIntoConstraints = true
                pinGrid.addSubview(row)
            }
            row.setTileMode(row.pinHeight > 52)
            tileRows.append(row)
        }
        pinGrid.rows = tileRows
        for old in pinGrid.subviews where !tileRows.contains(where: { $0 === old }) {
            old.removeFromSuperview()
        }
        pinGrid.isHidden = tileRows.isEmpty
        pinGridHeight.constant = pinGrid.requiredHeight
        let firstRegularIndex = BrowserTabPlacement.current == .bottom ? 2 : 1
        for (index, tab) in regularTabs.enumerated() {
            let row: TabRow
            if let existing = tabRows[tab.id], existing.superview === tabStack { row = existing }
            else {
                discardTabRow(tab.id)
                row = TabRow(tabID: tab.id, target: self)
                tabRows[tab.id] = row
            }
            if row.superview !== tabStack {
                row.removeFromSuperview()
                row.translatesAutoresizingMaskIntoConstraints = false
                tabStack.insertArrangedSubview(row, at: min(firstRegularIndex + index, tabStack.arrangedSubviews.count))
            }
            row.setTileMode(false)
            if tabWidthConstraints[tab.id] == nil {
                let width = row.widthAnchor.constraint(equalTo: tabStack.widthAnchor)
                width.isActive = true
                tabWidthConstraints[tab.id] = width
            }
            let desired = firstRegularIndex + index
            if tabStack.arrangedSubviews.firstIndex(of: row) != desired {
                tabStack.removeArrangedSubview(row)
                row.removeFromSuperview()
                tabStack.insertArrangedSubview(row, at: min(desired, tabStack.arrangedSubviews.count))
            }
        }
        let regularIDs = Set(regularTabs.map(\.id))
        for case let stale as TabRow in tabStack.subviews where !regularIDs.contains(stale.tabID) {
            tabStack.removeArrangedSubview(stale)
            stale.removeFromSuperview()
        }
        for tab in visibleTabs {
            guard let row = tabRows[tab.id] else { continue }
            let ownerName = ownerSpace(for: tab).saved.name
            var displayTitle = tab.ownerSpaceID == activeSpace.saved.id
                ? tab.title : "\(tab.title)  ·  \(ownerName)"
            if splitTabIDs?.0 == tab.id, let other = self.tab(id: splitTabIDs!.1) {
                displayTitle += "  │  \(other.title)"
            }
            if tab.isFloating { displayTitle += "  ↗" }
            let isSelected = tab.id == activeTabID ||
                (splitTabIDs?.0 == tab.id && splitTabIDs?.1 == activeTabID)
            row.update(title: displayTitle, selected: isSelected,
                       favicon: tab.favicon, isTerminal: tab.isTerminal, isPinned: tab.isPinned,
                       loadingProgress: tab.navigationInProgress ? (tab.webView?.estimatedProgress ?? 0) : nil)
            let ownerID = ownerSpace(for: tab).saved.id
            if row.themeSpaceID != ownerID {
                row.applyTheme(BrowserTheme.profile(for: ownerID))
                row.themeSpaceID = ownerID
            }
        }
        tabStack.needsLayout = true
        pinGrid.needsLayout = true
        pinGrid.needsDisplay = true
        tabStack.needsDisplay = true
        tabStack.enclosingScrollView?.contentView.needsDisplay = true
    }

    @objc fileprivate func selectTabAction(_ sender: TabActionButton) {
        tabPreview.hide()
        guard let tab = tabs.first(where: { $0.id == sender.tabID }) else { return }
        if sender.physicalDoubleClick {
            let id = tab.id
            // Present after NSButton finishes handling the double click. Moving the
            // tab synchronously here can remove the very button handling this event.
            DispatchQueue.main.async { [weak self] in
                guard let self, let row = self.tabRows[id], row.window != nil else { return }
                let menu = NSMenu(title: "Tab Actions")
                self.appendFloatingItem(for: id, to: menu)
                self.appendMoveItems(for: id, to: menu)
                guard !menu.items.isEmpty else { return }
                menu.popUp(positioning: nil, at: NSPoint(x: 0, y: row.bounds.maxY), in: row)
            }
            return
        }
        selectTab(tab)
    }

    @objc private func selectTabByNumber(_ sender: NSMenuItem) {
        let visibleTabs = visibleSidebarTabs
        let index = sender.tag == 9 ? visibleTabs.count - 1 : sender.tag - 1
        guard visibleTabs.indices.contains(index) else { return }
        selectTab(visibleTabs[index])
    }

    @objc fileprivate func closeTabAction(_ sender: TabActionButton) { closeVisibleTab(id: sender.tabID) }

    @objc fileprivate func closeTabMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        closeVisibleTab(id: id)
    }

    private func closeVisibleTab(id: UUID) {
        if let splitTabIDs, splitTabIDs.0 == id {
            closeTab(id: splitTabIDs.1)
        }
        closeTab(id: id)
    }

    @objc fileprivate func togglePinTabAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        var ordered = tabs
        let tab = ordered.remove(at: index)
        let previousPins = ordered.filter(\.isPinned)
        tab.isPinned.toggle()
        var redistributed = false
        if tab.isPinned, (2...3).contains(previousPins.count) {
            let width = 1 / CGFloat(previousPins.count + 1)
            for pin in previousPins { pin.pinWidthFraction = width }
            tab.pinWidthFraction = width
            redistributed = true
        }
        ordered.insert(tab, at: ordered.prefix { $0.isPinned }.count)
        tabs = ordered
        if redistributed {
            for space in spaces { savePinnedTabs(for: space) }
        } else { savePinnedTabs(for: displaySpace(for: tab)) }
        refreshTabs()
    }

    @objc fileprivate func arrangePinsAction(_ sender: NSMenuItem) {
        guard (2...4).contains(sender.tag) else { return }
        let width = 1 / CGFloat(sender.tag)
        for tab in visibleSidebarTabs where tab.isPinned { tab.pinWidthFraction = width }
        for space in spaces { savePinnedTabs(for: space) }
        refreshTabs()
    }

    fileprivate func appendMoveItems(for tabID: UUID, to menu: NSMenu) {
        guard !BrowserExperiment.cyclesNewTabProfiles, spaces.count > 1 else { return }
        let root = NSMenuItem(title: "Show in Profile", action: nil, keyEquivalent: "")
        let destinations = NSMenu(title: "Show in Profile")
        for space in spaces where space.saved.id != activeSpace.saved.id {
            let item = destinations.addItem(withTitle: space.saved.name,
                                            action: #selector(moveTabMenuAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = [tabID, space.saved.id]
        }
        root.submenu = destinations
        menu.addItem(root)
    }

    fileprivate func appendFloatingItem(for tabID: UUID, to menu: NSMenu) {
        guard let tab = tab(id: tabID) else { return }
        let item = menu.addItem(withTitle: tab.isFloating ? "Dock in Webby" : "Floating",
                                action: #selector(toggleFloatingMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = tabID
    }

    @objc private func toggleFloatingMenuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let tab = tab(id: id) else { return }
        if tab.isFloating { dockFloatingTab(id: id, activate: true) }
        else { floatTab(tab) }
    }

    private func floatTab(_ tab: BrowserTab) {
        guard !tab.isFloating else { floatingWindows[tab.id]?.makeKeyAndOrderFront(nil); return }
        if let pair = splitTabIDs, pair.0 == tab.id || pair.1 == tab.id { endSplit() }
        let floating = FloatingTabWindow(tabID: tab.id, title: tab.title,
                                         screen: window.screen ?? NSScreen.main)
        floating.delegate = self
        floating.addressField.target = self
        floating.addressField.action = #selector(floatingAddressSubmitted(_:))
        floating.addressField.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
        floating.addressField.stringValue = tab.webView?.url.map(displayAddress) ?? tab.searchDraft
        floatingWindows[tab.id] = floating
        tab.isFloating = true
        if tab.isTerminal && tab.terminalView == nil { _ = terminalPane(for: tab) }
        attachFloatingContent(for: tab)
        if activeTabID == tab.id {
            activeTabID = nil
            if let next = tabs.first(where: { $0.id != tab.id && !$0.isFloating }) {
                selectTab(next)
            } else { addTab(select: true) }
        }
        refreshTabs()
        floating.makeKeyAndOrderFront(nil)
        if tab.webView == nil && !tab.isTerminal { floating.makeFirstResponder(floating.addressField) }
    }

    private func attachFloatingContent(for tab: BrowserTab) {
        guard let host = floatingWindows[tab.id]?.contentHost else { return }
        let view: NSView
        if let webView = tab.webView {
            NSLayoutConstraint.deactivate(tab.pageConstraints)
            view = webView
        } else if let terminal = tab.terminalView {
            NSLayoutConstraint.deactivate(tab.terminalConstraints)
            view = terminal
        } else { return }
        NSLayoutConstraint.deactivate(floatingContentConstraints.removeValue(forKey: tab.id) ?? [])
        view.removeFromSuperview()
        host.addSubview(view)
        view.translatesAutoresizingMaskIntoConstraints = false
        let constraints = [
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ]
        floatingContentConstraints[tab.id] = constraints
        NSLayoutConstraint.activate(constraints)
        view.isHidden = false
        view.alphaValue = 1
        if tab.isTerminal { tab.terminalView?.open() }
    }

    private func dockFloatingTab(id: UUID, activate: Bool) {
        guard let tab = tab(id: id), let floating = floatingWindows.removeValue(forKey: id) else { return }
        NSLayoutConstraint.deactivate(floatingContentConstraints.removeValue(forKey: id) ?? [])
        if let webView = tab.webView {
            webView.removeFromSuperview()
            pageArea.addSubview(webView, positioned: .below, relativeTo: homeView)
            NSLayoutConstraint.activate(tab.pageConstraints)
            webView.isHidden = true
        } else if let terminal = tab.terminalView {
            terminal.removeFromSuperview()
            pageArea.addSubview(terminal)
            NSLayoutConstraint.activate(tab.terminalConstraints)
            terminal.isHidden = true
        }
        tab.isFloating = false
        floating.delegate = nil
        floating.close()
        refreshTabs()
        guard activate else { return }
        if let index = spaces.firstIndex(where: { $0.tabs.contains { $0.id == id } }),
           index != activeSpaceIndex, !BrowserExperiment.cyclesNewTabProfiles {
            switchToSpace(index)
        }
        activeTabID = nil
        selectTab(tab)
        window.makeKeyAndOrderFront(nil)
    }

    private func discardFloatingWindow(for id: UUID) {
        guard let floating = floatingWindows.removeValue(forKey: id) else { return }
        NSLayoutConstraint.deactivate(floatingContentConstraints.removeValue(forKey: id) ?? [])
        floating.delegate = nil
        floating.close()
        tab(id: id)?.isFloating = false
    }

    @objc private func floatingAddressSubmitted(_ sender: NSTextField) {
        guard let rawID = sender.identifier?.rawValue, let id = UUID(uuidString: rawID),
              let tab = tab(id: id) else { return }
        navigate(sender.stringValue, in: tab)
        if let view = tab.webView { floatingWindows[id]?.makeFirstResponder(view) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let floating = sender as? FloatingTabWindow else { return true }
        dockFloatingTab(id: floating.tabID, activate: false)
        return false
    }

    fileprivate func appendSplitItem(for tabID: UUID, to menu: NSMenu) {
        guard splitTabIDs?.0 == tabID else { return }
        let item = menu.addItem(withTitle: "Unsplit Tabs", action: #selector(unsplitMenuAction), keyEquivalent: "")
        item.target = self
    }

    @objc private func unsplitMenuAction() {
        endSplit()
        if let activeTab { activeTabID = nil; selectTab(activeTab) }
        refreshTabs()
    }

    fileprivate func splitTabs(sourceID: UUID, targetID: UUID) -> Bool {
        guard sourceID != targetID,
              let source = tabs.first(where: { $0.id == sourceID }),
              let target = tabs.first(where: { $0.id == targetID }),
              !source.isTerminal, !target.isTerminal,
              !source.isFloating, !target.isFloating,
              source.webView?.url != nil, target.webView?.url != nil else { return false }
        endSplit()
        let left = makeWebView(for: target)
        let right = makeWebView(for: source)
        NSLayoutConstraint.deactivate(target.pageConstraints + source.pageConstraints)
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.wantsLayer = true
        split.layer?.backgroundColor = NSColor.clear.cgColor
        pageArea.addSubview(split, positioned: .below, relativeTo: homeView)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            split.topAnchor.constraint(equalTo: pageArea.topAnchor),
            split.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor)
        ])
        let panes = (0..<2).map { _ -> NSView in
            let pane = NSView()
            pane.translatesAutoresizingMaskIntoConstraints = false
            split.addArrangedSubview(pane)
            return pane
        }
        for (view, pane) in zip([left, right], panes) {
            view.removeFromSuperview()
            pane.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                view.topAnchor.constraint(equalTo: pane.topAnchor),
                view.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
            ])
            view.isHidden = false
            view.alphaValue = 1
        }
        splitView = split
        splitTabIDs = (targetID, sourceID)
        activeTabID = nil
        selectTab(target)
        pageArea.layoutSubtreeIfNeeded()
        split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
        return true
    }

    fileprivate func reorderTab(sourceID: UUID, targetID: UUID, before: Bool) -> Bool {
        guard sourceID != targetID,
              let source = tabs.first(where: { $0.id == sourceID }),
              let target = tabs.first(where: { $0.id == targetID }),
              source.isPinned == target.isPinned else { return false }
        if let splitTabIDs,
           [splitTabIDs.0, splitTabIDs.1].contains(sourceID) ||
           [splitTabIDs.0, splitTabIDs.1].contains(targetID) { endSplit() }
        var ordered = tabs
        guard let from = ordered.firstIndex(where: { $0.id == sourceID }) else { return false }
        let tab = ordered.remove(at: from)
        guard let targetIndex = ordered.firstIndex(where: { $0.id == targetID }) else { return false }
        ordered.insert(tab, at: targetIndex + (before ? 0 : 1))
        tabs = ordered
        if tab.isPinned { savePinnedTabs(for: displaySpace(for: tab)) }
        refreshTabs()
        return true
    }

    private func endSplit() {
        guard let split = splitView, let pair = splitTabIDs else { return }
        for id in [pair.0, pair.1] {
            guard let tab = tab(id: id), let view = tab.webView else { continue }
            view.removeFromSuperview()
            pageArea.addSubview(view, positioned: .below, relativeTo: homeView)
            NSLayoutConstraint.activate(tab.pageConstraints)
            view.isHidden = id != activeTabID
        }
        split.removeFromSuperview()
        splitView = nil
        splitTabIDs = nil
    }

    @objc fileprivate func moveTabMenuAction(_ sender: NSMenuItem) {
        guard let ids = sender.representedObject as? [UUID], ids.count == 2,
              let source = spaces.first(where: { $0.tabs.contains { $0.id == ids[0] } }),
              let destinationIndex = spaces.firstIndex(where: { $0.saved.id == ids[1] }),
              source !== spaces[destinationIndex],
              let index = source.tabs.firstIndex(where: { $0.id == ids[0] }) else { return }
        if let splitTabIDs, splitTabIDs.0 == ids[0] || splitTabIDs.1 == ids[0] { endSplit() }
        let tab = source.tabs.remove(at: index)
        tab.ownerSpaceID = tab.ownerSpaceID ?? source.saved.id
        if tab.isPinned { savePinnedTabs(for: source) }
        spaces[destinationIndex].tabs.append(tab)
        spaces[destinationIndex].activeTabID = tab.id
        if source.activeTabID == tab.id { source.activeTabID = source.tabs.first?.id }
        switchToSpace(destinationIndex, direction: destinationIndex >= activeSpaceIndex ? 1 : -1)
        if activeTabID != tab.id { selectTab(tab) }
        if tab.isPinned { savePinnedTabs(for: spaces[destinationIndex]) }
        refreshTabs()
    }

    private func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabPreview.hide(for: id)
        linkPreview?.close()
        if let splitTabIDs, splitTabIDs.0 == id || splitTabIDs.1 == id { endSplit() }
        let wasActive = activeTabID == id
        let containingSpace = displaySpace(for: tabs[index])
        let closingTab = tabs[index]
        recentlyClosedTabs.append(ClosedTabRecord(
            title: closingTab.title,
            address: closingTab.webView?.url?.absoluteString ?? destination(for: closingTab.searchDraft)?.absoluteString,
            searchDraft: closingTab.searchDraft,
            ownerSpaceID: ownerSpace(for: closingTab).saved.id,
            displaySpaceID: containingSpace.saved.id,
            wasPinned: closingTab.isPinned, wasTerminal: closingTab.isTerminal,
            pinWidthFraction: closingTab.pinWidthFraction, pinHeight: closingTab.pinHeight))
        if recentlyClosedTabs.count > 20 { recentlyClosedTabs.removeFirst() }
        discardFloatingWindow(for: id)
        let closing = tabs.remove(at: index)
        if closing.isPinned { savePinnedTabs(for: containingSpace) }
        closing.progressObservation?.invalidate()
        closing.progressObservation = nil
        closing.faviconTask?.cancel()
        closing.faviconTask = nil
        closing.webView?.stopLoading()
        closing.webView?.navigationDelegate = nil
        closing.webView?.uiDelegate = nil
        closing.webView?.removeFromSuperview()
        closing.terminalView?.stop()
        closing.terminalView?.removeFromSuperview()
        closing.terminalView = nil
        if tabs.isEmpty {
            activeTabID = nil
            addTab(select: true)
        } else if wasActive {
            activeTabID = nil
            selectTab(tabs[min(index, tabs.count - 1)])
        }
        else { refreshTabs() }
    }

    @objc private func reopenLastClosedTab() {
        guard let snapshot = recentlyClosedTabs.popLast() else { return }
        let destination = spaces.first { $0.saved.id == snapshot.displaySpaceID } ?? activeSpace
        let ownerID = spaces.contains { $0.saved.id == snapshot.ownerSpaceID }
            ? snapshot.ownerSpaceID : destination.saved.id
        let tab = BrowserTab()
        tab.title = snapshot.title
        tab.ownerSpaceID = ownerID
        tab.searchDraft = snapshot.searchDraft
        tab.isPinned = snapshot.wasPinned
        tab.isTerminal = snapshot.wasTerminal
        tab.pinWidthFraction = snapshot.pinWidthFraction
        tab.pinHeight = snapshot.pinHeight
        destination.tabs.insert(tab, at: tab.isPinned ? destination.tabs.prefix { $0.isPinned }.count : destination.tabs.count)
        if !BrowserExperiment.cyclesNewTabProfiles && destination !== activeSpace {
            destination.activeTabID = tab.id
        }
        if BrowserExperiment.cyclesNewTabProfiles { fusedTabOrder.append(tab.id) }
        if let address = snapshot.address, let url = URL(string: address),
           ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            tab.navigationInProgress = true
            let view = makeWebView(for: tab)
            view.isHidden = true
            view.load(URLRequest(url: url))
        }
        if tab.isPinned { savePinnedTabs(for: destination) }
        if !BrowserExperiment.cyclesNewTabProfiles,
           let index = spaces.firstIndex(where: { $0 === destination }), index != activeSpaceIndex {
            switchToSpace(index, direction: index > activeSpaceIndex ? 1 : -1)
        }
        if activeTabID != tab.id { selectTab(tab) }
        else { refreshTabs() }
    }

    @objc private func toggleSidebar() {
        content.layoutSubtreeIfNeeded()
        sidebarTransitionToken += 1
        let token = sidebarTransitionToken
        sidebarVisible.toggle()
        if sidebarVisible { sidebar.isHidden = false }
        sidebarWidth.constant = sidebarVisible ? 238 : 0
        UserDefaults.standard.set(!sidebarVisible, forKey: "sidebarHidden")
        if Motion.enabled {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.allowsImplicitAnimation = true
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.2, 1)
                content.animator().layoutSubtreeIfNeeded()
            } completionHandler: { [weak self] in
                guard let self else { return }
                if self.sidebarTransitionToken == token && !self.sidebarVisible { self.sidebar.isHidden = true }
            }
        } else {
            content.layoutSubtreeIfNeeded()
            if !sidebarVisible { sidebar.isHidden = true }
        }
    }

    @objc private func toggleToolbar() {
        if toolbarVisible { hideToolbar(animated: true) }
        else { showToolbar() }
    }

    private func showToolbar() {
        guard activeWebView != nil, !terminalMode else { return }
        if toolbarVisible { scheduleToolbarHide(); return }
        toolbarTransitionToken += 1
        let visibleOpacity = toolbar.layer?.presentation()?.opacity ?? 0
        let visibleY = (toolbar.layer?.presentation()?.value(forKeyPath: "transform.translation.y") as? NSNumber)
            .map { CGFloat(truncating: $0) } ?? -7
        toolbarVisible = true
        toolbar.isHidden = false
        chromeToggle.isHidden = true
        if Motion.enabled {
            Motion.basic(toolbar.layer, key: "opacity", from: visibleOpacity, to: 1, duration: 0.18)
            Motion.basic(toolbar.layer, key: "transform.translation.y", from: visibleY, to: 0, duration: 0.20)
        }
        scheduleToolbarHide()
    }

    private func hideToolbar(animated: Bool) {
        toolbarHideTimer?.invalidate()
        toolbarHideTimer = nil
        toolbarTransitionToken += 1
        let token = toolbarTransitionToken
        let wasVisible = toolbarVisible && !toolbar.isHidden
        let visibleOpacity = toolbar.layer?.presentation()?.opacity ?? 1
        let visibleY = (toolbar.layer?.presentation()?.value(forKeyPath: "transform.translation.y") as? NSNumber)
            .map { CGFloat(truncating: $0) } ?? 0
        toolbarVisible = false
        if animated && Motion.enabled && wasVisible {
            Motion.basic(toolbar.layer, key: "opacity", from: visibleOpacity, to: 0, duration: 0.18)
            Motion.basic(toolbar.layer, key: "transform.translation.y", from: visibleY, to: -7, duration: 0.18)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.toolbarTransitionToken == token, !self.toolbarVisible else { return }
                self.toolbar.isHidden = true
                self.chromeToggle.isHidden = self.activeWebView == nil
            }
        } else {
            toolbar.isHidden = true
            chromeToggle.isHidden = activeWebView == nil
        }
    }

    private func scheduleToolbarHide() {
        toolbarHideTimer?.invalidate()
        toolbarHideTimer = Timer.scheduledTimer(timeInterval: 2.2, target: self,
                                                selector: #selector(toolbarHideTimerFired), userInfo: nil, repeats: false)
    }

    @objc private func toolbarHideTimerFired() {
        guard toolbarVisible else { return }
        toolbarHideTimer = nil
        let point = toolbar.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if toolbar.bounds.contains(point) || addressField.currentEditor() != nil { scheduleToolbarHide() }
        else { hideToolbar(animated: true) }
    }

    private func installChromeMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .mouseMoved]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .scrollWheel {
                let sidebarPoint = self.sidebar.convert(event.locationInWindow, from: nil)
                let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.25
                if !BrowserExperiment.cyclesNewTabProfiles,
                   self.sidebarVisible, self.sidebar.bounds.contains(sidebarPoint), horizontal,
                   event.momentumPhase == [] {
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastScrollAt > 0.30 { self.swipeDistance = 0 }
                    self.lastScrollAt = now
                    self.swipeDistance += event.scrollingDeltaX
                    if abs(self.swipeDistance) >= 48, now - self.lastSwipeAt > 0.45 {
                        let direction = self.swipeDistance < 0 ? 1 : -1
                        self.swipeDistance = 0
                        self.lastSwipeAt = now
                        self.switchSpace(direction)
                    }
                    return nil
                }
            }
            if event.type == .scrollWheel, let webView = self.activeWebView, event.scrollingDeltaY > 2 {
                let point = self.pageArea.convert(event.locationInWindow, from: nil)
                if let hit = self.pageArea.hitTest(point), hit.isDescendant(of: webView) {
                    self.showToolbar()
                }
            } else if event.type == .mouseMoved && self.toolbarVisible {
                let point = self.toolbar.convert(event.locationInWindow, from: nil)
                if self.toolbar.bounds.contains(point) {
                    self.toolbarHideTimer?.invalidate()
                    self.toolbarHideTimer = nil
                } else if self.toolbarHideTimer == nil { self.scheduleToolbarHide() }
            }
            return event
        }
    }

    private func loadRules() {
        guard let resources = Bundle.main.resourceURL,
              let store = WKContentRuleListStore(url: resources.appendingPathComponent("ContentRules", isDirectory: true)) else {
            fastModeEnabled = false; fastModeItem?.isEnabled = false; return
        }
        store.lookUpContentRuleList(forIdentifier: "FastRules") { [weak self] rule, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.fastRule = rule
                if rule == nil { self.fastModeEnabled = false; self.fastModeItem?.isEnabled = false }
            }
        }
    }

    private func makeWebView(for tab: BrowserTab, popupConfiguration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let existing = tab.webView { return existing }
        let configuration = popupConfiguration ?? WKWebViewConfiguration()
        if popupConfiguration == nil {
            configuration.websiteDataStore = ownerSpace(for: tab).dataStore
            if fastModeEnabled, let fastRule { configuration.userContentController.add(fastRule) }
            configuration.userContentController.add(self, name: "browserPasswordField")
            configuration.userContentController.add(self, name: "browserLinkPreview")
            if let url = Bundle.main.url(forResource: "LinkPreview", withExtension: "js"),
               let source = try? String(contentsOf: url, encoding: .utf8) {
                configuration.userContentController.addUserScript(
                    WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
            configuration.userContentController.addUserScript(WKUserScript(source: """
        (() => {
          if (location.protocol !== 'https:') return;
          let sent = false;
          function check() {
            if (sent || !document.querySelector('input[type=password],input[autocomplete="username"],input[type=email][name=identifier]')) return;
            sent = true;
            window.webkit.messageHandlers.browserPasswordField.postMessage(location.host);
          }
          new MutationObserver(check).observe(document, {childList:true,subtree:true});
          document.addEventListener('DOMContentLoaded', check, {once:true});
          check();
        })();
        """, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            if let scriptURL = Bundle.main.url(forResource: "VideoControls", withExtension: "js"),
               let script = try? String(contentsOf: scriptURL, encoding: .utf8) {
                let videoWorld = WKContentWorld.world(name: "WebbyVideo")
                configuration.userContentController.add(self, contentWorld: videoWorld, name: "browserVideoFloat")
                configuration.userContentController.addUserScript(
                    WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                 forMainFrameOnly: false, in: videoWorld))
            }
        }
        GlassPageInjector.install(into: configuration)
        let view = WKWebView(frame: .zero, configuration: configuration)
        // Keep each site's color-scheme stable while switching tabs changes
        // the material underneath it for readable text.
        view.appearance = window.effectiveAppearance
        GlassPageInjector.makeWebViewTransparent(view)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.translatesAutoresizingMaskIntoConstraints = false
        pageArea.addSubview(view, positioned: .below, relativeTo: homeView)
        let pageConstraints = [
            view.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            view.topAnchor.constraint(equalTo: pageArea.topAnchor),
            view.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor)
        ]
        tab.pageConstraints = pageConstraints
        NSLayoutConstraint.activate(pageConstraints)
        tab.webView = view
        let tabID = tab.id
        tab.progressObservation = view.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let view,
                      let tab = self.spaces.lazy.flatMap(\.tabs).first(where: { $0.id == tabID }),
                      tab.webView === view, tab.navigationInProgress else { return }
                self.tabRows[tabID]?.setLoadingProgress(view.estimatedProgress)
                guard self.activeTabID == tabID else { return }
                self.toolbar.setProgress(min(view.estimatedProgress, 0.96))
                if self.activeTab?.showsSearchView == true {
                    self.homeSearchSurface.setLoadingProgress(view.estimatedProgress)
                }
            }
        }
        webViewReadyAt = ProcessInfo.processInfo.systemUptime
        return view
    }

    private func applyGlassTone(for tab: BrowserTab) {
        mainArea.appearance = NSAppearance(named: tab.prefersDarkGlass ? .darkAqua : .aqua)
    }

    private func updateGlassTone(for webView: WKWebView) {
        webView.evaluateJavaScript("""
        (() => {
          const luminance = element => {
            if (!element || element.closest('img,video,canvas,svg,iframe')) return null;
            const numbers = getComputedStyle(element).color.match(/[\\d.]+/g);
            if (!numbers || numbers.length < 3) return null;
            const [r, g, b] = numbers.slice(0, 3).map(Number);
            return 0.2126 * r + 0.7152 * g + 0.0722 * b;
          };
          const samples = [];
          for (const y of [0.23, 0.5, 0.77]) {
            for (const x of [0.2, 0.5, 0.8]) {
              const value = luminance(document.elementFromPoint(innerWidth * x, innerHeight * y));
              if (value !== null) samples.push(value);
            }
          }
          if (!samples.length) {
            const value = luminance(document.body || document.documentElement);
            if (value !== null) samples.push(value);
          }
          samples.sort((a, b) => a - b);
          return samples.length ? samples[Math.floor(samples.length / 2)] >= 135 : null;
        })()
        """) { [weak self, weak webView] result, _ in
            DispatchQueue.main.async { [weak self, weak webView] in
                guard let self, let webView, let tab = self.tab(for: webView),
                      let dark = result as? Bool else { return }
                tab.prefersDarkGlass = dark
                if self.activeTabID == tab.id { self.applyGlassTone(for: tab) }
            }
        }
    }

    private func tab(for view: WKWebView) -> BrowserTab? {
        spaces.lazy.flatMap(\.tabs).first { $0.webView === view }
    }

    private func tab(id: UUID) -> BrowserTab? {
        spaces.lazy.flatMap(\.tabs).first { $0.id == id }
    }

    private func navigate(_ input: String, in tab: BrowserTab? = nil) {
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let url = destination(for: query), let target = tab ?? activeTab else { return }
        if target.isFloating {
            if target.isTerminal {
                NSLayoutConstraint.deactivate(floatingContentConstraints.removeValue(forKey: target.id) ?? [])
                NSLayoutConstraint.deactivate(target.terminalConstraints)
                target.terminalView?.stop()
                target.terminalView?.removeFromSuperview()
                target.terminalView = nil
                target.terminalConstraints = []
            }
            target.isTerminal = false
            target.showsSearchView = false
            target.navigationInProgress = true
            target.searchDraft = query
            target.pendingSearchInput = query
            target.loadError = nil
            let view = makeWebView(for: target)
            attachFloatingContent(for: target)
            target.title = query.contains("://") || query.contains(".") ? (url.host ?? query) : query
            floatingWindows[target.id]?.title = target.title
            floatingWindows[target.id]?.addressField.stringValue = query
            view.load(URLRequest(url: url))
            refreshTabs()
            return
        }
        suggestions.close()
        loadErrorLabel.isHidden = true
        target.loadError = nil
        let startsFromSearch = target.webView == nil || target.showsSearchView
        terminalTransitionToken += 1
        // A tab that becomes a website can no longer reach its old shell.
        // Release that pane; terminal tabs themselves keep their sessions alive.
        target.terminalView?.stop()
        target.terminalView?.removeFromSuperview()
        target.terminalView = nil
        target.isTerminal = false
        target.showsSearchView = startsFromSearch
        target.navigationInProgress = true
        target.searchDraft = query
        target.pendingSearchInput = query
        terminalMode = false
        target.terminalView?.isHidden = true
        if startsFromSearch {
            homeSearchSurface.isHidden = false
            globe.engine.showScene("search")
        }
        hideToolbar(animated: false)
        chromeToggle.isHidden = startsFromSearch
        let view = makeWebView(for: target)
        target.title = query.contains("://") || query.contains(".") ? (url.host ?? query) : query
        if target.id == activeTabID {
            view.isHidden = false
            if startsFromSearch {
                homeView.isHidden = false
                view.alphaValue = 0.001
                homeSearchField.stringValue = query
                homeSearchSurface.startLoading()
            } else {
                homeView.isHidden = true
                view.alphaValue = 1
            }
            addressField.stringValue = query
        }
        lastHost = url.host
        view.load(URLRequest(url: url))
        refreshTabs()
    }

    private func destination(for input: String) -> URL? {
        if input.contains("://") {
            guard let url = URL(string: input), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return url
        }
        let lower = input.lowercased()
        if !input.contains(where: \.isWhitespace) && (input.contains(".") || lower == "localhost" || lower.hasPrefix("localhost:")) {
            return URL(string: "https://" + input)
        }
        var search = URLComponents(string: "https://www.google.com/search")!
        search.queryItems = [URLQueryItem(name: "q", value: input)]
        return search.url
    }

    private func displayAddress(_ url: URL) -> String {
        if let host = url.host?.lowercased(), ["google.com", "www.google.com"].contains(host),
           url.path == "/search", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let query = components.queryItems?.first(where: { $0.name == "q" })?.value, !query.isEmpty {
            return query
        }
        return url.absoluteString
    }

    @objc private func openAddress() {
        let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        navigate(text)
    }

    @objc private func openHomeSearch() {
        guard let tab = activeTab, (tab.webView == nil || tab.showsSearchView), !tab.isTerminal else { return }
        let query = homeSearchField.currentEditor()?.string ?? homeSearchField.stringValue
        tab.searchDraft = query
        navigate(query, in: tab)
    }
    @objc private func focusAddress() {
        if terminalMode { activeTab?.terminalView?.focus() }
        else if activeWebView == nil || activeTab?.showsSearchView == true {
            window.makeFirstResponder(homeSearchField)
            homeSearchField.currentEditor()?.selectAll(nil)
        }
        else {
            showToolbar()
            window.makeFirstResponder(addressField)
            addressField.currentEditor()?.selectAll(nil)
        }
    }
    @objc private func goBack() { activeWebView?.goBack() }
    @objc private func goForward() { activeWebView?.goForward() }
    @objc private func reloadPage() { activeWebView?.reload() }
    @objc private func closeCurrentTab() {
        guard let activeTabID else { return }
        closeTab(id: activeTabID)
    }

    private func updateNavigation() {
        backButton.isEnabled = activeWebView?.canGoBack == true
        forwardButton.isEnabled = activeWebView?.canGoForward == true
        if !terminalMode { addressField.stringValue = activeWebView?.url.map(displayAddress) ?? "" }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if let tab = tab(for: webView) {
            tab.loadError = nil
            tab.navigationInProgress = true
            tab.previewImage = nil
            tab.previewCapturedAt = 0
            tab.previewGeneration += 1
            tab.faviconGeneration += 1
            tab.faviconTask?.cancel()
            tab.faviconTask = nil
            tab.favicon = nil
            refreshTabs()
        }
        if let tab = tab(for: webView), tab.id == activeTabID {
            loadErrorLabel.isHidden = true
            navigationToken += 1
            navigationStartedAt = ProcessInfo.processInfo.systemUptime
            navigationCommittedAt = nil; navigationFinishedAt = nil
            toolbar.resetProgress(); toolbar.setProgress(0.08)
            hideToolbar(animated: false)
            webView.isHidden = false
            if tab.showsSearchView {
                chromeToggle.isHidden = true
                homeView.isHidden = false
                webView.alphaValue = 0.001
                homeSearchSurface.isHidden = false
                homeSearchSurface.startLoading()
                if let pending = tab.pendingSearchInput { tab.searchDraft = pending }
                else if let url = webView.url { tab.searchDraft = displayAddress(url) }
                homeSearchField.stringValue = tab.searchDraft
                globe.engine.showScene("search")
            } else {
                chromeToggle.isHidden = false
                homeView.isHidden = true
                webView.alphaValue = 1
            }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        tab.title = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host ?? tab.title)
        if let floating = floatingWindows[tab.id] {
            floating.title = tab.title
            if let url = webView.url { floating.addressField.stringValue = displayAddress(url) }
        }
        if tab.id == activeTabID {
            navigationCommittedAt = ProcessInfo.processInfo.systemUptime
            lastHost = webView.url?.host
            toolbar.materialView.blendingMode = .withinWindow
            toolbar.setProgress(max(webView.estimatedProgress, 0.55))
            if tab.showsSearchView { homeSearchSurface.setLoadingProgress(webView.estimatedProgress) }
            if tab.showsSearchView, let url = webView.url {
                tab.searchDraft = displayAddress(url)
                homeSearchField.stringValue = tab.searchDraft
            }
            tab.pendingSearchInput = nil
            updateNavigation()
        }
        refreshTabs()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(for: webView) else { return }
        updateGlassTone(for: webView)
        let wasShowingSearch = tab.showsSearchView
        tab.title = webView.title?.isEmpty == false ? webView.title! : (webView.url?.host ?? tab.title)
        if let floating = floatingWindows[tab.id] {
            floating.title = tab.title
            if let url = webView.url { floating.addressField.stringValue = displayAddress(url) }
        }
        tab.showsSearchView = false
        tab.loadError = nil
        tab.navigationInProgress = false
        tab.pendingSearchInput = nil
        if let url = webView.url,
           let space = spaces.first(where: { $0.saved.id == tab.ownerSpaceID })
                       ?? spaces.first(where: { $0.tabs.contains { $0.id == tab.id } }) {
            space.recordVisit(url: url, title: tab.title)
            if tab.isPinned { savePinnedTabs(for: space) }
            scheduleSpaceSave()
        }
        if tab.id == activeTabID {
            navigationFinishedAt = ProcessInfo.processInfo.systemUptime
            toolbar.setProgress(1)
            if wasShowingSearch {
                homeSearchSurface.setLoadingProgress(1)
                homeSearchSurface.stopLoading()
            }
            webView.alphaValue = 1
            homeView.isHidden = true
            webView.isHidden = false
            globe.engine.hide()
            chromeToggle.isHidden = false
            let token = navigationToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.navigationToken == token else { return }
                self.toolbar.hideProgress()
            }
            updateNavigation()
        }
        refreshTabs()
        loadFavicon(for: tab, webView: webView)
        if tab.id == activeTabID || tab.isFloating {
            let tabID = tab.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let current = self.tab(id: tabID) else { return }
                self.captureTabPreview(current)
            }
        }
    }

    private func loadFavicon(for tab: BrowserTab, webView: WKWebView) {
        guard let pageURL = webView.url, let host = pageURL.host,
              ["http", "https"].contains(pageURL.scheme?.lowercased() ?? "") else { return }
        let generation = tab.faviconGeneration
        var fallbackParts = URLComponents()
        fallbackParts.scheme = pageURL.scheme
        fallbackParts.host = host
        fallbackParts.port = pageURL.port
        fallbackParts.path = "/favicon.ico"
        let fallback = fallbackParts.url
        let script = "Array.from(document.querySelectorAll('link[rel]')).find(x => /(?:^|\\s)(?:icon|apple-touch-icon)(?:\\s|$)/i.test(x.rel) && x.href)?.href || ''"
        webView.evaluateJavaScript(script) { [weak self, weak webView] value, _ in
            DispatchQueue.main.async {
                guard let self, let webView, let current = self.tab(id: tab.id),
                      current.faviconGeneration == generation, current.webView === webView else { return }
                let declared = (value as? String).flatMap(URL.init(string:))
                let candidates = [declared, fallback].compactMap { $0 }
                    .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
                self.fetchFavicon(candidates, index: 0, tabID: tab.id, generation: generation)
            }
        }
    }

    private func fetchFavicon(_ candidates: [URL], index: Int, tabID: UUID, generation: Int) {
        guard let tab = tab(id: tabID),
              tab.faviconGeneration == generation, candidates.indices.contains(index) else { return }
        let url = candidates[index]
        if let cached = faviconCache[url] {
            tab.favicon = cached
            if let pageURL = tab.webView?.url { suggestions.rememberFavicon(cached, for: pageURL) }
            refreshTabs()
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        tab.faviconTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, let current = self.tab(id: tabID),
                      current.faviconGeneration == generation else { return }
                current.faviconTask = nil
                if error == nil, let response = response as? HTTPURLResponse,
                   (200..<300).contains(response.statusCode), let data,
                   data.count <= 1_000_000, let image = NSImage(data: data) {
                    self.faviconCache[url] = image
                    current.favicon = image
                    if let pageURL = current.webView?.url {
                        self.suggestions.rememberFavicon(image, for: pageURL)
                    }
                    self.refreshTabs()
                } else {
                    self.fetchFavicon(candidates, index: index + 1, tabID: tabID, generation: generation)
                }
            }
        }
        tab.faviconTask?.resume()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(in: webView, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(in: webView, error: error)
    }

    private func navigationFailed(in webView: WKWebView, error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled, let tab = tab(for: webView) else { return }
        tab.navigationInProgress = false
        tab.showsSearchView = true
        let address = webView.url?.host ?? "this site"
        tab.loadError = "Couldn’t load \(address): \(error.localizedDescription)\nCheck the address or retry. You can turn off ad blocking in View."
        refreshTabs()
        if tab.id == activeTabID {
            toolbar.hideProgress()
            webView.isHidden = false
            homeSearchSurface.stopLoading()
            homeView.isHidden = false
            webView.alphaValue = 0.001
            chromeToggle.isHidden = true
            globe.engine.showScene("search")
            loadErrorLabel.stringValue = tab.loadError ?? ""
            loadErrorLabel.isHidden = false
            homeSearchField.stringValue = tab.pendingSearchInput ?? tab.searchDraft
            updateNavigation()
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.contains(.command),
           navigationAction.targetFrame != nil,
           let source = tab(for: webView),
           let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let tab = BrowserTab()
            tab.ownerSpaceID = ownerSpace(for: source).saved.id
            tab.title = url.host ?? "New Tab"
            tab.navigationInProgress = true
            activeSpace.tabs.append(tab)
            let background = makeWebView(for: tab)
            background.isHidden = true
            background.load(navigationAction.request)
            refreshTabs()
            decisionHandler(.cancel)
            return
        }
        decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        decisionHandler(!navigationResponse.canShowMIMEType || disposition.contains("attachment")
                        ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) { beginDownload(download, from: webView) }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) { beginDownload(download, from: webView) }

    private func beginDownload(_ download: WKDownload, from webView: WKWebView) {
        downloads.attach(download)
        if let tab = tab(for: webView) {
            tab.navigationInProgress = false
            refreshTabs()
            if tab.id == activeTabID {
                toolbar.hideProgress()
                homeSearchSurface.stopLoading()
            }
        }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        let tab = BrowserTab()
        tab.ownerSpaceID = self.tab(for: webView).map { ownerSpace(for: $0).saved.id } ?? activeSpace.saved.id
        tabs.append(tab)
        let background = navigationAction.modifierFlags.contains(.command)
        if !background { selectTab(tab) }
        let popup = makeWebView(for: tab, popupConfiguration: configuration)
        tab.showsSearchView = false
        popup.isHidden = background
        popup.alphaValue = 1
        if !background {
            homeView.isHidden = true
            chromeToggle.isHidden = false
        }
        refreshTabs()
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        closeTab(id: tab.id)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "Website"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "Website"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = webView.url?.host ?? "Website"
        alert.informativeText = prompt
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 26)
        alert.accessoryView = field
        alert.beginSheetModal(for: window) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    private func installMenus() {
        let main = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Webby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; main.addItem(app)
        let file = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let tab = fileMenu.addItem(withTitle: "New Tab", action: #selector(newTabAction), keyEquivalent: "t")
        tab.target = self
        let close = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeCurrentTab), keyEquivalent: "w")
        close.target = self
        let reopen = fileMenu.addItem(withTitle: "Reopen Closed Tab", action: #selector(reopenLastClosedTab), keyEquivalent: "t")
        reopen.target = self
        reopen.keyEquivalentModifierMask = [.command, .shift]
        let location = fileMenu.addItem(withTitle: "Open Location", action: #selector(focusAddress), keyEquivalent: "l")
        location.target = self
        fileMenu.addItem(.separator())
        let history = fileMenu.addItem(withTitle: "History", action: #selector(openHistoryMenu), keyEquivalent: "y")
        history.target = self
        let deleteProfile = fileMenu.addItem(withTitle: "Delete Profile…", action: #selector(showDeleteProfile), keyEquivalent: "")
        deleteProfile.target = self
        let passwords = fileMenu.addItem(withTitle: "Saved Passwords…", action: #selector(showSavedPasswords), keyEquivalent: "")
        passwords.target = self
        let fillPassword = fileMenu.addItem(withTitle: "Fill Password for This Site…", action: #selector(fillSavedPasswordForCurrentSite), keyEquivalent: "")
        fillPassword.target = self
        let importPasswords = fileMenu.addItem(withTitle: "Import Chrome Passwords…", action: #selector(importChromePasswords), keyEquivalent: "")
        importPasswords.target = self
        let importSignIns = fileMenu.addItem(withTitle: "Import Chrome Sign-ins…", action: #selector(importChromeSignIns), keyEquivalent: "")
        importSignIns.target = self
        file.submenu = fileMenu; main.addItem(file)
        let edit = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.submenu = editMenu; main.addItem(edit)
        let view = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let reload = viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        reload.target = self
        let sidebarItem = viewMenu.addItem(withTitle: "Toggle Tabs Sidebar", action: #selector(toggleSidebar), keyEquivalent: "\\")
        sidebarItem.target = self
        let fuse = viewMenu.addItem(withTitle: "Fuse All Profile Tabs", action: #selector(toggleFuseMode), keyEquivalent: "f")
        fuse.target = self
        fuse.keyEquivalentModifierMask = [.command]
        fuse.state = BrowserExperiment.cyclesNewTabProfiles ? .on : .off
        fuseMenuItem = fuse
        viewMenu.addItem(NSMenuItem.separator())
        for number in 1...9 {
            let item = viewMenu.addItem(withTitle: number == 9 ? "Show Last Tab" : "Show Tab \(number)",
                                        action: #selector(selectTabByNumber(_:)), keyEquivalent: String(number))
            item.target = self
            item.tag = number
            item.keyEquivalentModifierMask = [.command]
        }
        viewMenu.addItem(NSMenuItem.separator())
        let fast = NSMenuItem(title: "Block Common Ads and Trackers", action: #selector(toggleFastMode(_:)), keyEquivalent: "")
        fast.target = self; fast.state = .on; fastModeItem = fast; viewMenu.addItem(fast)
        viewMenu.addItem(NSMenuItem.separator())
        let report = viewMenu.addItem(withTitle: "Copy Performance Report", action: #selector(copyPerformanceReport), keyEquivalent: "")
        report.target = self
        view.submenu = viewMenu; main.addItem(view)
        NSApplication.shared.mainMenu = main
    }

    @objc private func toggleFuseMode() {
        BrowserExperiment.cyclesNewTabProfiles.toggle()
        experimentalModeChanged()
    }

    @objc private func toggleFastMode(_ sender: NSMenuItem) {
        guard let fastRule else { return }
        fastModeEnabled.toggle()
        sender.state = fastModeEnabled ? .on : .off
        for tab in tabs {
            guard let view = tab.webView else { continue }
            let controller = view.configuration.userContentController
            if fastModeEnabled { controller.add(fastRule) }
            else { controller.remove(fastRule) }
            if view.url != nil { view.reload() }
        }
    }

    @objc private func copyPerformanceReport() {
        func duration(_ start: TimeInterval?, _ end: TimeInterval?) -> String {
            guard let start, let end else { return "not recorded" }
            return String(format: "%.2f s", max(0, end - start))
        }
        let report = """
        Webby performance report
        Window visible: \(duration(launchedAt, windowShownAt)) after launch
        WebKit ready: \(duration(launchedAt, webViewReadyAt)) after launch
        Last site: \(lastHost ?? "none")
        Navigation to response: \(duration(navigationStartedAt, navigationCommittedAt))
        Navigation to finish: \(duration(navigationStartedAt, navigationFinishedAt))
        Common ad and tracker blocking: \(fastModeEnabled && fastRule != nil ? "on" : "off")
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

@main struct Main {
    static func main() {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-icon" {
            try? WebbyIcon.writeDefaultPNG(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        let app = NSApplication.shared
        let delegate = BrowserApp()
        app.delegate = delegate
        app.run()
    }
}
