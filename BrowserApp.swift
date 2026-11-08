import AppKit
import WebKit
import LocalAuthentication
import Security
import os
import CryptoKit

/// Changes only the position of WebKit's existing native PiP window. Video,
/// transport buttons and native resize tracking remain owned by WebKit/macOS.
@MainActor final class NativePiPWindowMotion {
    private var monitor: Any?
    var isMonitoring: Bool { monitor != nil }
    private var timer: Timer?
    private weak var dragged: NSWindow?
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var samples: [(NSPoint, TimeInterval)] = []

    func setActive(_ active: Bool) {
        if !active {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil; cancel(); return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                return self.handle(event)
            }
        }
    }

    func cancel() {
        timer?.invalidate(); timer = nil; dragged = nil; samples.removeAll()
    }

    static func canDrag(_ window: NSWindow, at location: NSPoint) -> Bool {
        guard let root = window.contentView else { return false }
        let point = root.convert(location, from: nil)
        let safe = root.bounds.insetBy(dx: 10, dy: 10)
        guard safe.contains(point) else { return false } // Native edge/corner resizing.
        var hit = root.hitTest(point)
        while let view = hit {
            if view is NSControl { return false } // Preserve play, close and return controls.
            hit = view.superview
        }
        return true
    }

    fileprivate func handle(_ event: NSEvent) -> NSEvent? {
        if event.type == .leftMouseDown {
            guard let window = event.window,
                  NSStringFromClass(type(of: window)).contains("PIPPanel"), event.clickCount == 1,
                  !event.modifierFlags.contains(.command),
                  Self.canDrag(window, at: event.locationInWindow) else { return event }
            begin(window, point: NSEvent.mouseLocation, time: event.timestamp)
            return nil
        }
        guard dragged != nil else { return event }
        if event.type == .leftMouseDragged { move(point: NSEvent.mouseLocation, time: event.timestamp); return nil }
        if event.type == .leftMouseUp { finish(point: NSEvent.mouseLocation, time: event.timestamp); return nil }
        return event
    }

    func begin(_ window: NSWindow, point: NSPoint, time: TimeInterval) {
        cancel(); dragged = window; startOrigin = window.frame.origin; startMouse = point
        samples = [(point,time)]
    }

    private func record(_ point: NSPoint, _ time: TimeInterval) {
        samples.append((point,time))
        samples.removeAll { time - $0.1 > 0.10 }
        if samples.count > 16 { samples.removeFirst(samples.count - 16) }
    }

    static func screenBounds(for point: NSPoint, window: NSWindow) -> NSRect {
        (NSScreen.screens.first { $0.frame.contains(point) } ?? window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x:0,y:0,width:1280,height:800)
    }

    static func clamp(_ origin: NSPoint, size: NSSize, in bounds: NSRect) -> NSPoint {
        NSPoint(x:min(max(bounds.minX,origin.x),max(bounds.minX,bounds.maxX-size.width)),
                y:min(max(bounds.minY,origin.y),max(bounds.minY,bounds.maxY-size.height)))
    }

    func move(point: NSPoint, time: TimeInterval) {
        guard let window = dragged else { return }
        record(point,time)
        let next = NSPoint(x:startOrigin.x+point.x-startMouse.x, y:startOrigin.y+point.y-startMouse.y)
        window.setFrameOrigin(Self.clamp(next,size:window.frame.size,in:Self.screenBounds(for:point,window:window)))
    }

    @discardableResult func finish(point: NSPoint, time: TimeInterval) -> Bool {
        guard let window = dragged else { return false }
        move(point:point,time:time)
        let first = samples.first ?? (point,time)
        let dt = time-first.1
        let velocity = dt > 0.008 ? NSPoint(x:(point.x-first.0.x)/dt,y:(point.y-first.0.y)/dt) : .zero
        let delta = NSPoint(x:point.x-startMouse.x,y:point.y-startMouse.y)
        let distance = hypot(delta.x,delta.y)
        dragged = nil; samples.removeAll()
        guard distance >= 8 else { return false }
        let bounds = Self.screenBounds(for:point,window:window)
        let target = Self.directionalCorner(origin:startOrigin,delta:delta,size:window.frame.size,bounds:bounds)
        spring(window, target:target, velocity:velocity, bounds:bounds)
        return true
    }

    static func corner(origin: NSPoint, velocity: NSPoint, size: NSSize, bounds: NSRect) -> NSPoint {
        let predicted = NSPoint(x:origin.x+size.width/2+velocity.x*0.18,
                                y:origin.y+size.height/2+velocity.y*0.18)
        let inset = bounds.insetBy(dx:14,dy:14)
        return clamp(NSPoint(x:predicted.x < bounds.midX ? inset.minX : inset.maxX-size.width,
                             y:predicted.y < bounds.midY ? inset.minY : inset.maxY-size.height),size:size,in:bounds)
    }

    /// Choose by drag intent, not by whether the pointer crossed half the screen.
    /// Ignore minor off-axis hand movement, preserving the current corner on that axis.
    static func directionalCorner(origin: NSPoint, delta: NSPoint, size: NSSize, bounds: NSRect) -> NSPoint {
        let threshold = max(8, max(abs(delta.x),abs(delta.y))*0.45)
        let right = abs(delta.x) >= threshold ? delta.x > 0 : origin.x+size.width/2 >= bounds.midX
        let top = abs(delta.y) >= threshold ? delta.y > 0 : origin.y+size.height/2 >= bounds.midY
        let inset = bounds.insetBy(dx:14,dy:14)
        return clamp(NSPoint(x:right ? inset.maxX-size.width : inset.minX,
                             y:top ? inset.maxY-size.height : inset.minY),size:size,in:bounds)
    }

    /// Analytic damped spring, preserving release velocity. There is no idle timer.
    static func position(start: NSPoint, target: NSPoint, velocity: NSPoint, time: Double) -> NSPoint {
        let omega = 20.0, damping = 0.88
        let wd = omega*sqrt(1-damping*damping), decay = exp(-damping*omega*time)
        func axis(_ from: CGFloat, _ to: CGFloat, _ speed: CGFloat) -> CGFloat {
            let x = Double(from-to), v = min(2400,max(-2400,Double(speed)))
            return to + CGFloat(decay*(x*cos(wd*time)+(v+damping*omega*x)/wd*sin(wd*time)))
        }
        return NSPoint(x:axis(start.x,target.x,velocity.x),y:axis(start.y,target.y,velocity.y))
    }

    private func spring(_ window: NSWindow, target: NSPoint, velocity: NSPoint, bounds: NSRect) {
        timer?.invalidate()
        let start = window.frame.origin
        guard Motion.enabled else { window.setFrameOrigin(target); return }
        let started = ProcessInfo.processInfo.systemUptime
        let fps = min(120,max(60,window.screen?.maximumFramesPerSecond ?? 60))
        let animation = Timer(timeInterval:1/Double(fps),repeats:true) { [weak self,weak window] tick in
            MainActor.assumeIsolated {
                guard let self,let window,window.isVisible else {tick.invalidate();return}
                let t = ProcessInfo.processInfo.systemUptime-started
                if t >= 0.48 {
                    window.setFrameOrigin(target);tick.invalidate();self.timer = nil
                } else {
                    let point = Self.position(start:start,target:target,velocity:velocity,time:t)
                    window.setFrameOrigin(Self.clamp(point,size:window.frame.size,in:bounds))
                }
            }
        }
        timer = animation
        RunLoop.main.add(animation,forMode:.common)
    }
}

final class BrowserTab {
    let id = UUID()
    // The tab may be displayed in another profile; its WebKit data and credentials
    // always belong to the profile where it was created.
    var ownerSpaceID: UUID?
    var fuseSearch = true
    var title = "New Tab"
    var siteName:String?
    var searchDraft = ""
    var pendingSearchInput: String?
    var showsSearchView = false
    var navigationInProgress = false
    var navigationTiming = BrowserNavigationTiming()
    var currentNavigation: WKNavigation?
    var lastMainFrameRequest: URLRequest?
    var lastMainFrameSourceURL: URL?
    var hasUnsavedEdits = false
    var lastPasswordProbeAt: TimeInterval = 0
    var passwordProbePending = false
    var captureMayBeActive = false
    var hasPictureInPicture = false
    var returningPictureInPicture = false
    var restoredScroll: NSPoint?
    var discardCheckInFlight = false
    var loadError: String?
    var recoveryOverlay: NSView?
    var isTerminal = false
    var isPinned = false
    var groupID: UUID?
    var pinnedInstanceClosed = false
    var suspendedURL: URL?
    var lastActiveAt = Date()
    var pinWidthFraction: CGFloat = 0.5
    var pinHeight: CGFloat = 72
    var savedSplit: SavedSplitRecord?
    var savedSplitTabIDs: [UUID] = []
    var isFloating = false
    var ide: LightweightIDE?
    var ideConstraints: [NSLayoutConstraint] = []
    var splitSurface: NSView? { ide?.view ?? (isTerminal ? nil : pageView) }
    var splitSurfaceConstraints: [NSLayoutConstraint] { ide != nil ? ideConstraints : pageConstraints }
    var canSplit: Bool {
        !isFloating && (ide != nil || (!isTerminal && pageView != nil &&
            (pageURL != nil || currentNavigation != nil || URL(string: searchDraft)?.host != nil)))
    }
    var terminalView: NativeTerminalPane?
    var webView: WKWebView?
    var engine = BrowserEngine.defaultEngine
    var chromiumView: WBChromiumView?
    var pageView: NSView? { (webView as NSView?) ?? chromiumView }
    var pageURL: URL? {
        if let url = webView?.url { return url }
        guard let address = chromiumView?.pageURL, !address.isEmpty else { return nil }
        return URL(string: address)
    }
    var progressObservation: NSKeyValueObservation?
    var pageConstraints: [NSLayoutConstraint] = []
    var terminalConstraints: [NSLayoutConstraint] = []
    var favicon: NSImage?
    var previewImage: NSImage?
    var previewCaptureInFlight = false
    var previewCapturedAt: TimeInterval = 0
    var previewGeneration = 0
    var faviconGeneration = 0
    var faviconTask: URLSessionDataTask?
    var prefersDarkGlass = true
}

struct SavedSplitRecord: Codable {
    struct Page: Codable {
        let title: String
        let url: String
        let owner: UUID
        var engine: BrowserEngine? = nil
    }
    let pages: [Page]
    let layout: String
    let fractions: [Double]
    var anchorIndex: Int? = nil
}

private struct PinnedTabRecord: Codable {
    let title: String
    let url: String
    let ownerSpaceID: UUID?
    let widthFraction: Double?
    let height: Double?
    let instanceClosed: Bool?
    var split: SavedSplitRecord? = nil
    var engine: BrowserEngine? = nil
}

private struct ClosedTabRecord {
    let title: String
    let address: String?
    let searchDraft: String
    let ownerSpaceID: UUID
    let displaySpaceID: UUID
    let wasPinned: Bool
    let wasTerminal: Bool
    let wasIDE: Bool
    let ideProject: URL?
    let pinWidthFraction: CGFloat
    let pinHeight: CGFloat
    var engine: BrowserEngine? = nil
}

private struct BrowserSessionRecord: Codable {
    struct Page: Codable {
        let title: String
        let url: String
        let ownerSpaceID: UUID
        let displaySpaceID: UUID
        let groupID: UUID?
        var engine: BrowserEngine? = nil
    }
    let pages: [Page]
}

private struct TabGroupRecord: Codable {
    let id: UUID
    let profileID: UUID
    var name: String
    var collapsed: Bool
    var automaticName:Bool? = nil
}

private enum SitePermission: String, CaseIterable {
    case camera, microphone, notifications, location, clipboard, downloads, popups
    var title: String { rawValue.capitalized }
    static func choice(_ kind: Self, host: String, profile: UUID) -> Int {
        UserDefaults.standard.integer(forKey: "webbyPermission.\(profile.uuidString).\(host.lowercased()).\(kind.rawValue)")
    }
    static func set(_ choice: Int, for kind: Self, host: String, profile: UUID) {
        UserDefaults.standard.set(choice, forKey: "webbyPermission.\(profile.uuidString).\(host.lowercased()).\(kind.rawValue)")
    }
}

@MainActor private final class TabGroupHeader: NSView, NSTextFieldDelegate {
    let groupID: UUID
    let nameField = NSTextField()
    let disclosure = NSButton()
    private let tint=CAGradientLayer()
    private let countLabel=NSTextField(labelWithString:"")
    var onRename: ((String) -> Void)?
    var onToggle: (() -> Void)?
    var onDrop: ((UUID) -> Void)?
    var onDelete: (() -> Void)?

    init(groupID: UUID) {
        self.groupID = groupID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds=true
        tint.cornerRadius=12;tint.opacity=0;layer?.addSublayer(tint)
        layer?.borderWidth = 0
        disclosure.isBordered = false
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.translatesAutoresizingMaskIntoConstraints = false
        nameField.isBordered = false
        nameField.drawsBackground = false
        nameField.font = WebbyTypography.font(ofSize: 12, weight: .semibold)
        nameField.delegate = self
        nameField.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font=WebbyTypography.font(ofSize:10,weight:.semibold)
        countLabel.textColor = .secondaryLabelColor;countLabel.alignment = .center
        countLabel.translatesAutoresizingMaskIntoConstraints=false
        nameField.lineBreakMode = .byTruncatingTail
        addSubview(disclosure);addSubview(nameField);addSubview(countLabel)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 24),
            nameField.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 4),
            nameField.trailingAnchor.constraint(equalTo: countLabel.leadingAnchor, constant: -5),
            countLabel.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-9),
            countLabel.centerYAnchor.constraint(equalTo:centerYAnchor),
            countLabel.widthAnchor.constraint(equalToConstant:24),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 36)
        ])
        registerForDraggedTypes([.string])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {super.layout();CATransaction.begin();CATransaction.setDisableActions(true);tint.frame=bounds;CATransaction.commit()}
    func configure(name: String, collapsed: Bool, count:Int, profile:PetGradientProfile) {
        if nameField.currentEditor()==nil {nameField.stringValue=name}
        countLabel.stringValue=String(count)
        BrowserTheme.apply(profile.gradients.ambient,to:tint,alpha:0.12)
        layer?.borderWidth=0
        toolTip="Command-click another tab to add it · Drag tabs here · Click the arrow to collapse"
        setAccessibilityLabel("\(name), \(count) tabs, \(collapsed ? "collapsed":"expanded")")
        if disclosure.title != (collapsed ? "▸":"▾") {Motion.change(disclosure,character:.tabs)}
        disclosure.title = collapsed ? "▸" : "▾"
    }
    func focusName() { window?.makeFirstResponder(nameField); nameField.currentEditor()?.selectAll(nil) }
    @objc private func toggle() { onToggle?() }
    private var committingName=false
    func controlTextDidEndEditing(_ obj: Notification) {if !committingName {onRename?(nameField.stringValue)}}
    func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector)->Bool {
        guard commandSelector==NSSelectorFromString("insertNewline:") || commandSelector==NSSelectorFromString("insertNewlineIgnoringFieldEditor:") else{return false}
        committingName=true
        nameField.stringValue=textView.string
        onRename?(textView.string)
        window?.makeFirstResponder(nil)
        committingName=false
        return true
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.string(forType: .string).flatMap(UUID.init(uuidString:)) == nil ? [] : .move
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let raw = sender.draggingPasteboard.string(forType: .string), let id = UUID(uuidString: raw) else { return false }
        onDrop?(id)
        return true
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let remove = menu.addItem(withTitle: "Delete Group", action: #selector(deleteGroup), keyEquivalent: "")
        remove.target = self
        return menu
    }
    @objc private func deleteGroup() { onDelete?() }
}

@MainActor private final class TabGroupContainer:NSView {
    let header:TabGroupHeader
    let members=NSStackView()
    let clip=NSView()
    let frost=WebbyGlassBackdrop()
    let horizontal:Bool
    private var extent:NSLayoutConstraint!
    private var contentExtent:NSLayoutConstraint!
    private var initialized=false
    private(set) var collapsed=false
    init(header:TabGroupHeader,horizontal:Bool=false) {
        self.header=header;self.horizontal=horizontal
        super.init(frame:.zero);translatesAutoresizingMaskIntoConstraints=false;wantsLayer=true
        layer?.cornerRadius=14;layer?.borderWidth=0.6;layer?.borderColor=NSColor.white.withAlphaComponent(0.13).cgColor
        frost.material = .sidebar;frost.blendingMode = .withinWindow;frost.state = .active
        frost.wantsLayer=true;frost.layer?.cornerRadius=14;frost.layer?.masksToBounds=true
        frost.translatesAutoresizingMaskIntoConstraints=false;addSubview(frost)
        clip.wantsLayer=true;clip.layer?.masksToBounds=true;clip.translatesAutoresizingMaskIntoConstraints=false
        members.orientation=horizontal ? .horizontal:.vertical;members.alignment=horizontal ? .centerY:.leading;members.spacing=0
        members.translatesAutoresizingMaskIntoConstraints=false
        addSubview(header);addSubview(clip);clip.addSubview(members)
        NSLayoutConstraint.activate([frost.leadingAnchor.constraint(equalTo:leadingAnchor),frost.trailingAnchor.constraint(equalTo:trailingAnchor),frost.topAnchor.constraint(equalTo:topAnchor),frost.bottomAnchor.constraint(equalTo:bottomAnchor)])
        if horizontal {
            extent=clip.widthAnchor.constraint(equalToConstant:0);contentExtent=members.widthAnchor.constraint(equalToConstant:0)
            NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant:39),header.leadingAnchor.constraint(equalTo:leadingAnchor,constant:4),header.widthAnchor.constraint(equalToConstant:140),header.centerYAnchor.constraint(equalTo:centerYAnchor),clip.leadingAnchor.constraint(equalTo:header.trailingAnchor),clip.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-4),clip.topAnchor.constraint(equalTo:topAnchor),clip.bottomAnchor.constraint(equalTo:bottomAnchor),members.leadingAnchor.constraint(equalTo:clip.leadingAnchor),members.topAnchor.constraint(equalTo:clip.topAnchor),members.heightAnchor.constraint(equalTo:clip.heightAnchor),extent,contentExtent])
        } else {
            extent=clip.heightAnchor.constraint(equalToConstant:0);contentExtent=members.heightAnchor.constraint(equalToConstant:0)
            NSLayoutConstraint.activate([header.leadingAnchor.constraint(equalTo:leadingAnchor,constant:4),header.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-4),header.topAnchor.constraint(equalTo:topAnchor,constant:3),clip.topAnchor.constraint(equalTo:header.bottomAnchor),clip.bottomAnchor.constraint(equalTo:bottomAnchor,constant:-5),clip.leadingAnchor.constraint(equalTo:leadingAnchor,constant:24),clip.trailingAnchor.constraint(equalTo:trailingAnchor,constant:-8),members.leadingAnchor.constraint(equalTo:clip.leadingAnchor),members.trailingAnchor.constraint(equalTo:clip.trailingAnchor),members.topAnchor.constraint(equalTo:clip.topAnchor),extent,contentExtent])
        }
        updateGlass(opacity:0,material:BrowserGlass.matchPageGlassSidebar ? .popover:.sidebar)
    }
    required init?(coder:NSCoder){fatalError()}
    func updateGlass(opacity:Double,material:NSVisualEffectView.Material) {
        frost.material=material;frost.alphaValue=opacity
        frost.appearance=BrowserGlass.matchPageGlassSidebar ? nil:NSAppearance(named:.darkAqua)
        let visibility=1-BrowserGlass.sidebarTransparency*0.86
        layer?.backgroundColor=NSColor.white.withAlphaComponent(0.04*visibility).cgColor
        layer?.borderColor=NSColor.white.withAlphaComponent(0.16*visibility).cgColor
    }
    func setMembers(_ rows:[TabRow],collapsed:Bool) {
        let full=CGFloat(rows.count)*(horizontal ? 210:39)
        let target:CGFloat=collapsed ? 0:full
        let visible=window?.occlusionState.contains(.visible)==true
        // First attachment has no meaningful presentation geometry. The parent
        // is still assembling/reordering the stack; never spring from that frame.
        let animate=initialized && self.collapsed != collapsed && Motion.enabled && visible
        let views:[NSView]=[self,header,clip,frost]
        let previous=views.map{($0,$0.layer?.presentation()?.bounds ?? $0.layer?.bounds ?? .zero,$0.layer?.presentation()?.position ?? $0.layer?.position ?? .zero)}
        for child in members.arrangedSubviews where !rows.contains(where:{$0 === child}) {members.removeArrangedSubview(child);child.removeFromSuperview()}
        for (i,row) in rows.enumerated() {
            if row.superview !== members {if let stack=row.superview as? NSStackView,stack.arrangedSubviews.contains(row) {stack.removeArrangedSubview(row)};row.removeFromSuperview();members.addArrangedSubview(row)}
            if members.arrangedSubviews.firstIndex(of:row) != i {members.removeArrangedSubview(row);members.insertArrangedSubview(row,at:min(i,members.arrangedSubviews.count))}
        }
        self.collapsed=collapsed
        contentExtent.constant=full;extent.constant=target
        if initialized {superview?.layoutSubtreeIfNeeded();layoutSubtreeIfNeeded()}
        if animate {
            for (view,bounds,position) in previous {
                guard let layer=view.layer else{continue}
                for (key,from,to) in [("bounds",NSValue(rect:bounds),NSValue(rect:layer.bounds)),("position",NSValue(point:position),NSValue(point:layer.position))] {
                    let spring=CASpringAnimation(keyPath:key);spring.fromValue=from;spring.toValue=to;spring.mass=1;spring.stiffness=420;spring.damping=34;spring.duration=min(0.42,spring.settlingDuration);layer.add(spring,forKey:"groupFold."+key)
                }
            }
        }
        if !initialized {Motion.reveal(self,character:.tabs)}
        initialized=true
    }
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
    private(set) var physicalModifiers:NSEvent.ModifierFlags=[]

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

    override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
    override func mouseDown(with event: NSEvent) {
        physicalModifiers=event.modifierFlags
        defer {physicalModifiers=[]}
        if event.modifierFlags.contains(.command),action == #selector(BrowserApp.selectTabAction(_:)) {
            NSApp.sendAction(action!,to:target,from:self)
            return
        }
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
                                                                       .font: WebbyTypography.font(ofSize: 12)])
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
    var onBeginResize: (() -> Void)?
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
        for row in rows {Motion.interact(row)}
        onBeginResize?()
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
    private var renderingEngine: BrowserEngine?
    func setRenderingEngine(_ engine: BrowserEngine?) {
        guard renderingEngine != engine else { return }
        renderingEngine = engine; needsDisplay = true
        setAccessibilityHelp(engine.map { "\($0.name) rendering engine" })
    }
    let tabID: UUID
    var pinWidthFraction: CGFloat = 0.5
    var pinHeight: CGFloat = 72
    var horizontal = false
    private let pageColorFill = CAShapeLayer()
    var pageColor: NSColor = .windowBackgroundColor
    let titleButton: TabActionButton
    private let selectButton: TabActionButton
    private let closeButton: TabActionButton
    private let iconContainer = NSView()
    private let siteIcon = NSImageView()
    private var splitIcons: [NSImageView] = []
    private var splitIconCount = 0
    private let pinIcon = NSImageView()
    private let fallbackIcon = GradientSymbolView(symbol: "globe", size: 14)
    private let closeIcon = GradientSymbolView(symbol: "xmark", size: 12)
    private var terminalIcon: TerminalTabIconView?
    private let selectionGradient = CAGradientLayer()
    private let groupRail=CAGradientLayer()
    private let loadingTrack = CAShapeLayer()
    private let loadingBeam = CAShapeLayer()
    private let loadingGradient = CAGradientLayer()
    private var loadingActive = false
    private var loadingFraction: CGFloat = 0
    private var hovered = false
    private var selected = false
    private var grouped=false
    private var tileMode = false
    private var rowHeight: NSLayoutConstraint!
    private var iconLeading: NSLayoutConstraint!
    private var iconCenterY: NSLayoutConstraint!
    private var titleCenterY: NSLayoutConstraint!
    private var titleTrailing:NSLayoutConstraint!
    private var closeCenterY: NSLayoutConstraint!
    private var closeTrailing: NSLayoutConstraint!
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
    private struct Presentation: Equatable {
        let title: String; let selected: Bool; let favicon: ObjectIdentifier?
        let split: [ObjectIdentifier?]; let terminal: Bool; let pinned: Bool; let tile: Bool; let horizontal: Bool
    }
    private var lastHorizontalTitle = ""
    private var lastHorizontalSelected: Bool?
    private var lastHorizontalPinned: Bool?
    private var lastHorizontalColor: NSColor?
    private var lastHorizontalChromeTint: NSColor?
    private var lastEdgeMatch = false
    private var lastPresentation: Presentation?
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
        layer?.addSublayer(groupRail);groupRail.opacity=0;groupRail.cornerRadius=1.5
        applyTheme(BrowserTheme.profile)
        rowHeight = heightAnchor.constraint(equalToConstant: 39)
        iconLeading = iconContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10)
        iconCenterX = iconContainer.centerXAnchor.constraint(equalTo: centerXAnchor)
        iconWidth = iconContainer.widthAnchor.constraint(equalToConstant: 18)
        iconHeight = iconContainer.heightAnchor.constraint(equalToConstant: 18)
        iconCenterY = iconContainer.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleCenterY = titleButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        titleTrailing=titleButton.trailingAnchor.constraint(equalTo:closeButton.leadingAnchor,constant:-13)
        closeCenterY = closeButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        closeTrailing = closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5)
        NSLayoutConstraint.activate([
            rowHeight,
            selectButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            selectButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            selectButton.topAnchor.constraint(equalTo: topAnchor),
            selectButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            iconLeading,
            iconCenterY,
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
            titleTrailing,
            titleCenterY,
            closeTrailing,
            closeCenterY,
            closeButton.widthAnchor.constraint(equalToConstant: 25),
            closeButton.heightAnchor.constraint(equalToConstant: 25),
            closeIcon.centerXAnchor.constraint(equalTo: closeButton.centerXAnchor),
            closeIcon.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            closeIcon.widthAnchor.constraint(equalToConstant: 15),
            closeIcon.heightAnchor.constraint(equalToConstant: 15)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setHorizontal(pinned: Bool, color: NSColor, chromeTint: NSColor? = nil) {
        guard !horizontal || lastHorizontalTitle != titleButton.title || lastHorizontalSelected != selected
            || lastHorizontalPinned != pinned || lastHorizontalColor != color || lastHorizontalChromeTint != chromeTint
            || lastEdgeMatch != BrowserGlass.matchWebsiteEdge else { return }
        lastHorizontalTitle = titleButton.title; lastHorizontalSelected = selected
        lastHorizontalPinned = pinned; lastHorizontalColor = color; lastHorizontalChromeTint = chromeTint
        lastEdgeMatch = BrowserGlass.matchWebsiteEdge
        horizontal = true
        pageColor = color
        setTileMode(pinned)
        rowHeight.isActive = true
        rowHeight.constant = 38
        // Center within the tab body, above its curved feet, with equal end padding.
        iconCenterY.constant = pinned ? 0 : 4
        titleCenterY.constant = pinned ? 0 : 4
        closeCenterY.constant = pinned ? 0 : 4
        closeTrailing.constant = -22
        titleTrailing.constant = -3
        if pinned { setTileIconSize(20) } else { iconLeading.constant = 26 }
        let rgb = color.usingColorSpace(.deviceRGB) ?? .black
        let light = rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722 > 0.55
        let edgeText: NSColor = light ? .black : .white
        let text = selected && !pinned ? edgeText : chromeTint ?? (BrowserGlass.matchWebsiteEdge ? edgeText : .white)
        titleButton.attributedTitle = NSAttributedString(string: titleButton.title, attributes: [.foregroundColor: text, .font: WebbyTypography.font(ofSize: 12, weight: selected ? .semibold : .regular)])
        needsDisplay = true;needsLayout=true;updateTabGlassMask()
    }

    fileprivate func horizontalTabPath()->CGPath {
        if tileMode {return CGPath(roundedRect:bounds.insetBy(dx:3,dy:4),cornerWidth:9,cornerHeight:9,transform:nil)}
        if !selected {return CGPath(roundedRect:bounds.insetBy(dx:9,dy:4),cornerWidth:8,cornerHeight:8,transform:nil)}
            let w = bounds.width, h = bounds.height
            let foot: CGFloat = 16, shoulder: CGFloat = 12
            let k: CGFloat = 0.55228475
            let path = CGMutablePath()
            path.move(to: .zero)
            path.addLine(to: NSPoint(x: w, y: 0))
            path.addCurve(to: NSPoint(x: w-foot, y: foot),
                       control1: NSPoint(x: w-foot*k, y: 0),
                       control2: NSPoint(x: w-foot, y: foot*(1-k)))
            path.addLine(to: NSPoint(x: w-foot, y: h-shoulder))
            path.addCurve(to: NSPoint(x: w-foot-shoulder, y: h),
                       control1: NSPoint(x: w-foot, y: h-shoulder+shoulder*k),
                       control2: NSPoint(x: w-foot-shoulder+shoulder*k, y: h))
            path.addLine(to: NSPoint(x: foot+shoulder, y: h))
            path.addCurve(to: NSPoint(x: foot, y: h-shoulder),
                       control1: NSPoint(x: foot+shoulder-shoulder*k, y: h),
                       control2: NSPoint(x: foot, y: h-shoulder+shoulder*k))
            path.addLine(to: NSPoint(x: foot, y: foot))
            path.addCurve(to: .zero,
                       control1: NSPoint(x: foot, y: foot*(1-k)),
                       control2: NSPoint(x: foot*k, y: 0))
            path.closeSubpath();return path
    }
    fileprivate func verticalGlassRect()->NSRect {
        let font=titleButton.font ?? WebbyTypography.font(ofSize:13)
        let textWidth=min(titleButton.bounds.width,ceil((titleButton.title as NSString).size(withAttributes:[.font:font]).width))
        let end=min(closeButton.frame.minX-2,max(iconContainer.frame.maxX+8,titleButton.frame.minX+textWidth+10))
        let height=max(0,min(bounds.height-8,max(30,ceil(font.ascender-font.descender)+10)))
        return NSRect(x:2,y:(bounds.height-height)/2,width:max(0,end-2),height:height)
    }
    fileprivate func updateTabGlassMask() {
        if horizontal {
            wantsLayer = true
            if pageColorFill.superlayer == nil { layer?.insertSublayer(pageColorFill, at: 0) }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            pageColorFill.frame = bounds
            pageColorFill.path = horizontalTabPath()
            pageColorFill.isHidden = !selected || tileMode || grouped
            CATransaction.commit()
            Motion.color(pageColorFill, key: "fillColor", to: pageColor.cgColor,
                         animate: !pageColorFill.isHidden && window?.occlusionState.contains(.visible) == true)
        }
        guard let frost=subviews.first(where:{$0 is WallpaperTabFrost}) else{return}
        CATransaction.begin();CATransaction.setDisableActions(true)
        if horizontal {
            let mask=(frost.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.frame=frost.bounds;mask.path=horizontalTabPath();mask.fillColor=NSColor.white.cgColor
            frost.layer?.cornerRadius=0;frost.layer?.mask=mask
        } else if tileMode {frost.layer?.mask=nil;frost.layer?.cornerRadius=10}
        else {
            let mask=(frost.layer?.mask as? CAShapeLayer) ?? CAShapeLayer()
            mask.frame=frost.bounds;mask.path=CGPath(roundedRect:verticalGlassRect(),cornerWidth:9,cornerHeight:9,transform:nil);mask.fillColor=NSColor.white.cgColor
            frost.layer?.cornerRadius=0;frost.layer?.mask=mask
        }
        CATransaction.commit()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        defer {
            if let engine = renderingEngine {
                let rect = horizontal ? bounds.insetBy(dx: 15, dy: 5) : (tileMode ? bounds.insetBy(dx: 8, dy: 5) : verticalGlassRect().insetBy(dx: 7, dy: 2))
                let line = NSRect(x: rect.minX, y: rect.minY, width: max(0, rect.width), height: selected ? 2.2 : 1.6)
                NSGradient(colors: engine.colors.map { $0.withAlphaComponent(selected ? 0.95 : 0.7) })?
                    .draw(in: NSBezierPath(roundedRect: line, xRadius: 1.1, yRadius: 1.1), angle: 0)
            }
        }
        if grouped && !tileMode {
            if selected || hovered {
                (selected ? NSColor.black.withAlphaComponent(0.23):NSColor.white.withAlphaComponent(0.07)).setFill()
                NSBezierPath(roundedRect:bounds.insetBy(dx:3,dy:3),xRadius:10,yRadius:10).fill()
            }
            return
        }
        guard horizontal else { return }
        if tileMode {
            let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 4), xRadius: 9, yRadius: 9)
            NSColor.white.withAlphaComponent(selected ? 0.16 : 0.07).setFill(); box.fill()
                        if let colors = profileRim.colors as? [CGColor], colors.count > 1 {
                let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 4), xRadius: 9, yRadius: 9)
                ring.append(NSBezierPath(roundedRect: bounds.insetBy(dx: selected ? 5 : 4, dy: selected ? 6 : 5), xRadius: 8, yRadius: 8))
                ring.windingRule = .evenOdd
                NSGraphicsContext.saveGraphicsState(); ring.addClip()
                NSGradient(colors: colors.compactMap { NSColor(cgColor: $0) })?.draw(in: bounds, angle: 25)
                NSGraphicsContext.restoreGraphicsState()
            }
        } else if selected && pageColorFill.superlayer == nil {
            if let context=NSGraphicsContext.current?.cgContext {
                context.saveGState();context.addPath(horizontalTabPath());context.setFillColor(pageColor.cgColor);context.fillPath();context.restoreGState()
            }
        } else if hovered && !selected {
            NSColor.white.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 9, dy: 4), xRadius: 8, yRadius: 8).fill()
        }
    }

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
        Motion.change(self,character:.tabs)
        tileMode = enabled
        iconLeading.isActive = !enabled
        iconCenterX.isActive = enabled
        iconWidth.constant = enabled ? 32 : splitIconWidth
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

    private var splitIconWidth: CGFloat {
        splitIconCount > 1 ? CGFloat(splitIconCount * 18 + (splitIconCount - 1) * 3) : 18
    }

    private func setSplitFavicons(_ favicons: [NSImage?]?) {
        splitIconCount = favicons?.count ?? 0
        while splitIcons.count < splitIconCount {
            let icon = NSImageView()
            icon.imageScaling = .scaleProportionallyDown
            iconContainer.addSubview(icon)
            splitIcons.append(icon)
        }
        for (index, icon) in splitIcons.enumerated() {
            icon.isHidden = index >= splitIconCount
            guard index < splitIconCount else { continue }
            icon.image = favicons?[index] ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")
            icon.contentTintColor = favicons?[index] == nil ? .secondaryLabelColor : nil
        }
        if !tileMode { iconWidth.constant = splitIconWidth }
        needsLayout = true
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
        if owner?.supportsPin(for: tabID) != false {
            let pin = menu.addItem(withTitle: pinned ? "Unpin Tab" : "Pin Tab",
                                  action: #selector(BrowserApp.togglePinTabAction(_:)), keyEquivalent: "")
            pin.target = owner
            pin.representedObject = tabID
        }
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
        owner?.appendGroupItem(for: tabID, to: menu)
        owner?.appendMoveItems(for: tabID, to: menu)
        let close = menu.addItem(withTitle: "Close Tab", action: #selector(BrowserApp.closeTabMenuAction(_:)), keyEquivalent: "")
        close.target = owner
        close.representedObject = tabID
        return menu
    }

    func setGroupAccent(_ profile:PetGradientProfile?) {
        if grouped != (profile != nil) {grouped=profile != nil;needsDisplay=true}
        guard let profile else{groupRail.opacity=0;return}
        wantsLayer=true
        if groupRail.superlayer==nil {layer?.addSublayer(groupRail)}
        groupRail.opacity=0
        BrowserTheme.apply(profile.gradients.ambient,to:groupRail)
        needsLayout=true
    }
    private func updateBackground() {
        updateTabGlassMask()
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.borderWidth = 0
        selectionGradient.opacity = 0
        profileRim.opacity = 0
        faviconRim.opacity = 0
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        if splitIconCount > 1 {
            let size: CGFloat = tileMode ? 14 : 18
            let columns = tileMode ? 2 : splitIconCount
            let gap: CGFloat = tileMode ? 2 : 3
            let rows = (splitIconCount + columns - 1) / columns
            let totalWidth = CGFloat(columns) * size + CGFloat(columns - 1) * gap
            let totalHeight = CGFloat(rows) * size + CGFloat(rows - 1) * gap
            for index in 0..<splitIconCount {
                let column = index % columns
                let row = index / columns
                splitIcons[index].frame = NSRect(
                    x: (iconContainer.bounds.width - totalWidth) / 2 + CGFloat(column) * (size + gap),
                    y: (iconContainer.bounds.height + totalHeight) / 2 - size - CGFloat(row) * (size + gap),
                    width: size, height: size)
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updateTabGlassMask()
        groupRail.frame=horizontal ? CGRect(x:12,y:2,width:max(0,bounds.width-24),height:2):CGRect(x:2,y:6,width:3,height:max(0,bounds.height-12))
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

    override func draggingExited(_ sender: NSDraggingInfo?) { Motion.change(self,character:.tabs);layer?.borderWidth = 0 }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        layer?.borderWidth = 0
        guard let string = sender.draggingPasteboard.string(forType: .string),
              let source = UUID(uuidString: string) else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        if let before=reorderEdge(at:point) {
            return owner?.reorderTab(sourceID:source,targetID:tabID,before:before) ?? false
        }
        // The body is exclusively a split target. Never turn a failed split
        // (for example a sleeping tab) into an unexpected reorder.
        return owner?.splitTabs(sourceID:source,targetID:tabID) ?? false
    }

    fileprivate func reorderEdge(at point:NSPoint)->Bool? {
        let length=horizontal ? bounds.width:bounds.height
        let position=horizontal ? point.x:point.y
        let edge=min(10,max(4,length*0.12))
        if position<edge {return horizontal}
        if position>length-edge {return !horizontal}
        return nil
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

    func update(title: String, selected: Bool, favicon: NSImage?, splitFavicons: [NSImage?]?,
                isTerminal: Bool, isPinned: Bool,
                loadingProgress: Double?) {
        setLoadingProgress(loadingProgress)
        let presentation = Presentation(title: title, selected: selected, favicon: favicon.map(ObjectIdentifier.init),
            split: (splitFavicons ?? []).map { $0.map(ObjectIdentifier.init) }, terminal: isTerminal,
            pinned: isPinned, tile: tileMode, horizontal: horizontal)
        guard lastPresentation != presentation else { return }
        let previous = lastPresentation
        if previous?.favicon != presentation.favicon || previous?.split != presentation.split {Motion.change(iconContainer,character:.tabs)}
        lastPresentation = presentation
        if titleButton.title != title { titleButton.title = title }
        if previous?.selected != selected { titleButton.font = WebbyTypography.font(ofSize: 13, weight: selected ? .semibold : .regular) }
        selectButton.toolTip = superview is PinnedTabGrid
            ? "\(title) • Drag the bottom or right edge to resize" : title
        if self.selected != selected {
            Motion.change(self,character:.tabs)
            self.selected = selected
            updateBackground()
        }
        setSplitFavicons(splitFavicons)
        siteIcon.image = favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: "Website")
        siteIcon.contentTintColor = favicon == nil && tileMode ? .secondaryLabelColor : nil
        siteIcon.isHidden = splitIconCount > 1 || isTerminal || (favicon == nil && !tileMode)
        fallbackIcon.isHidden = splitIconCount > 1 || isTerminal || favicon != nil || tileMode
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
        needsLayout=true
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

    override func mouseDown(with event: NSEvent) { }
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private final class SplitResizeDelegate: NSObject, NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { true }
}

private final class HomeSearchGroup: NSView {
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

private final class SplitLinkWebView: WKWebView {
    var onLinkDrop: ((URL, Int) -> Bool)?
    var canAddPane: (() -> Bool)?
    private var dropHighlight: CALayer?
    private func link(_ sender: NSDraggingInfo) -> URL? {
        let board = sender.draggingPasteboard
        let raw = board.string(forType: .URL) ?? board.string(forType: .string) ?? ""
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }
    private func zone(_ sender: NSDraggingInfo) -> Int {
        let point = convert(sender.draggingLocation, from: nil)
        let edge = min(64, min(bounds.width, bounds.height) * 0.18)
        if point.x < edge { return 1 }
        if point.x > bounds.width - edge { return 2 }
        if point.y < edge { return isFlipped ? 3 : 4 }
        if point.y > bounds.height - edge { return isFlipped ? 4 : 3 }
        return 0
    }
    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        link(sender) != nil && (zone(sender) == 0 || canAddPane?() == true)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard link(sender) != nil else { return super.draggingEntered(sender) }
        guard accepts(sender) else { return [] }
        showDrop(sender); return .copy
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard link(sender) != nil else { return super.draggingUpdated(sender) }
        guard accepts(sender) else { clearDrop(); return [] }
        showDrop(sender); return .copy
    }
    override func draggingExited(_ sender: NSDraggingInfo?) { clearDrop(); super.draggingExited(sender) }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if link(sender) != nil { return accepts(sender) }
        return super.prepareForDragOperation(sender)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        clearDrop()
        if let url = link(sender) { return accepts(sender) && onLinkDrop?(url, zone(sender)) == true }
        return super.performDragOperation(sender)
    }
    private func clearDrop() { dropHighlight?.removeFromSuperlayer(); dropHighlight = nil }
    private func showDrop(_ sender: NSDraggingInfo) {
        clearDrop(); wantsLayer = true
        let highlight = CALayer()
        var rect = bounds.insetBy(dx: 4, dy: 4)
        switch zone(sender) {
        case 1: rect.size.width *= 0.3
        case 2: rect.origin.x += rect.width * 0.7; rect.size.width *= 0.3
        case 3, 4:
            let atTop = zone(sender) == 3
            if atTop != isFlipped { rect.origin.y += rect.height * 0.7 }
            rect.size.height *= 0.3
        default: break
        }
        highlight.frame = rect
        highlight.cornerRadius = 12
        highlight.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        highlight.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
        highlight.borderWidth = 2
        layer?.addSublayer(highlight); dropHighlight = highlight
    }
}

private final class SidebarResizeHandle: NSView {
    var onResize: ((CGFloat, Bool) -> Void)?
    var onBegin: (() -> Void)?
    var onReset: (() -> Void)?
    private var startX: CGFloat?

    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onReset?(); return }
        startX = event.locationInWindow.x
        onBegin?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX else { return }
        onResize?(event.locationInWindow.x - startX, false)
    }

    override func mouseUp(with event: NSEvent) {
        guard let startX else { return }
        self.startX = nil
        onResize?(event.locationInWindow.x - startX, true)
    }
}

private final class WebsiteFrameShadow: NSView {
    static let radius: CGFloat = 10

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: Self.radius,
                                   cornerHeight: Self.radius, transform: nil)
        CATransaction.commit()
    }
}

/// Paints the exposed inset without covering glass or content inside the page.
private final class WebsiteFrameRim: NSView {
    private let inset: CGFloat

    init(inset: CGFloat) {
        self.inset = inset
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func makeBackingLayer() -> CALayer {
        let shape = CAShapeLayer()
        shape.fillRule = .evenOdd
        return shape
    }

    override func layout() {
        super.layout()
        let path = CGMutablePath()
        path.addRect(bounds)
        let pane = bounds.insetBy(dx: inset, dy: inset)
        if !pane.isEmpty {
            let radius = WebsiteFrameShadow.radius
            path.addRoundedRect(in: pane, cornerWidth: radius, cornerHeight: radius)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        (layer as? CAShapeLayer)?.path = path
        CATransaction.commit()
    }
}

@MainActor final class BrowserApp: NSObject, NSApplicationDelegate, NSWindowDelegate, NSSearchFieldDelegate, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, NSPopoverDelegate {
    private var engineSwitchPopover: NSPopover?
    private var passwordLookup: (UUID, String) -> [BrowserCredential] = { profile, host in
        BrowserPasswords.credentials(in: profile, host: host)
    }
    private var enginePasswordCheck: [String: Any] = [:]
    private var chromiumQuitPending = false
    private var window: NSWindow!
    private var content: NSView!
    private var sidebar: NSView!
    private var sidebarBackdrop: NSVisualEffectView!
    private var sidebarNewTab:GlassButton!
    private var sidebarNewTabLeading:NSLayoutConstraint!
    private var sidebarHeaderTop: NSLayoutConstraint!
    private var sidebarRevealTop: NSLayoutConstraint!
    private var sidebarTabsTop: NSLayoutConstraint!
    private var sidebarSeparator: NSBox!
    private var sidebarTabScroll: NSView!
    private var sidebarAddressHost: NSView!
    private var addressPageState: Bool?
    private var sidebarRevealToggle:GlassButton!
    private var horizontalScroll: NSScrollView!
    private var horizontalStack: NSStackView!
    private var horizontalProfile: NSButton!
    private var websiteEdgeBackdrop: NSView?
    private var sidebarEdgeBackdrop: NSView?
    private var horizontalSelection: UUID?
    private var horizontalRows: [UUID: TabRow] = [:]
    private var horizontalGroups: [UUID: TabGroupHeader] = [:]
    private var horizontalGroupContainers:[UUID:TabGroupContainer]=[:]
    private var horizontalWidths: [UUID: NSLayoutConstraint] = [:]
    private var pageAreaTop: NSLayoutConstraint!
    private var pageChromeColors: [UUID: NSColor] = [:]
    private var pageAddressColors: [UUID: NSColor] = [:]
    private var addressEdgeBackdrop: NSView?
    private static let sidebarWidthKey = "webbyVerticalSidebarWidth"
    private static let defaultSidebarWidth: CGFloat = 238
    private var preferredSidebarWidth: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: BrowserApp.sidebarWidthKey)
        return saved.isFinite && saved > 0 ? min(440, max(206, saved)) : BrowserApp.defaultSidebarWidth
    }()
    private var sidebarWidth: NSLayoutConstraint!
    private var sidebarInnerWidth: NSLayoutConstraint!
    private var sidebarResizeHandle: SidebarResizeHandle!
    private var sidebarDragWidth: CGFloat?
    private var chromeResizeTimer: Timer?
    private var windowStyle = BrowserWindowStyle()
    private var windowStyleEditor: BrowserWindowStyleEditor?
    private let windowPaint = CAGradientLayer()
    private var windowPaintView: NSView!
    private var websiteFrameShadow: WebsiteFrameShadow!
    private var websiteFrameRim: WebsiteFrameRim?
    private var pageFrameEdges: [NSLayoutConstraint] = []
    private static let websiteInset: CGFloat = 8
    private var pageFrameInset: CGFloat { BrowserWindowStyle.inset ? Self.websiteInset : 0 }
    private var mainArea: NSView!
    private var mainBackdrop: NSVisualEffectView!
    private var pageArea: NSView!
    private var toolbar: GlassPanel!
    private var toolbarLeading: NSLayoutConstraint!
    private var addressChromeConstraints: [NSLayoutConstraint] = []
    private var addressControls: NSStackView!
    private var addressDismiss: NSButton!
    private var horizontalTabsTrailing: NSLayoutConstraint!
    private var addressChromeReady = false
    private var addressLayoutKey = ""
    private var sidebarControlTop: NSLayoutConstraint!

    private var topAddressSurface: GlassAddressSurface!
    private var addressField: NSTextField!
    private var homeSearchField: NSTextField!
    private var loadErrorLabel: NSTextField!
    private var homeView: NSView!
    private var homeCenter: NSView!
    private var homeCenterTop: NSLayoutConstraint!
    private var homeCenterX: NSLayoutConstraint!
    private let homeSearchAlignmentGuide = CAShapeLayer()
    private var homeSearchDragMonitor: Any?
    private var widgetDragMonitor: Any?
    private var homeSearchDragOrigin: NSPoint?
    private var homeSearchDragTop: CGFloat = 10
    private var homeSearchDragX: CGFloat = 0
    private var homeSearchDragFromField = false
    private var homeSearchDragProfile: UUID?
    private var homeSearchIsDragging = false
    private var widgetCanvas: WidgetCanvas!
    private var asciiCanvas: ASCIIBackgroundCanvas!
    private var wallpaper: BrowserWallpaperView!
    private var wallpaperConstraints:[NSLayoutConstraint]=[]
    private var wallpaperChromeHost:NSView?
    private var wallpaperPaneBlur:WallpaperTabFrost?
    private var wallpaperWindowBackdrop:WallpaperTabFrost?
    private var wallpaperMotionState:String?
    private var terminalCommandOnOpen: [UUID: String] = [:]
    private var lastWidgetRefresh: [UUID: Date] = [:]
    private struct WidgetFeedState {
        let id: UUID
        let query: String
        let attempted: Date
        var task: Task<Void,Never>?
    }
    private var widgetFeedStates: [String:WidgetFeedState] = [:]
    private var widgetTimer: Timer?
    private var recentDownloadLines: [String] = []
    private var downloadsScanInFlight = false
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
    private var chromeDepartures:[NSView]=[]
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
    private var tabGroups: [TabGroupRecord] = []
    private var groupHeaders: [UUID: TabGroupHeader] = [:]
    private var groupContainers:[UUID:TabGroupContainer]=[:]
    private var sitePermissionWindow: NSWindow?
    private var permissionEditingHost: String?
    private var permissionEditingProfile: UUID?
    private var floatingWindows = [UUID: FloatingTabWindow]()
    private var ideProjectOpenToken = UUID()
    private var chatGPTDrafts:[UUID:(String,[ChatGPTWidgetImage])]=[:]
    private var miniTabs:[UUID:BrowserTab]=[:]
    private var miniSuggestions:[UUID:BrowserSuggestionPopup]=[:]
    private var miniPreviousApps:[UUID:NSRunningApplication]=[:]
    private var miniSettings:MiniWebbySettings?
    private var pendingMiniURLs:[URL]=[]
    private var floatingContentConstraints = [UUID: [NSLayoutConstraint]]()
    private var tabWidthConstraints = [UUID: NSLayoutConstraint]()
    private var splitView: NSSplitView?
    private var splitTabIDs: [UUID]?
    private var splitRepresentativeID: UUID? {
        guard let ids = splitTabIDs else { return nil }
        return ids.first(where: { tab(id: $0)?.savedSplit != nil }) ?? ids.first
    }
    private weak var pointerLockedWebView: WKWebView?
    private let splitResizeDelegate = SplitResizeDelegate()
    private var splitContentConstraints: [NSLayoutConstraint] = []
    private enum SplitLayout: String, CaseIterable {
        case columns, rows, largeLeft, largeTop, grid
        var title: String {
            switch self {
            case .columns: "Side by Side"
            case .rows: "Stacked"
            case .largeLeft: "Large Left, Stacked Right"
            case .largeTop: "Large Top, Side by Side Below"
            case .grid: "Grid"
            }
        }
    }
    private var splitLayout: SplitLayout = .columns
    private var faviconCache = [URL: NSImage]()
    private let persistentFavicons = BrowserFaviconStore()
    private var backButton: GlassButton!
    private var forwardButton: GlassButton!
    private var spaces: [BrowserSpace] = []
    private let spaceSaveQueue = DispatchQueue(label: "WebKitBrowser.SpaceSave", qos: .utility)
    private var pendingSpaceSave: DispatchWorkItem?
    private var importInProgress = false
    private var buildingFirstWindow=false
    private var defersTabRefresh=false
    private var activeSpaceIndex = 0
    private var fusedTabOrder: [UUID] = []
    private var fusedActiveTabID: UUID?
    private var recentlyClosedTabs: [ClosedTabRecord] = []
    private var previousTabID: UUID?
    private var restoringVideoInline = false
    private let pipWindowMotion = NativePiPWindowMotion()
    private var recentTabOrder: [UUID] = []
    private var tabShortcutMonitor: Any?
    private var switcherPanel: NSPanel?
    private var switcherIDs: [UUID] = []
    private var switcherIndex = 0
    private struct LayoutSnapshot {
        struct Entry {
            let id: UUID
            let pinned: Bool
            let width: CGFloat
            let height: CGFloat
            let group: UUID?
            let savedSplit: SavedSplitRecord?
            let savedIDs: [UUID]
        }
        let spaces: [(UUID, [Entry])]
        let groups: [TabGroupRecord]
        let order: [UUID]
        let split: [UUID]
        let layout: SplitLayout
        let fractions: [Double]
        let active: UUID?
    }
    private var layoutUndo: [LayoutSnapshot] = []
    private var layoutRedo: [LayoutSnapshot] = []
    private var bypassLayoutShortcut = false
    private var applyingLayout = false
    private var restoringPinnedSplit = false
    private var sessionSaveWork: DispatchWorkItem?
    private let sessionWriter = BrowserSnapshotWriter()
    private var tabOffloadTimer: Timer?
    private var memoryPressureSource: DispatchSourceMemoryPressure?
    private var lastDiscardPass = -Double.infinity
    private var renderedTabIDs: [UUID] = []
    private var renderedTabScope = ""
    private var tabSwitchTimes: [Double] = []
    private var tabScope: String { activeSpace.saved.id.uuidString + String(BrowserExperiment.cyclesNewTabProfiles) + BrowserTabPlacement.current.rawValue }
    private var appliedPageInjection = BrowserGlass.pageInjectionEnabled
    private var findBar: NSVisualEffectView?
    private var findField: NSSearchField?
    private var findStatus: NSTextField?
    private var swipeDistance: CGFloat = 0
    private var profileSwipeActive = false
    private let profileMotion = ProfileSwitchMotion()
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
    private var mainSidebarLeading:NSLayoutConstraint!
    private var mainFullLeading:NSLayoutConstraint!
    private var tabsRetreating=false
    private var tabsPeekVisible=false
    private var peekHorizontal=false
    private var tabsPeekToken=0
    private var hoverDwell:DispatchWorkItem?
    private var hoverTarget=""
    private var tabsRetreatTimer:Timer?
    private var horizontalHoverGlass:NSVisualEffectView?
    private var toolbarFromHover=false
    private var terminalMode = false
    private var terminalTransitionToken = 0
    private var toolbarVisible = false
    private var toolbarTransitionToken = 0
    private var toolbarHideTimer: Timer?
    private var eventMonitor: Any?
    private var controlMotionMonitor:Any?
    private var commandLinkIntent:(source:UUID,time:TimeInterval)?
    private weak var pressedMotionButton:NSButton?
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
    private struct HistoryRevision: Equatable { let space: ObjectIdentifier; let revision: Int }
    private let suggestionIndex=BrowserSuggestionIndex()
    private var suggestionTask:Task<Void,Never>?
    private var suggestionGeneration=0
    private var suggestionCompletedGeneration=0
    private var fuseRouteRevision:[HistoryRevision]=[]
    private var fuseRoutes:[String:UUID]=[:]
    private let suggestionSignposter=OSSignposter(subsystem:"local.webby.browser",category:"Interaction")
    private let typographyWindows=NSHashTable<NSWindow>.weakObjects()
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
        profileSwipeActive=false;swipeDistance=0
        let motionSurface = BrowserTabPlacement.current == .horizontal ? horizontalScroll : tabStack?.enclosingScrollView
        if let motionSurface {profileMotion.prepare(motionSurface)}
        releasePointerLock()
        dismissTabSwitcher()
        fuseMenuItem?.state = BrowserExperiment.cyclesNewTabProfiles ? .on : .off
        tabPreview.hide()
        linkPreview?.close()
        let enabled = BrowserExperiment.cyclesNewTabProfiles
        let selectedID = enabled ? activeSpace.activeTabID : fusedActiveTabID
        newTerminalButton.isHidden = !enabled
        toolbarLeading.constant = enabled ? 92 : 51
        updateSpaceLabel(animated: true)
        if enabled {
            for tab in spaces.flatMap(\.tabs) where tab.pageView == nil && !tab.isTerminal { tab.fuseSearch = true }
            fusedTabOrder = spaces.flatMap(\.tabs).map(\.id)
            fusedActiveTabID = nil
        } else {
            if let ids = splitTabIDs,
               Set(ids.compactMap { tab(id: $0).map { displaySpace(for: $0).saved.id } }).count > 1 { endSplit() }
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
                tab.webView?.evaluateJavaScript("window.__webbyChromeTone?.({enabled:false})",in:nil,in:BrowserChromeTone.world,completionHandler:nil)
                tab.pageView?.isHidden = true
                tab.terminalView?.isHidden = true
                tab.ide?.view.isHidden = true
            }
        }
        if let selectedID, let selected = tab(id: selectedID), !selected.isFloating { selectTab(selected) }
        else if let first = tabs.first(where: { !$0.isFloating }) { selectTab(first) }
        else { addTab(select: true) }
        refreshTabs()
        motionSurface?.superview?.layoutSubtreeIfNeeded()
        profileMotion.finish(direction:BrowserExperiment.cyclesNewTabProfiles ? 1 : -1)
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
        buildingFirstWindow=true
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let saved: [SavedBrowserSpace]
        do { saved = try BrowserSpaceStore.load() }
        catch {
            let alert = NSAlert()
            alert.messageText = "We couldn’t read your saved profiles"
            alert.informativeText = "Your existing profiles and sign-ins have been left in place. Webby won’t replace them with an empty setup.\n\n" + error.localizedDescription
            alert.addButton(withTitle: "Show Profile Folder"); alert.addButton(withTitle: "Quit")
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([BrowserSpaceStore.fileURL])
            }
            exit(1) // No browser services or session writers have started yet.
        }
        if saved.isEmpty {
            let personal = SavedBrowserSpace(id: UUID(), name: "Personal", chromeDirectory: nil,
                                             bookmarks: [], history: [])
            spaces = [BrowserSpace(personal)]
            try? BrowserSpaceStore.save([personal])
        } else { spaces = saved.map(BrowserSpace.init) }
        if let data = UserDefaults.standard.data(forKey: "webbyTabGroups"),
           let groups = try? JSONDecoder().decode([TabGroupRecord].self, from: data) {
            tabGroups = groups.filter { group in spaces.contains { $0.saved.id == group.profileID } }
        }
        activeSpaceIndex = min(max(0, UserDefaults.standard.integer(forKey: "browserActiveSpace")), spaces.count - 1)
        BrowserTheme.activate(activeSpace.saved.id)
        loadRules() // Async lookup starts with launch, not after the first navigation.
        installMenus()
        makeWindow()
        downloads = BrowserDownloads()
        makeSidebar()
        makeMainArea()
        makeHome()
        updateWidgetActivity()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged),
                                               name: .browserThemeChanged, object: nil)
        NotificationCenter.default.addObserver(self,selector:#selector(geistChanged),name:Notification.Name("WebbyGeistChanged"),object:nil)
        NotificationCenter.default.addObserver(self, selector: #selector(glassChanged),
                                               name: .browserGlassChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(searchEngineChanged),
                                               name: .browserSearchEngineChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(addressPlacementChanged), name: Notification.Name("WebbyAddressPlacementChanged"), object: nil)
        defersTabRefresh=true
        addTab(select: true)
        activeSpace.activeTabID = activeTabID
        _ = restorePinnedTabs()
        do {
            let originalIndex = activeSpaceIndex
            for index in spaces.indices where index != originalIndex && spaces[index].tabs.isEmpty {
                activeSpaceIndex = index
                _ = restorePinnedTabs()
            }
            activeSpaceIndex = originalIndex
            updateSpaceLabel()
        }
        restoreSessionTabs()
        // Each profile starts on home; restored pages and pins stay available, asleep.
        for space in spaces where space.activeTabID == nil {
            let home = BrowserTab()
            home.ownerSpaceID = space.saved.id
            space.tabs.append(home)
            space.activeTabID = home.id
            if BrowserExperiment.cyclesNewTabProfiles { fusedTabOrder.append(home.id) }
        }
        defersTabRefresh=false
        refreshTabs()
        tabOffloadTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.offloadIdleTabs() }
        }
        tabOffloadTimer?.tolerance = 10
        memoryPressureSource = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        memoryPressureSource?.setEventHandler { [weak self] in self?.offloadIdleTabs(memoryPressure: true) }
        memoryPressureSource?.resume()
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.sizeWidgetCanvas() }
        // Yield a real first frame with working input before secondary services start.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) { [weak self] in self?.startSecondaryServices() }
        for url in pendingMiniURLs {openExternalLink(url)};pendingMiniURLs=[]
        pipWindowMotion.setActive(false)
        hideTrafficLights()
        themeChanged()
        buildingFirstWindow=false
        WebbyIcon.finishStartup()
        windowShownAt = ProcessInfo.processInfo.systemUptime
        app.activate(ignoringOtherApps: true)
        NotificationCenter.default.addObserver(self,selector:#selector(linkGlancesChanged),name:NSNotification.Name("WebbyLinkGlancesChanged"),object:nil)
        installChromeMonitor()
        if saved.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showChromeImport()
            }
        }
    }

    private func startSecondaryServices() {
        let mini=MiniWebbySettings()
        mini.open={ [weak self] in self?.openMiniWebby() }
        mini.toggle={ [weak self] in self?.toggleMiniWebby() }
        mini.restore={ [weak self] entry in
            guard let self,self.spaces.contains(where:{$0.saved.id==entry.profile}),let url=URL(string:entry.url) else{return}
            self.openMiniWebby(url:url,profile:entry.profile)
        }
        miniSettings=mini;mini.start()
        menuBar = BrowserMenuBar(showBrowser: { [weak self] in self?.showBrowserWindow() },
                                 addWidget: { [weak self] in self?.showAddWidget() },
                                 resetWidgets: { [weak self] in self?.widgetCanvas?.resetPositions(); self?.asciiCanvas?.resetPositions() },
                                 currentSpaceName: { [weak self] in self?.activeSpace.saved.name ?? "Profile" },
                                 currentSpaceID: { [weak self] in self?.activeSpace.saved.id ?? UUID() },
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
                                     return service == .calendar ? CalendarSubscription.isConfigured(profile: self.activeSpace.saved.id)
                                         : GoogleWorkspace.shared.isConnected(service, profile: self.activeSpace.saved.id)
                                 }, asciiCanvas: { [weak self] in self?.asciiCanvas }, openWallpaper: { [weak self] in self?.wallpaper?.openSettings() },
                                 editWindowAppearance: { [weak self] in self?.editWindowAppearance() },
                                 miniMenu: { [weak self] in self?.miniSettings?.menu() ?? NSMenu(title:"Mini Webby") })
        DispatchQueue.main.asyncAfter(deadline:.now()+0.2) {DesktopWidgetBridge.syncIfEnabled()}
    }

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1160, height: 770),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
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
        let paint = NSView()
        paint.wantsLayer = true
        paint.layer = windowPaint
        paint.translatesAutoresizingMaskIntoConstraints = false
        paint.isHidden = true
        content.addSubview(paint)
        NSLayoutConstraint.activate([
            paint.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            paint.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paint.topAnchor.constraint(equalTo: content.topAnchor),
            paint.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        windowPaintView = paint
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
        guard notification.object as? NSWindow === window else{return}
        updateSidebarWidth()
        sizeWidgetCanvas()
        if homeView?.isHidden == false { restoreHomeSearchPosition() }
        scheduleChromeResizeUpdate()
    }

    // Window and divider drags can deliver dozens of events per second. The
    // viewport follows constraints immediately; DOM color probes wait for rest.
    private func scheduleChromeResizeUpdate() {
        if let chromeResizeTimer {
            chromeResizeTimer.fireDate = Date().addingTimeInterval(0.14)
            return
        }
        chromeResizeTimer = Timer.scheduledTimer(withTimeInterval: 0.14, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.chromeResizeTimer = nil
                if let view = self.activeWebView { self.updateGlassTone(for: view) }
            }
        }
    }

    private func sizeWidgetCanvas() {
        widgetCanvas?.enclosingScrollView?.needsLayout = true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if chromiumQuitPending {
            guard !WBChromiumHasBrowsers() else { return .terminateCancel }
            WBChromiumShutdown()
            return .terminateNow
        }
        if spaces.flatMap(\.tabs).contains(where: { $0.ide?.mayClose() == false }) { return .terminateCancel }
        if downloads?.hasActiveDownloads == true {
            let alert = NSAlert()
            alert.messageText = "Downloads are still running"
            alert.informativeText = "Quitting stops these downloads. Let’s finish them first, or quit now."
            alert.addButton(withTitle: "Keep Downloading")
            alert.addButton(withTitle: "Quit Anyway")
            if alert.runModal() != .alertSecondButtonReturn { return .terminateCancel }
        }
        guard WBChromiumHasBrowsers() else { WBChromiumShutdown(); return .terminateNow }
        chromiumQuitPending = true
        saveSessionTabs(wait: true)
        // Quit can arrive from inside CefDoMessageLoopWork. AppKit's
        // terminateLater wait would trap that pump on its own call stack.
        // Cancel this attempt, unwind the event, then close and quit afresh.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for tab in self.spaces.flatMap(\.tabs) { tab.chromiumView?.closePage() }
            self.finishChromiumQuit()
        }
        return .terminateCancel
    }

    private func finishChromiumQuit() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if WBChromiumHasBrowsers() { self.finishChromiumQuit() }
            else { WBChromiumShutdown(); NSApp.terminate(nil) }
        }
    }
    func applicationWillTerminate(_ notification: Notification) {
        if BrowserEngineChecks.active {
            print("PASS: actual menu quit from a Chromium callback, asynchronous close, and application termination")
            fflush(stdout)
            return
        }
        WebbyIcon.stop()
        hoverDwell?.cancel();tabsRetreatTimer?.invalidate();toolbarHideTimer?.invalidate();discardLinkPreview()
        DesktopWidgetBridge.syncIfEnabled()
        CodeWorkbenchRuntime.shared.stop()
        miniSettings?.hotKey.stop()
        for id in Array(miniTabs.keys) {closeMiniWebby(id,restoreFocus:false)}
        sessionSaveWork?.cancel()
        tabOffloadTimer?.invalidate()
        memoryPressureSource?.cancel()
        for state in widgetFeedStates.values {state.task?.cancel()}
        saveSessionTabs(wait: true)
        NotificationCenter.default.removeObserver(self, name: .browserThemeChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .browserGlassChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .browserSearchEngineChanged, object: nil)
        closeSuggestions()
        tabPreview.hide()
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let controlMotionMonitor {NSEvent.removeMonitor(controlMotionMonitor)}
        if let tabShortcutMonitor { NSEvent.removeMonitor(tabShortcutMonitor) }
        switcherPanel?.close()
        if let homeSearchDragMonitor { NSEvent.removeMonitor(homeSearchDragMonitor) }
        if let widgetDragMonitor { NSEvent.removeMonitor(widgetDragMonitor) }
        for space in spaces { for tab in space.tabs { tab.terminalView?.stop(); tab.ide?.shutdown() } }
        pendingSpaceSave?.cancel()
        let snapshot = spaces.map(\.saved)
        spaceSaveQueue.sync { try? BrowserSpaceStore.save(snapshot) }
        for tab in spaces.flatMap(\.tabs) { tab.chromiumView?.closePage() }
    }

    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {
        if !flag,window != nil {showBrowserWindow()}
        return true
    }

    private func showBrowserWindow() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        hideTrafficLights()
    }

    @objc private func themeChanged() {
        reloadWindowStyle()
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
        asciiCanvas?.applyTheme(profile)
        for (id, row) in tabRows {
            let ownerID = tab(id: id).map { ownerSpace(for: $0).saved.id }
            let rowProfile = ownerID.map { BrowserTheme.profile(for: $0) } ?? profile
            row.applyTheme(rowProfile)
            row.themeSpaceID = ownerID
        }
        for (id, row) in horizontalRows {
            let ownerID = tab(id: id).map { ownerSpace(for: $0).saved.id }
            row.applyTheme(ownerID.map { BrowserTheme.profile(for: $0) } ?? profile)
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
        configureHorizontalTabs()
        showCurrentIndicator()
    }

    @objc private func geistChanged(){
        for host in NSApp.windows {if let root=host.contentView {WebbyTypography.apply(to:root)}}
        var configured=Set<ObjectIdentifier>()
        for tab in spaces.flatMap(\.tabs)+Array(miniTabs.values) {
            guard let view=tab.webView else{continue}
            let controller=view.configuration.userContentController
            if configured.insert(ObjectIdentifier(controller)).inserted {GlassPageInjector.installGeist(into:controller,replace:true)}
            GlassPageInjector.applyGeist(to:view)
        }
    }

    @objc private func glassChanged() {
        defer {applyWallpaperPresentation(); refreshHorizontalTabs(); updateWebsiteEdgeBackdrop(); if let view=activeWebView {updateGlassTone(for:view)}}
        mainBackdrop.alphaValue = 1 - BrowserGlass.backgroundTransparency
        sidebarBackdrop.material = BrowserGlass.matchPageGlassSidebar ? .popover : .sidebar
        sidebarBackdrop.appearance = BrowserGlass.matchPageGlassSidebar
            ? mainArea.appearance : NSAppearance(named: .darkAqua)
        sidebarBackdrop.alphaValue = BrowserGlass.matchPageGlassSidebar ? 1
            : 1 - BrowserGlass.sidebarTransparency * 0.86
        toolbar.applyGlassTransparency()
        topAddressSurface.applyGlassTransparency()
        homeSearchSurface.applyGlassTransparency()
        if appliedPageInjection != BrowserGlass.pageInjectionEnabled {
            appliedPageInjection = BrowserGlass.pageInjectionEnabled
            let splitIDs = splitTabIDs
            if splitIDs != nil { endSplit() }
            for tab in spaces.flatMap(\.tabs) where tab.webView != nil && !tab.isFloating {
                guard let url = tab.pageURL else { continue }
                let selected = tab.id == activeTabID
                tab.suspendedURL = url
                releaseWebView(for: tab)
                resumeTab(tab, show: selected)
            }
            if let splitIDs, splitIDs.allSatisfy({ tab(id: $0)?.splitSurface != nil }) { renderSplit(splitIDs) }
        }
    }

    @objc private func searchEngineChanged() {
        showCurrentIndicator()
        addressField.placeholderString = "Search \(BrowserSearchEngine.selected(for: activeSpace.saved.id).name) or enter a URL"
    }

    private func makeSidebar() {
        sidebar = NSView()
        sidebar.wantsLayer = true
        sidebar.layer?.masksToBounds = true
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(sidebar)
        sidebarWidth = sidebar.widthAnchor.constraint(equalToConstant: resolvedSidebarWidth(preferredSidebarWidth))
        NSLayoutConstraint.activate([
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor), sidebarWidth
        ])

        sidebarBackdrop = WebbyGlassBackdrop()
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
        sidebarAddressHost = sidebarInner
        sidebarInner.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(sidebarInner)
        sidebarInnerWidth = sidebarInner.widthAnchor.constraint(equalToConstant: sidebarWidth.constant)
        NSLayoutConstraint.activate([
            sidebarInner.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            sidebarInner.topAnchor.constraint(equalTo: sidebar.topAnchor),
            sidebarInner.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            sidebarInnerWidth
        ])

        let newTab = GlassButton(symbol: "plus", label: "New Tab", target: self, action: #selector(newTabAction))
        newTab.translatesAutoresizingMaskIntoConstraints = false
        sidebarNewTab=newTab
        sidebarNewTabLeading=newTab.leadingAnchor.constraint(equalTo:sidebarInner.leadingAnchor,constant:14)
        sidebarRevealToggle=GlassButton(symbol:"sidebar.left",label:"Keep Tabs Open",target:self,action:#selector(toggleSidebar))
        sidebarRevealToggle.translatesAutoresizingMaskIntoConstraints=false;sidebarRevealToggle.isHidden=true
        sidebarInner.addSubview(sidebarRevealToggle)
        sidebarRevealTop = sidebarRevealToggle.topAnchor.constraint(equalTo:sidebarInner.topAnchor,constant:16)
        NSLayoutConstraint.activate([sidebarRevealToggle.leadingAnchor.constraint(equalTo:sidebarInner.leadingAnchor,constant:10),sidebarRevealTop,sidebarRevealToggle.widthAnchor.constraint(equalToConstant:34),sidebarRevealToggle.heightAnchor.constraint(equalToConstant:34)])
        spaceLabel = FusedProfileLabel(frame: .zero)
        spaceLabel.showProfile(activeSpace.saved.name, animated: false)
        spaceLabel.translatesAutoresizingMaskIntoConstraints = false
        spaceLabel.toolTip = "Click to choose a profile, or swipe left or right with two fingers"
        spaceLabel.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(showSpaceMenu(_:))))
        let downloadButton = downloads.button
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSBox()
        sidebarSeparator = separator
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
        pinGrid.onBeginResize = { [weak self] in self?.rememberLayout() }
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
        let createGroupGesture = NSClickGestureRecognizer(target: self, action: #selector(tabSettingsFromEmptySpace(_:)))
        createGroupGesture.numberOfClicksRequired = 2
        createGroupGesture.delaysPrimaryMouseButtonEvents = false
        tabSpacer.addGestureRecognizer(createGroupGesture)
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
        sidebarTabScroll = scroll
        sidebarHeaderTop = newTab.topAnchor.constraint(equalTo:sidebarInner.topAnchor,constant:16)
        sidebarTabsTop = scroll.topAnchor.constraint(equalTo:newTab.bottomAnchor,constant:26)
        NSLayoutConstraint.activate([
            sidebarNewTabLeading,
            sidebarHeaderTop,
            newTab.widthAnchor.constraint(equalToConstant: 34), newTab.heightAnchor.constraint(equalToConstant: 34),
            spaceLabel.leadingAnchor.constraint(equalTo: newTab.trailingAnchor, constant: 4),
            spaceLabel.trailingAnchor.constraint(equalTo: downloadButton.leadingAnchor, constant: -4),
            spaceLabel.centerYAnchor.constraint(equalTo: newTab.centerYAnchor),
            downloadButton.trailingAnchor.constraint(equalTo: sidebarInner.trailingAnchor, constant: -14),
            downloadButton.centerYAnchor.constraint(equalTo: newTab.centerYAnchor),
            downloadButton.widthAnchor.constraint(equalToConstant: 34),
            downloadButton.heightAnchor.constraint(equalToConstant: 34),
            separator.leadingAnchor.constraint(equalTo: sidebarInner.leadingAnchor, constant: 12),
            separator.trailingAnchor.constraint(equalTo: sidebarInner.trailingAnchor, constant: -12),
            separator.topAnchor.constraint(equalTo: newTab.bottomAnchor, constant: 13),
            scroll.leadingAnchor.constraint(equalTo: sidebarInner.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: sidebarInner.trailingAnchor, constant: -8),
            sidebarTabsTop,
            scroll.bottomAnchor.constraint(equalTo: sidebarInner.bottomAnchor, constant: -10),
            tabStack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            tabStack.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
            pinGrid.widthAnchor.constraint(equalTo: tabStack.widthAnchor),
            pinGridHeight,
            tabSpacer.widthAnchor.constraint(equalTo: tabStack.widthAnchor),
            tabSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0)
        ])
        let handle = SidebarResizeHandle()
        handle.translatesAutoresizingMaskIntoConstraints = false
        handle.toolTip = "Drag to resize the sidebar. Double-click to reset."
        handle.isHidden = true
        handle.onBegin = { [weak self] in
            guard let self else { return }
            self.sidebarDragWidth = self.sidebarWidth.constant
            self.wallpaper?.isResizing = true
        }
        handle.onResize = { [weak self] offset, finished in
            guard let self, let initial = self.sidebarDragWidth else { return }
            self.resizeSidebar(to: initial + offset, finished: finished)
        }
        handle.onReset = { [weak self] in self?.resizeSidebar(to: Self.defaultSidebarWidth, finished: true) }
        sidebar.addSubview(handle)
        sidebarResizeHandle = handle
        NSLayoutConstraint.activate([
            handle.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            handle.topAnchor.constraint(equalTo: sidebar.topAnchor),
            handle.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor),
            handle.widthAnchor.constraint(equalToConstant: 7)
        ])
        applyTabPlacement()
        sidebarVisible = !UserDefaults.standard.bool(forKey: "sidebarHidden")
        if !sidebarVisible { sidebarWidth.constant = 0; sidebar.isHidden = true }
    }

    private func resolvedSidebarWidth(_ requested: CGFloat) -> CGFloat {
        // Leave room for address controls and split panes in a narrow window.
        let limit = max(206, min(440, (content?.bounds.width ?? 750) - 430))
        return min(limit, max(206, requested.rounded()))
    }

    private func updateSidebarWidth() {
        guard let sidebarWidth, let sidebarInnerWidth else { return }
        let width = resolvedSidebarWidth(preferredSidebarWidth)
        if sidebarInnerWidth.constant != width { sidebarInnerWidth.constant = width }
        if sidebarWidth.constant > 0 && sidebarWidth.constant != width { sidebarWidth.constant = width }
    }

    private func resizeSidebar(to requested: CGFloat, finished: Bool) {
        preferredSidebarWidth = resolvedSidebarWidth(requested)
        updateSidebarWidth()
        if !finished { return }
        sidebarDragWidth = nil
        wallpaper?.isResizing = false
        UserDefaults.standard.set(Double(preferredSidebarWidth), forKey: Self.sidebarWidthKey)
        content.layoutSubtreeIfNeeded()
        if homeView?.isHidden == false { restoreHomeSearchPosition() }
        scheduleChromeResizeUpdate()
    }

    private func applyTabPlacement() {
        chromeDepartures.forEach{$0.removeFromSuperview()};chromeDepartures=[]
        let searchGeometry=Motion.capture([homeCenter,sidebarToggleButton,newTerminalButton,chromeToggle].compactMap{$0},in:content)
        let widgetGeometry=widgetCanvas?.captureViewportLayout(in:content) ?? .empty
        configureHorizontalTabs()
        guard tabStack != nil, tabSpacer != nil else { return }
        tabStack.removeArrangedSubview(tabSpacer)
        tabSpacer.removeFromSuperview()
        let index = BrowserTabPlacement.current == .bottom ? min(1, tabStack.arrangedSubviews.count)
            : tabStack.arrangedSubviews.count
        tabStack.insertArrangedSubview(tabSpacer, at: index)
        refreshTabs()
        if mainArea != nil {
            content.layoutSubtreeIfNeeded()
            widgetCanvas?.settleViewportLayout(widgetGeometry,in:content)
            Motion.settle(searchGeometry,views:[homeCenter,sidebarToggleButton,newTerminalButton,chromeToggle].compactMap{$0},in:content,character:.widget)
        }
    }

    private func makeMainArea() {
        mainArea = NSView()
        mainArea.appearance = NSAppearance(named: .darkAqua)
        mainArea.wantsLayer = true
        mainArea.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(mainArea)
        mainSidebarLeading=mainArea.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor)
        mainFullLeading=mainArea.leadingAnchor.constraint(equalTo:content.leadingAnchor)
        NSLayoutConstraint.activate([
            mainSidebarLeading,
            mainArea.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            mainArea.topAnchor.constraint(equalTo: content.topAnchor),
            mainArea.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        // Only the backdrop fades. Child pages, fields, and buttons retain full opacity.
        mainBackdrop = WebbyGlassBackdrop()
        mainBackdrop.material = .popover
        mainBackdrop.blendingMode = .behindWindow
        mainBackdrop.state = .active
        mainBackdrop.alphaValue = 1 - BrowserGlass.backgroundTransparency
        mainBackdrop.translatesAutoresizingMaskIntoConstraints = false
        mainArea.addSubview(mainBackdrop)
        NSLayoutConstraint.activate([
            mainBackdrop.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor),
            mainBackdrop.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor),
            mainBackdrop.topAnchor.constraint(equalTo: mainArea.topAnchor),
            mainBackdrop.bottomAnchor.constraint(equalTo: mainArea.bottomAnchor)
        ])
        pageArea = NSView()
        pageArea.wantsLayer = true
        pageArea.layer?.backgroundColor = NSColor.clear.cgColor
        pageArea.translatesAutoresizingMaskIntoConstraints = false
        mainArea.addSubview(pageArea)
        pageAreaTop = pageArea.topAnchor.constraint(equalTo: mainArea.topAnchor)
        pageFrameEdges = [
            pageArea.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor),
            pageArea.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor),
            pageArea.bottomAnchor.constraint(equalTo: mainArea.bottomAnchor)
        ]
        NSLayoutConstraint.activate(pageFrameEdges + [pageAreaTop])

        let shadow = WebsiteFrameShadow()
        shadow.wantsLayer = true
        shadow.layer?.cornerRadius = WebsiteFrameShadow.radius
        shadow.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.06).cgColor
        shadow.layer?.shadowColor = NSColor.black.cgColor
        shadow.layer?.shadowOpacity = 0.28
        shadow.layer?.shadowRadius = 5
        shadow.layer?.shadowOffset = CGSize(width: 0, height: -1)
        shadow.translatesAutoresizingMaskIntoConstraints = false
        mainArea.addSubview(shadow, positioned: .below, relativeTo: pageArea)
        NSLayoutConstraint.activate([
            shadow.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            shadow.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            shadow.topAnchor.constraint(equalTo: pageArea.topAnchor),
            shadow.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor)
        ])
        websiteFrameShadow = shadow
        reloadWindowStyle()

        buildHorizontalTabs()

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
        addressField.placeholderString = "Search or enter a URL"
        addressField.target = self
        addressField.action = #selector(openAddress)
        let addressSurface = GlassAddressSurface(field: addressField)
        topAddressSurface = addressSurface
        configureSuggestions(for: addressSurface)
        addressSurface.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let controls = NSStackView(views: [back, forward, reload, addressSurface, dismiss])
        addressControls = controls; addressDismiss = dismiss
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false
        toolbar = GlassPanel(radius: 14)
        toolbar.useBareAddressChrome(surface: addressSurface)
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
        sidebarControlTop = sidebarToggleButton.topAnchor.constraint(equalTo: mainArea.topAnchor, constant: 16)
        sidebarToggleLeading = sidebarToggleButton.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor, constant: 10)
        sidebarToggleTerminalTrailing = sidebarToggleButton.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor, constant: -55)
        terminalButtonLeading = newTerminalButton.leadingAnchor.constraint(equalTo: sidebarToggleButton.trailingAnchor, constant: 7)
        terminalButtonTrailing = newTerminalButton.trailingAnchor.constraint(equalTo: sidebarToggleButton.leadingAnchor, constant: -7)
        NSLayoutConstraint.activate([
            sidebarToggleLeading,
            sidebarControlTop,
            sidebarToggleButton.widthAnchor.constraint(equalToConstant: 34),
            sidebarToggleButton.heightAnchor.constraint(equalToConstant: 34),
            terminalButtonLeading,
            newTerminalButton.centerYAnchor.constraint(equalTo: sidebarToggleButton.centerYAnchor),
            newTerminalButton.widthAnchor.constraint(equalToConstant: 34),
            newTerminalButton.heightAnchor.constraint(equalToConstant: 34),
            chromeToggle.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor, constant: -10),
            chromeToggle.centerYAnchor.constraint(equalTo: sidebarToggleButton.centerYAnchor),
            chromeToggle.widthAnchor.constraint(equalToConstant: 34),
            chromeToggle.heightAnchor.constraint(equalToConstant: 34),
            controls.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 10),
            controls.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -10),
            controls.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            back.widthAnchor.constraint(equalToConstant: 34), back.heightAnchor.constraint(equalToConstant: 34),
            forward.widthAnchor.constraint(equalToConstant: 34), forward.heightAnchor.constraint(equalToConstant: 34),
            reload.widthAnchor.constraint(equalToConstant: 34), reload.heightAnchor.constraint(equalToConstant: 34),
            dismiss.widthAnchor.constraint(equalToConstant: 34), dismiss.heightAnchor.constraint(equalToConstant: 34),
            addressSurface.heightAnchor.constraint(equalToConstant: 34),
            addressSurface.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        addressChromeReady = true
        applyAddressChrome()
    }

    @objc private func cycleWallpaperPair() {
        guard NSApp.currentEvent?.isARepeat != true else{return}
        wallpaper?.cycleWallpaperSet()
    }
    @objc private func openWallpaperSettings() { wallpaper?.openSettings() }

    @objc private func editWindowAppearance() {
        let editor = windowStyleEditor ?? BrowserWindowStyleEditor()
        windowStyleEditor = editor
        editor.onApply = { [weak self] in
            guard let self else { return }
            self.reloadWindowStyle()
            self.applyAddressChrome()
            self.applyWallpaperPresentation()
            self.refreshHorizontalTabs()
            self.content.layoutSubtreeIfNeeded()
            self.restoreHomeSearchPosition()
        }
        editor.open(profile: activeSpace.saved.id, name: activeSpace.saved.name)
    }

    private func reloadWindowStyle() {
        let updated = BrowserWindowStyle.load(for: activeSpace.saved.id)
        if windowStyle != updated || windowPaintView?.isHidden == true {
            if updated.hasColor { updated.paint(windowPaint) }
            windowPaintView?.isHidden = !updated.hasColor
            windowStyle = updated
        }
        let inset = pageFrameInset
        for (edge, constraint) in pageFrameEdges.enumerated() {
            constraint.constant = edge == 0 ? inset : -inset
        }
        pageArea?.layer?.cornerRadius = inset > 0 ? WebsiteFrameShadow.radius : 0
        pageArea?.layer?.masksToBounds = inset > 0
        pageArea?.layer?.borderWidth = inset > 0 ? 0.5 : 0
        pageArea?.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        // This backing only shows through transparent pages. Keep a soft
        // separation from the chrome without heavily shading glass pages.
        let shade = updated.hasColor
            ? NSColor(white: updated.usesDarkText ? 0 : 1, alpha: updated.usesDarkText ? 0.22 : 0.075)
            : NSColor(white: 0, alpha: inset > 0 ? 0.08 : 0)
        pageArea?.layer?.backgroundColor = shade.cgColor
        websiteFrameShadow?.isHidden = inset == 0
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
        wallpaper = BrowserWallpaperView(frame: .zero)
        wallpaper.translatesAutoresizingMaskIntoConstraints = false
        wallpaper.homepage = homeView
        wallpaper.presentationChanged={ [weak self] in self?.applyWallpaperPresentation();self?.refreshHomeTabColor() }
        wallpaper.chromeColorChanged={ [weak self] in self?.refreshHomeTabColor() }
        wallpaper.show(profile: activeSpace.saved.id)
        asciiCanvas = ASCIIBackgroundCanvas(frame: .zero)
        asciiCanvas.translatesAutoresizingMaskIntoConstraints = false
        homeView.addSubview(asciiCanvas)
        NSLayoutConstraint.activate([
            asciiCanvas.leadingAnchor.constraint(equalTo: homeView.leadingAnchor),
            asciiCanvas.trailingAnchor.constraint(equalTo: homeView.trailingAnchor),
            asciiCanvas.topAnchor.constraint(equalTo: homeView.topAnchor),
            asciiCanvas.bottomAnchor.constraint(equalTo: homeView.bottomAnchor)
        ])
        globe = AnimatedGlobeView(frame: .zero)
        globe.translatesAutoresizingMaskIntoConstraints = false
        globe.onClick = { [weak self] in self?.globeClicked() }
        homeSearchField = NSTextField(string: "")
        homeSearchField.placeholderString = "Search the web or enter a URL"
        homeSearchField.font = WebbyTypography.font(ofSize: 19, weight: .regular)
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
        loadErrorLabel.font = WebbyTypography.font(ofSize: 12)
        loadErrorLabel.textColor = .secondaryLabelColor
        loadErrorLabel.maximumNumberOfLines = 3
        loadErrorLabel.lineBreakMode = .byWordWrapping
        loadErrorLabel.isHidden = true
        loadErrorLabel.translatesAutoresizingMaskIntoConstraints = false
        center.addSubview(loadErrorLabel)
        let preferredWidth = center.widthAnchor.constraint(equalToConstant: 660)
        preferredWidth.priority = .defaultHigh
        NotificationCenter.default.addObserver(self,selector:#selector(arrangeHomepage(_:)),name:Notification.Name("WebbyArrangeHomepage"),object:nil)
        homeCenterTop = center.topAnchor.constraint(equalTo: homeView.topAnchor, constant: 10)
        homeCenterX = center.centerXAnchor.constraint(equalTo: homeView.centerXAnchor)
        NSLayoutConstraint.activate([
            homeCenterX,
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
        widgetCanvas.didRebuild = { [weak self] profile in
            guard let self else { return }
            // New cards have no feed data, even if this profile was fetched recently.
            self.lastWidgetRefresh.removeValue(forKey: profile)
            if self.widgetCanvas.has(.githubRecent),let space = self.spaces.first(where: { $0.saved.id == profile }) {
                let visits = space.saved.history.map(\.url)
                Task {
                    if await GitHubWidgetStore.shared.seedRecent(visits,profile:profile) {
                        NotificationCenter.default.post(name:.webbyGitHubChanged,object:profile,userInfo:["recentOnly":true])
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeSpace.saved.id == profile else { return }
                self.refreshGoogleWidgets()
            }
        }
        widgetCanvas.activate = { [weak self] kind in self?.activateWidget(kind) }
        widgetCanvas.openIDEProject = { [weak self] url in self?.openIDEProject(url) }
        widgetCanvas.openGitHubURL = { [weak self] url in
            guard let self else { return }
            self.addTab(select: true)
            self.navigate(url.absoluteString)
        }
        widgetCanvas.submitChatGPT = { [weak self] text,images in self?.launchChatGPTWidget(prompt:text,images:images) }
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
        widgetCanvas.calendarMonthChanged = { [weak self] date in self?.refreshCalendar(month: date) }
        widgetCanvas.calendarDayOpened = { [weak self] date in
            guard let self else { return }
            let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
            self.addTab(select: true)
            self.navigate("https://calendar.google.com/calendar/u/0/r/day/\(c.year!)/\(c.month!)/\(c.day!)")
        }
        widgetCanvas.show(profile: activeSpace.saved.id); asciiCanvas?.show(profile: activeSpace.saved.id); wallpaper?.show(profile: activeSpace.saved.id)
        widgetDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window, !self.homeView.isHidden else { return event }
            if self.asciiCanvas.isDragging { return self.asciiCanvas.handleDragEvent(event) ? nil : event }
            if self.widgetCanvas.handleDragEvent(event) {
                if event.type == .leftMouseDown { self.asciiCanvas.deselect() }
                return nil
            }
            let point = event.locationInWindow
            if self.widgetCanvas.coversPoint(inWindow: point)
                || self.homeSearchSurface.bounds.contains(self.homeSearchSurface.convert(point, from: nil))
                || self.globe.bounds.contains(self.globe.convert(point, from: nil))
                || self.suggestions.containsMouse() {
                if event.type == .leftMouseDown { self.asciiCanvas.deselect() }
                return event
            }
            return self.asciiCanvas.handleDragEvent(event) ? nil : event
        }
        homeSearchAlignmentGuide.strokeColor = NSColor.systemTeal.withAlphaComponent(0.8).cgColor
        homeSearchAlignmentGuide.lineWidth = 1
        homeSearchAlignmentGuide.lineDashPattern = [4, 4]
        homeSearchAlignmentGuide.fillColor = nil
        homeSearchAlignmentGuide.isHidden = true
        homeView.layer?.addSublayer(homeSearchAlignmentGuide)
        homeSearchSurface.toolTip = "Drag the glass edge to move · Snaps to the canvas center"
        globe.toolTip = "Click to switch · Drag to move with the search bar"
        installHomeSearchDragMonitor()
        DispatchQueue.main.async { [weak self] in self?.restoreHomeSearchPosition() }
        refreshGoogleWidgets()
    }

    @objc private func arrangeHomepage(_ notification:Notification) {
        guard let raw=notification.object as? Int,let style=HomepageLayout(rawValue:raw),let canvas=widgetCanvas else{return}
        content.layoutSubtreeIfNeeded()
        let padding:CGFloat=24,gap:CGFloat=24
        let height=homeView.bounds.height,searchHeight=homeCenter.bounds.height
        let top:CGFloat=style.searchPosition == 0 ? padding:style.searchPosition == 2 ? height-searchHeight-padding:(height-searchHeight)/2
        let geometry=Motion.capture([homeCenter],in:content)
        placeHomeSearch(top:top,x:0,snap:false)
        UserDefaults.standard.set(0.0,forKey:homeSearchHorizontalKey)
        UserDefaults.standard.set(false,forKey:homeSearchCenteredKey)
        UserDefaults.standard.set(Double((homeCenterTop.constant-10)/max(1,homeSearchMaximumTop-10)),forKey:homeSearchPositionKey)
        let centerRect=canvas.convert(homeCenter.bounds,from:homeCenter)
        let searchTop=centerRect.minY
        let searchBottom=centerRect.maxY
        // Widget canvas is flipped; reserve the complete logo/search block.
        let width=max(1,canvas.bounds.width-2*padding)
        var regions:[NSRect]=[]
        if style.searchPosition != 0,searchTop-gap>padding {regions.append(NSRect(x:padding,y:padding,width:width,height:searchTop-gap-padding))}
        if style.searchPosition != 2,canvas.bounds.height-padding>searchBottom+gap {regions.append(NSRect(x:padding,y:searchBottom+gap,width:width,height:canvas.bounds.height-padding-searchBottom-gap))}
        if regions.isEmpty {return}
        canvas.arrange(in:regions,style:style)
        Motion.settle(geometry,views:[homeCenter],in:content,character:.widget)
    }

    private var homeSearchPositionKey: String {
        "webbyHomeSearchPosition.\(activeSpace.saved.id.uuidString)"
    }

    private var homeSearchMaximumTop: CGFloat {
        guard homeView != nil, homeCenter != nil else { return 10 }
        return max(10, homeView.bounds.height - max(208, homeCenter.bounds.height) - 12)
    }

    private var homeSearchMaximumX: CGFloat {
        max(0, (homeView.bounds.width - homeCenter.bounds.width) / 2 - 12)
    }
    private var homeSearchHorizontalKey: String { "webbyHomeSearchHorizontal.\(activeSpace.saved.id.uuidString)" }
    private var homeSearchCenteredKey: String { "webbyHomeSearchCentered.\(activeSpace.saved.id.uuidString)" }
    private var homeSearchCenterTop: CGFloat {
        let bar = homeSearchSurface.convert(NSPoint(x: homeSearchSurface.bounds.midX, y: homeSearchSurface.bounds.midY), to: homeCenter)
        return homeView.bounds.height / 2 - (homeCenter.bounds.maxY - bar.y)
    }

    private func restoreHomeSearchPosition() {
        guard homeCenterTop != nil, !homeSearchIsDragging else { return }
        homeView.layoutSubtreeIfNeeded()
        let x = min(1, max(-1, UserDefaults.standard.double(forKey: homeSearchHorizontalKey)))
        homeCenterX.constant = CGFloat(x) * homeSearchMaximumX
        let fraction = min(1, max(0, UserDefaults.standard.double(forKey: homeSearchPositionKey)))
        homeCenterTop.constant = UserDefaults.standard.bool(forKey: homeSearchCenteredKey)
            ? min(homeSearchMaximumTop, max(10, homeSearchCenterTop))
            : 10 + CGFloat(fraction) * (homeSearchMaximumTop - 10)
    }

    private func placeHomeSearch(top: CGFloat, x: CGFloat, snap: Bool) {
        let centerTop = homeSearchCenterTop
        let centeredX = snap && abs(x) <= min(12, homeSearchMaximumX / 3)
        let centeredY = snap && centerTop >= 10 && centerTop <= homeSearchMaximumTop && abs(top - centerTop) <= 12
        homeCenterX.constant = centeredX ? 0 : min(homeSearchMaximumX, max(-homeSearchMaximumX, x))
        homeCenterTop.constant = centeredY ? centerTop : min(homeSearchMaximumTop, max(10, top))
        homeView.layoutSubtreeIfNeeded()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        homeSearchAlignmentGuide.frame = homeView.bounds
        let path = CGMutablePath()
        if centeredX {
            path.move(to: CGPoint(x: homeView.bounds.midX, y: 0))
            path.addLine(to: CGPoint(x: homeView.bounds.midX, y: homeView.bounds.height))
        }
        if centeredY {
            path.move(to: CGPoint(x: 0, y: homeView.bounds.midY))
            path.addLine(to: CGPoint(x: homeView.bounds.width, y: homeView.bounds.midY))
        }
        homeSearchAlignmentGuide.path = path
        homeSearchAlignmentGuide.isHidden = !snap || (!centeredX && !centeredY)
        CATransaction.commit()
    }

    private func installHomeSearchDragMonitor() {
        homeSearchDragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            guard let self, event.window === self.window, self.homeSearchSurface != nil else { return event }
            switch event.type {
            case .leftMouseDown:
                let point = self.homeSearchSurface.convert(event.locationInWindow, from: nil)
                let symbolPoint = self.globe.convert(event.locationInWindow, from: nil)
                if !self.homeView.isHidden && (self.homeSearchSurface.bounds.contains(point) || self.globe.bounds.contains(symbolPoint)) {
                    self.homeSearchDragOrigin = event.locationInWindow
                    self.homeSearchDragTop = self.homeCenterTop.constant
                    self.homeSearchDragX = self.homeCenterX.constant
                    self.homeSearchDragProfile = self.activeSpace.saved.id
                    self.homeSearchDragFromField = self.homeSearchField.bounds.contains(self.homeSearchField.convert(event.locationInWindow, from: nil))
                } else { self.homeSearchDragOrigin = nil }
                self.homeSearchIsDragging = false
            case .leftMouseDragged:
                guard let origin = self.homeSearchDragOrigin, self.homeSearchDragProfile == self.activeSpace.saved.id else { return event }
                let dx = event.locationInWindow.x - origin.x
                let dy = event.locationInWindow.y - origin.y
                if !self.homeSearchIsDragging {
                    // Leave horizontal text selection to the field editor. The glass edge
                    // and symbol drag in either direction; Option-drag also works over text.
                    if self.homeSearchDragFromField && !event.modifierFlags.contains(.option) {
                        guard abs(dy) > 6, abs(dy) > abs(dx) * 1.15 else { return event }
                    } else { guard hypot(dx, dy) > 6 else { return event } }
                    self.homeSearchIsDragging = true
                    self.closeSuggestions()
                    let draft = self.homeSearchField.currentEditor()?.string ?? self.homeSearchField.stringValue
                    self.homeSearchField.abortEditing()
                    self.homeSearchField.stringValue = draft
                    self.window.makeFirstResponder(nil)
                }
                self.placeHomeSearch(top: self.homeSearchDragTop - dy, x: self.homeSearchDragX + dx, snap: true)
                return nil
            case .leftMouseUp:
                defer {
                    let changedProfile = self.homeSearchDragProfile != nil && self.homeSearchDragProfile != self.activeSpace.saved.id
                    self.homeSearchDragOrigin = nil
                    self.homeSearchDragProfile = nil
                    self.homeSearchIsDragging = false
                    self.homeSearchAlignmentGuide.isHidden = true
                    if changedProfile { self.restoreHomeSearchPosition() }
                }
                guard self.homeSearchIsDragging else { return event }
                if self.homeSearchDragProfile == self.activeSpace.saved.id {
                    let travel = max(1, self.homeSearchMaximumTop - 10)
                    UserDefaults.standard.set(Double((self.homeCenterTop.constant - 10) / travel), forKey: self.homeSearchPositionKey)
                    UserDefaults.standard.set(Double(self.homeCenterX.constant / max(1, self.homeSearchMaximumX)), forKey: self.homeSearchHorizontalKey)
                    UserDefaults.standard.set(abs(self.homeCenterTop.constant - self.homeSearchCenterTop) < 0.5, forKey: self.homeSearchCenteredKey)
                }
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
        if service == .calendar {
            guard let text = widgetTextPrompt(title: "Private Google Calendar iCal link", value: "") else { return }
            do {
                try CalendarSubscription.save(text, profile: activeSpace.saved.id)
                widgetCanvas.addWidget(.calendar)
                let profile = activeSpace.saved.id
                Task { [weak self] in
                    await CalendarFeed.shared.invalidate(profile: profile)
                    guard let self, self.activeSpace.saved.id == profile else { return }
                    self.refreshGoogleWidgets(force: true)
                }
            } catch { showGoogleError(error) }
            return
        }
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
        if service == .calendar {
            let profile = activeSpace.saved.id
            CalendarSubscription.remove(profile: profile)
            widgetCanvas.removeWidget(.calendar)
            Task { await CalendarFeed.shared.invalidate(profile: profile) }
            return
        }
        GoogleWorkspace.shared.disconnect(service, profile: activeSpace.saved.id)
        refreshGoogleWidgets(force: true)
    }

    private var lastCalendarRefresh = Date.distantPast
    private var calendarRequestID = UUID()
    private func refreshCalendar(month: Date = Date()) {
        guard widgetCanvas?.has(.calendar) == true else { return }
        lastCalendarRefresh = Date()
        let profile = activeSpace.saved.id
        let requestID = UUID(); calendarRequestID = requestID
        if let cached = CalendarSnapshotCache.read(profile:profile,month:month) { widgetCanvas.setCalendar(cached) }
        Task { [weak self] in
            do {
                let snapshot = try await CalendarFeed.shared.load(profile: profile, month: month)
                guard let self, self.activeSpace.saved.id == profile, self.calendarRequestID == requestID else { return }
                self.widgetCanvas.setCalendar(snapshot)
            } catch {
                guard let self, self.activeSpace.saved.id == profile, self.calendarRequestID == requestID else { return }
                self.widgetCanvas.setCalendarStatus(error.localizedDescription)
            }
        }
    }

    private var startupWidgetRefresh:DispatchWorkItem?
    private func refreshGoogleWidgets(force: Bool = false) {
        guard widgetCanvas != nil else { return }
        if buildingFirstWindow {
            startupWidgetRefresh?.cancel()
            let work=DispatchWorkItem { [weak self] in self?.refreshGoogleWidgets(force:force) }
            startupWidgetRefresh=work
            DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
            return
        }
        let profile = activeSpace.saved.id
        if !force, let last = lastWidgetRefresh[profile], Date().timeIntervalSince(last) < 120 { return }
        lastWidgetRefresh[profile] = Date()
        refreshCalendar()
        for service in GoogleService.allCases where service != .calendar {
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
        alert.messageText = "We couldn’t connect to Google"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private func refreshLocalWidgets(profile: UUID) {
        if widgetCanvas.has(.note) {
            let note = UserDefaults.standard.string(forKey: "webbyNote.\(profile.uuidString)") ?? ""
            widgetCanvas.set(.note, subtitle: "Saved in this profile", lines: note.isEmpty ? ["Click Open to write a note"] : [note])
        }
        refreshNetworkWidgets(profile:profile)
        pollRealtimeWidgets()
    }

    private func refreshNetworkWidgets(profile: UUID) {
        guard activeSpace.saved.id==profile,!homeView.isHidden,window.isVisible,window.occlusionState.contains(.visible) else{return}
        for kind in [WebbyWidget.weather,.stocks] where widgetCanvas.has(kind) {
            let preference = kind == .weather ? "webbyWeatherCity." : "webbyStockSymbol."
            let query=UserDefaults.standard.string(forKey:preference+profile.uuidString) ?? (kind == .weather ? "San Francisco":"AAPL")
            let normalized=WidgetSnapshotCache.normalized(query)
            let key=profile.uuidString+"."+kind.rawValue
            let interval:TimeInterval=kind == .weather ? 300:120
            if let state=widgetFeedStates[key],state.query==normalized {
                if state.task != nil || Date().timeIntervalSince(state.attempted)<interval {continue}
            } else if widgetFeedStates[key] == nil {
                let cachedDate:Date?
                if kind == .weather {cachedDate=WidgetSnapshotCache.read(WeatherSnapshot.self,profile:profile,kind:kind.rawValue,query:query)?.updated}
                else {cachedDate=WidgetSnapshotCache.read(StockSnapshot.self,profile:profile,kind:kind.rawValue,query:query)?.updated}
                if let date=cachedDate,Date().timeIntervalSince(date)<interval {
                    widgetFeedStates[key]=WidgetFeedState(id:UUID(),query:normalized,attempted:min(date,Date()),task:nil)
                    continue
                }
            }
            widgetFeedStates[key]?.task?.cancel()
            let id=UUID()
            widgetFeedStates[key]=WidgetFeedState(id:id,query:normalized,attempted:Date(),task:nil)
            widgetCanvas.prepareFeed(kind,query:query,refreshing:true)
            let task=Task { [weak self] in
                do {
                    let feed:WidgetFeed
                    if kind == .weather {feed=try await WidgetFeeds.weather(city:query)}
                    else {feed=try await WidgetFeeds.stock(symbol:query)}
                    guard let self,!Task.isCancelled,self.widgetFeedStates[key]?.id==id else{return}
                    self.widgetFeedStates[key]?.task=nil
                    let current=UserDefaults.standard.string(forKey:preference+profile.uuidString) ?? (kind == .weather ? "San Francisco":"AAPL")
                    guard WidgetSnapshotCache.normalized(current)==normalized else{return}
                    if let value=feed.weather {WidgetSnapshotCache.save(value,profile:profile,kind:kind.rawValue,query:query)}
                    if let value=feed.stock {WidgetSnapshotCache.save(value,profile:profile,kind:kind.rawValue,query:query)}
                    guard self.activeSpace.saved.id==profile else{return}
                    if let value=feed.weather {self.widgetCanvas.setWeather(value)}
                    if let value=feed.stock {self.widgetCanvas.setStock(value)}
                } catch {
                    guard let self,!Task.isCancelled,self.widgetFeedStates[key]?.id==id else{return}
                    self.widgetFeedStates[key]?.task=nil
                    let current=UserDefaults.standard.string(forKey:preference+profile.uuidString) ?? (kind == .weather ? "San Francisco":"AAPL")
                    if self.activeSpace.saved.id==profile && WidgetSnapshotCache.normalized(current)==normalized {self.widgetCanvas.failFeed(kind,message:error.localizedDescription)}
                }
            }
            widgetFeedStates[key]?.task=task
        }
    }

    // Stop the timer itself while its consumers are hidden. Mini-window expiry
    // remains active independently of homepage visibility.
    private func updateWidgetActivity() {
        asciiCanvas?.refreshActivity()
        let visible = widgetCanvas != nil && homeView?.isHidden == false && window?.isVisible == true && window?.occlusionState.contains(.visible) == true
        widgetCanvas?.setFeedsVisible(visible)
        let needed = visible || !miniTabs.isEmpty
        if !needed { widgetTimer?.invalidate(); widgetTimer = nil; return }
        guard widgetTimer == nil else { return }
        widgetTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollRealtimeWidgets() }
        }
        widgetTimer?.tolerance = 1
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        updateWidgetActivity()
        wallpaper?.refreshActivity()
        if window.occlusionState.contains(.visible) { pollRealtimeWidgets() }
    }

    private func pollRealtimeWidgets() {
        updateWidgetActivity()
        let hours=MiniWebbySettings.archiveHours
        if hours>0 {for (id,host) in floatingWindows {if let mini=host as? MiniWebbyWindow,!mini.isKeyWindow,Date().timeIntervalSince(mini.lastUsed)>Double(hours)*3600 {expireMiniWebby(id,hours:hours)}}}
        let visible = widgetCanvas != nil && !homeView.isHidden && window.isVisible && window.occlusionState.contains(.visible)
        widgetCanvas?.setFeedsVisible(visible)
        guard widgetCanvas != nil, !homeView.isHidden, window.isVisible, window.occlusionState.contains(.visible) else { return }
        refreshNetworkWidgets(profile:activeSpace.saved.id)
        if widgetCanvas.has(.calendar), Date().timeIntervalSince(lastCalendarRefresh) >= 300 { refreshCalendar() }
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
            widgetCanvas.set(.downloads, subtitle: "Recent Downloads",
                             lines: downloads.widgetLines.isEmpty ? recentDownloadLines : downloads.widgetLines)
            if downloads.widgetLines.isEmpty && !downloadsScanInFlight {
                downloadsScanInFlight = true
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    let recent = WidgetSystemData.recentDownloads().map { "↓ \($0.lastPathComponent)" }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.downloadsScanInFlight = false
                        self.recentDownloadLines = recent
                        guard self.widgetCanvas != nil, self.widgetCanvas.has(.downloads),
                              self.downloads.widgetLines.isEmpty else { return }
                        self.widgetCanvas.set(.downloads, subtitle: "Recent Downloads", lines: recent)
                    }
                }
            }
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
        if kind.githubKind != nil { GitHubWidgetConnection.present(profile: activeSpace.saved.id); return }
        if kind == .calendar { openGoogleService(.calendar); return }
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
        case .ide:
            openIDEProject(nil)
        case .chatgpt:
            launchChatGPTWidget(prompt:"",images:[])
        case .codex, .codexUsage:
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

    private func launchChatGPTWidget(prompt:String,images:[ChatGPTWidgetImage]) {
        addTab(select:true)
        guard let target=activeTab else{return}
        if !images.isEmpty {chatGPTDrafts[target.id]=(prompt,images)}
        navigate(ChatGPTWidgetRoute.url(prompt:prompt,hasImages:!images.isEmpty).absoluteString,in:target)
    }
    private func sendChatGPTDraft(_ tab:BrowserTab,webView:WKWebView){
        guard webView.url?.host=="chatgpt.com",let draft=chatGPTDrafts.removeValue(forKey:tab.id),
              let path=Bundle.main.path(forResource:"ChatGPTWidget",ofType:"js"),let script=try? String(contentsOfFile:path,encoding:.utf8) else{return}
        let value:[String:Any]=["text":draft.0,"images":draft.1.map{["name":$0.name,"data":$0.data.base64EncodedString()]}]
        webView.callAsyncJavaScript(script,arguments:["draft":value],in:nil,in:.page){[weak self,weak tab] result in
            guard let self,let tab,self.tab(id:tab.id) === tab else{return}
            if case .success(let sent)=result,sent as? Bool==true {return}
            // A sign-in or changed composer must not discard the draft.
            self.chatGPTDrafts[tab.id]=draft
        }
    }

    private func launchCodexWidget(prompt: String) {
        let text = prompt.trimmingCharacters(in:.whitespacesAndNewlines)
        if text.isEmpty { CodexWidgetHub.open(); return }
        var url = URLComponents(string:"codex://threads/new")!
        url.queryItems = [.init(name:"prompt",value:text)]
        if let url = url.url { NSWorkspace.shared.open(url) }
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
        editor.font = WebbyTypography.font(ofSize: 13)
        editor.string = value
        scroll.documentView = editor
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return editor.string
    }

    private func showAddWidget() {
        showBrowserWindow()
        let missing = WebbyWidget.allCases.filter { ($0.googleService == nil || $0 == .calendar) && !widgetCanvas.has($0) }
        let artwork = ASCIIArtwork.catalog.filter { !asciiCanvas.has($0.id) }
        guard !missing.isEmpty || !artwork.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Let’s add a widget"
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        picker.addItems(withTitles: missing.map(\.title) + artwork.map { "ASCII · \($0.name) (Background)" })
        alert.accessoryView = picker
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        WebbySounds.play("widget-add")
        let index = picker.indexOfSelectedItem
        if index < missing.count { widgetCanvas.addWidget(missing[index]) }
        else { asciiCanvas.toggle(artwork[index - missing.count].id) }
        refreshGoogleWidgets(force: true)
    }

    private func configureSuggestions(for surface: GlassAddressSurface) {
        surface.onExpandedEntranceBeam = { [weak self] in self?.suggestions.playEntranceBeam() }
        suggestions.knownFavicon = { [weak self] url in
            guard let self, let host = url.host?.lowercased() else { return nil }
            return self.spaces.lazy.flatMap(\.tabs).first {
                $0.webView?.url?.host?.lowercased() == host && $0.favicon != nil
            }?.favicon
        }
        suggestions.onChoose = { [weak self] item in
            guard let self else { return }
            self.editingSearchField = nil
            self.navigate(item.url, profileID: item.profileID)
            self.window.makeFirstResponder(self.activeWebView)
        }
        surface.onBeginEditing = { [weak self] field in
            guard let self else { return }
            self.editingSearchField = field
            self.presentSuggestions(for: field)
            for space in self.suggestionSpaces { self.loadCookieHosts(for: space) }
        }
        surface.onChange = { [weak self] field in self?.presentSuggestions(for: field) }
        surface.onEndEditing = { [weak self] field in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
                guard let self, field.currentEditor() == nil else { return }
                if self.suggestions.containsMouse() { return }
                self.closeSuggestions()
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
                self.closeSuggestions()
                if field === self.addressField {
                    self.window.makeFirstResponder(self.activeWebView)
                    self.hideToolbar(animated: true)
                }
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)), let choice = self.suggestions.selected() {
                self.closeSuggestions()
                self.editingSearchField = nil
                self.navigate(choice.url, profileID: choice.profileID)
                self.window.makeFirstResponder(self.activeWebView)
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
                if self.suggestionSpaces.contains(where: { $0.saved.id == id }), let field = self.editingSearchField {
                    self.presentSuggestions(for: field)
                }
            }
        }
    }

    private var usesFuseSearch: Bool { BrowserExperiment.cyclesNewTabProfiles && activeTab?.fuseSearch == true }
    private var suggestionSpaces: [BrowserSpace] {
        if usesFuseSearch { return spaces }
        return [activeTab.map { ownerSpace(for: $0) } ?? activeSpace]
    }
    private var fuseHistorySources: [FuseHistoryRouting.Source] {
        spaces.map { .init(id: $0.saved.id, name: $0.saved.name, history: $0.saved.history) }
    }

    private func closeSuggestions() {
        suggestionGeneration &+= 1;suggestionTask?.cancel();suggestionTask=nil
        suggestions.close()
    }
    private func presentSuggestions(for field: NSTextField) {
        guard !terminalMode,let surface=field.superview else{return}
        suggestionGeneration &+= 1
        let generation=suggestionGeneration
        suggestionTask?.cancel()
        suggestions.invalidateSelection()
        let query=(field.currentEditor()?.string ?? field.stringValue).trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        if field === homeSearchField && query.isEmpty {closeSuggestions();return}
        let fuse=usesFuseSearch,tabID=activeTabID
        let sources=suggestionSpaces
        let revision=sources.map{HistoryRevision(space:ObjectIdentifier($0),revision:$0.historyRevision)}
        let snapshots=sources.map { space in
            SuggestionSearchSource(id:space.saved.id,identity:ObjectIdentifier(space),revision:space.historyRevision,name:space.saved.name,
                bookmarks:space.saved.bookmarks,history:space.saved.history,
                pins:space.tabs.filter(\.isPinned).compactMap { tab in
                    guard let url=tab.pageURL?.absoluteString ?? destination(for:tab.searchDraft,profile:space.saved.id)?.absoluteString else{return nil}
                    return BrowserLink(title:tab.title,url:url,visitedAt:nil)
                },cookies:cookieHosts[space.saved.id] ?? [])
        }
        let index=suggestionIndex,signposter=suggestionSignposter
        let interval=signposter.beginInterval("Suggestions",id:signposter.makeSignpostID())
        suggestionTask=Task(priority:.userInitiated) { @MainActor [weak self,weak field,weak surface] in
            defer {signposter.endInterval("Suggestions",interval)}
            let result=await index.search(query,sources:snapshots,fuse:fuse)
            guard !Task.isCancelled,let self,let field,let surface,
                  self.suggestionGeneration==generation,self.activeTabID==tabID,self.usesFuseSearch==fuse,
                  self.suggestionSpaces.map({HistoryRevision(space:ObjectIdentifier($0),revision:$0.historyRevision)})==revision,
                  (field.currentEditor()?.string ?? field.stringValue).trimmingCharacters(in:.whitespacesAndNewlines).lowercased()==query else{return}
            if fuse {self.fuseRoutes=result.routes;self.fuseRouteRevision=revision}
            self.suggestions.show(result.items,at:surface)
            self.suggestionCompletedGeneration=generation
        }
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
        guard let tab = activeTab, tab.pageView == nil, !tab.isTerminal else { return }
        let id = tab.ownerSpaceID ?? activeSpace.saved.id
        let index = spaces.firstIndex { $0.saved.id == id } ?? activeSpaceIndex
        let fused = usesFuseSearch
        globe.engine.setProfile(fused ? BrowserTheme.fuseProfile : BrowserTheme.profile(for: id), wave: true)
        globe.engine.showScene(fused ? BrowserExperiment.fuseScene : BrowserExperiment.scene(for: id, index: index))
        let name = spaces.first(where: { $0.saved.id == id })?.saved.name ?? activeSpace.saved.name
        homeSearchField.placeholderString = BrowserExperiment.cyclesNewTabProfiles
            ? (fused ? "Search across profiles or enter a URL" : "Search in \(name) or enter a URL")
            : "Search \(BrowserSearchEngine.selected(for: id).name) or enter a URL"
        globe.toolTip = BrowserExperiment.cyclesNewTabProfiles
            ? (fused ? "Fuse · All profiles · Click for the first profile" : "\(name) · Click for the next profile or Fuse") : "Open Terminal"
    }

    private func assignSearchProfile(_ tab: BrowserTab, to space: BrowserSpace) {
        guard tab.pageView == nil else { return }
        let old = displaySpace(for: tab)
        if old !== space {
            old.tabs.removeAll { $0.id == tab.id }
            space.tabs.append(tab)
            if old.activeTabID == tab.id { old.activeTabID = old.tabs.first?.id }
            // A Fuse group can span accounts; changing the new tab’s owner keeps its group.
        }
        tab.ownerSpaceID = space.saved.id
        space.activeTabID = tab.id
        if let index = spaces.firstIndex(where: { $0 === space }) { activeSpaceIndex = index }
        BrowserTheme.activate(space.saved.id)
        widgetCanvas?.show(profile: space.saved.id); asciiCanvas?.show(profile: space.saved.id); wallpaper?.show(profile: space.saved.id)
        restoreHomeSearchPosition()
        lastWidgetRefresh.removeValue(forKey: space.saved.id)
        updateSpaceLabel()
    }

    private func globeClicked() {
        guard BrowserExperiment.cyclesNewTabProfiles,
              let tab = activeTab, tab.pageView == nil, !tab.isTerminal,
              !spaces.isEmpty else { toggleTerminal(); return }
        closeSuggestions()
        let current = tab.fuseSearch ? nil : tab.ownerSpaceID
        if let next = FuseHistoryRouting.nextProfile(after: current, profiles: spaces.map { $0.saved.id }),
           let space = spaces.first(where: { $0.saved.id == next }) {
            tab.fuseSearch = false
            assignSearchProfile(tab, to: space)
        } else { tab.fuseSearch = true }
        showCurrentIndicator()
        refreshTabs()
        if let field = editingSearchField { presentSuggestions(for: field) }
    }

    private func toggleTerminal() {
        guard let tab = activeTab, tab.pageView == nil, tab.ide == nil else { return }
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
                tab.ide?.view.isHidden = true
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
                      tab.pageView == nil, !tab.isTerminal else { return }
                self.homeView.layoutSubtreeIfNeeded()
                self.homeSearchSurface.playEntranceBeam()
            }
        } else { refreshTabs() }
        scheduleSessionSave()
    }

    private var restoreTabsOnLaunch: Bool { UserDefaults.standard.bool(forKey: "webbyRestoreTabs") }

    private func scheduleSessionSave() {
        guard restoreTabsOnLaunch else { return }
        sessionSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveSessionTabs() }
        sessionSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    private func saveSessionTabs(wait: Bool = false) {
        guard restoreTabsOnLaunch else { return }
        let pages = spaces.flatMap { space in
            space.tabs.compactMap { tab -> BrowserSessionRecord.Page? in
                guard !tab.isPinned, !tab.isTerminal,
                      let url = tab.pageURL ?? tab.suspendedURL
                        ?? (!tab.searchDraft.isEmpty
                            ? destination(for: tab.searchDraft, profile: ownerSpace(for: tab).saved.id) : nil),
                      ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
                return .init(title: tab.title, url: url.absoluteString,
                             ownerSpaceID: ownerSpace(for: tab).saved.id, displaySpaceID: space.saved.id,
                             groupID: tab.groupID, engine: tab.engine)
            }
        }
        sessionWriter.save(BrowserSessionRecord(pages: pages), key: "webbySessionTabs", wait: wait)
    }

    private func restoreSessionTabs() {
        guard restoreTabsOnLaunch,
              let data = UserDefaults.standard.data(forKey: "webbySessionTabs"),
              let record = try? JSONDecoder().decode(BrowserSessionRecord.self, from: data) else { return }
        for page in record.pages.prefix(80) {
            guard let url = URL(string: page.url),
                  let display = spaces.first(where: { $0.saved.id == page.displaySpaceID }) else { continue }
            let tab = BrowserTab()
            tab.title = page.title
            tab.engine = page.engine ?? .webKit
            tab.searchDraft = page.url
            tab.suspendedURL = url
            tab.ownerSpaceID = spaces.contains(where: { $0.saved.id == page.ownerSpaceID })
                ? page.ownerSpaceID : display.saved.id
            tab.groupID = tabGroups.contains(where: { $0.id == page.groupID }) ? page.groupID : nil
            display.tabs.append(tab)
            restoreFavicon(for: tab, url: url)
            if BrowserExperiment.cyclesNewTabProfiles { fusedTabOrder.append(tab.id) }
        }
        refreshTabs()
    }

    private func offloadIdleTabs(memoryPressure: Bool = false) {
        let minutes = UserDefaults.standard.integer(forKey: "webbyOffloadMinutes")
        let now = ProcessInfo.processInfo.systemUptime
        guard minutes > 0, now-lastDiscardPass >= 15 else { return }
        lastDiscardPass = now
        let cutoff = Date().addingTimeInterval(-Double(memoryPressure ? min(minutes, 3) : minutes) * 60)
        let recent = Set(recentTabOrder.prefix(2))
        let candidates = spaces.flatMap(\.tabs).filter {
            canDiscard($0, cutoff: cutoff) && !recent.contains($0.id)
        }.sorted { a, b in a.isPinned == b.isPinned ? a.lastActiveAt < b.lastActiveAt : !a.isPinned }
        // A soft working-set target accelerates only already-eligible idle tabs.
        // User idle timeouts, dirty/media/capture/split checks and keep-loaded
        // exceptions are unchanged. No timer is added and each pass stays bounded.
        let loaded = spaces.reduce(0) { $0 + $1.tabs.lazy.filter { $0.pageView != nil }.count }
        let budget = BrowserWorkingSet.discardBatch(loaded: loaded, physicalMemory: ProcessInfo.processInfo.physicalMemory, pressure: memoryPressure)
        for tab in candidates.prefix(budget) { checkDiscard(tab, cutoff: cutoff) }
    }

    private func canDiscard(_ tab: BrowserTab, cutoff: Date) -> Bool {
        guard tab.id != activeTabID, !(splitTabIDs?.contains(tab.id) ?? false), !tab.isFloating,
              !tab.isTerminal, !tab.navigationInProgress, !tab.hasUnsavedEdits, !tab.captureMayBeActive, !tab.hasPictureInPicture,
              !tab.discardCheckInFlight, tab.lastActiveAt < cutoff,
              keepLoadedKey(for: tab).map { !UserDefaults.standard.bool(forKey: $0) } ?? true,
              downloads?.hasActiveDownloads != true else { return false }
        if let page = tab.chromiumView { return page.isHidden && !page.loading && !page.protectsFromDiscard }
        guard let view = tab.webView, view.isHidden, !view.isLoading,
              view.cameraCaptureState == .none, view.microphoneCaptureState == .none,
              view.fullscreenState == .notInFullscreen,
              downloads?.hasActiveDownloads != true else { return false }
        return true
    }

    private func checkDiscard(_ tab: BrowserTab, cutoff: Date) {
        if tab.chromiumView != nil {
            guard canDiscard(tab, cutoff: cutoff), let url = tab.pageURL else { return }
            tab.suspendedURL = url; tab.searchDraft = url.absoluteString
            releaseWebView(for: tab); refreshTabContent(tab); scheduleSessionSave()
            return
        }
        guard canDiscard(tab, cutoff: cutoff), let view = tab.webView else { return }
        let generation = tab.navigationTiming.id
        tab.discardCheckInFlight = true
        view.requestMediaPlaybackState { [weak self, weak tab, weak view] state in
            guard let self, let tab, let view else { return }
            guard state == .none || state == .paused else { tab.discardCheckInFlight = false; return }
            view.callAsyncJavaScript("return window.__webbyDiscardState?.() ?? null", arguments: [:], in: nil,
                                     in: BrowserPageActivity.world) { [weak self, weak tab, weak view] result in
                guard let self, let tab, let view else { return }
                tab.discardCheckInFlight = false
                guard self.tab(id: tab.id) === tab, tab.webView === view, tab.navigationTiming.id == generation,
                      self.canDiscard(tab, cutoff: cutoff),
                      let value = (try? result.get()) as? [String: Any],
                      value["edited"] as? Bool == false, value["form"] as? Bool == false,
                      value["embedded"] as? Bool == false, value["media"] as? Bool == false,
                      let url = view.url else { return }
                // A discarded page reloads on selection. Keep metadata and its icon.
                // Never classify resource eviction as the user closing a pin.
                tab.suspendedURL = url; tab.searchDraft = url.absoluteString
                if let x = value["x"] as? Double, let y = value["y"] as? Double, x.isFinite, y.isFinite {
                    tab.restoredScroll = NSPoint(x: x, y: y)
                }
                self.releaseWebView(for: tab)
                self.refreshTabContent(tab)
                self.scheduleSessionSave()
            }
        }
    }

    private func releaseWebView(for tab: BrowserTab) {
        tab.chromiumView?.closePage()
        tab.chromiumView?.removeFromSuperview()
        tab.chromiumView = nil
        releaseWebKit(for: tab)
    }

    private func releaseWebKit(for tab: BrowserTab) {
        if pointerLockedWebView === tab.webView { releasePointerLock() }
        tab.recoveryOverlay?.removeFromSuperview(); tab.recoveryOverlay = nil
        tab.progressObservation?.invalidate()
        tab.progressObservation = nil
        tab.faviconTask?.cancel()
        tab.faviconTask = nil
        tab.webView?.stopLoading()
        tab.webView?.navigationDelegate = nil
        tab.webView?.uiDelegate = nil
        NSLayoutConstraint.deactivate(tab.pageConstraints)
        tab.pageConstraints = []
        tab.webView?.removeFromSuperview()
        tab.webView = nil
        tab.hasPictureInPicture = false
        tab.currentNavigation = nil
        tab.navigationTiming = BrowserNavigationTiming()
        tab.discardCheckInFlight = false
        tab.previewImage = nil
        tab.navigationInProgress = false
    }

    private func resumeTab(_ tab: BrowserTab, show: Bool) {
        guard let url = tab.suspendedURL ?? (tab.isPinned ? URL(string: tab.searchDraft) : nil) else { return }
        if tab.engine == .chromium {
            if openChromium(url, in: tab, show: show) {
                tab.suspendedURL = nil; tab.pinnedInstanceClosed = false
            }
            return
        }
        tab.suspendedURL = nil
        tab.pinnedInstanceClosed = false
        tab.navigationInProgress = true
        tab.showsSearchView = false
        let view = makeWebView(for: tab)
        view.isHidden = !show
        tab.currentNavigation = view.load(URLRequest(url: url))
        if tab.isPinned { savePinnedTabs(for: displaySpace(for: tab)) }
    }

    private func pinnedKey(for space: BrowserSpace) -> String { "webbyPinnedTabs.\(space.saved.id.uuidString)" }

    private func savePinnedTabs(for space: BrowserSpace) {
        let records = space.tabs.filter { $0.isPinned && !$0.isTerminal }.compactMap { tab -> PinnedTabRecord? in
            guard let url = tab.pageURL?.absoluteString ?? destination(for: tab.searchDraft)?.absoluteString,
                  let parsed = URL(string: url), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else { return nil }
            return PinnedTabRecord(title: tab.title, url: url, ownerSpaceID: tab.ownerSpaceID,
                                   widthFraction: Double(tab.pinWidthFraction), height: Double(tab.pinHeight),
                                   instanceClosed: tab.pinnedInstanceClosed, split: savedSplitRecord(for: tab), engine: tab.engine)
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
                                    widthFraction: width, height: $0.height, instanceClosed: $0.instanceClosed, split: $0.split, engine: $0.engine)
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
            tab.engine = record.engine ?? .webKit
            tab.savedSplit = record.split
            tab.pinWidthFraction = min(1, max(0.22, CGFloat(record.widthFraction ?? 0.5)))
            tab.pinHeight = min(240, max(39, CGFloat(record.height ?? 72)))
            tab.title = record.title
            tab.searchDraft = record.url
            tab.suspendedURL = url
            tab.pinnedInstanceClosed = record.instanceClosed == true
            restoreFavicon(for: tab, url: url)
            if BrowserExperiment.cyclesNewTabProfiles {
                activeSpace.tabs.insert(tab, at: activeSpace.tabs.prefix { $0.isPinned }.count)
                fusedTabOrder.insert(tab.id, at: fusedTabOrder.prefix { id in
                    self.tab(id: id)?.isPinned == true
                }.count)
            } else {
                tabs.insert(tab, at: tabs.prefix { $0.isPinned }.count)
            }
        }
        refreshTabs()
        return tabs.first(where: { $0.isPinned })
    }

    private func attachIDE(to tab: BrowserTab, project: URL? = nil) {
        let ide = LightweightIDE()
        tab.ide = ide
        tab.isTerminal = true
        tab.title = "IDE"
        tab.favicon = IDEIdentity.image(size:32)
        ide.onTitleChange = { [weak self, weak tab] title in
            guard let tab else { return }
            tab.title = title
            self?.refreshTabs()
        }
        ide.view.translatesAutoresizingMaskIntoConstraints = false
        ide.view.isHidden = true
        pageArea.addSubview(ide.view)
        tab.ideConstraints = [
            ide.view.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            ide.view.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            ide.view.topAnchor.constraint(equalTo: pageArea.topAnchor),
            ide.view.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor)
        ]
        NSLayoutConstraint.activate(tab.ideConstraints)
        if let project { ide.restoreProject(project) }
    }

    private func openIDEProject(_ project: URL?) {
        let token=UUID();ideProjectOpenToken=token
        let origin=activeSpace.saved.id
        guard let project else { openIDE(); return }
        let normalized = project.standardizedFileURL
        Task { [weak self] in
            let exists = await Task.detached(priority:.userInitiated) { () -> Bool in
                var directory: ObjCBool = false
                return FileManager.default.fileExists(atPath:normalized.path,isDirectory:&directory) && directory.boolValue
            }.value
            guard let self, self.ideProjectOpenToken == token, self.activeSpace.saved.id == origin else { return }
            guard exists else {
                let alert=NSAlert();alert.messageText="We couldn’t find this project";alert.informativeText=normalized.path
                alert.addButton(withTitle:"Keep in Recents");alert.addButton(withTitle:"Remove from Recents")
                if alert.runModal() == .alertSecondButtonReturn { IDERecentProjects.forget(normalized) };return
            }
            // Reuse only a workspace visible in this profile/Fuse, preserving profile isolation.
            if let existing = self.tabs.first(where: { !$0.isFloating && $0.ide?.projectURL?.standardizedFileURL == normalized }) {
                self.showBrowserWindow(); self.selectTab(existing); IDERecentProjects.record(normalized); return
            }
            self.showBrowserWindow(); self.addTab(select:false)
            guard let tab=self.tabs.last else { return }
            self.attachIDE(to:tab,project:normalized);self.selectTab(tab)
        }
    }

    @objc private func openIDE() {
        ideProjectOpenToken=UUID()
        showBrowserWindow()
        addTab(select: false)
        guard let tab = tabs.last else { return }
        attachIDE(to: tab)
        selectTab(tab)
    }

    @objc private func newTabAction() { if let previous=NSApp.keyWindow as? MiniWebbyWindow {let next=openMiniWebby();if let host=floatingWindows[next.id] as? MiniWebbyWindow {host.positionForSwitch(from:previous);previous.orderOut(nil);host.makeKeyAndOrderFront(nil)};return};addTab(select: true); WebbySounds.play("tab-open") }

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
        let appearance = menu.addItem(withTitle: "Window Appearance…", action: #selector(editWindowAppearance), keyEquivalent: "")
        appearance.target = self
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
        alert.messageText = "Which profile should we delete?"
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
        confirm.informativeText = "We’ll remove this profile’s Webby copy and its saved passwords."
        confirm.addButton(withTitle: "Delete Profile")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        deleteProfile(at: index)
    }

    private func deleteProfile(at index: Int) {
        guard spaces.indices.contains(index), !importInProgress else { return }
        let deleting = spaces[index]
        guard !spaces.flatMap(\.tabs).contains(where: { tab in
            (tab.ownerSpaceID == deleting.saved.id || deleting.tabs.contains { $0.id == tab.id })
                && tab.ide?.mayClose() == false
        }) else { return }
        for tab in Array(miniTabs.values) where tab.ownerSpaceID == deleting.saved.id {closeMiniWebby(tab.id,restoreFocus:false)}
        MiniWebbyArchive.entries=MiniWebbyArchive.entries.filter{$0.profile != deleting.saved.id}
        dismissTabSwitcher()
        layoutUndo.removeAll(); layoutRedo.removeAll()
        if BrowserExperiment.cyclesNewTabProfiles {
            BrowserExperiment.cyclesNewTabProfiles = false
            experimentalModeChanged()
        }
        linkPreview?.close()
        pendingSpaceSave?.cancel()
        let target = spaces[index]
        tabGroups.removeAll { $0.profileID == target.saved.id }
        saveTabGroups()
        GoogleWorkspace.shared.deleteProfile(target.saved.id)
        let deletedGitHubProfile = target.saved.id
        Task { await GitHubWidgetStore.shared.deleteProfile(deletedGitHubProfile) }
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
            tab.chromiumView?.closePage()
            tab.chromiumView?.removeFromSuperview()
            tab.chromiumView = nil
            tab.progressObservation?.invalidate()
            tab.progressObservation = nil
            tab.faviconTask?.cancel()
            tab.webView?.stopLoading()
            tab.webView?.navigationDelegate = nil
            tab.webView?.uiDelegate = nil
            tab.webView?.removeFromSuperview()
            tab.webView = nil
            tab.ide?.shutdown()
            NSLayoutConstraint.deactivate(tab.ideConstraints)
            tab.ide?.view.removeFromSuperview()
            tab.ide = nil
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
        // Legacy default-store profiles can share a store. Deleting one must
        // never sign another surviving profile out.
        if !spaces.contains(where: { $0.dataStore === store }) {
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
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
        releasePointerLock()
        dismissTabSwitcher()
        previousTabID = activeTabID
        tabPreview.hide()
        linkPreview?.close()
        let motionSurface = BrowserTabPlacement.current == .horizontal ? horizontalScroll : tabStack.enclosingScrollView
        if let motionSurface { profileMotion.prepare(motionSurface) }
        for tab in tabs where tab.id == activeTabID && !restoringVideoInline {
            captureTabPreview(tab)
            tab.webView?.evaluateJavaScript("window.__webbyFollowPlayingVideo?.()", in: nil,
                                            in: WKContentWorld.world(name: "WebbyVideo"), completionHandler: nil)
        }
        for tab in tabs {
            if !tab.isFloating {
                tab.webView?.evaluateJavaScript("window.__webbyChromeTone?.({enabled:false})",in:nil,in:BrowserChromeTone.world,completionHandler:nil)
                tab.pageView?.isHidden = true
                tab.terminalView?.isHidden = true
                tab.ide?.view.isHidden = true
            }
        }
        splitView?.isHidden = true
        WebbySounds.play("profile-switch")
        activeSpaceIndex = index
        BrowserTheme.activate(activeSpace.saved.id)
        widgetCanvas?.show(profile: activeSpace.saved.id); asciiCanvas?.show(profile: activeSpace.saved.id); wallpaper?.show(profile: activeSpace.saved.id)
        restoreHomeSearchPosition()
        lastWidgetRefresh.removeValue(forKey: activeSpace.saved.id)
        if tabs.isEmpty { _ = restorePinnedTabs() }
        for tab in tabs { tab.terminalView?.applyTheme(BrowserTheme.profile) }
        UserDefaults.standard.set(index, forKey: "browserActiveSpace")
        updateSpaceLabel(animated:true)
        let selected = activeSpace.activeTabID.flatMap { id in tabs.first { $0.id == id && !$0.isFloating } }
            ?? tabs.first(where: { !$0.isFloating })
        activeTabID = nil
        if let selected { selectTab(selected) }
        else { addTab(select: true) }
        motionSurface?.superview?.layoutSubtreeIfNeeded()
        profileMotion.finish(direction:direction)
    }

    private func scheduleSpaceSave() {
        guard !BrowserEngineChecks.active else { return }
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
            alert.messageText = "We couldn’t find any Chrome profiles"
            alert.informativeText = "Let’s open Chrome once, then try again."
            alert.runModal()
            return
        }
        let alert = NSAlert()
        alert.messageText = "Let’s bring your Chrome profiles over"
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
            failure.informativeText = "We didn’t import any profiles. \(error.localizedDescription)"
            failure.runModal()
            return
        }
        importInProgress = true
        pendingSpaceSave?.cancel()
        let oldSpaces = spaces.map(\.saved)
        let progress = NSAlert()
        progress.messageText = "Importing Chrome profiles…"
        progress.informativeText = "We’re reading your bookmarks, history, passwords, and website cookies."
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
            alert.messageText = "We couldn’t import your passwords"
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
            alert.messageText = "We can’t access that Chrome profile"
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
            alert.messageText = "We couldn’t access your Chrome sign-ins"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        let progress = NSAlert()
        progress.messageText = "Importing sign-ins from \(source.name)…"
        progress.informativeText = "We’re reading Chrome’s encrypted cookies."
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
                    alert.messageText = "We couldn’t import your sign-ins"
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
                alert.informativeText = "We haven’t saved any passwords here yet. Let’s import a Chrome password CSV from the menu bar."
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
        if message.name == "browserChromeTone" {
            guard message.frameInfo.isMainFrame, (BrowserTabPlacement.current == .horizontal || BrowserGlass.matchWebsiteEdge),
                  let view=message.webView,let tab=tab(for:view),tab.id == activeTabID,
                  let rgb=(message.body as? [String:Any])?["edge"] as? [Double] ?? message.body as? [Double],rgb.count==3,
                  rgb.allSatisfy({$0.isFinite && (0...255).contains($0)}) else {return}
            let color=NSColor(srgbRed:rgb[0]/255,green:rgb[1]/255,blue:rgb[2]/255,alpha:1)
            if let top=(message.body as? [String:Any])?["top"] as? [Double], top.count==3,
               top.allSatisfy({$0.isFinite && (0...255).contains($0)}) {
                pageAddressColors[tab.id]=NSColor(srgbRed:top[0]/255,green:top[1]/255,blue:top[2]/255,alpha:1)
                updateAddressEdgeBackdrop()
            }
            if pageChromeColors[tab.id] != color {
                pageChromeColors[tab.id]=color
                refreshTabContent(tab)
            }
            return
        }
        if message.name == "browserPageActivity" {
            guard message.body as? String == "edited", let view = message.webView, let tab = tab(for: view) else { return }
            tab.hasUnsavedEdits = true
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

    private func discardLinkPreview() {
        let popover=linkPreview,view=linkPreviewWebView
        linkPreview=nil;linkPreviewWebView=nil;linkPreviewURL=nil;linkPreviewOwnerID=nil
        popover?.delegate=nil;popover?.close();popover?.contentViewController=nil
        view?.evaluateJavaScript("document.querySelectorAll('video,audio').forEach(m=>m.pause())",completionHandler:nil)
        view?.stopLoading();view?.removeFromSuperview()
    }
    func popoverDidClose(_ notification:Notification) {
        if let popover=notification.object as? NSPopover,popover === linkPreview {discardLinkPreview()}
    }
    @objc private func linkGlancesChanged() {
        if !BrowserHoverPreferences.glancesEnabled {discardLinkPreview()}
        for tab in spaces.flatMap(\.tabs)+Array(miniTabs.values) {
            tab.webView?.evaluateJavaScript("window.__webbySetLinkPreviewsEnabled?.(\(BrowserHoverPreferences.glancesEnabled ? "true":"false"));",completionHandler:nil)
        }
    }
    private func showLinkPreview(_ message: WKScriptMessage) {
        guard BrowserHoverPreferences.glancesEnabled,message.frameInfo.isMainFrame,
              let source = message.webView, let tab = tab(for: source), tab.id == activeTabID,
              let body = message.body as? [String: Any],
              let raw = body["url"] as? String, raw.count < 4096,
              let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let x = body["x"] as? Double, let y = body["y"] as? Double,
              x.isFinite, y.isFinite else { return }
        let ownerID = ownerSpace(for: tab).saved.id
        if linkPreviewOwnerID != ownerID {
            discardLinkPreview()
            let config = WKWebViewConfiguration()
            config.websiteDataStore = ownerSpace(for: tab).dataStore
            GlassPageInjector.install(into: config)
            let view = WKWebView(frame: .zero, configuration: config)
            GlassPageInjector.makeWebViewTransparent(view)
            view.translatesAutoresizingMaskIntoConstraints = false
            let backdrop = WebbyGlassBackdrop(frame: NSRect(x: 0, y: 0, width: 470, height: 335))
            backdrop.material = .popover
            backdrop.blendingMode = .behindWindow
            backdrop.state = .active
            let host = NSViewController()
            host.view = backdrop
            let title = NSTextField(labelWithString: "Link Preview")
            title.translatesAutoresizingMaskIntoConstraints = false
            title.font = WebbyTypography.font(ofSize: 12, weight: .medium)
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
            popover.delegate = self
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
        tab.currentNavigation = makeWebView(for: tab).load(URLRequest(url: url))
    }

    @objc private func fillSavedPasswordForCurrentSite() {
        guard let tab = activeTab, let url = tab.pageURL,
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else {
            let alert = NSAlert()
            alert.messageText = "Open a secure website first"
            alert.informativeText = "Saved passwords can only fill on an HTTPS site with a matching website address."
            alert.runModal()
            return
        }
        let matches = passwordLookup(ownerSpace(for: tab).saved.id, host)
        guard !matches.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No password for \(host)"
            alert.informativeText = "Import a password CSV into \(activeSpace.saved.name). The URL in each entry determines its website."
            alert.runModal()
            return
        }
        if matches.count == 1 { fill(matches[0], in: tab); return }
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
        fill(matches[picker.indexOfSelectedItem], in: tab)
    }

    private func fill(_ credential: BrowserCredential, in webView: WKWebView) {
        guard let url = webView.url, let script = BrowserPasswordFill.script(for: credential, at: url) else { return }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    private func fill(_ credential: BrowserCredential, in tab: BrowserTab) {
        guard let url = tab.pageURL, let origin = BrowserPasswordFill.origin(for: url),
              let script = BrowserPasswordFill.script(for: credential, at: url) else { return }
        if let page = tab.chromiumView { _ = page.runScript(script, expectedOrigin: origin) }
        else if let view = tab.webView { view.evaluateJavaScript(script, completionHandler: nil) }
    }

    private func autofillChromiumPassword(_ tab: BrowserTab, page: WBChromiumView) {
        guard self.tab(id: tab.id) === tab, tab.id == activeTabID, tab.chromiumView === page,
              !page.loading, let url = tab.pageURL, BrowserPasswordFill.origin(for: url) != nil,
              let host = url.host?.lowercased() else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let remaining = 0.5 - (now - tab.lastPasswordProbeAt)
        if remaining > 0 {
            tab.passwordProbePending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self, weak tab, weak page] in
                guard let self, let tab, let page, tab.passwordProbePending else { return }
                self.autofillChromiumPassword(tab, page: page)
            }
            return
        }
        tab.passwordProbePending = false
        tab.lastPasswordProbeAt = now
        let profile = ownerSpace(for: tab).saved.id
        let matches = passwordLookup(profile, host)
        guard matches.count == 1, tab.chromiumView === page, tab.id == activeTabID,
              ownerSpace(for: tab).saved.id == profile,
              tab.pageURL.flatMap(BrowserPasswordFill.origin(for:)) == BrowserPasswordFill.origin(for: url) else { return }
        fill(matches[0], in: tab)
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
        tab.currentNavigation = view.loadHTMLString(libraryHTML(title: heading, links: links), baseURL: nil)
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
        let selectionStarted = ProcessInfo.processInfo.systemUptime
        let previousSelection = activeTabID
        if !restoringPinnedSplit, tab.savedSplit != nil,
           splitTabIDs?.contains(tab.id) != true {
            openPinnedSplit(tab)
            return
        }
        if pointerLockedWebView !== tab.webView { releasePointerLock() }
        recentTabOrder.removeAll { $0 == tab.id }
        recentTabOrder.insert(tab.id, at: 0)
        tabPreview.hide()
        findBar?.isHidden = true
        if !tab.isTerminal && (tab.suspendedURL != nil || tab.pinnedInstanceClosed) {
            resumeTab(tab, show: true)
        }
        if tab.isFloating {
            floatingWindows[tab.id]?.makeKeyAndOrderFront(nil)
            return
        }
        guard tabs.contains(where: { $0.id == tab.id }) else { return }
        if activeTabID == tab.id {
            returnVideoInline(tab)
            return
        }
        // A newly selected page must never inherit a previous page's spring position.
        Motion.interact(pageArea)
        if tab.pageView == nil || tab.showsSearchView { if let homeCenter { Motion.interact(homeCenter) } }
        if let view = tab.webView { Motion.interact(view) }
        closeSuggestions()
        linkPreview?.close()
        if let previous = activeTab, previous.id != tab.id {
            previous.webView?.evaluateJavaScript("window.__webbyChromeTone?.({enabled:false})",in:nil,in:BrowserChromeTone.world,completionHandler:nil)
            previousTabID = previous.id
            previous.lastActiveAt = Date()
            captureTabPreview(previous)
            if !restoringVideoInline {
                previous.webView?.evaluateJavaScript("window.__webbyFollowPlayingVideo?.()", in: nil,
                    in: WKContentWorld.world(name: "WebbyVideo"), completionHandler: nil)
            }
        }
        if let previous = activeTab, (previous.pageView == nil || previous.showsSearchView) && !previous.isTerminal {
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
        tab.lastActiveAt = Date()
        if BrowserExperiment.cyclesNewTabProfiles {
            displaySpace(for: tab).activeTabID = tab.id
            if let index = spaces.firstIndex(where: { $0.saved.id == ownerSpace(for: tab).saved.id }) {
                let changedProfile = activeSpaceIndex != index
                activeSpaceIndex = index
                BrowserTheme.activate(activeSpace.saved.id)
                if changedProfile {
                    widgetCanvas?.show(profile: activeSpace.saved.id); asciiCanvas?.show(profile: activeSpace.saved.id); wallpaper?.show(profile: activeSpace.saved.id)
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
        let showsSplit = splitTabIDs?.contains(tab.id) ?? false
        splitView?.isHidden = !showsSplit
        for item in tabs {
            if item.isFloating { continue }
            let inSplit = splitTabIDs?.contains(item.id) ?? false
            if let view = item.pageView {
                let hidden = inSplit ? !showsSplit : item.id != tab.id
                if view.isHidden != hidden { view.isHidden = hidden }
                let alpha: CGFloat = item.id == tab.id && item.showsSearchView ? 0.001 : 1
                if view.alphaValue != alpha { view.alphaValue = alpha }
            }
        }
        homeView.isHidden = showsSplit || (tab.pageView != nil && !tab.showsSearchView) || tab.isTerminal
        if !homeView.isHidden { refreshGoogleWidgets() }
        for item in tabs {
            item.terminalView?.isHidden = item.id != tab.id || !tab.isTerminal
            item.ide?.view.isHidden = (splitTabIDs?.contains(item.id) ?? false) ? !showsSplit : item.id != tab.id
        }
        homeSearchSurface.isHidden = false
        loadErrorLabel.stringValue = tab.loadError ?? ""
        loadErrorLabel.isHidden = tab.loadError == nil
        if (tab.pageView == nil || tab.showsSearchView) && !tab.isTerminal { showCurrentIndicator() }
        else { globe.engine.hide() }
        applyAddressChrome()
        if let view = tab.webView, view.isLoading { toolbar.setProgress(min(view.estimatedProgress, 0.96)) }
        addressField.stringValue = tab.pageURL.map(displayAddress) ?? ""
        homeSearchField.stringValue = tab.searchDraft
        if tab.showsSearchView, let view = tab.webView, view.isLoading {
            homeSearchSurface.startLoading()
            homeSearchSurface.setLoadingProgress(view.estimatedProgress)
        } else { homeSearchSurface.stopLoading() }
        updateNavigation()
        content.layoutSubtreeIfNeeded()
        for id in showsSplit ? (splitTabIDs ?? []) : [tab.id] {
            if let visibleTab = self.tab(id: id) { returnVideoInline(visibleTab) }
        }
        refreshTabSelection(previousID: previousSelection)
        tabSwitchTimes.append((ProcessInfo.processInfo.systemUptime-selectionStarted)*1000)
        if tabSwitchTimes.count > 200 { tabSwitchTimes.removeFirst() }
        if let view = tab.webView { window.makeFirstResponder(view) }
        else if let chromium = tab.chromiumView { chromium.focusPage() }
        else if let ide = tab.ide { ide.show() }
        else if tab.isTerminal {
            let pane = terminalPane(for: tab)
            pane.isHidden = false
            pane.open()
        }
        else { window.makeFirstResponder(homeSearchField) }

    }

    fileprivate func showTabPreview(for id: UUID, from row: NSView) {
        guard let tab = tab(id: id), row.window === window else { return }
        let address = tab.isTerminal ? (tab.ide == nil ? "Terminal" : "IDE") :
            (tab.pageURL.map(displayAddress) ?? (tab.searchDraft.isEmpty ? "New Tab" : tab.searchDraft))
        tabPreview.show(tabID: id, title: tab.title, address: address,
                        image: tab.previewImage, from: row, preferredEdge: (row as? TabRow)?.horizontal == true ? .minY : .maxX)
        if tab.id == activeTabID { captureTabPreview(tab) }
    }

    fileprivate func hideTabPreview(for id: UUID) { tabPreview.hide(for: id) }

    private func captureTabPreview(_ tab: BrowserTab) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !tab.previewCaptureInFlight, now - tab.previewCapturedAt > 8,
              !tab.showsSearchView, !tab.navigationInProgress,
              let webView = tab.webView, !webView.isHidden, webView.alphaValue > 0.5,
              webView.bounds.width >= 100, webView.bounds.height >= 80 else { return }
        tab.previewCapturedAt = now
        tab.previewCaptureInFlight = true
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0,
                                    width: min(webView.bounds.width, 850),
                                    height: min(webView.bounds.height, 500))
        let capturedURL = webView.url
        let tabID = tab.id
        let generation = tab.previewGeneration
        webView.takeSnapshot(with: configuration) { [weak self, weak webView, weak tab] image, _ in
            DispatchQueue.main.async {
                defer { tab?.previewCaptureInFlight = false }
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
        let visible = tabs.filter { !(splitTabIDs?.contains($0.id) ?? false) || $0.id == splitRepresentativeID }
        return visible.filter(\.isPinned) + visible.filter { tab in
            guard !tab.isPinned, let groupID = tab.groupID,
                  let group = tabGroups.first(where: { $0.id == groupID }) else { return !tab.isPinned }
            return !group.collapsed
        }
    }

    private var visibleTabGroups: [TabGroupRecord] {
        tabGroups.filter { group in
            BrowserExperiment.cyclesNewTabProfiles || group.profileID == activeSpace.saved.id || activeSpace.tabs.contains{$0.groupID==group.id}
        }
    }

    @objc private func tabSettingsFromEmptySpace(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended else { return }
        showTabSettings(at: gesture.location(in: tabSpacer), in: tabSpacer)
    }

    private func showTabSettings(at point: NSPoint, in view: NSView) {
        guard let menu = menuBar?.makeTabSettingsMenu() else { return }
        menu.addItem(.separator())
        let group = menu.addItem(withTitle: "New Tab Group", action: #selector(createGroupFromEmptySpace), keyEquivalent: "")
        group.target = self
        menu.popUp(positioning: nil, at: point, in: view)
    }

    @objc private func createGroupFromEmptySpace() {
        rememberLayout()
        let group = TabGroupRecord(id: UUID(), profileID: activeSpace.saved.id, name: "New Group", collapsed: false)
        let member = BrowserTab()
        member.ownerSpaceID = activeSpace.saved.id
        member.groupID = group.id
        tabs.append(member)
        tabGroups.append(group)
        saveTabGroups()
        refreshTabs()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            (BrowserTabPlacement.current == .horizontal ? self.horizontalGroups[group.id] : self.groupHeaders[group.id])?.focusName()
        }
    }

    private func commandGroupTab(_ id:UUID,with source:BrowserTab?=nil,focusName:Bool=true) {
        tabPreview.hide()
        guard let clicked=tab(id:id),!clicked.isFloating else{return}
        guard !clicked.isPinned else {selectTab(clicked);return}
        let current=(source ?? activeTab).flatMap{!$0.isPinned && !$0.isFloating ? $0:nil}
        func unit(_ tab:BrowserTab)->[BrowserTab] {
            if splitTabIDs?.contains(tab.id)==true {return (splitTabIDs ?? []).compactMap{self.tab(id:$0)}.filter{!$0.isPinned && !$0.isFloating}}
            return [tab]
        }
        var members=unit(clicked)
        if let current {members += unit(current)}
        var seen=Set<UUID>();members=members.filter{seen.insert($0.id).inserted}
        let existing=(current?.groupID ?? clicked.groupID).flatMap{id in tabGroups.first{$0.id==id}}
        if let existing,members.allSatisfy({$0.groupID==existing.id}) {return}
        rememberLayout()
        let websiteName=commonSiteName(members)
        let group=existing ?? TabGroupRecord(id:UUID(),profileID:current.map{ownerSpace(for:$0).saved.id} ?? ownerSpace(for:clicked).saved.id,name:websiteName ?? "New Group",collapsed:false,automaticName:websiteName != nil)
        if existing==nil {tabGroups.append(group)}
        let previous=Set(members.compactMap(\.groupID)).subtracting([group.id])
        for member in members {member.groupID=group.id}
        if let index=tabGroups.firstIndex(where:{$0.id==group.id}) {
            tabGroups[index].collapsed=false
            if tabGroups[index].automaticName==nil && tabGroups[index].name=="New Group" {tabGroups[index].automaticName=true}
        }
        // Moving the last member must not leave an empty glass shell behind.
        tabGroups.removeAll{old in previous.contains(old.id) && !spaces.flatMap(\.tabs).contains{$0.groupID==old.id}}
        updateAutomaticGroupName(group.id)
        saveTabGroups();refreshTabs()
        if current==nil && focusName {selectTab(clicked)}
        if existing==nil && focusName && websiteName==nil {
            DispatchQueue.main.async { [weak self] in
                guard let self else{return}
                let header=BrowserTabPlacement.current == .horizontal ? self.horizontalGroups[group.id]:self.groupHeaders[group.id]
                if let header {Motion.reveal(header,character:.tabs);header.focusName()}
            }
        }
    }

    private func siteHost(_ tab:BrowserTab)->String? {
        let candidates=[tab.pageURL,tab.suspendedURL,URL(string:tab.searchDraft)]
        guard let host=candidates.compactMap({$0?.host?.lowercased()}).first else{return nil}
        return host.hasPrefix("www.") ? String(host.dropFirst(4)):host
    }
    private func commonSiteName(_ members:[BrowserTab])->String? {
        guard let first=members.first,let host=siteHost(first),members.allSatisfy({siteHost($0)==host}) else{return nil}
        if let name=members.compactMap(\.siteName).first,!name.isEmpty {return name}
        let known=["chatgpt.com":"ChatGPT","youtube.com":"YouTube","github.com":"GitHub","google.com":"Google","mail.google.com":"Gmail","calendar.google.com":"Google Calendar","docs.google.com":"Google Docs"]
        return known[host] ?? host
    }
    private func updateAutomaticGroupName(_ id:UUID) {
        guard let index=tabGroups.firstIndex(where:{$0.id==id}),tabGroups[index].automaticName==true else{return}
        let members=spaces.flatMap(\.tabs).filter{$0.groupID==id && !$0.isPinned}
        let name=commonSiteName(members) ?? "Tab Group"
        if tabGroups[index].name != name {tabGroups[index].name=name;saveTabGroups()}
    }
    private func groupBackgroundLink(_ opened:BrowserTab,from source:BrowserTab,url:URL) {
        guard !source.isFloating,let host=url.host?.lowercased() else{return}
        let normalized=host.hasPrefix("www.") ? String(host.dropFirst(4)):host
        guard siteHost(source)==normalized else{return}
        commandGroupTab(opened.id,with:source,focusName:false)
    }
    private func readSiteName(_ tab:BrowserTab,view:WKWebView) {
        let generation=tab.navigationTiming.id
        view.evaluateJavaScript("(document.querySelector('meta[property=\"og:site_name\"],meta[name=\"application-name\"]')?.content || '').trim().slice(0,80)",in:nil,in:BrowserPageActivity.world) { [weak self,weak tab,weak view] result in
            guard let self,let tab,tab.webView === view,tab.navigationTiming.id==generation else{return}
            if case .success(let value)=result,let name=value as? String,!name.isEmpty {tab.siteName=name.components(separatedBy:.whitespacesAndNewlines).filter{!$0.isEmpty}.joined(separator:" ")}
            if let id=tab.groupID,self.tabGroups.first(where:{$0.id==id})?.automaticName==true {
                self.updateAutomaticGroupName(id);self.refreshTabs()
            }
        }
    }

    private func saveTabGroups() {
        UserDefaults.standard.set(try? JSONEncoder().encode(tabGroups), forKey: "webbyTabGroups")
        scheduleSessionSave()
    }

    private func addTab(_ id: UUID, toGroup groupID: UUID) {
        guard let tab = tab(id: id), !tab.isPinned,
              let index = tabGroups.firstIndex(where: { $0.id == groupID }) else { return }
        rememberLayout()
        tab.groupID = groupID
        tabGroups[index].collapsed = false
        saveTabGroups()
        refreshTabs()
    }

    fileprivate func appendGroupItem(for tabID: UUID, to menu: NSMenu) {
        guard let tab=tab(id:tabID),!tab.isPinned else{return}
        let group=menu.addItem(withTitle:"Group with Current Tab",action:#selector(groupWithCurrent(_:)),keyEquivalent:"")
        group.target=self;group.representedObject=tabID
        guard tab.groupID != nil else {return}
        let item = menu.addItem(withTitle: "Remove from Group", action: #selector(removeTabFromGroup(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = tabID
    }

    @objc private func groupWithCurrent(_ sender:NSMenuItem) {if let id=sender.representedObject as? UUID {commandGroupTab(id)}}

    @objc private func removeTabFromGroup(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tab(id: id) else { return }
        rememberLayout()
        tab.groupID = nil
        scheduleSessionSave()
        refreshTabs()
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

    private func buildHorizontalTabs() {
        horizontalScroll = NSScrollView()
        horizontalScroll.drawsBackground = false
        horizontalScroll.scrollerStyle = .overlay
        horizontalScroll.hasHorizontalScroller = true
        horizontalScroll.autohidesScrollers = true
        horizontalScroll.translatesAutoresizingMaskIntoConstraints = false
        horizontalStack = NSStackView()
        horizontalStack.orientation = .horizontal
        horizontalStack.alignment = .bottom
        horizontalStack.spacing = 0
        horizontalStack.translatesAutoresizingMaskIntoConstraints = false
        horizontalScroll.documentView = horizontalStack
        let emptyDoubleClick = NSClickGestureRecognizer(target: self, action: #selector(horizontalEmptyDoubleClick(_:)))
        emptyDoubleClick.numberOfClicksRequired = 2
        emptyDoubleClick.delaysPrimaryMouseButtonEvents = false
        horizontalScroll.addGestureRecognizer(emptyDoubleClick)
        mainArea.addSubview(horizontalScroll)
        horizontalProfile = NSButton(title: activeSpace.saved.name, target: self, action: #selector(horizontalProfileMenu(_:)))
        horizontalProfile.isBordered = false
        horizontalProfile.font = WebbyTypography.font(ofSize: 12, weight: .semibold)
        horizontalProfile.contentTintColor = .white
        horizontalProfile.translatesAutoresizingMaskIntoConstraints = false
        mainArea.addSubview(horizontalProfile)
        let add = NSButton(title: "+", target: self, action: #selector(newTabAction))
        add.isBordered = false; add.font = WebbyTypography.font(ofSize: 23, weight: .light)
        add.contentTintColor = .white; add.translatesAutoresizingMaskIntoConstraints = false
        add.identifier = NSUserInterfaceItemIdentifier("horizontalNewTab")
        mainArea.addSubview(add)
        horizontalTabsTrailing = horizontalScroll.trailingAnchor.constraint(equalTo: add.leadingAnchor)
        NSLayoutConstraint.activate([
            horizontalProfile.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor, constant: 8),
            horizontalProfile.centerYAnchor.constraint(equalTo: horizontalScroll.centerYAnchor),
            horizontalProfile.widthAnchor.constraint(equalToConstant: 92), horizontalProfile.heightAnchor.constraint(equalToConstant: 34),
            horizontalScroll.leadingAnchor.constraint(equalTo: horizontalProfile.trailingAnchor),
            horizontalTabsTrailing,
            horizontalScroll.topAnchor.constraint(equalTo: mainArea.topAnchor, constant: 6),
            horizontalScroll.heightAnchor.constraint(equalToConstant: 38),
            horizontalStack.heightAnchor.constraint(equalToConstant: 38),
            horizontalStack.leadingAnchor.constraint(equalTo: horizontalScroll.contentView.leadingAnchor),
            horizontalStack.topAnchor.constraint(equalTo: horizontalScroll.contentView.topAnchor),
            add.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor, constant: -8),
            add.centerYAnchor.constraint(equalTo: horizontalScroll.centerYAnchor),
            add.widthAnchor.constraint(equalToConstant: 34), add.heightAnchor.constraint(equalToConstant: 34)
        ])
        configureHorizontalTabs()
    }

    @objc private func horizontalEmptyDoubleClick(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let point = horizontalScroll.convert(gesture.location(in: horizontalScroll), to: horizontalStack)
        if horizontalStack.arrangedSubviews.contains(where: { !$0.isHidden && $0.frame.contains(point) }) { return }
        showTabSettings(at: gesture.location(in: horizontalScroll), in: horizontalScroll)
    }

    @objc private func horizontalProfileMenu(_ sender: NSButton) {
        let menu = NSMenu()
        let fuse = menu.addItem(withTitle: "Fuse", action: #selector(toggleHorizontalFuse), keyEquivalent: "")
        fuse.target = self; fuse.state = BrowserExperiment.cyclesNewTabProfiles ? .on : .off
        for (index, space) in spaces.enumerated() {
            let item = menu.addItem(withTitle: space.saved.name, action: #selector(selectHorizontalProfile(_:)), keyEquivalent: "")
            item.target = self; item.tag = index; item.state = activeSpaceIndex == index ? .on : .off
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.minY), in: sender)
    }
    @objc private func selectHorizontalProfile(_ item: NSMenuItem) { switchToSpace(item.tag) }
    @objc private func toggleHorizontalFuse() { BrowserExperiment.cyclesNewTabProfiles.toggle(); experimentalModeChanged() }

    private func configureHorizontalTabs() {
        let moving = (homeView?.isHidden == false ? [sidebar] : [pageArea, websiteFrameShadow, websiteFrameRim, sidebar]).compactMap { $0 }
        let layoutGeometry = buildingFirstWindow ? Motion.Geometry.empty : Motion.capture(moving, in: content)
        let previousLayout = horizontalScroll?.isHidden
        defer {
            if let previousLayout, previousLayout != horizontalScroll?.isHidden {
                Motion.settle(layoutGeometry, views: moving, in: content, character: .split)
            }
        }
        defer {applyWallpaperPresentation()}
        guard horizontalScroll != nil else { return }
        let horizontal = BrowserTabPlacement.current == .horizontal
        if horizontalScroll.isHidden { horizontalSelection = nil }
        if tabsPeekVisible && (peekHorizontal != horizontal || !tabsHiddenByUser) {tabsPeekVisible=false;tabsRetreating=false;tabsPeekToken+=1;tabsRetreatTimer?.invalidate()}
        sidebarToggleButton?.isHidden = horizontal
        applyHiddenChromeLayout()
        if horizontal { refreshHorizontalTabs() }
        if let view=activeWebView {updateGlassTone(for:view)}
    }

    private func horizontalTabColor(_ tab:BrowserTab,row:TabRow)->NSColor {
        if tab.id==activeTabID,homeView?.isHidden==false,let wallpaper {
            if windowStyle.hasColor { return windowStyle.representativeColor }
            let point=wallpaper.convert(row.convert(NSPoint(x:row.bounds.midX,y:0),to:nil),from:nil)
            if let color=wallpaper.chromeColor(at:point) {return color}
            return NSColor(white:0.13,alpha:1)
        }
        return pageChromeColors[tab.id] ?? (tab.prefersDarkGlass ? NSColor(white:0.13,alpha:1):.white)
    }
    private func updateSidebarEdgeBackdrop() {
        guard sidebar != nil, sidebarBackdrop != nil else { return }
        let matching = !windowStyle.hasColor && BrowserGlass.matchWebsiteEdge && homeView?.isHidden == true && BrowserTabPlacement.current != .horizontal
        guard matching, let active = activeTab else {
            sidebarEdgeBackdrop?.isHidden = true
            let light = windowStyle.hasColor && windowStyle.usesDarkText
            sidebar.appearance = windowStyle.hasColor ? NSAppearance(named: light ? .aqua : .darkAqua) : nil
            for row in tabRows.values { row.titleButton.contentTintColor = light ? .black : .white }
            return
        }
        if sidebarEdgeBackdrop == nil {
            let backdrop = NSView()
            backdrop.wantsLayer = true; backdrop.translatesAutoresizingMaskIntoConstraints = false
            sidebar.addSubview(backdrop, positioned: .above, relativeTo: sidebarBackdrop)
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),
                backdrop.topAnchor.constraint(equalTo: sidebar.topAnchor),
                backdrop.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
            ])
            sidebarEdgeBackdrop = backdrop
        }
        var color = pageChromeColors[active.id] ?? (active.prefersDarkGlass ? NSColor(white:0.13,alpha:1) : .white)
        if homeView?.isHidden == false, let wallpaper {
            let point = wallpaper.convert(sidebar.convert(NSPoint(x:sidebar.bounds.maxX,y:sidebar.bounds.midY),to:nil),from:nil)
            color = wallpaper.chromeColor(at:point) ?? NSColor(white:0.13,alpha:1)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        Motion.color(sidebarEdgeBackdrop?.layer, to: color.cgColor, animate: sidebarEdgeBackdrop?.isHidden == false && window.occlusionState.contains(.visible))
        sidebarEdgeBackdrop?.isHidden = false
        CATransaction.commit()
        let rgb = color.usingColorSpace(.deviceRGB) ?? .black
        let light = rgb.redComponent*0.2126 + rgb.greenComponent*0.7152 + rgb.blueComponent*0.0722 > 0.55
        sidebar.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        for row in tabRows.values { row.titleButton.contentTintColor = light ? .black : .white }
    }

    /// Reserved address-header space follows the page's top edge, independently
    /// of the left-edge color used by a vertical sidebar. Homepage keeps wallpaper.
    private func updateAddressEdgeBackdrop() {
        guard mainArea != nil, pageArea != nil, addressChromeReady else { return }
        let visible = !windowStyle.hasColor && BrowserGlass.matchWebsiteEdge && homeView?.isHidden == true
            && toolbar.superview === mainArea && !toolbar.isHidden
        guard visible, let tab=activeTab else {addressEdgeBackdrop?.isHidden=true;toolbar.appearance=nil;return}
        if addressEdgeBackdrop == nil {
            let backdrop=NSView();backdrop.wantsLayer=true;backdrop.translatesAutoresizingMaskIntoConstraints=false
            mainArea.addSubview(backdrop,positioned:.below,relativeTo:pageArea)
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo:mainArea.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo:mainArea.trailingAnchor),
                backdrop.topAnchor.constraint(equalTo:mainArea.topAnchor),
                backdrop.bottomAnchor.constraint(equalTo:pageArea.topAnchor)
            ])
            addressEdgeBackdrop=backdrop
        }
        let color=pageAddressColors[tab.id] ?? pageChromeColors[tab.id]
            ?? (tab.prefersDarkGlass ? NSColor(white:0.13,alpha:1):.white)
        Motion.color(addressEdgeBackdrop?.layer,to:color.cgColor,
                     animate:addressEdgeBackdrop?.isHidden == false && window.occlusionState.contains(.visible))
        addressEdgeBackdrop?.isHidden=false
        let rgb=color.usingColorSpace(.deviceRGB) ?? .black
        let light=rgb.redComponent*0.2126+rgb.greenComponent*0.7152+rgb.blueComponent*0.0722>0.55
        toolbar.appearance=NSAppearance(named:light ? .aqua:.darkAqua)
    }

    private func updateWebsiteEdgeBackdrop() {
        updateAddressEdgeBackdrop()
        guard mainArea != nil, horizontalScroll != nil else { return }
        updateSidebarEdgeBackdrop()
        updateWebsiteFrameRim()
        let visible = !windowStyle.hasColor && BrowserGlass.matchWebsiteEdge && homeView?.isHidden == true
            && BrowserTabPlacement.current == .horizontal && !horizontalScroll.isHidden
        guard visible, let tab = activeTab else {
            websiteEdgeBackdrop?.isHidden = true
            let tint: NSColor = windowStyle.hasColor && windowStyle.usesDarkText ? .black : .white
            horizontalProfile?.contentTintColor = tint
            (mainArea.subviews.first { $0.identifier?.rawValue == "horizontalNewTab" } as? NSButton)?.contentTintColor = tint
            return
        }
        if websiteEdgeBackdrop == nil {
            let backdrop = NSView()
            backdrop.wantsLayer = true
            backdrop.translatesAutoresizingMaskIntoConstraints = false
            mainArea.addSubview(backdrop, positioned: .below, relativeTo: horizontalScroll)
            NSLayoutConstraint.activate([
                backdrop.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor),
                backdrop.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor),
                backdrop.topAnchor.constraint(equalTo: mainArea.topAnchor),
                backdrop.heightAnchor.constraint(equalToConstant: 44)
            ])
            websiteEdgeBackdrop = backdrop
        }
        let rowID = splitTabIDs?.contains(tab.id) == true ? splitRepresentativeID ?? tab.id : tab.id
        let color = horizontalRows[rowID].map { horizontalTabColor(tab, row: $0) }
            ?? pageChromeColors[tab.id] ?? NSColor(white: 0.13, alpha: 1)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        Motion.color(websiteEdgeBackdrop?.layer, to: color.cgColor, animate: websiteEdgeBackdrop?.isHidden == false && window.occlusionState.contains(.visible))
        websiteEdgeBackdrop?.isHidden = false
        CATransaction.commit()
        let rgb = color.usingColorSpace(.deviceRGB) ?? .black
        let light = rgb.redComponent * 0.2126 + rgb.greenComponent * 0.7152 + rgb.blueComponent * 0.0722 > 0.55
        horizontalProfile.contentTintColor = light ? .black : .white
        mainArea.subviews.first { $0.identifier?.rawValue == "horizontalNewTab" }.map { ($0 as? NSButton)?.contentTintColor = light ? .black : .white }
        let pinnedIDs = Set(tabs.lazy.filter(\.isPinned).map(\.id))
        for view in horizontalRows.values where view.tabID != rowID {
            // Reuse the active edge color for legible inactive labels as well.
            view.setHorizontal(pinned: pinnedIDs.contains(view.tabID), color: color)
        }
    }

    private func updateWebsiteFrameRim() {
        guard pageFrameInset > 0, !windowStyle.hasColor, BrowserGlass.matchWebsiteEdge,
              homeView?.isHidden == true, let tab = activeTab else {
            websiteFrameRim?.isHidden = true
            return
        }
        let rim: WebsiteFrameRim
        if let existing = websiteFrameRim {
            rim = existing
        } else {
            let inset = Self.websiteInset
            rim = WebsiteFrameRim(inset: inset)
            rim.isHidden = true
            rim.translatesAutoresizingMaskIntoConstraints = false
            mainArea.addSubview(rim, positioned: .below, relativeTo: websiteFrameShadow)
            NSLayoutConstraint.activate([
                rim.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor, constant: -inset),
                rim.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor, constant: inset),
                rim.topAnchor.constraint(equalTo: pageArea.topAnchor, constant: -inset),
                rim.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor, constant: inset)
            ])
            websiteFrameRim = rim
        }
        let edge = pageChromeColors[tab.id] ?? (tab.prefersDarkGlass ? NSColor(white: 0.13, alpha: 1) : .white)
        Motion.color(rim.layer, key: "fillColor", to: edge.withAlphaComponent(1).cgColor,
                     animate: !rim.isHidden && window.occlusionState.contains(.visible))
        rim.isHidden = false
    }

    private var windowChromeTint: NSColor? {
        guard windowStyle.hasColor else { return nil }
        return windowStyle.usesDarkText ? .black : .white
    }

    private func refreshHomeTabColor() {
        if BrowserTabPlacement.current != .horizontal { updateWebsiteEdgeBackdrop(); return }
        guard BrowserTabPlacement.current == .horizontal,homeView?.isHidden==false,let tab=activeTab,let row=horizontalRows[tab.id] else{return}
        row.setHorizontal(pinned:tab.isPinned,color:horizontalTabColor(tab,row:row),chromeTint:windowChromeTint)
        updateWebsiteEdgeBackdrop()
    }
    private func refreshHorizontalTabs() {
        defer { updateWebsiteEdgeBackdrop() }
        guard !defersTabRefresh else{return}
        guard horizontalStack != nil, BrowserTabPlacement.current == .horizontal else { return }
        horizontalProfile.title = BrowserExperiment.cyclesNewTabProfiles ? "Fuse · " + activeSpace.saved.name : activeSpace.saved.name
        let visible = tabs.filter{!(splitTabIDs?.contains($0.id) ?? false) || $0.id==splitRepresentativeID}.filter { tab in
            guard !tab.isPinned,let id=tab.groupID,tabGroups.first(where:{$0.id==id})?.collapsed==true else{return true}
            return horizontalRows[tab.id] != nil
        }
        let valid = Set(visible.map(\.id))
        for (id, row) in horizontalRows where !valid.contains(id) {
            if horizontalStack.arrangedSubviews.contains(row) {horizontalStack.removeArrangedSubview(row)};if let parent=row.superview as? NSStackView,parent.arrangedSubviews.contains(row) {parent.removeArrangedSubview(row)};row.removeFromSuperview()
            horizontalWidths.removeValue(forKey: id)?.isActive = false
            horizontalRows.removeValue(forKey: id)
        }
        let groups = visibleTabGroups, groupIDs = Set(groups.map(\.id))
        for (id, header) in horizontalGroups where !groupIDs.contains(id) {
            if let container=horizontalGroupContainers.removeValue(forKey:id) {horizontalStack.removeArrangedSubview(container);container.removeFromSuperview()}
            header.removeFromSuperview();horizontalGroups.removeValue(forKey:id)
        }
        var ordered: [NSView] = []
        func append(_ tab: BrowserTab, standalone:Bool=true) {
            let row = horizontalRows[tab.id] ?? TabRow(tabID: tab.id, target: self)
            horizontalRows[tab.id] = row
            if horizontalWidths[tab.id]==nil {
                let width = row.widthAnchor.constraint(equalToConstant: tab.isPinned ? 48 : 210)
                width.isActive = true; horizontalWidths[tab.id] = width
            }
            horizontalWidths[tab.id]?.constant = tab.isPinned ? 48 : 210
            updateTabPresentation(tab, row: row)
            row.setHorizontal(pinned:tab.isPinned,color:horizontalTabColor(tab,row:row),chromeTint:windowChromeTint)
            if standalone {
                if row.superview !== horizontalStack {if let parent=row.superview as? NSStackView,parent.arrangedSubviews.contains(row) {parent.removeArrangedSubview(row)};row.removeFromSuperview();horizontalStack.addArrangedSubview(row)}
                ordered.append(row)
            }
        }
        for tab in visible.filter(\.isPinned) { append(tab) }
        for tab in visible where !tab.isPinned && (tab.groupID == nil || !groupIDs.contains(tab.groupID!)) { append(tab) }
        for group in groups {
            let header = horizontalGroups[group.id] ?? TabGroupHeader(groupID: group.id)
            horizontalGroups[group.id] = header
            header.configure(name:group.name,collapsed:group.collapsed,count:tabs.filter{$0.groupID==group.id && !$0.isPinned}.count,profile:BrowserTheme.profile(for:group.profileID))
            if let original = groupHeaders[group.id] {
                header.onRename = original.onRename; header.onToggle = original.onToggle
                header.onDrop = original.onDrop; header.onDelete = original.onDelete
            }
            let container=horizontalGroupContainers[group.id] ?? TabGroupContainer(header:header,horizontal:true)
            horizontalGroupContainers[group.id]=container
            if container.superview !== horizontalStack {horizontalStack.addArrangedSubview(container)}
            let grouped=visible.filter{!$0.isPinned && $0.groupID==group.id}
            for tab in grouped {append(tab,standalone:false)}
            container.setMembers(grouped.compactMap{horizontalRows[$0.id]},collapsed:group.collapsed)
            ordered.append(container)
        }
        for (index, view) in ordered.enumerated() where horizontalStack.arrangedSubviews.firstIndex(of: view) != index {
            horizontalStack.removeArrangedSubview(view); view.removeFromSuperview(); horizontalStack.insertArrangedSubview(view, at: min(index, horizontalStack.arrangedSubviews.count))
        }
        horizontalStack.layoutSubtreeIfNeeded()
        if horizontalSelection != activeTabID, let id = activeTabID, let row = horizontalRows[id] {
            horizontalSelection = id; horizontalStack.scrollToVisible(row.convert(row.bounds,to:horizontalStack))
        }
    }

    private func updateTabPresentation(_ tab: BrowserTab, row: TabRow) {
        row.setRenderingEngine(tab.isTerminal || tab.ide != nil ? nil : tab.engine)
        let ownerName = ownerSpace(for: tab).saved.name
        var displayTitle = tab.ownerSpaceID == activeSpace.saved.id
            ? tab.title : "\(tab.title)  ·  \(ownerName)"
        if splitRepresentativeID == tab.id {
            for otherID in splitTabIDs?.filter({ $0 != tab.id }) ?? [] {
                if let other = self.tab(id: otherID) { displayTitle += "  │  \(other.title)" }
            }
        }
        if tab.isFloating { displayTitle += "  ↗" }
        let isSelected = tab.id == activeTabID ||
            (splitRepresentativeID == tab.id && (splitTabIDs?.contains(activeTabID ?? UUID()) ?? false))
        let splitFavicons: [NSImage?]? = splitRepresentativeID == tab.id
            ? splitTabIDs?.map { self.tab(id: $0)?.favicon }
            : (tab.savedSplit != nil ? tab.savedSplitTabIDs.map { self.tab(id: $0)?.favicon } : nil)
        row.setGroupAccent(!tab.isPinned && tab.groupID != nil ? BrowserTheme.profile(for:ownerSpace(for:tab).saved.id):nil)
        row.update(title: displayTitle, selected: isSelected,
                   favicon: tab.favicon, splitFavicons: splitFavicons,
                   isTerminal: tab.isTerminal && tab.ide == nil, isPinned: tab.isPinned,
                   loadingProgress: tab.navigationInProgress ? (tab.webView?.estimatedProgress ?? 0) : nil)
        let ownerID = ownerSpace(for: tab).saved.id
        if row.themeSpaceID != ownerID {
            row.applyTheme(BrowserTheme.profile(for: ownerID))
            row.themeSpaceID = ownerID
        }
    }

    private func refreshTabContent(_ changed: BrowserTab) {
        defer { if changed.id == activeTabID { updateWebsiteEdgeBackdrop() } }
        let id = splitTabIDs?.contains(changed.id) == true ? splitRepresentativeID ?? changed.id : changed.id
        guard let representative = tab(id: id) else { return }
        if let row = tabRows[id] { updateTabPresentation(representative, row: row) }
        if let row = horizontalRows[id] {
            updateTabPresentation(representative, row: row)
            row.setHorizontal(pinned:representative.isPinned,color:horizontalTabColor(representative,row:row),chromeTint:windowChromeTint)
        }
    }

    private func refreshTabSelection(previousID: UUID?) {
        if renderedTabScope != tabScope || renderedTabIDs != visibleSidebarTabs.map(\.id) {
            refreshTabs(); return
        }
        if let previousID, let previous = tab(id: previousID) { refreshTabContent(previous) }
        if let activeTab { refreshTabContent(activeTab) }
        if BrowserTabPlacement.current == .horizontal {
            let id = activeTabID.flatMap { splitTabIDs?.contains($0) == true ? splitRepresentativeID : $0 }
            if horizontalSelection != id, let id, let row = horizontalRows[id] {
                horizontalSelection = id; horizontalStack.scrollToVisible(row.convert(row.bounds,to:horizontalStack))
            }
        }
    }

    private func refreshTabs() {
        guard !defersTabRefresh else{return}
        let occupiedGroups = Set(spaces.flatMap(\.tabs).filter { !$0.isPinned }.compactMap(\.groupID))
        let emptyGroups = Set(tabGroups.map(\.id)).subtracting(occupiedGroups)
        if !emptyGroups.isEmpty {
            tabGroups.removeAll { emptyGroups.contains($0.id) }
            for tab in spaces.flatMap(\.tabs) where tab.groupID.map(emptyGroups.contains) == true {
                tab.groupID = nil
            }
            saveTabGroups()
        }
        let geometry=buildingFirstWindow ? Motion.Geometry.empty:Motion.capture(Array(tabRows.values)+Array(horizontalRows.values)+Array(groupHeaders.values),in:content)
        defer {Motion.settle(geometry,views:Array(tabRows.values)+Array(horizontalRows.values)+Array(groupHeaders.values),in:content,character:.tabs)}
        defer {applyWallpaperPresentation();updateWebsiteEdgeBackdrop()}
        let visibleTabs = tabs.filter{!(splitTabIDs?.contains($0.id) ?? false) || $0.id==splitRepresentativeID}.filter { tab in
            guard !tab.isPinned,let id=tab.groupID,tabGroups.first(where:{$0.id==id})?.collapsed==true else{return true}
            return tabRows[tab.id] != nil
        }
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
        let visibleGroupIDs=Set(visibleTabGroups.map(\.id))
        for (index, tab) in regularTabs.enumerated() {
            let isGrouped=tab.groupID.map{visibleGroupIDs.contains($0)} ?? false
            let row: TabRow
            if let existing=tabRows[tab.id],!(existing.superview is PinnedTabGrid) {row=existing}
            else {
                discardTabRow(tab.id)
                row = TabRow(tabID: tab.id, target: self)
                tabRows[tab.id] = row
            }
            if row.superview==nil || (row.superview !== tabStack && !isGrouped) {
                if let stack=row.superview as? NSStackView,stack.arrangedSubviews.contains(row) {stack.removeArrangedSubview(row)}
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
            tabWidthConstraints[tab.id]?.constant=isGrouped ? -32:0
            let desired = firstRegularIndex + index
            if !isGrouped,tabStack.arrangedSubviews.firstIndex(of: row) != desired {
                tabStack.removeArrangedSubview(row)
                row.removeFromSuperview()
                tabStack.insertArrangedSubview(row, at: min(desired, tabStack.arrangedSubviews.count))
            }
        }
        let regularIDs = Set(regularTabs.map(\.id))
        for case let stale as TabRow in tabStack.subviews where !regularIDs.contains(stale.tabID) {
            if tab(id:stale.tabID)?.isPinned != true {Motion.depart(stale,character:.tabs)}
            tabStack.removeArrangedSubview(stale)
            stale.removeFromSuperview()
        }
        let groups = visibleTabGroups
        for (id, header) in Array(groupHeaders) where !groups.contains(where: { $0.id == id }) {
            Motion.depart(header,character:.tabs)
            if tabStack.arrangedSubviews.contains(header) { tabStack.removeArrangedSubview(header) }
            if let container=groupContainers.removeValue(forKey:id) {tabStack.removeArrangedSubview(container);container.removeFromSuperview()}
            header.removeFromSuperview()
            groupHeaders.removeValue(forKey: id)
        }
        let groupIDs = Set(groups.map(\.id))
        var orderedViews: [NSView] = regularTabs.filter { $0.groupID == nil || !groupIDs.contains($0.groupID!) }
            .compactMap { tabRows[$0.id] }
        for group in groups {
            let header = groupHeaders[group.id] ?? TabGroupHeader(groupID: group.id)
            groupHeaders[group.id] = header
            header.configure(name:group.name,collapsed:group.collapsed,count:tabs.filter{$0.groupID==group.id && !$0.isPinned}.count,profile:BrowserTheme.profile(for:group.profileID))
            header.onRename = { [weak self] name in
                guard let self, let index = self.tabGroups.firstIndex(where: { $0.id == group.id }) else { return }
                self.rememberLayout()
                self.tabGroups[index].automaticName=false
                self.tabGroups[index].name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? "Untitled Group" : name.trimmingCharacters(in: .whitespacesAndNewlines)
                self.saveTabGroups()
            }
            header.onToggle = { [weak self] in
                guard let self, let index = self.tabGroups.firstIndex(where: { $0.id == group.id }) else { return }
                self.rememberLayout()
                self.tabGroups[index].collapsed.toggle()
                self.saveTabGroups()
                self.refreshTabs()
            }
            header.onDrop = { [weak self] id in self?.addTab(id, toGroup: group.id) }
            header.onDelete = { [weak self] in
                guard let self else { return }
                self.rememberLayout()
                for tab in self.spaces.flatMap(\.tabs) where tab.groupID == group.id { tab.groupID = nil }
                self.tabGroups.removeAll { $0.id == group.id }
                self.saveTabGroups()
                self.refreshTabs()
            }
            let container=groupContainers[group.id] ?? TabGroupContainer(header:header)
            groupContainers[group.id]=container
            if container.superview !== tabStack {tabStack.addArrangedSubview(container);container.widthAnchor.constraint(equalTo:tabStack.widthAnchor).isActive=true}
            let rows=regularTabs.filter{$0.groupID==group.id}.compactMap{tabRows[$0.id]}
            container.setMembers(rows,collapsed:group.collapsed)
            orderedViews.append(container)
        }
        for (offset, view) in orderedViews.enumerated() {
            let desired = firstRegularIndex + offset
            if tabStack.arrangedSubviews.firstIndex(of: view) != desired {
                tabStack.removeArrangedSubview(view)
                view.removeFromSuperview()
                tabStack.insertArrangedSubview(view, at: min(desired, tabStack.arrangedSubviews.count))
            }
        }
        for tab in visibleTabs {
            if let row = tabRows[tab.id] { updateTabPresentation(tab, row: row) }
        }
        tabStack.needsLayout = true
        pinGrid.needsLayout = true
        pinGrid.needsDisplay = true
        tabStack.needsDisplay = true
        tabStack.enclosingScrollView?.contentView.needsDisplay = true
        refreshHorizontalTabs()
        renderedTabIDs = visibleSidebarTabs.map(\.id)
        renderedTabScope = tabScope
    }

    @objc fileprivate func selectTabAction(_ sender: TabActionButton) {
        tabPreview.hide()
        guard let tab = tabs.first(where: { $0.id == sender.tabID }) else { return }
        if sender.physicalModifiers.contains(.command) {
            commandGroupTab(tab.id)
            return
        }
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
        let wasRestoring = restoringPinnedSplit
        restoringPinnedSplit = true
        defer { restoringPinnedSplit = wasRestoring }
        if let ids = splitTabIDs, splitRepresentativeID == id {
            for otherID in ids.filter({ $0 != id }) { closeTab(id: otherID) }
        }
        closeTab(id: id)
    }

    fileprivate func supportsPin(for id: UUID) -> Bool { tab(id: id)?.ide == nil }

    @objc fileprivate func togglePinTabAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let index = tabs.firstIndex(where: { $0.id == id }), tabs[index].ide == nil else { return }
        rememberLayout()
        var ordered = tabs
        let tab = ordered.remove(at: index)
        if tab.isPinned { tab.savedSplit = nil; tab.savedSplitTabIDs = [] }
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
        rememberLayout()
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

    private func keepLoadedKey(for tab: BrowserTab) -> String? {
        guard let host = (tab.pageURL ?? tab.suspendedURL ?? URL(string: tab.searchDraft))?.host?.lowercased() else { return nil }
        return "webbyKeepLoaded.\(ownerSpace(for: tab).saved.id.uuidString).\(host)"
    }

    @objc private func toggleKeepLoaded(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let tab = tab(id: id), let key = keepLoadedKey(for: tab) else { return }
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: key), forKey: key)
    }

    fileprivate func appendFloatingItem(for tabID: UUID, to menu: NSMenu) {
        guard let tab = tab(id: tabID), tab.ide == nil else { return }
        if let key = keepLoadedKey(for: tab) {
            let keep = menu.addItem(withTitle: "Keep This Site Loaded", action: #selector(toggleKeepLoaded(_:)), keyEquivalent: "")
            keep.target = self; keep.representedObject = tabID
            keep.state = UserDefaults.standard.bool(forKey: key) ? .on : .off
        }
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
        defer {if let floating=floatingWindows[tab.id] {Motion.reveal(floating.contentView ?? NSView(),character:.panel)}}
        guard tab.ide == nil else { return }
        guard !tab.isFloating else { floatingWindows[tab.id]?.makeKeyAndOrderFront(nil); return }
        if splitTabIDs?.contains(tab.id) == true { endSplit() }
        let floating = FloatingTabWindow(tabID: tab.id, title: tab.title,
                                         screen: window.screen ?? NSScreen.main)
        floating.delegate = self
        floating.addressField.target = self
        floating.addressField.action = #selector(floatingAddressSubmitted(_:))
        floating.addressField.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
        floating.addressField.stringValue = tab.pageURL.map(displayAddress) ?? tab.searchDraft
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
        if tab.pageView == nil && !tab.isTerminal { floating.makeFirstResponder(floating.addressField) }
    }

    private func attachFloatingContent(for tab: BrowserTab) {
        guard let host = floatingWindows[tab.id]?.contentHost else { return }
        let view: NSView
        if let page = tab.pageView {
            NSLayoutConstraint.deactivate(tab.pageConstraints)
            view = page
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
        defer {if activate {Motion.reveal(pageArea,character:.split)}}
        guard let tab = tab(id: id), let floating = floatingWindows.removeValue(forKey: id) else { return }
        NSLayoutConstraint.deactivate(floatingContentConstraints.removeValue(forKey: id) ?? [])
        if let page = tab.pageView {
            page.removeFromSuperview()
            pageArea.addSubview(page, positioned: .below, relativeTo: homeView)
            NSLayoutConstraint.activate(tab.pageConstraints)
            page.isHidden = true
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
        let input=miniSuggestions[id]?.selected()?.url ?? sender.stringValue
        miniSuggestions[id]?.close()
        (floatingWindows[id] as? MiniWebbyWindow)?.expand()
        navigate(input, in: tab)
        if let view = tab.webView { floatingWindows[id]?.makeFirstResponder(view) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if let mini=sender as? MiniWebbyWindow {closeMiniWebby(mini.tabID);return false}
        guard let floating = sender as? FloatingTabWindow else { return true }
        dockFloatingTab(id: floating.tabID, activate: false)
        return false
    }

    fileprivate func appendSplitItem(for tabID: UUID, to menu: NSMenu) {
        guard splitRepresentativeID == tabID else { return }
        let pin = menu.addItem(withTitle: "Pin Entire Split", action: #selector(pinEntireSplit), keyEquivalent: "")
        pin.target = self
        let item = menu.addItem(withTitle: "Unsplit Tabs", action: #selector(unsplitMenuAction), keyEquivalent: "")
        item.target = self
        let root = NSMenuItem(title: "Split Layout", action: nil, keyEquivalent: "")
        let layouts = NSMenu(title: "Split Layout")
        for layout in SplitLayout.allCases {
            let choice = layouts.addItem(withTitle: layout.title, action: #selector(changeSplitLayout(_:)), keyEquivalent: "")
            choice.target = self
            choice.representedObject = layout.rawValue
            choice.state = splitLayout == layout ? .on : .off
            choice.isEnabled = layout != .grid || (splitTabIDs?.count ?? 0) == 4
        }
        root.submenu = layouts
        menu.addItem(root)
    }

    @objc private func changeSplitLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let layout = SplitLayout(rawValue: raw), let ids = splitTabIDs else { return }
        rememberLayout()
        splitLayout = layout
        renderSplit(ids)
    }

    @objc private func unsplitMenuAction() {
        rememberLayout()
        endSplit()
        if let activeTab { activeTabID = nil; selectTab(activeTab) }
        refreshTabs()
    }

    fileprivate func splitTabs(sourceID: UUID, targetID: UUID) -> Bool {
        guard sourceID != targetID,
              let source = tabs.first(where: { $0.id == sourceID }),
              let target = tabs.first(where: { $0.id == targetID }),
              !source.isFloating,!target.isFloating,(source.ide != nil || !source.isTerminal),(target.ide != nil || !target.isTerminal) else { return false }
        for page in [source,target] where page.ide==nil && (page.suspendedURL != nil || page.pinnedInstanceClosed) {resumeTab(page,show:false)}
        guard source.canSplit,target.canSplit else{return false}
        let existing = splitTabIDs ?? []
        let targetGroup = existing.contains(targetID) ? existing : [targetID]
        guard !targetGroup.contains(sourceID), targetGroup.count < 4 else { return false }
        rememberLayout()
        let ids = targetGroup + [sourceID]
        if splitTabIDs == nil { splitLayout = .columns }
        renderSplit(ids)
        activeTabID = nil
        selectTab(target)
        return true
    }

    private func renderSplit(_ ids: [UUID], fractions: [Double] = []) {
        let surfaces=ids.compactMap{tab(id:$0)?.splitSurface}
        let geometry=Motion.capture(surfaces,in:pageArea)
        defer {Motion.settle(geometry,views:surfaces,in:pageArea,character:.split)}
        guard (2...4).contains(ids.count), ids.allSatisfy({ tab(id: $0)?.splitSurface != nil }) else { return }
        endSplit()
        let views = ids.compactMap { tab(id: $0)?.splitSurface }
        for id in ids {
            if let tab = tab(id: id) { NSLayoutConstraint.deactivate(tab.splitSurfaceConstraints) }
        }
        func makePane(_ view: NSView) -> NSView {
            let pane = NSView()
            pane.translatesAutoresizingMaskIntoConstraints = false
            view.removeFromSuperview()
            pane.addSubview(view)
            let constraints = [
                view.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
                view.topAnchor.constraint(equalTo: pane.topAnchor),
                view.bottomAnchor.constraint(equalTo: pane.bottomAnchor)
            ]
            NSLayoutConstraint.activate(constraints)
            splitContentConstraints += constraints
            view.isHidden = false
            view.alphaValue = 1
            return pane
        }
        func makeSplit(_ children: [NSView], vertical: Bool) -> NSSplitView {
            let split = NSSplitView()
            split.isVertical = vertical
            split.delegate = splitResizeDelegate
            split.dividerStyle = .thin
            split.translatesAutoresizingMaskIntoConstraints = false
            split.wantsLayer = true
            split.layer?.backgroundColor = NSColor.clear.cgColor
            for child in children { split.addArrangedSubview(child) }
            return split
        }
        var initialFractions: [ObjectIdentifier: CGFloat] = [:]
        func makeLinearSplit(_ children: [NSView], vertical: Bool) -> NSSplitView {
            if children.count == 2 { return makeSplit(children, vertical: vertical) }
            let midpoint = children.count / 2
            let leading = midpoint == 1 ? children[0] :
                makeLinearSplit(Array(children[..<midpoint]), vertical: vertical)
            let trailing = children.count - midpoint == 1 ? children[midpoint] :
                makeLinearSplit(Array(children[midpoint...]), vertical: vertical)
            let split = makeSplit([leading, trailing], vertical: vertical)
            initialFractions[ObjectIdentifier(split)] = CGFloat(midpoint) / CGFloat(children.count)
            return split
        }
        let root: NSSplitView
        switch splitLayout {
        case .columns:
            root = makeLinearSplit(views.map(makePane), vertical: true)
        case .rows:
            root = makeLinearSplit(views.map(makePane), vertical: false)
        case .largeLeft where views.count > 2:
            let small = makeLinearSplit(views.dropFirst().map(makePane), vertical: false)
            root = makeSplit([makePane(views[0]), small], vertical: true)
        case .largeTop where views.count > 2:
            let small = makeLinearSplit(views.dropFirst().map(makePane), vertical: true)
            root = makeSplit([makePane(views[0]), small], vertical: false)
        case .grid where views.count == 4:
            let left = makeSplit(Array(views[0...1]).map(makePane), vertical: false)
            let right = makeSplit(Array(views[2...3]).map(makePane), vertical: false)
            root = makeSplit([left, right], vertical: true)
        default:
            root = makeLinearSplit(views.map(makePane), vertical: true)
        }
        pageArea.addSubview(root, positioned: .below, relativeTo: homeView)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            root.topAnchor.constraint(equalTo: pageArea.topAnchor),
            root.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor)
        ])
        splitView = root
        splitTabIDs = ids
        root.isHidden = false
        pageArea.layoutSubtreeIfNeeded()
        // NSSplitView starts with the first pane filling the available space.
        // Give every pane a visible share, including panes in nested layouts.
        var fractionIndex = 0
        func distribute(_ split: NSSplitView) {
            split.layoutSubtreeIfNeeded()
            let length = split.isVertical ? split.bounds.width : split.bounds.height
            guard length > 0, split.arrangedSubviews.count == 2 else { return }
            let fraction = fractions.indices.contains(fractionIndex)
                ? CGFloat(min(0.9, max(0.1, fractions[fractionIndex])))
                : (initialFractions[ObjectIdentifier(split)] ?? 0.5)
            fractionIndex += 1
            split.setPosition(length * fraction, ofDividerAt: 0)
            split.layoutSubtreeIfNeeded()
            for child in split.arrangedSubviews {
                if let nested = child as? NSSplitView { distribute(nested) }
            }
        }
        distribute(root)
        refreshTabs()
    }

    fileprivate func reorderTab(sourceID: UUID, targetID: UUID, before: Bool) -> Bool {
        guard sourceID != targetID,
              let source = tabs.first(where: { $0.id == sourceID }),
              let target = tabs.first(where: { $0.id == targetID }),
              source.isPinned == target.isPinned else { return false }
        rememberLayout()
        if splitTabIDs?.contains(sourceID) == true || splitTabIDs?.contains(targetID) == true { endSplit() }
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
        let surfaces=(splitTabIDs ?? []).compactMap{tab(id:$0)?.splitSurface}
        let geometry=Motion.capture(surfaces,in:pageArea)
        defer {Motion.settle(geometry,views:surfaces,in:pageArea,character:.split)}
        guard let split = splitView, let ids = splitTabIDs else { return }
        if let anchor = splitRepresentativeID.flatMap({ tab(id: $0) }), anchor.savedSplit != nil,
           anchor.savedSplitTabIDs == ids {
            anchor.savedSplit = savedSplitRecord(for: anchor)
            savePinnedTabs(for: displaySpace(for: anchor))
        }
        NSLayoutConstraint.deactivate(splitContentConstraints)
        splitContentConstraints = []
        for id in ids {
            guard let tab = tab(id: id), let view = tab.splitSurface else { continue }
            view.removeFromSuperview()
            pageArea.addSubview(view, positioned: .below, relativeTo: homeView)
            NSLayoutConstraint.activate(tab.splitSurfaceConstraints)
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
        rememberLayout()
        if splitTabIDs?.contains(ids[0]) == true { endSplit() }
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
        if let row=tabRows[id],tab(id:id)?.isPinned != true {Motion.depart(row)}
        if let row=horizontalRows[id],tab(id:id)?.isPinned != true {Motion.depart(row)}
        chatGPTDrafts.removeValue(forKey:id)
        if miniTabs[id] != nil {closeMiniWebby(id);return}
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        guard tabs[index].ide?.mayClose() != false else { return }
        if pointerLockedWebView === tabs[index].webView { releasePointerLock() }
        tabPreview.hide(for: id)
        linkPreview?.close()
        if splitTabIDs?.contains(id) == true { endSplit() }
        let wasActive = activeTabID == id
        let containingSpace = displaySpace(for: tabs[index])
        let closingTab = tabs[index]
        if closingTab.isPinned {
            if closingTab.pinnedInstanceClosed { return }
            if let address = closingTab.pageURL?.absoluteString {
                closingTab.searchDraft = address
                closingTab.suspendedURL = URL(string: address)
            }
            discardFloatingWindow(for: id)
            releaseWebView(for: closingTab)
            closingTab.terminalView?.stop()
            NSLayoutConstraint.deactivate(closingTab.terminalConstraints)
            closingTab.terminalConstraints = []
            closingTab.terminalView?.removeFromSuperview()
            closingTab.terminalView = nil
            closingTab.previewImage = nil
            closingTab.navigationInProgress = false
            closingTab.pinnedInstanceClosed = true
            savePinnedTabs(for: containingSpace)
            if wasActive {
                activeTabID = nil
                if let next = tabs.first(where: { $0.id != id && !$0.isFloating && !$0.pinnedInstanceClosed }) {
                    selectTab(next)
                } else { addTab(select: true) }
            } else { refreshTabs() }
            return
        }
        recentlyClosedTabs.append(ClosedTabRecord(
            title: closingTab.title,
            address: closingTab.pageURL?.absoluteString ?? destination(for: closingTab.searchDraft)?.absoluteString,
            searchDraft: closingTab.searchDraft,
            ownerSpaceID: ownerSpace(for: closingTab).saved.id,
            displaySpaceID: containingSpace.saved.id,
            wasPinned: closingTab.isPinned, wasTerminal: closingTab.isTerminal,
            wasIDE: closingTab.ide != nil, ideProject: closingTab.ide?.projectURL,
            pinWidthFraction: closingTab.pinWidthFraction, pinHeight: closingTab.pinHeight, engine: closingTab.engine))
        if recentlyClosedTabs.count > 20 { recentlyClosedTabs.removeFirst() }
        discardFloatingWindow(for: id)
        let closing = tabs.remove(at: index)
        if closing.isPinned { savePinnedTabs(for: containingSpace) }
        closing.progressObservation?.invalidate()
        closing.progressObservation = nil
        closing.faviconTask?.cancel()
        closing.faviconTask = nil
        closing.chromiumView?.closePage()
        closing.chromiumView?.removeFromSuperview()
        closing.chromiumView = nil
        closing.webView?.stopLoading()
        closing.webView?.navigationDelegate = nil
        closing.webView?.uiDelegate = nil
        closing.webView?.removeFromSuperview()
        closing.ide?.shutdown()
        NSLayoutConstraint.deactivate(closing.ideConstraints)
        closing.ide?.view.removeFromSuperview()
        closing.ide = nil
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
        scheduleSessionSave()
    }

    @objc private func reopenLastClosedTab() {
        guard let snapshot = recentlyClosedTabs.popLast() else { return }
        let destination = spaces.first { $0.saved.id == snapshot.displaySpaceID } ?? activeSpace
        let ownerID = spaces.contains { $0.saved.id == snapshot.ownerSpaceID }
            ? snapshot.ownerSpaceID : destination.saved.id
        let tab = BrowserTab()
        tab.title = snapshot.title
        tab.engine = snapshot.engine ?? .webKit
        tab.ownerSpaceID = ownerID
        tab.searchDraft = snapshot.searchDraft
        tab.isPinned = snapshot.wasPinned
        tab.isTerminal = snapshot.wasTerminal
        tab.pinWidthFraction = snapshot.pinWidthFraction
        tab.pinHeight = snapshot.pinHeight
        if snapshot.wasIDE { attachIDE(to: tab, project: snapshot.ideProject) }
        destination.tabs.insert(tab, at: tab.isPinned ? destination.tabs.prefix { $0.isPinned }.count : destination.tabs.count)
        if !BrowserExperiment.cyclesNewTabProfiles && destination !== activeSpace {
            destination.activeTabID = tab.id
        }
        if BrowserExperiment.cyclesNewTabProfiles { fusedTabOrder.append(tab.id) }
        if let address = snapshot.address, let url = URL(string: address),
           ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") {
            tab.suspendedURL = url
            resumeTab(tab, show: false)
        }
        if tab.isPinned { savePinnedTabs(for: destination) }
        if !BrowserExperiment.cyclesNewTabProfiles,
           let index = spaces.firstIndex(where: { $0 === destination }), index != activeSpaceIndex {
            switchToSpace(index, direction: index > activeSpaceIndex ? 1 : -1)
        }
        if activeTabID != tab.id { selectTab(tab) }
        else { refreshTabs() }
    }

    private var tabsHiddenByUser:Bool {BrowserTabPlacement.current == .horizontal ? UserDefaults.standard.bool(forKey:"horizontalTabsHidden"):!sidebarVisible}
    private var horizontalChrome:[NSView] {[horizontalScroll,horizontalProfile,mainArea?.subviews.first{$0.identifier?.rawValue=="horizontalNewTab"}].compactMap{$0}}
    private func applyHiddenChromeLayout() {
        guard mainArea != nil,sidebar != nil,horizontalScroll != nil else{return}
        let horizontal=BrowserTabPlacement.current == .horizontal
        let hidden=tabsHiddenByUser
        let presented = !hidden || tabsPeekVisible
        let pinnedVertical = !horizontal && !hidden
        let floatingVertical = !horizontal && tabsPeekVisible
        sidebarNewTabLeading?.constant = floatingVertical ? 56:14
        sidebarRevealToggle?.isHidden = !floatingVertical
        sidebarToggleButton?.isHidden = horizontal || floatingVertical
        mainSidebarLeading?.isActive=false;mainFullLeading?.isActive=false
        if pinnedVertical {mainSidebarLeading?.isActive=true}else{mainFullLeading?.isActive=true}
        let width = resolvedSidebarWidth(preferredSidebarWidth)
        sidebarInnerWidth.constant = width
        sidebarWidth.constant = !horizontal && presented ? width : 0
        sidebarResizeHandle.isHidden = !pinnedVertical
        sidebar.isHidden = horizontal || !presented
        sidebar.layer?.cornerRadius = tabsPeekVisible ? 16:0
        pageAreaTop.constant = (horizontal && !hidden ? 44 : 0) + pageFrameInset
        if addressChromeReady { applyAddressChrome() }
        for view in horizontalChrome {view.isHidden = !horizontal || !presented}
        if !horizontal && tabsPeekVisible {content.addSubview(sidebar,positioned:.above,relativeTo:mainArea)}
        if horizontalHoverGlass == nil {
            let glass=WebbyGlassBackdrop();glass.wantsLayer=true;glass.layer?.cornerRadius=14;glass.layer?.masksToBounds=true;glass.material = .popover;glass.blendingMode = .withinWindow;glass.state = .active
            glass.translatesAutoresizingMaskIntoConstraints=false;mainArea.addSubview(glass,positioned:.below,relativeTo:horizontalScroll)
            NSLayoutConstraint.activate([glass.leadingAnchor.constraint(equalTo:mainArea.leadingAnchor),glass.trailingAnchor.constraint(equalTo:mainArea.trailingAnchor),glass.topAnchor.constraint(equalTo:mainArea.topAnchor),glass.heightAnchor.constraint(equalToConstant:48)])
            horizontalHoverGlass=glass
        }
        horizontalHoverGlass?.isHidden = !horizontal || !tabsPeekVisible
        updateWebsiteEdgeBackdrop()
    }
    private func animateTabPeek(_ view:NSView,show:Bool,horizontal:Bool) {
        guard Motion.enabled,let layer=view.layer else{return}
        let key=horizontal ? "transform.translation.y":"transform.translation.x"
        let resting:CGFloat=horizontal ? 14:-24
        let interrupted=layer.animation(forKey:"webbyEdgeReveal") != nil
        let from=interrupted ? ((layer.presentation()?.value(forKeyPath:key) as? NSNumber)?.doubleValue ?? 0):(show ? Double(resting):0)
        let movement:CABasicAnimation
        if show {
            let spring=CASpringAnimation(keyPath:key);spring.mass=1;spring.stiffness=580;spring.damping=48;spring.duration=0.30;movement=spring
        } else {
            movement=CABasicAnimation(keyPath:key);movement.duration=0.18;movement.timingFunction=CAMediaTimingFunction(name:.easeInEaseOut)
        }
        movement.fromValue=from;movement.toValue=show ? 0:resting
        movement.fillMode = .forwards;movement.isRemovedOnCompletion=false
        layer.add(movement,forKey:"webbyEdgeReveal")
        let fade=CABasicAnimation(keyPath:"opacity");fade.fromValue=interrupted ? (layer.presentation()?.opacity ?? 1):(show ? 0:1);fade.toValue=show ? 1:0;fade.duration=show ? 0.16:0.18
        fade.fillMode = .forwards;fade.isRemovedOnCompletion=false
        layer.add(fade,forKey:"webbyEdgeOpacity")
    }
    // Hidden tabs require deliberate contact with the outer edge. Once open,
    // the existing full-panel hover region keeps them available for selection.
    private func tabHoverRegion(horizontal:Bool)->NSRect {
        if horizontal {return NSRect(x:mainArea.frame.minX,y:content.bounds.maxY-4,width:max(0,mainArea.bounds.width-64),height:4)}
        return NSRect(x:content.bounds.minX,y:content.bounds.minY,width:min(4,content.bounds.width),height:content.bounds.height)
    }
    private func revealTabsFromEdge() {
        guard tabsHiddenByUser,(!tabsPeekVisible || tabsRetreating) else{return}
        tabsRetreating=false;tabsPeekToken+=1;tabsPeekVisible=true;peekHorizontal=BrowserTabPlacement.current == .horizontal
        applyHiddenChromeLayout();content.layoutSubtreeIfNeeded();applyWallpaperPresentation()
        for view in peekHorizontal ? horizontalChrome+[horizontalHoverGlass].compactMap({$0}):[sidebar!] {view.wantsLayer=true;animateTabPeek(view,show:true,horizontal:peekHorizontal)}
        scheduleTabsRetreat()
    }
    private func retreatTabs() {
        guard tabsPeekVisible else{return}
        tabsRetreatTimer?.invalidate();tabsRetreatTimer=nil;tabsPeekToken+=1
        let token=tabsPeekToken,horizontal=peekHorizontal
        tabsRetreating=true
        for view in horizontal ? horizontalChrome+[horizontalHoverGlass].compactMap({$0}):[sidebar!] {animateTabPeek(view,show:false,horizontal:horizontal)}
        let finish={ [weak self] in
            guard let self,self.tabsPeekToken==token else{return}
            self.tabsPeekVisible=false;self.tabsRetreating=false;self.applyHiddenChromeLayout();self.content.layoutSubtreeIfNeeded()
            // Hide first, then clear the held presentation. Otherwise Core
            // Animation briefly restores opacity/position before AppKit hides it.
            for view in horizontal ? self.horizontalChrome+[self.horizontalHoverGlass].compactMap({$0}):[self.sidebar!] {
                view.layer?.removeAnimation(forKey:"webbyEdgeReveal");view.layer?.removeAnimation(forKey:"webbyEdgeOpacity")
            }
            self.applyWallpaperPresentation()
        }
        if Motion.enabled {DispatchQueue.main.asyncAfter(deadline:.now()+0.18,execute:finish)}else{finish()}
    }
    private func pointerOverTabs()->Bool {
        let point=content.convert(window.mouseLocationOutsideOfEventStream,from:nil)
        if peekHorizontal {return NSRect(x:mainArea.frame.minX,y:content.bounds.maxY-56,width:mainArea.bounds.width,height:56).contains(point)}
        return sidebar.frame.insetBy(dx:-8,dy:-8).contains(point)
    }
    private func scheduleTabsRetreat() {
        tabsRetreatTimer?.invalidate()
        tabsRetreatTimer=Timer.scheduledTimer(withTimeInterval:0.45,repeats:false){[weak self] _ in MainActor.assumeIsolated {
            guard let self,self.tabsPeekVisible else{return}
            let editing=(self.window.firstResponder as? NSTextView).map{$0.isDescendant(of:self.sidebar) || $0.isDescendant(of:self.horizontalScroll)} ?? false
            if NSApp.isActive && (self.pointerOverTabs() || editing || NSEvent.pressedMouseButtons != 0 || self.profileSwipeActive || NSApp.modalWindow != nil) {self.scheduleTabsRetreat()}
            else {self.retreatTabs()}
        }}
    }
    private func updateChromeHover(_ event:NSEvent) {
        guard window.isKeyWindow,NSApp.isActive,NSEvent.pressedMouseButtons==0,pointerLockedWebView==nil else {hoverDwell?.cancel();hoverDwell=nil;hoverTarget="";return}
        if tabsPeekVisible && tabsRetreating && pointerOverTabs() {revealTabsFromEdge()}
        let p=content.convert(event.locationInWindow,from:nil)
        let horizontal=BrowserTabPlacement.current == .horizontal
        let nearTabs=tabsHiddenByUser && !tabsPeekVisible && tabHoverRegion(horizontal:horizontal).contains(p)
        let target = nearTabs ? "tabs" : "" // Page controls never trigger address chrome.
        if target != hoverTarget {
            hoverDwell?.cancel();hoverDwell=nil;hoverTarget=target
            if !target.isEmpty {
                let work=DispatchWorkItem{[weak self] in
                    guard let self else{return}
                    self.hoverDwell=nil
                    guard self.hoverTarget==target,self.window.isKeyWindow,NSApp.isActive else{self.hoverTarget="";return}
                    let current=self.content.convert(self.window.mouseLocationOutsideOfEventStream,from:nil)
                    let horizontal=BrowserTabPlacement.current == .horizontal
                    let stillAtTarget = self.tabHoverRegion(horizontal:horizontal).contains(current)
                    guard self.content.bounds.contains(current),stillAtTarget,NSEvent.pressedMouseButtons==0,self.pointerLockedWebView==nil else{self.hoverTarget="";return}
                    self.revealTabsFromEdge()
                };hoverDwell=work;DispatchQueue.main.asyncAfter(deadline:.now()+0.24,execute:work)
            }
        }
        if toolbarVisible {
            if toolbarHideTimer==nil {scheduleToolbarHide()}
        }
    }
    @objc private func toggleSidebar() {
        let horizontal=BrowserTabPlacement.current == .horizontal
        let opening=tabsHiddenByUser
        let wasPeeking=tabsPeekVisible
        chromeDepartures.forEach{$0.removeFromSuperview()};chromeDepartures=[]
        let movingViews=[homeCenter,sidebarToggleButton,newTerminalButton,chromeToggle,toolbar].compactMap{$0}
        var controlFrames=Motion.capture(movingViews,in:content).frames
        // The revealed header and pinned page button are the same action.
        // Transfer its visible position across the two native controls.
        if opening && tabsPeekVisible && !horizontal,let button=sidebarRevealToggle,!button.isHidden {
            controlFrames[ObjectIdentifier(sidebarToggleButton!)]=button.convert(button.bounds,to:content)
        }
        let controls=Motion.Geometry(frames:controlFrames)
        let framedPage = [pageArea, websiteFrameShadow, websiteFrameRim].compactMap { $0 }
        let pageGeometry=Motion.capture(framedPage,in:content)
        let widgetGeometry=widgetCanvas?.captureViewportLayout(in:content) ?? .empty
        if !opening {
            chromeDepartures=Motion.departChrome(horizontal ? horizontalChrome:[sidebar!],in:content,horizontal:horizontal)
        }
        hoverDwell?.cancel();hoverTarget="";tabsRetreatTimer?.invalidate();tabsPeekToken+=1;tabsPeekVisible=false;tabsRetreating=false
        for view in horizontalChrome+[sidebar].compactMap({$0}) {view.layer?.removeAnimation(forKey:"webbyEdgeReveal");view.layer?.removeAnimation(forKey:"webbyEdgeOpacity");view.layer?.removeAnimation(forKey:"webbyGeometry")}
        if horizontal {UserDefaults.standard.set(!tabsHiddenByUser,forKey:"horizontalTabsHidden")}
        else {sidebarVisible.toggle();UserDefaults.standard.set(!sidebarVisible,forKey:"sidebarHidden")}
        configureHorizontalTabs();content.layoutSubtreeIfNeeded()
        if opening && !wasPeeking {
            for view in horizontal ? horizontalChrome:[sidebar!] {view.wantsLayer=true;animateTabPeek(view,show:true,horizontal:horizontal)}
        }
        // Animate leaves, never both a parent and its children: that doubled
        // translations and made the controls judder at the end of a switch.
        if homeView?.isHidden != false {Motion.settle(pageGeometry,views:framedPage,in:content,character:.split)}
        Motion.settle(controls,views:movingViews,in:content,character:.widget)
        widgetCanvas?.settleViewportLayout(widgetGeometry,in:content)
    }

    @objc private func toggleToolbar() { focusAddress() }

    private func showToolbar(fromHover: Bool = false) {
        guard !fromHover else { return }
        applyAddressChrome()
    }

    private func hideToolbar(animated: Bool) {
        toolbarHideTimer?.invalidate(); toolbarHideTimer = nil
        applyAddressChrome()
    }

    private func scheduleToolbarHide() {
        toolbarHideTimer?.invalidate(); toolbarHideTimer = nil
    }

    @objc private func toolbarHideTimerFired() {
        // Explicitly opened chrome stays open until Escape, navigation, or a page click.
        toolbarHideTimer?.invalidate(); toolbarHideTimer = nil
    }

    private var addressHeaderViews: [NSView] {
        [sidebarNewTab, spaceLabel, downloads?.button, sidebarRevealToggle,
         sidebarTabScroll, sidebarToggleButton, newTerminalButton, toolbar].compactMap { $0 }
    }

    @objc private func addressPlacementChanged() {
        closeSuggestions()
        let views = addressHeaderViews
        let geometry = Motion.capture(views, in: content)
        let wasHidden = toolbar.isHidden
        toolbarTransitionToken += 1
        toolbar.layer?.removeAllAnimations()
        toolbarVisible = false
        applyAddressChrome()
        content.layoutSubtreeIfNeeded()
        Motion.settle(geometry, views: views, in: content, character: .widget)
        if wasHidden && !toolbar.isHidden { Motion.reveal(toolbar, character: .widget) }
    }

    /// Sidebar address mode occupies sidebar space only; the webpage keeps its full height.
    private func applyAddressChrome() {
        updateEngineAppearance()
        guard addressChromeReady else { return }
        let horizontal = BrowserTabPlacement.current == .horizontal
        let mode = BrowserAddressPlacement.current
        let pane = mode == .tabBar && !horizontal
        let compact = mode == .tabBar && horizontal && !tabsHiddenByUser
        let page = activeTab?.pageView != nil && activeTab?.showsSearchView != true && !terminalMode && pointerLockedWebView == nil
        if pane && !sidebarVisible && !tabsPeekVisible && addressField.currentEditor() != nil {
            window.makeFirstResponder(activeTab?.pageView)
        }
        let pageChanged = addressPageState != nil && addressPageState != page
        addressPageState = page
        let moving = addressHeaderViews
        let geometry = pageChanged ? Motion.capture(moving, in: content) : .empty
        defer {
            if pageChanged {
                content.layoutSubtreeIfNeeded()
                Motion.settle(geometry, views: moving, in: content, character: .widget)
            }
        }
        let base: CGFloat = horizontal && !tabsHiddenByUser ? 44 : 0
        pageAreaTop.constant = base + (page && !compact && !pane ? 42 : 0) + pageFrameInset
        horizontalTabsTrailing?.constant = compact && page ? -300 : 0
        let sharedHeader = page && !horizontal && !pane
        sidebarHeaderTop.constant = sharedHeader ? 4 : 16
        sidebarRevealTop.constant = sharedHeader ? 4 : 16
        sidebarTabsTop.constant = pane ? 50 : (sharedHeader ? 4 : 26)
        sidebarSeparator.isHidden = pane || sharedHeader
        sidebarControlTop.constant = page && !pane ? base + 4 : base + 16
        sidebarToggleButton.isHidden = horizontal || tabsPeekVisible || pane && sidebarVisible
        newTerminalButton.isHidden = !BrowserExperiment.cyclesNewTabProfiles || page && (horizontal || pane)
        let layoutKey = "\(mode.rawValue):\(pane):\(compact):\(base):\(BrowserExperiment.cyclesNewTabProfiles)"
        if layoutKey != addressLayoutKey {
            addressLayoutKey = layoutKey
            NSLayoutConstraint.deactivate(addressChromeConstraints)
            let host: NSView = pane ? sidebarAddressHost : mainArea
            if toolbar.superview !== host { toolbar.removeFromSuperview(); host.addSubview(toolbar) }
            if pane {
                addressChromeConstraints = [
                    toolbar.topAnchor.constraint(equalTo: sidebarNewTab.bottomAnchor, constant: 8),
                    toolbar.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 4),
                    toolbar.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -4),
                    toolbar.heightAnchor.constraint(equalToConstant: 34)
                ]
            } else {
                addressChromeConstraints = [
                    toolbar.topAnchor.constraint(equalTo: mainArea.topAnchor, constant: compact ? 8 : base + 4),
                    toolbar.trailingAnchor.constraint(equalTo: mainArea.trailingAnchor, constant: compact ? -48 : -8),
                    toolbar.heightAnchor.constraint(equalToConstant: 34)
                ]
                if compact { addressChromeConstraints.append(toolbar.widthAnchor.constraint(equalToConstant: 288)) }
                else {
                    toolbarLeading = toolbar.leadingAnchor.constraint(equalTo: mainArea.leadingAnchor, constant: horizontal ? 8 : (BrowserExperiment.cyclesNewTabProfiles ? 92 : 51))
                    addressChromeConstraints.append(toolbarLeading)
                }
            }
            NSLayoutConstraint.activate(addressChromeConstraints)
        }
        for view in addressControls.arrangedSubviews where view !== topAddressSurface {
            view.isHidden = pane || compact || view === addressDismiss
        }
        addressControls.spacing = pane || compact ? 0 : 5
        toolbar.layer?.cornerRadius = pane || compact ? 12 : 14
        chromeToggle.isHidden = true
        toolbar.isHidden = pane ? terminalMode : !page
        toolbarVisible = !toolbar.isHidden
        updateAddressEdgeBackdrop()
        updateWebsiteFrameRim()
        updateWidgetActivity()
        wallpaper?.refreshActivity()
    }

    private func installChromeMonitor() {
        controlMotionMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseUp]){[weak self] event in
            guard let self,let host=event.window,host === self.window || self.floatingWindows.values.contains(where:{$0 === host}) else{return event}
            if event.type == .leftMouseUp {if let button=self.pressedMotionButton {Motion.basic(button.layer,key:"transform.scale",from:0.99,to:1,duration:0.12)};self.pressedMotionButton=nil;return event}
            var hit=host.contentView?.hitTest(host.contentView?.convert(event.locationInWindow,from:nil) ?? .zero)
            self.commandLinkIntent=nil
            if event.modifierFlags.contains(.command),!event.modifierFlags.contains(.option) {
                var node=hit
                while let current=node {
                    if let view=current as? WKWebView,let tab=self.tab(for:view) {self.commandLinkIntent=(tab.id,ProcessInfo.processInfo.systemUptime);break}
                    node=current.superview
                }
            }
            if event.modifierFlags.contains(.command) {
                var candidate=hit;var closing=false
                while let node=candidate {
                    if let button=node as? TabActionButton,button.action == #selector(BrowserApp.closeTabAction(_:)) {closing=true}
                    if let row=node as? TabRow {
                        if !closing {self.commandGroupTab(row.tabID);return nil}
                        break
                    }
                    candidate=node.superview
                }
            }
            while let current=hit,!(current is NSButton) {hit=current.superview}
            if let button=hit as? NSButton,!(button is GlassButton),button.isEnabled {button.wantsLayer=true;self.pressedMotionButton=button;Motion.basic(button.layer,key:"transform.scale",from:0.97,to:1,duration:0.16)}
            return event
        }

        installTabShortcuts()
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .mouseMoved]) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            if event.type == .scrollWheel {
                let sidebarPoint = self.sidebar.convert(event.locationInWindow, from: nil)
                let horizontalLayout = BrowserTabPlacement.current == .horizontal
                let profilePoint = self.horizontalProfile.convert(event.locationInWindow, from: nil)
                let overProfile = horizontalLayout
                    ? !self.horizontalProfile.isHidden && self.horizontalProfile.bounds.contains(profilePoint)
                    : (self.sidebarVisible || self.tabsPeekVisible) && self.sidebar.bounds.contains(sidebarPoint)
                let horizontal = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.25
                if BrowserExperiment.cyclesNewTabProfiles || self.spaces.count < 2 {
                    if self.profileSwipeActive { self.profileSwipeActive=false;self.swipeDistance=0;self.profileMotion.cancel() }
                } else if self.profileSwipeActive || (overProfile && horizontal && event.momentumPhase == []) {
                    let now=ProcessInfo.processInfo.systemUptime
                    if !self.profileSwipeActive {
                        guard event.momentumPhase == [] else {return nil}
                        if now-self.lastScrollAt>0.25 {self.swipeDistance=0}
                        self.profileSwipeActive=true
                        let surface=horizontalLayout ? self.horizontalScroll : self.tabStack.enclosingScrollView
                        if let surface {self.profileMotion.beginTracking(surface)}
                    }
                    self.lastScrollAt=now
                    if event.momentumPhase != [] {return nil}
                    self.swipeDistance += event.scrollingDeltaX
                    let surface=horizontalLayout ? self.horizontalScroll : self.tabStack.enclosingScrollView
                    if let surface {self.profileMotion.track(surface,distance:self.swipeDistance)}
                    let ended=event.phase.contains(.ended), cancelled=event.phase.contains(.cancelled)
                    // Trackpad commits once on release. Phase-less mice retain discrete switching.
                    if ended || cancelled || (event.phase == [] && abs(self.swipeDistance)>=64) {
                        let distance=self.swipeDistance
                        self.profileSwipeActive=false;self.swipeDistance=0
                        if !cancelled && abs(distance)>=48 && now-self.lastSwipeAt>0.12 {
                            self.lastSwipeAt=now
                            self.switchSpace(distance<0 ? 1 : -1)
                        } else {self.profileMotion.cancel()}
                    }
                    return nil
                }

            }
            if event.type == .mouseMoved {self.updateChromeHover(event)}
            return event
        }
    }

    private func loadRules() {
        // Compile on this machine into WebKit's writable, per-app cache. Bundled
        // bytecode is tied to the build machine's WebKit version.
        guard let url = Bundle.main.url(forResource: "FastRules", withExtension: "json") else { return }
        guard let store = WKContentRuleListStore.default() else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let json = try? String(contentsOf: url, encoding: .utf8) else { return }
            DispatchQueue.main.async { [weak self] in
                let identifier = "WebbyFastRules-" + SHA256.hash(data: Data(json.utf8)).map { String(format: "%02x", $0) }.joined()
                store.lookUpContentRuleList(forIdentifier: identifier) { [weak self] rule, _ in
                    if let rule { self?.fastRule = rule; self?.applyFastRule(rule); return }
                    store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { [weak self] rule, _ in
                        guard let self, let rule else { return } // Browsing still works if compilation fails.
                        self.fastRule = rule; self.applyFastRule(rule)
                    }
                }
            }
        }
    }

    private func applyFastRule(_ rule: WKContentRuleList) {
        var updated = Set<ObjectIdentifier>()
        for tab in spaces.flatMap(\.tabs) + Array(miniTabs.values) {
            guard let controller = tab.webView?.configuration.userContentController,
                  updated.insert(ObjectIdentifier(controller)).inserted else { continue }
            controller.remove(rule)
            if fastModeEnabled { controller.add(rule) }
        }
    }

    private let passwordProbeSource = Bundle.main.url(forResource: "PasswordFieldProbe", withExtension: "js").flatMap { try? String(contentsOf: $0) }
    private let linkPreviewSource = Bundle.main.url(forResource: "LinkPreview", withExtension: "js").flatMap { try? String(contentsOf: $0) }
    private let videoControlsSource = Bundle.main.url(forResource: "VideoControls", withExtension: "js").flatMap { try? String(contentsOf: $0) }

    /// macOS exposes fullscreen publicly, but keeps its PiP enablement on WKPreferences.
    /// Use the verified boolean setter only when present; never unguarded KVC.
    private func configureVideoPresentation(_ configuration: WKWebViewConfiguration) {
        configuration.preferences.isElementFullscreenEnabled = true
        let preferences = configuration.preferences
        let setter = NSSelectorFromString("_setAllowsPictureInPictureMediaPlayback:")
        if preferences.responds(to: setter), let implementation = preferences.method(for: setter) {
            typealias BooleanSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(implementation, to: BooleanSetter.self)(preferences, setter, true)
        }
    }

    private func makeWebView(for tab: BrowserTab, popupConfiguration: WKWebViewConfiguration? = nil) -> WKWebView {
        if let existing = tab.webView { return existing }
        tab.engine = .webKit
        let configuration = popupConfiguration ?? WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = false
        // WebKit synchronously issues font sandbox extensions on the UI thread
        // for every new content process. On some macOS installations that call
        // stalls for many seconds. Use system and web-provided fonts instead;
        // the web-content sandbox remains enabled. This guarded private setting
        // is the only WebKit switch for excluding locally installed fonts.
        let fontPreferences = configuration.preferences
        let fontSetter = NSSelectorFromString("_setShouldAllowUserInstalledFonts:")
        if fontPreferences.responds(to: fontSetter), let implementation = fontPreferences.method(for: fontSetter) {
            typealias BooleanSetter = @convention(c) (AnyObject, Selector, Bool) -> Void
            unsafeBitCast(implementation, to: BooleanSetter.self)(fontPreferences, fontSetter, false)
        }
        configureVideoPresentation(configuration)
        if popupConfiguration == nil {
            configuration.websiteDataStore = ownerSpace(for: tab).dataStore
            if fastModeEnabled, let fastRule { configuration.userContentController.add(fastRule) }
            configuration.userContentController.add(self, name: "browserPasswordField")
            configuration.userContentController.add(self, name: "browserLinkPreview")
            if let source = linkPreviewSource {
                configuration.userContentController.addUserScript(
                    WKUserScript(source: source+"\nwindow.__webbySetLinkPreviewsEnabled?.(\(BrowserHoverPreferences.glancesEnabled ? "true":"false"));", injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
            if let source = passwordProbeSource {
                configuration.userContentController.addUserScript(WKUserScript(source: source,
                    injectionTime: .atDocumentEnd, forMainFrameOnly: true))
            }
            if let script = videoControlsSource {
                let videoWorld = WKContentWorld.world(name: "WebbyVideo")
                configuration.userContentController.addUserScript(
                    WKUserScript(source: script, injectionTime: .atDocumentEnd,
                                 forMainFrameOnly: false, in: videoWorld))
            }
            BrowserPageActivity.install(into: configuration, handler: self)
            BrowserChromeTone.install(into: configuration, handler: self)
            installSitePolicy(into: configuration, profile: ownerSpace(for: tab).saved.id)
            GlassPageInjector.install(into: configuration)
        }
        // WebKit popup configurations already inherit the opener's controller and session.
        // Reinstalling handlers on that shared controller raises an Objective-C exception.
        let view = SplitLinkWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        view.registerForDraggedTypes([.URL, .string])
        view.canAddPane = { [weak self,weak tab] in guard let self,let tab,self.miniTabs[tab.id]==nil else{return false};return (self.splitTabIDs?.count ?? 1)<4 }
        view.onLinkDrop = { [weak self, weak tab] url, zone in
            guard let self, let tab else { return false }
            if self.miniTabs[tab.id] != nil {self.navigate(url.absoluteString,in:tab);return true}
            guard !tab.isFloating else{return false}
            return self.dropLink(url, on: tab, zone: zone)
        }
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
                      let tab = self.tab(id:tabID),
                      tab.webView === view, tab.navigationInProgress else { return }
                self.updateMiniChrome(tab)
                let rowID = self.splitTabIDs?.contains(tabID) == true ? self.splitRepresentativeID ?? tabID : tabID
                self.tabRows[rowID]?.setLoadingProgress(view.estimatedProgress)
                self.horizontalRows[rowID]?.setLoadingProgress(view.estimatedProgress)
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

    private func installSitePolicy(into configuration: WKWebViewConfiguration, profile: UUID) {
        let prefix = "webbyPermission.\(profile.uuidString)."
        var blocked: [String: [String]] = [:]
        for (key, value) in UserDefaults.standard.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let choice = value as? Int, choice == 2 else { continue }
            let suffix = String(key.dropFirst(prefix.count))
            guard let dot = suffix.lastIndex(of: ".") else { continue }
            let host = String(suffix[..<dot])
            let kind = String(suffix[suffix.index(after: dot)...])
            blocked[host, default: []].append(kind)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: blocked),
              let json = String(data: data, encoding: .utf8) else { return }
        let source = """
        (() => {
          const blocked = (\(json)[location.hostname.toLowerCase()] || []);
          if (blocked.includes('location') && navigator.geolocation) {
            const denied = error => error?.({code: 1, message: 'Location blocked in Webby'});
            try { navigator.geolocation.getCurrentPosition = (_, error) => denied(error); } catch (_) {}
            try { navigator.geolocation.watchPosition = (_, error) => { denied(error); return -1; }; } catch (_) {}
          }
          if (blocked.includes('notifications') && window.Notification) {
            try { Notification.requestPermission = () => Promise.resolve('denied'); } catch (_) {}
          }
          if (blocked.includes('clipboard') && navigator.clipboard) {
            const deny = () => Promise.reject(new DOMException('Clipboard blocked in Webby', 'NotAllowedError'));
            for (const name of ['read', 'readText', 'write', 'writeText']) {
              try { navigator.clipboard[name] = deny; } catch (_) {}
            }
          }
        })();
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false))
    }

    private func applyGlassTone(for tab: BrowserTab) {
        mainArea.appearance = NSAppearance(named: BrowserGlass.pageInjectionEnabled || tab.prefersDarkGlass ? .darkAqua : .aqua)
        if BrowserGlass.matchPageGlassSidebar { sidebarBackdrop.appearance = mainArea.appearance }
    }

    private func updateGlassTone(for webView: WKWebView) {
        guard let tab=tab(for:webView) else {return}
        let enabled=(BrowserTabPlacement.current == .horizontal || BrowserGlass.matchWebsiteEdge) && tab.id == activeTabID
        var sampleX:CGFloat=0.5
        let rowID=splitTabIDs?.contains(tab.id) == true ? splitRepresentativeID ?? tab.id : tab.id
        if let row=horizontalRows[rowID],webView.bounds.width>0 {
            let point=webView.convert(row.convert(NSPoint(x:row.bounds.midX,y:0),to:nil),from:nil)
            sampleX=min(0.98,max(0.02,point.x/webView.bounds.width))
        }
        webView.evaluateJavaScript("window.__webbyChromeTone?.({enabled:\(enabled),x:\(sampleX),left:\(BrowserGlass.matchWebsiteEdge && BrowserTabPlacement.current != .horizontal),glass:\(BrowserGlass.pageInjectionEnabled)})",
            in:nil,in:BrowserChromeTone.world,completionHandler:nil)
        if BrowserGlass.pageInjectionEnabled {
            tab.prefersDarkGlass=true
            if tab.id == activeTabID {applyGlassTone(for:tab)}
            return
        }
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
        spaces.lazy.flatMap(\.tabs).first { $0.webView === view } ?? miniTabs.values.first {$0.webView === view}
    }

    private func tab(id: UUID) -> BrowserTab? {
        spaces.lazy.flatMap(\.tabs).first { $0.id == id } ?? miniTabs[id]
    }

    private func navigate(_ input: String, in tab: BrowserTab? = nil, profileID: UUID? = nil) {
        closeSuggestions()
        let query = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let target = tab ?? activeTab,
              let url = destination(for: query, profile: ownerSpace(for: target).saved.id) else { return }
        if BrowserExperiment.cyclesNewTabProfiles && target.fuseSearch && target.id == activeTabID && !target.isTerminal {
            let isWebsite = query.contains("://") || (!query.contains(where: \.isWhitespace) && (query.contains(".") || query.lowercased().hasPrefix("localhost")))
            let routingRevision=spaces.map{HistoryRevision(space:ObjectIdentifier($0),revision:$0.historyRevision)}
            let cachedProfile=fuseRouteRevision==routingRevision ? fuseRoutes[url.host?.lowercased() ?? ""]:nil
            let routedID = profileID ?? (isWebsite ? cachedProfile ?? FuseHistoryRouting.profile(for: url, sources: fuseHistorySources) : nil)
            if let routedID, let space = spaces.first(where: { $0.saved.id == routedID }), ownerSpace(for: target) !== space {
                if target.pageView == nil && !target.isTerminal { assignSearchProfile(target, to: space) }
                else {
                    addTab(select: false)
                    guard let fresh = tabs.last else { return }
                    assignSearchProfile(fresh, to: space)
                    selectTab(fresh)
                    navigate(input, in: fresh, profileID: space.saved.id)
                    return
                }
            }
        }
        if target.ide != nil {
            addTab(select: true)
            navigate(input)
            return
        }
        if target.engine == .chromium && !target.isTerminal {
            _ = openChromium(url, in: target, show: target.id == activeTabID)
            return
        }
        target.navigationTiming = BrowserNavigationTiming()
        target.currentNavigation = nil
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
            target.currentNavigation = view.load(URLRequest(url: url))
            refreshTabs()
            return
        }
        closeSuggestions()
        loadErrorLabel.isHidden = true
        target.loadError = nil
        let startsFromSearch = target.pageView == nil || target.showsSearchView
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
            globe.engine.showScene(usesFuseSearch ? BrowserExperiment.fuseScene : "search")
        }
        hideToolbar(animated: false)
        applyAddressChrome()
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
        target.currentNavigation = view.load(URLRequest(url: url))
        refreshTabs()
    }

    private func destination(for input: String, profile: UUID? = nil) -> URL? {
        if input.contains("://") {
            guard let url = URL(string: input), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
            return url
        }
        let lower = input.lowercased()
        if !input.contains(where: \.isWhitespace) && (input.contains(".") || lower == "localhost" || lower.hasPrefix("localhost:")) {
            return URL(string: "https://" + input)
        }
        let engine = BrowserSearchEngine.selected(for: profile ?? activeSpace.saved.id)
        var search = URLComponents(string: engine.searchBase)!
        search.queryItems = [URLQueryItem(name: "q", value: input)]
        return search.url
    }

    private func displayAddress(_ url: URL) -> String {
        if let host = url.host?.lowercased(),
           ["google.com", "www.google.com", "duckduckgo.com", "www.bing.com",
            "search.brave.com", "www.ecosia.org"].contains(host),
           ["/search", "/"].contains(url.path),
           let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let query = components.queryItems?.first(where: { $0.name == "q" })?.value, !query.isEmpty {
            return query
        }
        return url.absoluteString
    }

    @objc private func openAddress() {
        let text = addressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        navigate(text)
        window.makeFirstResponder(activeTab?.pageView)
    }

    @objc private func openHomeSearch() {
        guard let tab = activeTab, (tab.pageView == nil || tab.showsSearchView), !tab.isTerminal else { return }
        let query = homeSearchField.currentEditor()?.string ?? homeSearchField.stringValue
        tab.searchDraft = query
        navigate(query, in: tab)
    }
    @objc private func focusAddress() {
        if let mini=NSApp.keyWindow as? MiniWebbyWindow {mini.makeFirstResponder(mini.addressField);mini.addressField.currentEditor()?.selectAll(nil);return}
        if let ide = activeTab?.ide { ide.focus() }
        else if terminalMode { activeTab?.terminalView?.focus() }
        else if BrowserAddressPlacement.current == .tabBar && BrowserTabPlacement.current != .horizontal {
            if !sidebarVisible { toggleSidebar() }
            applyAddressChrome(); content.layoutSubtreeIfNeeded()
            window.makeFirstResponder(addressField)
            addressField.currentEditor()?.selectAll(nil)
        }
        else if activeTab?.pageView == nil || activeTab?.showsSearchView == true {
            window.makeFirstResponder(homeSearchField)
            homeSearchField.currentEditor()?.selectAll(nil)
        }
        else {
            showToolbar()
            window.makeFirstResponder(addressField)
            addressField.currentEditor()?.selectAll(nil)
        }
    }
    private func performNavigation(_ action: (WKWebView) -> WKNavigation?) {
        let target=(NSApp.keyWindow as? MiniWebbyWindow).flatMap{miniTabs[$0.tabID]} ?? activeTab
        guard let tab=target,let view=tab.webView else{return}
        tab.navigationTiming = BrowserNavigationTiming()
        tab.currentNavigation = action(view)
    }
    @objc private func goBack() { if !(NSApp.keyWindow is MiniWebbyWindow), let page = activeTab?.chromiumView { page.goBack() } else { performNavigation { $0.goBack() } } }
    @objc private func goForward() { if !(NSApp.keyWindow is MiniWebbyWindow), let page = activeTab?.chromiumView { page.goForward() } else { performNavigation { $0.goForward() } } }
    @objc private func reloadPage() { if !(NSApp.keyWindow is MiniWebbyWindow), let page = activeTab?.chromiumView { activeTab?.loadError = nil; loadErrorLabel.isHidden = true; page.reload() } else { performNavigation { $0.reload() } } }
    @objc private func closeCurrentTab() {
        if let mini=NSApp.keyWindow as? MiniWebbyWindow {closeMiniWebby(mini.tabID);return}
        guard let activeTabID else { return }
        if let ids = splitTabIDs, let anchor = splitRepresentativeID.flatMap({ tab(id: $0) }),
           anchor.savedSplit != nil, ids.contains(activeTabID) { closeVisibleTab(id: anchor.id) }
        else { closeTab(id: activeTabID) }
    }

    @objc private func splitWithPreviousTab() {
        if let ide = activeTab?.ide { ide.saveCurrentFile(); return }
        guard let current = activeTab, let previousTabID, previousTabID != current.id else { return }
        if !BrowserExperiment.cyclesNewTabProfiles,
           !tabs.contains(where: { $0.id == previousTabID }),
           let previous = tab(id: previousTabID) {
            let source = displaySpace(for: previous)
            source.tabs.removeAll { $0.id == previousTabID }
            if previous.isPinned { savePinnedTabs(for: source) }
            activeSpace.tabs.append(previous)
            if previous.isPinned { savePinnedTabs(for: activeSpace) }
        }
        if let previous = tab(id: previousTabID), previous.pageView == nil, previous.suspendedURL != nil {
            resumeTab(previous, show: false)
        }
        _ = splitTabs(sourceID: previousTabID, targetID: current.id)
    }

    @objc private func switchToProfileShortcut(_ sender: NSMenuItem) {
        guard spaces.indices.contains(sender.tag) else { return }
        if BrowserExperiment.cyclesNewTabProfiles {
            let profile = spaces[sender.tag].saved.id
            if let tab = tabs.first(where: { ownerSpace(for: $0).saved.id == profile && !$0.isFloating }) {
                selectTab(tab)
            }
        } else { switchToSpace(sender.tag) }
    }

    @objc private func showFindBar() {
        if let ide = activeTab?.ide { ide.find(); return }
        guard activeTab?.pageView != nil else { return }
        if findBar == nil {
            let bar = WebbyGlassBackdrop()
            bar.material = .popover
            bar.blendingMode = .withinWindow
            bar.state = .active
            bar.wantsLayer = true
            bar.layer?.cornerRadius = 14
            bar.layer?.masksToBounds = true
            bar.translatesAutoresizingMaskIntoConstraints = false
            let field = NSSearchField()
            field.placeholderString = "Find in page"
            field.target = self
            field.action = #selector(findNext)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.delegate = self
            let status = NSTextField(labelWithString: "")
            status.textColor = .secondaryLabelColor
            status.translatesAutoresizingMaskIntoConstraints = false
            let previous = NSButton(title: "↑", target: self, action: #selector(findPrevious))
            let next = NSButton(title: "↓", target: self, action: #selector(findNext))
            let close = NSButton(title: "×", target: self, action: #selector(hideFindBar))
            for button in [previous, next, close] {
                button.isBordered = false
                button.translatesAutoresizingMaskIntoConstraints = false
            }
            for child in [field, status, previous, next, close] as [NSView] { bar.addSubview(child) }
            pageArea.addSubview(bar, positioned: .above, relativeTo: nil)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: pageArea.topAnchor, constant: 12),
                bar.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor, constant: -16),
                bar.widthAnchor.constraint(equalToConstant: 390), bar.heightAnchor.constraint(equalToConstant: 46),
                field.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
                field.centerYAnchor.constraint(equalTo: bar.centerYAnchor), field.widthAnchor.constraint(equalToConstant: 220),
                status.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 5),
                status.centerYAnchor.constraint(equalTo: bar.centerYAnchor), status.widthAnchor.constraint(equalToConstant: 62),
                previous.leadingAnchor.constraint(equalTo: status.trailingAnchor, constant: 2),
                previous.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
                next.leadingAnchor.constraint(equalTo: previous.trailingAnchor, constant: 2),
                next.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
                close.leadingAnchor.constraint(equalTo: next.trailingAnchor, constant: 2),
                close.centerYAnchor.constraint(equalTo: bar.centerYAnchor)
            ])
            findBar = bar
            findField = field
            findStatus = status
        }
        findBar?.isHidden = false
        if let findBar {Motion.reveal(findBar,character:.panel)}
        window.makeFirstResponder(findField)
        findField?.currentEditor()?.selectAll(nil)
    }

    @objc private func hideFindBar() { if let findBar {Motion.depart(findBar,character:.panel)};findBar?.isHidden = true; window.makeFirstResponder(activeTab?.pageView) }
    @objc private func findNext() { if let ide = activeTab?.ide { ide.find(backwards: false); return }; findInPage(backwards: false) }
    @objc private func findPrevious() { if let ide = activeTab?.ide { ide.find(backwards: true); return }; findInPage(backwards: true) }

    @objc private func showSitePermissions() {
        guard let tab = activeTab, let host = tab.pageURL?.host ?? tab.suspendedURL?.host else { return }
        let profile = ownerSpace(for: tab).saved.id
        permissionEditingHost = host
        permissionEditingProfile = profile
        sitePermissionWindow?.close()
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Site Permissions"
        panel.isReleasedWhenClosed = false
        panel.center()
        let glass = WebbyGlassBackdrop(frame: panel.contentView?.bounds ?? .zero)
        glass.material = .popover
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.autoresizingMask = [.width, .height]
        panel.contentView = glass
        let heading = NSTextField(labelWithString: host)
        heading.font = WebbyTypography.font(ofSize: 18, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        heading.frame = NSRect(x: 24, y: 342, width: 372, height: 27)
        glass.addSubview(heading)
        let profileName = ownerSpace(for: tab).saved.name
        let subtitle = NSTextField(labelWithString: "Permissions for \(profileName)")
        subtitle.font = WebbyTypography.font(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.frame = NSRect(x: 24, y: 321, width: 372, height: 18)
        glass.addSubview(subtitle)
        for (index, kind) in SitePermission.allCases.enumerated() {
            let y = CGFloat(274 - index * 39)
            let label = NSTextField(labelWithString: kind.title)
            label.font = WebbyTypography.font(ofSize: 13)
            label.frame = NSRect(x: 27, y: y + 4, width: 160, height: 20)
            glass.addSubview(label)
            let picker = NSPopUpButton(frame: NSRect(x: 200, y: y, width: 190, height: 28), pullsDown: false)
            picker.addItems(withTitles: ["Ask", "Allow", "Block"])
            picker.selectItem(at: SitePermission.choice(kind, host: host, profile: profile))
            picker.tag = index
            picker.target = self
            picker.action = #selector(sitePermissionChanged(_:))
            glass.addSubview(picker)
        }
        let note = NSTextField(labelWithString: "Allow does not bypass macOS or website permission prompts.")
        note.font = WebbyTypography.font(ofSize: 10)
        note.textColor = .tertiaryLabelColor
        note.frame = NSRect(x: 24, y: 12, width: 380, height: 16)
        glass.addSubview(note)
        sitePermissionWindow = panel
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func sitePermissionChanged(_ sender: NSPopUpButton) {
        guard let host = permissionEditingHost, let profile = permissionEditingProfile,
              SitePermission.allCases.indices.contains(sender.tag) else { return }
        SitePermission.set(sender.indexOfSelectedItem, for: SitePermission.allCases[sender.tag],
                           host: host, profile: profile)
        let splitIDs = splitTabIDs
        if splitIDs != nil { endSplit() }
        for tab in spaces.flatMap(\.tabs) where tab.ownerSpaceID == profile
            && tab.webView != nil && !tab.isFloating {
            guard let url = tab.pageURL else { continue }
            let selected = tab.id == activeTabID
            tab.suspendedURL = url
            releaseWebView(for: tab)
            resumeTab(tab, show: selected)
        }
        if let splitIDs, splitIDs.allSatisfy({ tab(id: $0)?.splitSurface != nil }) { renderSplit(splitIDs) }
    }

    private func findInPage(backwards: Bool) {
        if let page = activeTab?.chromiumView, let query = findField?.stringValue, !query.isEmpty {
            page.findText(query, backwards: backwards); findStatus?.stringValue = ""; return
        }
        guard let view = activeWebView, let query = findField?.stringValue, !query.isEmpty else {
            findStatus?.stringValue = ""
            return
        }
        let options = WKFindConfiguration()
        options.backwards = backwards
        options.wraps = true
        view.find(query, configuration: options) { [weak self] result in
            self?.findStatus?.stringValue = result.matchFound ? "Found" : "No match"
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field=obj.object as? NSTextField,let raw=field.identifier?.rawValue,let id=UUID(uuidString:raw),miniTabs[id] != nil {showMiniSuggestions(id);return}
        guard obj.object as? NSTextField === findField else { return }
        findInPage(backwards: false)
    }

    private func updateNavigation() {
        backButton.isEnabled = activeTab?.chromiumView?.canGoBack ?? (activeWebView?.canGoBack == true)
        forwardButton.isEnabled = activeTab?.chromiumView?.canGoForward ?? (activeWebView?.canGoForward == true)
        if !terminalMode && addressField.currentEditor() == nil { addressField.stringValue = activeTab?.pageURL.map(displayAddress) ?? "" }
        addressField.toolTip = activeTab?.pageURL?.absoluteString
        applyAddressChrome()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if pointerLockedWebView === webView { releasePointerLock() }
        if let tab = tab(for: webView) {
            tab.recoveryOverlay?.removeFromSuperview(); tab.recoveryOverlay = nil
            tab.navigationTiming = BrowserNavigationTiming()
            tab.siteName=nil
            tab.currentNavigation = navigation
            tab.loadError = nil
            tab.navigationInProgress = true
            tab.previewImage = nil
            tab.previewCapturedAt = 0
            tab.previewGeneration += 1
            tab.faviconGeneration += 1
            tab.faviconTask?.cancel()
            tab.faviconTask = nil
            // Keep the existing icon until its replacement arrives.
            refreshTabContent(tab)
            updateMiniChrome(tab)
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
                applyAddressChrome()
                homeView.isHidden = false
                webView.alphaValue = 0.001
                homeSearchSurface.isHidden = false
                homeSearchSurface.startLoading()
                if let pending = tab.pendingSearchInput { tab.searchDraft = pending }
                else if let url = webView.url { tab.searchDraft = displayAddress(url) }
                homeSearchField.stringValue = tab.searchDraft
                globe.engine.showScene("search")
            } else {
                applyAddressChrome()
                homeView.isHidden = true
                webView.alphaValue = 1
            }
        }
    }

    private func requestPagePresentation(_ tab: BrowserTab, webView: WKWebView) {
        let generation = tab.navigationTiming.id
        // Commit means a response exists, not that it has painted. Give WebKit a
        // presentation opportunity, with a bounded fallback for busy pages.
        webView.callAsyncJavaScript("await new Promise(resolve => requestAnimationFrame(() => resolve())); return true",
            arguments: [:], in: nil, in: BrowserPageActivity.world) { [weak self, weak tab, weak webView] result in
                guard case .success = result, let self, let tab, let webView else { return }
                self.presentPage(tab, webView: webView, generation: generation)
            }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak tab, weak webView] in
            guard let self, let tab, let webView else { return }
            self.presentPage(tab, webView: webView, generation: generation)
        }
    }

    private func presentPage(_ tab: BrowserTab, webView: WKWebView, generation: UUID) {
        guard self.tab(id: tab.id) === tab, tab.webView === webView, tab.navigationTiming.id == generation,
              tab.navigationTiming.committed != nil, tab.loadError == nil else { return }
        guard tab.navigationTiming.presented == nil else { return }
        tab.navigationTiming.presented = ProcessInfo.processInfo.systemUptime
        tab.showsSearchView = false
        webView.alphaValue = 1
        guard tab.id == activeTabID else { return }
        homeView.isHidden = true
        webView.isHidden = false
        globe.engine.hide()
        homeSearchSurface.stopLoading()
        applyAddressChrome()
        if homeSearchField.currentEditor() != nil {
            homeSearchField.abortEditing(); window.makeFirstResponder(webView)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tab(for: webView), tab.currentNavigation === navigation else { return }
        tab.navigationTiming.committed = ProcessInfo.processInfo.systemUptime
        updateMiniChrome(tab)
        tab.hasUnsavedEdits = false
        tab.captureMayBeActive = false
        requestPagePresentation(tab, webView: webView)
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
        refreshTabContent(tab)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = tab(for: webView), tab.currentNavigation === navigation else { return }
        tab.navigationTiming.finished = ProcessInfo.processInfo.systemUptime
        readSiteName(tab,view:webView)
        sendChatGPTDraft(tab,webView:webView)
        updateMiniChrome(tab)
        presentPage(tab, webView: webView, generation: tab.navigationTiming.id)
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
            if GitHubWidgetStore.repositoryURL(url) != nil {
                let profile = space.saved.id
                Task {
                    await GitHubWidgetStore.shared.recordVisit(url, profile: profile)
                    NotificationCenter.default.post(name:.webbyGitHubChanged,object:profile,userInfo:["recentOnly":true])
                }
            }
            if tab.isPinned { savePinnedTabs(for: space) }
            scheduleSpaceSave()
            scheduleSessionSave()
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
            applyAddressChrome()
            let token = navigationToken
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.navigationToken == token else { return }
                self.toolbar.hideProgress()
            }
            updateNavigation()
        }
        refreshTabContent(tab)
        if let position = tab.restoredScroll {
            tab.restoredScroll = nil
            webView.callAsyncJavaScript("window.scrollTo(x, y)", arguments: ["x": position.x, "y": position.y],
                                       in: nil, in: .page, completionHandler: nil)
        }
        loadFavicon(for: tab, webView: webView)
        if tab.id == activeTabID || tab.isFloating {
            let tabID = tab.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, let current = self.tab(id: tabID) else { return }
                self.captureTabPreview(current)
            }
        }
    }

    private func restoreFavicon(for tab: BrowserTab, url: URL) {
        guard tab.favicon == nil else { return }
        let profile = ownerSpace(for: tab).saved.id
        persistentFavicons.load(for: url, profile: profile) { [weak self, weak tab] image in
            guard let self, let tab, self.tab(id: tab.id) === tab, tab.favicon == nil,
                  self.ownerSpace(for: tab).saved.id == profile,
                  (tab.pageURL ?? tab.suspendedURL)?.absoluteString == url.absoluteString,
                  let image else { return }
            tab.favicon = image
            self.suggestions.rememberFavicon(image, for: url)
            self.refreshTabContent(tab)
        }
    }

    private func rememberFavicon(_ image: NSImage, for tab: BrowserTab, pageURL: URL) {
        persistentFavicons.remember(image, for: pageURL, profile: ownerSpace(for: tab).saved.id)
        suggestions.rememberFavicon(image, for: pageURL)
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
        let script = """
        const links = Array.from(document.querySelectorAll('link[rel]'))
            .filter(x => /(?:^|\\s)(?:icon|apple-touch-icon)(?:\\s|$)/i.test(x.rel) && x.href);
        // Prefer raster icons, but let WebKit decode SVG and authenticated assets too.
        links.sort((a, b) => Number(/svg/i.test(a.type + a.href)) - Number(/svg/i.test(b.type + b.href)));
        const urls = [...new Set(links.map(x => x.href))].slice(0, 8);
        for (const url of urls) {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), 2500);
            let objectURL;
            try {
                const response = await fetch(url, {credentials: 'same-origin', signal: controller.signal});
                if (!response.ok) continue;
                const blob = await response.blob();
                if (blob.size > 1000000 || !blob.type.startsWith('image/')) continue;
                objectURL = URL.createObjectURL(blob);
                const image = new Image(); image.src = objectURL;
                await image.decode();
                const canvas = document.createElement('canvas'); canvas.width = canvas.height = 64;
                canvas.getContext('2d').drawImage(image, 0, 0, 64, 64);
                return {urls, png: canvas.toDataURL('image/png').split(',')[1]};
            } catch (_) {
            } finally {
                clearTimeout(timer);
                if (objectURL) URL.revokeObjectURL(objectURL);
            }
        }
        return {urls};
        """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page, completionHandler: { [weak self, weak webView] result in
            DispatchQueue.main.async {
                guard let self, let webView, let current = self.tab(id: tab.id),
                      current.faviconGeneration == generation, current.webView === webView else { return }
                let value = (try? result.get()) as? [String: Any]
                if let png = value?["png"] as? String, let data = Data(base64Encoded: png),
                   let image = NSImage(data: data) {
                    current.favicon = image
                    self.rememberFavicon(image, for: current, pageURL: pageURL)
                    self.refreshTabContent(current)
                    return
                }
                let declared = (value?["urls"] as? [String] ?? []).compactMap(URL.init(string:))
                let candidates = (declared + [fallback].compactMap { $0 })
                    .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
                self.fetchFavicon(candidates, index: 0, tabID: tab.id, generation: generation)
            }
        })
    }

    private func fetchFavicon(_ candidates: [URL], index: Int, tabID: UUID, generation: Int) {
        guard let tab = tab(id: tabID),
              tab.faviconGeneration == generation, candidates.indices.contains(index) else { return }
        let url = candidates[index]
        if let cached = faviconCache[url] {
            tab.favicon = cached
            if let pageURL = tab.pageURL { rememberFavicon(cached, for: tab, pageURL: pageURL) }
            refreshTabContent(tab)
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
                    if self.faviconCache.count >= 256 { self.faviconCache.removeAll(keepingCapacity: true) }
                    self.faviconCache[url] = image
                    current.favicon = image
                    if let pageURL = current.pageURL {
                        self.rememberFavicon(image, for: current, pageURL: pageURL)
                    }
                    self.refreshTabContent(current)
                } else {
                    self.fetchFavicon(candidates, index: index + 1, tabID: tabID, generation: generation)
                }
            }
        }
        tab.faviconTask?.resume()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        if pointerLockedWebView === webView { releasePointerLock() }
        tab.faviconTask?.cancel(); tab.faviconTask = nil
        tab.faviconGeneration += 1; tab.previewGeneration += 1
        tab.previewCaptureInFlight = false; tab.discardCheckInFlight = false
        tab.currentNavigation = nil
        tab.navigationTiming = BrowserNavigationTiming()
        tab.captureMayBeActive = false; tab.hasPictureInPicture = false
        if let url = webView.url { tab.searchDraft = displayAddress(url) }
        tab.pendingSearchInput = tab.searchDraft
        // A native recovery control also works in split panes and floating windows,
        // where the shared homepage error label would otherwise be hidden.
        tab.recoveryOverlay?.removeFromSuperview()
        let recovery = WebbyGlassBackdrop()
        recovery.material = .hudWindow; recovery.blendingMode = .withinWindow
        recovery.wantsLayer = true; recovery.layer?.cornerRadius = 14; recovery.layer?.masksToBounds = true
        let label = NSTextField(wrappingLabelWithString: "This page stopped. Let’s reload it.")
        label.alignment = .center
        let retry = NSButton(title: "Reload Page", target: self, action: #selector(reloadStoppedPage(_:)))
        retry.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString); retry.bezelStyle = .rounded
        for child in [label, retry] { child.translatesAutoresizingMaskIntoConstraints = false; recovery.addSubview(child) }
        recovery.translatesAutoresizingMaskIntoConstraints = false; webView.addSubview(recovery)
        NSLayoutConstraint.activate([
            recovery.centerXAnchor.constraint(equalTo: webView.centerXAnchor),
            recovery.centerYAnchor.constraint(equalTo: webView.centerYAnchor),
            recovery.widthAnchor.constraint(lessThanOrEqualTo: webView.widthAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: recovery.topAnchor, constant: 16),
            label.leadingAnchor.constraint(equalTo: recovery.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: recovery.trailingAnchor, constant: -16),
            retry.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 12),
            retry.centerXAnchor.constraint(equalTo: recovery.centerXAnchor),
            retry.bottomAnchor.constraint(equalTo: recovery.bottomAnchor, constant: -16)
        ])
        tab.recoveryOverlay = recovery
        // Never automatically replay a form submission or loop on a crashing site.
        navigationFailed(in: webView, error: NSError(domain: "WebbyRenderer", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "This page’s web process stopped. Press Command-R to reload it."]))
        if splitTabIDs?.contains(tab.id) == true || tab.isFloating {
            tab.showsSearchView = false; webView.alphaValue = 1
            if splitTabIDs?.contains(activeTabID ?? UUID()) == true { homeView.isHidden = true }
        }
    }

    @objc private func reloadStoppedPage(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw),
              let tab = tab(id: id), let view = tab.webView else { return }
        tab.navigationTiming = BrowserNavigationTiming()
        tab.currentNavigation = view.reload()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard let tab = tab(for: webView), tab.currentNavigation == nil || tab.currentNavigation === navigation else { return }
        tab.currentNavigation = navigation
        navigationFailed(in: webView, error: error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard let tab = tab(for: webView), tab.currentNavigation == nil || tab.currentNavigation === navigation else { return }
        tab.currentNavigation = navigation
        navigationFailed(in: webView, error: error)
    }

    private func navigationFailed(in webView: WKWebView, error: Error) {
        let failure = error as NSError
        guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled),
              let tab = tab(for: webView) else { return }
        tab.navigationInProgress = false
        if let mini=floatingWindows[tab.id] as? MiniWebbyWindow {mini.status.stringValue="Couldn’t load this page. Reload to try again.";mini.progress.isHidden=true;return}
        if tab.navigationTiming.presented != nil {
            tab.loadError = "The page stopped loading. Reload to try again."
            refreshTabContent(tab)
            if tab.id == activeTabID { toolbar.hideProgress(); homeSearchSurface.stopLoading() }
            return
        }
        tab.navigationTiming = BrowserNavigationTiming()
        tab.showsSearchView = true
        let address = webView.url?.host ?? "this site"
        tab.loadError = "Couldn’t load \(address): \(error.localizedDescription)\nLet’s check the address and try again. You can also turn off ad blocking in View."
        refreshTabs()
        if tab.id == activeTabID {
            toolbar.hideProgress()
            webView.isHidden = false
            homeSearchSurface.stopLoading()
            homeView.isHidden = false
            webView.alphaValue = 0.001
            applyAddressChrome()
            globe.engine.showScene("search")
            loadErrorLabel.stringValue = tab.loadError ?? ""
            loadErrorLabel.isHidden = false
            homeSearchField.stringValue = tab.pendingSearchInput ?? tab.searchDraft
            updateNavigation()
        }
    }

    private func isCommandLink(_ action:WKNavigationAction,source:BrowserTab)->Bool {
        if action.modifierFlags.contains(.command) {return true}
        if let intent=commandLinkIntent,intent.source==source.id,ProcessInfo.processInfo.systemUptime-intent.time<0.75 {return true}
        guard let event=NSApp.currentEvent,[NSEvent.EventType.leftMouseDown,.leftMouseUp].contains(event.type),event.modifierFlags.contains(.command) else{return false}
        return ProcessInfo.processInfo.systemUptime-event.timestamp<0.75
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload,
           let tab = tab(for: webView), let host = webView.url?.host,
           SitePermission.choice(.downloads, host: host, profile: ownerSpace(for: tab).saved.id) == 2 {
            decisionHandler(.cancel)
            return
        }
        if navigationAction.targetFrame?.isMainFrame != false, let tab = tab(for:webView) {
            tab.lastMainFrameRequest = navigationAction.request
            tab.lastMainFrameSourceURL = webView.url
        }
        if navigationAction.shouldPerformDownload,
           let url = navigationAction.request.url, ["http","https"].contains(url.scheme?.lowercased() ?? ""),
           (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET",
           navigationAction.request.httpBody == nil, navigationAction.request.httpBodyStream == nil {
            decisionHandler(.cancel)
            downloads.startGET(navigationAction.request,from:webView.configuration.websiteDataStore.httpCookieStore,sourceURL:webView.url,suggestedFilename:nil)
            return
        }
        if navigationAction.navigationType == .linkActivated,
           navigationAction.modifierFlags.intersection([.command,.option]) == [.command,.option],
           let source=tab(for:webView),let url=navigationAction.request.url,["http","https"].contains(url.scheme?.lowercased() ?? "") {
            decisionHandler(.cancel);openMiniWebby(url:url,profile:ownerSpace(for:source).saved.id);return
        }
        if navigationAction.navigationType == .linkActivated,
           let source = tab(for: webView),isCommandLink(navigationAction,source:source),
           let url = navigationAction.request.url,
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            let tab = BrowserTab()
            tab.ownerSpaceID = ownerSpace(for: source).saved.id
            tab.title = url.host ?? "New Tab"
            tab.searchDraft=url.absoluteString
            tab.showsSearchView=false
            tab.navigationInProgress = true
            displaySpace(for: source).tabs.append(tab)
            if BrowserExperiment.cyclesNewTabProfiles { fusedTabOrder.append(tab.id) }
            let background = makeWebView(for: tab)
            background.isHidden = true
            background.load(navigationAction.request)
            groupBackgroundLink(tab,from:source,url:url)
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
        let isDownload = !navigationResponse.canShowMIMEType || disposition.contains("attachment")
        if isDownload, let tab = tab(for: webView), let host = webView.url?.host,
           SitePermission.choice(.downloads, host: host, profile: ownerSpace(for: tab).saved.id) == 2 {
            decisionHandler(.cancel)
        } else if isDownload, navigationResponse.isForMainFrame,
                  let tab = tab(for:webView), let request = tab.lastMainFrameRequest,
                  let url = request.url, ["http","https"].contains(url.scheme?.lowercased() ?? ""),
                  (request.httpMethod ?? "GET").uppercased() == "GET", request.httpBody == nil, request.httpBodyStream == nil {
            decisionHandler(.cancel)
            tab.navigationInProgress = false
            downloads.startGET(request,from:webView.configuration.websiteDataStore.httpCookieStore,sourceURL:tab.lastMainFrameSourceURL,suggestedFilename:navigationResponse.response.suggestedFilename,expectedMIMEType:navigationResponse.response.mimeType)
            if tab.id == activeTabID { toolbar.hideProgress();homeSearchSurface.stopLoading() }
        } else { decisionHandler(isDownload ? .download : .allow) }
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
        if let source = tab(for: webView), let host = webView.url?.host,
           SitePermission.choice(.popups, host: host, profile: ownerSpace(for: source).saved.id) == 2 { return nil }
        guard let source = self.tab(for: webView) else { return nil }
        if miniTabs[source.id] != nil {
            let mini=openMiniWebby(profile:ownerSpace(for:source).saved.id,popupConfiguration:configuration)
            return mini.webView
        }
        let tab = BrowserTab()
        tab.ownerSpaceID = ownerSpace(for: source).saved.id
        tab.showsSearchView = false
        tab.navigationInProgress = true
        displaySpace(for: source).tabs.append(tab)
        if BrowserExperiment.cyclesNewTabProfiles { fusedTabOrder.append(tab.id) }
        let commandLink=isCommandLink(navigationAction,source:source)
        let background = commandLink
            || !tabs.contains(where: { $0.id == source.id })
        // Construct with WebKit's exact configuration before selection can create a default view.
        let popup = makeWebView(for: tab, popupConfiguration: configuration)
        if !background { selectTab(tab) }
        popup.isHidden = background
        popup.alphaValue = 1
        if commandLink,let url=navigationAction.request.url {
            tab.searchDraft=url.absoluteString
            groupBackgroundLink(tab,from:source,url:url)
        }
        if !background {
            homeView.isHidden = true
            applyAddressChrome()
        }
        refreshTabs()
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let tab = tab(for: webView) else { return }
        closeTab(id: tab.id)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        guard let tab = tab(for: webView) else { decisionHandler(.deny); return }
        let profile = ownerSpace(for: tab).saved.id
        let host = origin.host
        let kinds: [SitePermission]
        switch type {
        case .camera: kinds = [.camera]
        case .microphone: kinds = [.microphone]
        case .cameraAndMicrophone: kinds = [.camera, .microphone]
        @unknown default: decisionHandler(.deny); return
        }
        let choices = kinds.map { SitePermission.choice($0, host: host, profile: profile) }
        if choices.contains(2) { decisionHandler(.deny); return }
        if choices.allSatisfy({ $0 == 1 }) { tab.captureMayBeActive = true; decisionHandler(.grant); return }
        let alert = NSAlert()
        alert.messageText = "Allow \(host) to use \(kinds.map(\.title).joined(separator: " and "))?"
        alert.informativeText = "This permission applies to the \(ownerSpace(for: tab).saved.name) profile."
        alert.addButton(withTitle: "Allow Once")
        alert.addButton(withTitle: "Always Allow")
        alert.addButton(withTitle: "Block")
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                for kind in kinds { SitePermission.set(1, for: kind, host: host, profile: profile) }
                tab.captureMayBeActive = true; decisionHandler(.grant)
            } else if response == .alertFirstButtonReturn { tab.captureMayBeActive = true; decisionHandler(.grant) }
            else { decisionHandler(.deny) }
        }
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

    @objc(_webView:hasVideoInPictureInPictureDidChange:)
    func webView(_ webView: WKWebView, hasVideoInPictureInPictureDidChange active: Bool) {
        if let tab = tab(for: webView) {
            tab.hasPictureInPicture = active
            if !active { tab.returningPictureInPicture = false }
        }
        pipWindowMotion.setActive(spaces.flatMap(\.tabs).contains { $0.hasPictureInPicture } || miniTabs.values.contains { $0.hasPictureInPicture })
    }

    private func returnVideoInline(_ tab: BrowserTab) {
        guard tab.hasPictureInPicture, !tab.returningPictureInPicture, !restoringVideoInline,
              let view = tab.webView, view.fullscreenState == .notInFullscreen else { return }
        tab.returningPictureInPicture = true
        pipWindowMotion.cancel()
        // Let the selected page paint its final geometry before native PiP flies back.
        // Per-video inline presentation avoids WebKit's crashing close-all callback path.
        view.callAsyncJavaScript("await new Promise(resolve=>requestAnimationFrame(resolve));window.__webbyReturnVideoInline?.();return true",
            arguments: [:], in: nil, in: WKContentWorld.world(name: "WebbyVideo")) { [weak tab,weak view] result in
                guard let tab,tab.webView === view else { return }
                if case .failure = result { tab.returningPictureInPicture = false }
            }
    }

    @objc(_webViewFullscreenMayReturnToInline:)
    func webViewVideoMayReturnToInline(_ webView: WKWebView) {
        guard let tab = tab(for: webView), !restoringVideoInline, !tab.returningPictureInPicture else { return }
        restoringVideoInline = true
        defer { restoringVideoInline = false }
        if let host = floatingWindows[tab.id] {
            host.makeKeyAndOrderFront(nil)
        } else {
            if !BrowserExperiment.cyclesNewTabProfiles,
               let index = spaces.firstIndex(where: { $0.tabs.contains { $0.id == tab.id } }), index != activeSpaceIndex {
                switchToSpace(index)
            }
            selectTab(tab)
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc(_webViewDidRequestPointerLock:completionHandler:)
    func webViewDidRequestPointerLock(_ webView: WKWebView, completionHandler: @escaping (Bool) -> Void) {
        guard NSApplication.shared.isActive, webView.window?.isKeyWindow == true,
              !webView.isHiddenOrHasHiddenAncestor, let tab = tab(for: webView),
              !tab.showsSearchView,
              tab.isFloating || tab.id == activeTabID ||
                (splitTabIDs?.contains(tab.id) == true && splitView?.isHidden == false) else {
            completionHandler(false)
            return
        }
        if let locked = pointerLockedWebView, locked !== webView { releasePointerLock() }
        pointerLockedWebView = webView
        completionHandler(true)
    }

    @objc(_webViewDidLosePointerLock:)
    func webViewDidLosePointerLock(_ webView: WKWebView) {
        if pointerLockedWebView === webView { pointerLockedWebView = nil }
    }

    private func releasePointerLock() {
        let locked = pointerLockedWebView
        pointerLockedWebView = nil
        locked?.evaluateJavaScript("document.exitPointerLock?.()", completionHandler: nil)
    }

    func applicationDidResignActive(_ notification: Notification) {
        releasePointerLock()
        dismissTabSwitcher()
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let locked = pointerLockedWebView,
              notification.object as? NSWindow === locked.window else { return }
        releasePointerLock()
    }

    private func splitFractions() -> [Double] {
        var result: [Double] = []
        func visit(_ split: NSSplitView) {
            guard let first = split.arrangedSubviews.first else { return }
            let length = split.isVertical ? split.bounds.width : split.bounds.height
            let size = split.isVertical ? first.frame.width : first.frame.height
            result.append(length > 0 ? Double(size / length) : 0.5)
            for child in split.arrangedSubviews {
                if let nested = child as? NSSplitView { visit(nested) }
            }
        }
        if let splitView { visit(splitView) }
        return result
    }

    private func savedSplitRecord(for anchor: BrowserTab) -> SavedSplitRecord? {
        guard let saved = anchor.savedSplit else { return nil }
        let ids = anchor.savedSplitTabIDs
        let pages = ids.compactMap { id -> SavedSplitRecord.Page? in
            guard let page = tab(id: id),
                  let url = page.pageURL ?? page.suspendedURL ?? URL(string: page.searchDraft),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return .init(title: page.title, url: url.absoluteString, owner: ownerSpace(for: page).saved.id, engine: page.engine)
        }
        guard pages.count == saved.pages.count else { return saved }
        return SavedSplitRecord(pages: pages, layout: splitTabIDs == ids ? splitLayout.rawValue : saved.layout,
                                fractions: splitTabIDs == ids ? splitFractions() : saved.fractions,
                                anchorIndex: ids.firstIndex(of: anchor.id) ?? saved.anchorIndex)
    }

    @objc private func pinEntireSplit() {
        guard let ids = splitTabIDs, let first = splitRepresentativeID, let anchor = tab(id: first) else { return }
        let pages = ids.compactMap { id -> SavedSplitRecord.Page? in
            guard let page = tab(id: id), let url = page.pageURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return .init(title: page.title, url: url.absoluteString, owner: ownerSpace(for: page).saved.id, engine: page.engine)
        }
        guard pages.count == ids.count else { return }
        rememberLayout()
        anchor.isPinned = true
        anchor.savedSplit = SavedSplitRecord(pages: pages, layout: splitLayout.rawValue, fractions: splitFractions(),
                                            anchorIndex: ids.firstIndex(of: anchor.id))
        anchor.savedSplitTabIDs = ids
        savePinnedTabs(for: displaySpace(for: anchor))
        refreshTabs()
    }

    private func openPinnedSplit(_ anchor: BrowserTab) {
        guard let saved = anchor.savedSplit, (2...4).contains(saved.pages.count) else { return }
        restoringPinnedSplit = true
        defer { restoringPinnedSplit = false }
        // The anchor's display profile hosts the saved workspace. Each page's
        // immutable owner continues to select its original WebKit data store.
        let host = displaySpace(for: anchor)
        var members: [BrowserTab] = []
        for (index, page) in saved.pages.enumerated() {
            guard spaces.contains(where: { $0.saved.id == page.owner }),
                  let url = URL(string: page.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { continue }
            let referenced = anchor.savedSplitTabIDs.indices.contains(index)
                ? tab(id: anchor.savedSplitTabIDs[index]) : nil
            let existing = referenced ?? host.tabs.first(where: { candidate in
                candidate.id != anchor.id && !members.contains(where: { $0.id == candidate.id })
                    && !candidate.isFloating && !candidate.isTerminal
                    && candidate.ownerSpaceID == page.owner
                    && (candidate.pageURL?.absoluteString ?? candidate.suspendedURL?.absoluteString ?? candidate.searchDraft) == page.url
            })
            let reusable = existing.map { !$0.isFloating && (!$0.isPinned || displaySpace(for: $0) === host) } ?? false
            let member = index == (saved.anchorIndex ?? 0) ? anchor : (reusable ? existing! : BrowserTab())
            if !spaces.contains(where: { $0.tabs.contains(where: { $0 === member }) }) {
                member.ownerSpaceID = page.owner
                member.title = page.title
                member.engine = page.engine ?? .webKit
                member.searchDraft = page.url
                member.suspendedURL = url
                host.tabs.append(member)
                restoreFavicon(for: member, url: url)
            }
            if !BrowserExperiment.cyclesNewTabProfiles, displaySpace(for: member) !== host {
                let old = displaySpace(for: member)
                old.tabs.removeAll { $0.id == member.id }
                if old.activeTabID == member.id { old.activeTabID = nil }
                host.tabs.append(member)
                if member.isPinned { savePinnedTabs(for: old) }
            }
            if member.pageView == nil { resumeTab(member, show: false) }
            members.append(member)
        }
        guard members.count >= 2 else {
            activeTabID = nil; selectTab(anchor); return
        }
        if !BrowserExperiment.cyclesNewTabProfiles,
           let index = spaces.firstIndex(where: { $0 === host }), activeSpaceIndex != index {
            switchToSpace(index)
        }
        anchor.savedSplitTabIDs = members.map(\.id)
        splitLayout = SplitLayout(rawValue: saved.layout) ?? .columns
        if splitLayout == .grid && members.count != 4 { splitLayout = .columns }
        renderSplit(members.map(\.id), fractions: saved.fractions)
        activeTabID = nil
        selectTab(anchor)
        savePinnedTabs(for: host)
    }

    private func layoutSnapshot() -> LayoutSnapshot {
        LayoutSnapshot(spaces: spaces.map { space in
            (space.saved.id, space.tabs.map {
                LayoutSnapshot.Entry(id: $0.id, pinned: $0.isPinned, width: $0.pinWidthFraction,
                                     height: $0.pinHeight, group: $0.groupID,
                                     savedSplit: $0.savedSplit, savedIDs: $0.savedSplitTabIDs)
            })
        }, groups: tabGroups, order: fusedTabOrder, split: splitTabIDs ?? [],
           layout: splitLayout, fractions: splitFractions(), active: activeTabID)
    }

    private func rememberLayout() {
        guard !applyingLayout else { return }
        layoutUndo.append(layoutSnapshot())
        if layoutUndo.count > 40 { layoutUndo.removeFirst() }
        layoutRedo.removeAll()
    }

    @objc private func undoTabLayout() {
        guard let state = layoutUndo.popLast() else { return }
        layoutRedo.append(layoutSnapshot()); applyLayout(state)
    }

    @objc private func redoTabLayout() {
        guard let state = layoutRedo.popLast() else { return }
        layoutUndo.append(layoutSnapshot()); applyLayout(state)
    }

    private func applyLayout(_ state: LayoutSnapshot) {
        applyingLayout = true
        restoringPinnedSplit = true
        defer { applyingLayout = false; restoringPinnedSplit = false }
        dismissTabSwitcher()
        endSplit()
        // Restore only surviving tabs and profiles; undo must never resurrect a
        // deleted account, resurrect closed tabs, or destroy newly opened tabs.
        let all = spaces.flatMap(\.tabs)
        let live = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        let restorable = state.spaces.filter { entry in spaces.contains { $0.saved.id == entry.0 } }
        let moved = Set(restorable.flatMap { $0.1.map(\.id) })
        for space in spaces { space.tabs.removeAll { moved.contains($0.id) } }
        for (profile, entries) in restorable {
            guard let space = spaces.first(where: { $0.saved.id == profile }) else { continue }
            for entry in entries {
                guard let tab = live[entry.id] else { continue }
                tab.isPinned = entry.pinned; tab.pinWidthFraction = entry.width; tab.pinHeight = entry.height
                tab.groupID = entry.group; tab.savedSplit = entry.savedSplit; tab.savedSplitTabIDs = entry.savedIDs
                space.tabs.append(tab)
            }
        }
        for space in spaces {
            if let id = space.activeTabID, !space.tabs.contains(where: { $0.id == id }) { space.activeTabID = nil }
        }
        tabGroups = state.groups.filter { group in spaces.contains { $0.saved.id == group.profileID } }
        fusedTabOrder = state.order.filter { live[$0] != nil } + all.map(\.id).filter { !state.order.contains($0) }
        let ids = state.split.filter { live[$0]?.isFloating == false && (live[$0]?.ide != nil || live[$0]?.isTerminal == false) }
        if ids.count == state.split.count, ids.count >= 2,
           BrowserExperiment.cyclesNewTabProfiles || Set(ids.compactMap { live[$0].map { displaySpace(for: $0).saved.id } }).count == 1 {
            for id in ids { if let tab = live[id], tab.ide == nil, tab.pageView == nil { resumeTab(tab, show: false) } }
            splitLayout = state.layout
            renderSplit(ids, fractions: state.fractions)
        }
        if let id = state.active, let tab = live[id], !tab.isFloating {
            if !BrowserExperiment.cyclesNewTabProfiles,
               let index = spaces.firstIndex(where: { $0.tabs.contains { $0.id == id } }) { switchToSpace(index) }
            activeTabID = nil; selectTab(tab)
        } else if let tab = activeTab { activeTabID = nil; selectTab(tab) }
        for space in spaces { savePinnedTabs(for: space) }
        saveTabGroups(); scheduleSessionSave(); refreshTabs()
    }

    private func dropLink(_ url: URL, on target: BrowserTab, zone: Int) -> Bool {
        guard tabs.contains(where: { $0.id == target.id }) else { return false }
        if zone == 0 {
            navigate(url.absoluteString, in: target)
            selectTab(target)
            return true
        }
        let existing = splitTabIDs?.contains(target.id) == true ? splitTabIDs! : [target.id]
        guard existing.count < 4 else { return false }
        rememberLayout()
        let new = BrowserTab()
        new.ownerSpaceID = ownerSpace(for: target).saved.id
        new.searchDraft = url.absoluteString
        new.title = url.host ?? "New Tab"
        displaySpace(for: target).tabs.append(new)
        if new.engine == .chromium { _ = openChromium(url, in: new, show: false) }
        else { new.currentNavigation = makeWebView(for: new).load(URLRequest(url: url)) }
        var ids = existing
        let index = ids.firstIndex(of: target.id) ?? 0
        ids.insert(new.id, at: index + ((zone == 2 || zone == 4) ? 1 : 0))
        splitLayout = zone <= 2 ? .columns : .rows
        renderSplit(ids)
        activeTabID = nil; selectTab(new)
        return true
    }

    private func installTabShortcuts() {
        tabShortcutMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, event.window === self.window || self.switcherPanel != nil else { return event }
            if event.type == .flagsChanged {
                if self.switcherPanel != nil && !event.modifierFlags.contains(.control) { self.commitTabSwitcher() }
                return event
            }
            if self.bypassLayoutShortcut { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if event.keyCode == 53, self.pointerLockedWebView != nil {
                self.releasePointerLock()
                return event
            }
            if event.keyCode == 48, flags.contains(.control), !flags.contains(.command), !flags.contains(.option) {
                self.cycleRecentTab(backward: flags.contains(.shift)); return nil
            }
            if self.switcherPanel != nil {
                if event.keyCode == 53 { self.dismissTabSwitcher(); return nil }
                if event.keyCode == 36 { self.commitTabSwitcher(); return nil }
            }
            if event.charactersIgnoringModifiers?.lowercased() == "z", flags.contains(.command), !flags.contains(.option) {
                if self.window.firstResponder is NSTextView || self.activeTab?.isTerminal == true { return event }
                let redo = flags.contains(.shift)
                guard !(redo ? self.layoutRedo : self.layoutUndo).isEmpty else { return event }
                if let web = self.activeWebView, let responder = self.window.firstResponder as? NSView,
                   responder === web || responder.isDescendant(of: web) {
                    // Let contenteditable/input undo remain owned by the page.
                    web.evaluateJavaScript("(() => {const e=document.activeElement;return !!(e && (e.isContentEditable || /^(INPUT|TEXTAREA|IFRAME)$/.test(e.tagName)))})()") { [weak self, weak web] editable, error in
                        guard let self, error == nil, self.activeWebView === web, event.window === self.window else { return }
                        if editable as? Bool == true {
                            self.bypassLayoutShortcut = true
                            NSApplication.shared.sendEvent(event)
                            self.bypassLayoutShortcut = false
                        } else { redo ? self.redoTabLayout() : self.undoTabLayout() }
                    }
                } else { redo ? self.redoTabLayout() : self.undoTabLayout() }
                return nil
            }
            return event
        }
    }

    private func cycleRecentTab(backward: Bool) {
        if switcherPanel == nil {
            releasePointerLock()
            let eligible = tabs.filter { !$0.isFloating && !$0.pinnedInstanceClosed }
            let ids = Set(eligible.map(\.id))
            switcherIDs = recentTabOrder.filter { ids.contains($0) }
                + eligible.map(\.id).filter { !recentTabOrder.contains($0) }
            guard switcherIDs.count > 1 else { return }
            if let activeTabID, let index = switcherIDs.firstIndex(of: activeTabID) {
                switcherIDs.remove(at: index); switcherIDs.insert(activeTabID, at: 0)
            }
            switcherIndex = 0
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            window.addChildWindow(panel, ordered: .above)
            switcherPanel = panel
        }
        switcherIndex = (switcherIndex + (backward ? -1 : 1) + switcherIDs.count) % switcherIDs.count
        drawTabSwitcher()
    }

    private func drawTabSwitcher() {
        guard let panel = switcherPanel, switcherIDs.indices.contains(switcherIndex),
              let selected = tab(id: switcherIDs[switcherIndex]) else { dismissTabSwitcher(); return }
        let glass = WebbyGlassBackdrop(frame: NSRect(x: 0, y: 0, width: 440, height: 340))
        glass.material = .hudWindow; glass.blendingMode = .behindWindow; glass.state = .active
        glass.wantsLayer = true; glass.layer?.cornerRadius = 22; glass.layer?.masksToBounds = true
        // Owner color remains meaningful when tabs from multiple profiles are fused.
        let gradient = CAGradientLayer()
        gradient.frame = glass.bounds
        let profile = BrowserTheme.profile(for: ownerSpace(for: selected).saved.id)
        gradient.colors = profile.gradients.ambient.stops.map { BrowserTheme.color($0.color, alpha: 0.16).cgColor }
        gradient.locations = profile.gradients.ambient.stops.map { NSNumber(value: $0.location) }
        glass.layer?.addSublayer(gradient)
        let image = NSImageView(frame: NSRect(x: 16, y: 84, width: 408, height: 240))
        image.imageScaling = .scaleProportionallyUpOrDown
        image.image = selected.previewImage ?? selected.favicon ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        glass.addSubview(image)
        let title = NSTextField(labelWithString: selected.title)
        title.font = WebbyTypography.font(ofSize: 17, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 22, y: 48, width: 396, height: 24); glass.addSubview(title)
        let detail = NSTextField(labelWithString: "\(ownerSpace(for: selected).saved.name) · \(switcherIndex + 1) / \(switcherIDs.count)")
        detail.textColor = .secondaryLabelColor
        detail.frame = NSRect(x: 22, y: 22, width: 396, height: 20); glass.addSubview(detail)
        panel.contentView = glass
        panel.setFrameOrigin(NSPoint(x: window.frame.midX - 220, y: window.frame.midY - 170))
        panel.orderFront(nil)
    }

    private func commitTabSwitcher() {
        let id = switcherIDs.indices.contains(switcherIndex) ? switcherIDs[switcherIndex] : nil
        dismissTabSwitcher()
        if let id, let tab = tab(id: id), tabs.contains(where: { $0.id == id }) { selectTab(tab) }
    }

    private func dismissTabSwitcher() {
        if let panel = switcherPanel { window.removeChildWindow(panel); panel.close() }
        switcherPanel = nil; switcherIDs = []; switcherIndex = 0
    }

    private func installMenus() {
        let main = NSMenu()
        let app = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Webby", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; main.addItem(app)
        let file = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        let ideItem = fileMenu.addItem(withTitle: "New IDE Tab", action: #selector(openIDE), keyEquivalent: "i")
        ideItem.target = self
        ideItem.keyEquivalentModifierMask = [.command, .shift]
        let mini=fileMenu.addItem(withTitle:"New Mini Webby",action:#selector(openMiniAction),keyEquivalent:"")
        mini.target=self
        let promote=fileMenu.addItem(withTitle:"Keep Mini Page in Webby",action:#selector(keepMiniAction),keyEquivalent:"o");promote.target=self
        let tab = fileMenu.addItem(withTitle: "New Tab", action: #selector(newTabAction), keyEquivalent: "t")
        tab.target = self
        let close = fileMenu.addItem(withTitle: "Close Tab", action: #selector(closeCurrentTab), keyEquivalent: "w")
        close.target = self
        let splitPrevious = fileMenu.addItem(withTitle: "Split With Previous Tab", action: #selector(splitWithPreviousTab), keyEquivalent: "s")
        splitPrevious.target = self
        let reopen = fileMenu.addItem(withTitle: "Reopen Closed Tab", action: #selector(reopenLastClosedTab), keyEquivalent: "t")
        reopen.target = self
        reopen.keyEquivalentModifierMask = [.command, .shift]
        let location = fileMenu.addItem(withTitle: "Open Location", action: #selector(focusAddress), keyEquivalent: "l")
        location.target = self
        let permissions = fileMenu.addItem(withTitle: "Site Permissions…", action: #selector(showSitePermissions), keyEquivalent: "")
        permissions.target = self
        let pinSplit = fileMenu.addItem(withTitle: "Pin Entire Split", action: #selector(pinEntireSplit), keyEquivalent: "")
        pinSplit.target = self
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
        let undoLayout = editMenu.addItem(withTitle: "Undo Tab Layout", action: #selector(undoTabLayout), keyEquivalent: "")
        undoLayout.target = self
        let redoLayout = editMenu.addItem(withTitle: "Redo Tab Layout", action: #selector(redoTabLayout), keyEquivalent: "")
        redoLayout.target = self
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let find = editMenu.addItem(withTitle: "Find in Page", action: #selector(showFindBar), keyEquivalent: "f")
        find.target = self
        let findNextItem = editMenu.addItem(withTitle: "Find Next", action: #selector(findNext), keyEquivalent: "g")
        findNextItem.target = self
        let findPreviousItem = editMenu.addItem(withTitle: "Find Previous", action: #selector(findPrevious), keyEquivalent: "G")
        findPreviousItem.keyEquivalentModifierMask = [.command, .shift]
        findPreviousItem.target = self
        edit.submenu = editMenu; main.addItem(edit)
        let view = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let backgroundSettings = viewMenu.addItem(withTitle: "Background & Effects…", action: #selector(openWallpaperSettings), keyEquivalent: "")
        backgroundSettings.target = self
        let nextPair=viewMenu.addItem(withTitle:"Next Wallpaper Pair",action:#selector(cycleWallpaperPair),keyEquivalent:"w")
        nextPair.target=self;nextPair.keyEquivalentModifierMask=[.command,.shift]
        let reload = viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage), keyEquivalent: "r")
        reload.target = self
        let switchEngine = viewMenu.addItem(withTitle: "Switch Rendering Engine…", action: #selector(switchRenderingEngine), keyEquivalent: "e")
        switchEngine.target = self; switchEngine.keyEquivalentModifierMask = [.command, .shift]
        let otherEngineTab = viewMenu.addItem(withTitle: "New Tab in Other Engine", action: #selector(newTabWithOtherEngine), keyEquivalent: "e")
        otherEngineTab.target = self; otherEngineTab.keyEquivalentModifierMask = [.command, .option, .shift]
        let sidebarItem = viewMenu.addItem(withTitle: "Show / Hide Tabs", action: #selector(toggleSidebar), keyEquivalent: "\\")
        sidebarItem.target = self
        let fuse = viewMenu.addItem(withTitle: "Fuse All Profile Tabs", action: #selector(toggleFuseMode), keyEquivalent: "F")
        fuse.target = self
        fuse.keyEquivalentModifierMask = [.command, .shift]
        fuse.state = BrowserExperiment.cyclesNewTabProfiles ? .on : .off
        fuseMenuItem = fuse
        for index in 0..<min(spaces.count, 2) {
            let item = viewMenu.addItem(withTitle: "Switch to \(spaces[index].saved.name)",
                                        action: #selector(switchToProfileShortcut(_:)), keyEquivalent: String(index + 1))
            item.keyEquivalentModifierMask = [.control]
            item.tag = index
            item.target = self
        }
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
        // Update every account, including shared popup controllers, once.
        // Do not reload forms, editors or background tabs to change the policy.
        applyFastRule(fastRule)
    }

    @objc private func copyPerformanceReport() {
        func duration(_ start: TimeInterval?, _ end: TimeInterval?) -> String {
            guard let start, let end else { return "not recorded" }
            return String(format: "%.2f s", max(0, end - start))
        }
        let timing = activeTab?.navigationTiming
        let sortedSwitches = tabSwitchTimes.sorted()
        let p95 = sortedSwitches.isEmpty ? "not recorded" : String(format: "%.1f ms", sortedSwitches[min(sortedSwitches.count-1, Int(Double(sortedSwitches.count-1)*0.95))])
        let all = spaces.flatMap(\.tabs)
        let report = """
        Webby performance report
        Window visible: \(duration(launchedAt, windowShownAt)) after launch
        WebKit ready: \(duration(launchedAt, webViewReadyAt)) after launch
        Last site: \(lastHost ?? "none")
        Active navigation to response: \(duration(timing?.started, timing?.committed))
        Active navigation to native reveal: \(duration(timing?.started, timing?.presented))
        Active navigation to finish: \(duration(timing?.started, timing?.finished))
        Tab selection main-thread p95 (last \(tabSwitchTimes.count)): \(p95)
        Loaded website views: \(all.filter { $0.webView != nil }.count) / \(all.count) tabs
        Sleeping tab records: \(all.filter { $0.webView == nil && $0.suspendedURL != nil }.count)
        Common ad and tracker blocking: \(fastModeEnabled && fastRule != nil ? "on" : "off")
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }
}

extension BrowserApp {
    private var chromiumRoot: URL {
        if BrowserEngineChecks.active {
            return FileManager.default.temporaryDirectory.appendingPathComponent("webby-engine-ui-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Webby/Chromium", isDirectory: true)
    }

    private func updateEngineAppearance() {
        guard let tab = activeTab else { return }
        topAddressSurface?.setRenderingEngine(tab.engine)
        homeSearchSurface?.setRenderingEngine(tab.engine)
        topAddressSurface?.onSwitchEngine = { [weak self] in self?.switchRenderingEngine() }
        homeSearchSurface?.onSwitchEngine = { [weak self] in self?.switchRenderingEngine() }
    }

    @discardableResult private func openChromium(_ url: URL, in tab: BrowserTab, show: Bool) -> Bool {
        guard ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return false }
        if let page = tab.chromiumView {
            tab.loadError = nil; tab.navigationInProgress = true
            page.navigate(url.absoluteString)
            return true
        }
        guard WBChromiumInitialize(chromiumRoot.path) else {
            let alert = NSAlert(); alert.messageText = "Chromium is unavailable"
            alert.informativeText = "Webby could not load the embedded Chromium framework. This tab remains in its current engine."
            alert.beginSheetModal(for: window); return false
        }
        let page = WBChromiumView(frame: pageArea.bounds)
        page.translatesAutoresizingMaskIntoConstraints = false
        page.isHidden = !show
        tab.chromiumView = page
        page.eventHandler = { [weak self, weak tab, weak page] event, value in
            guard let self, let tab, let page, tab.chromiumView === page else { return }
            switch event {
            case "title": if !value.isEmpty { tab.title = value }
            case "url": tab.searchDraft = value; self.scheduleSessionSave()
            case "loading":
                tab.navigationInProgress = value == "1"
                if tab.navigationInProgress { tab.loadError = nil }
                if !tab.navigationInProgress {
                    tab.pendingSearchInput = nil
                    if let url = tab.pageURL { self.recordChromiumHistory(tab, url: url) }
                    if tab.isPinned { self.savePinnedTabs(for: self.displaySpace(for: tab)) }
                    if tab.passwordProbePending {
                        DispatchQueue.main.async { [weak self, weak tab, weak page] in
                            guard let self, let tab, let page else { return }
                            self.autofillChromiumPassword(tab, page: page)
                        }
                    }
                }
            case "activity":
                if let data = value.data(using: .utf8),
                   let state = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    tab.hasUnsavedEdits = state["edited"] as? Bool ?? true
                    if let x = state["x"] as? Double, let y = state["y"] as? Double, x.isFinite, y.isFinite {
                        tab.restoredScroll = NSPoint(x: x, y: y)
                    }
                }
                return
            case "passwordField":
                tab.passwordProbePending = true
                // Keychain interaction must happen after the CEF callback unwinds.
                DispatchQueue.main.async { [weak self, weak tab, weak page] in
                    guard let self, let tab, let page else { return }
                    self.autofillChromiumPassword(tab, page: page)
                }
                return
            case "passwordCheck":
                if BrowserEngineChecks.active, let data = value.data(using: .utf8),
                   let check = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    self.enginePasswordCheck = check
                }
                return
            case "error": tab.loadError = value; tab.navigationInProgress = false
            case "popup":
                if let host = tab.pageURL?.host,
                   SitePermission.choice(.popups, host: host, profile: self.ownerSpace(for: tab).saved.id) == 2 { return }
                guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
                let fresh = BrowserTab(); fresh.engine = .chromium; fresh.ownerSpaceID = tab.ownerSpaceID
                self.displaySpace(for: tab).tabs.append(fresh)
                if BrowserExperiment.cyclesNewTabProfiles { self.fusedTabOrder.append(fresh.id) }
                self.selectTab(fresh); _ = self.openChromium(url, in: fresh, show: true)
                return
            default: return
            }
            if tab.id == self.activeTabID {
                let failed = tab.loadError != nil
                self.homeView.isHidden = !failed; tab.showsSearchView = failed
                page.alphaValue = failed ? 0.001 : 1
                if failed { self.homeSearchField.stringValue = tab.searchDraft }
                self.homeSearchSurface.stopLoading(); self.globe.engine.hide()
                self.loadErrorLabel.stringValue = tab.loadError ?? ""
                self.loadErrorLabel.isHidden = tab.loadError == nil
                self.toolbar.setProgress(tab.navigationInProgress ? 0.45 : 1)
                if !tab.navigationInProgress { self.toolbar.resetProgress() }
                self.updateNavigation(); self.applyAddressChrome()
            }
            if let floating = self.floatingWindows[tab.id] {
                floating.title = tab.title; floating.addressField.stringValue = tab.pageURL.map(self.displayAddress) ?? tab.searchDraft
            }
            self.refreshTabContent(tab)
        }
        pageArea.addSubview(page, positioned: .below, relativeTo: homeView)
        let constraints = [page.leadingAnchor.constraint(equalTo: pageArea.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: pageArea.trailingAnchor),
            page.topAnchor.constraint(equalTo: pageArea.topAnchor),
            page.bottomAnchor.constraint(equalTo: pageArea.bottomAnchor)]
        NSLayoutConstraint.activate(constraints)
        pageArea.layoutSubtreeIfNeeded()
        let profile = chromiumRoot.appendingPathComponent(ownerSpace(for: tab).saved.id.uuidString, isDirectory: true)
        guard page.openURL(url.absoluteString, profile: profile.path) else {
            page.closePage(); page.removeFromSuperview(); NSLayoutConstraint.deactivate(constraints)
            tab.chromiumView = nil
            return false
        }
        // Keep the previous WebKit page until Chromium has actually been created.
        releaseWebKit(for: tab)
        tab.pageConstraints = constraints; tab.engine = .chromium
        tab.searchDraft = url.absoluteString; tab.title = url.host ?? url.absoluteString
        tab.hasUnsavedEdits = false; tab.captureMayBeActive = false
        tab.showsSearchView = false; tab.navigationInProgress = true; tab.loadError = nil
        tab.suspendedURL = nil
        if tab.isFloating { attachFloatingContent(for: tab) }
        else if show {
            terminalMode = false; page.isHidden = false; homeView.isHidden = true
            globe.engine.hide(); homeSearchSurface.stopLoading()
            applyAddressChrome(); updateNavigation(); page.focusPage()
        }
        refreshTabs(); scheduleSessionSave()
        return true
    }

    private func recordChromiumHistory(_ tab: BrowserTab, url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let space = ownerSpace(for: tab)
        space.recordVisit(url: url, title: tab.title)
        scheduleSpaceSave()
    }

    @objc private func switchRenderingEngine() {
        guard let tab = activeTab, !tab.isTerminal, tab.ide == nil, !tab.isFloating else { return }
        engineSwitchPopover?.close()
        let next = tab.engine.other
        guard tab.pageURL != nil || tab.suspendedURL != nil else {
            tab.engine = next; updateEngineAppearance(); refreshTabContent(tab); return
        }
        let currentEngine = tab.engine
        let prompt = EngineSwitchPrompt(engine: next, hasEdits: tab.hasUnsavedEdits)
        let popover = NSPopover(); popover.behavior = .transient
        popover.contentViewController = prompt; popover.contentSize = NSSize(width: 330, height: 152)
        engineSwitchPopover = popover
        prompt.onCancel = { [weak popover] in popover?.close() }
        prompt.onConfirm = { [weak self, weak tab, weak popover] in
            popover?.close()
            guard let self, let tab, self.activeTabID == tab.id, tab.engine == currentEngine,
                  let url = tab.pageURL ?? tab.suspendedURL else { return }
            let ids = self.splitTabIDs
            if ids?.contains(tab.id) == true { self.endSplit() }
            if next == .chromium {
                _ = self.openChromium(url, in: tab, show: true)
            } else {
                self.releaseWebView(for: tab)
                tab.engine = .webKit; tab.hasUnsavedEdits = false; tab.captureMayBeActive = false
                tab.suspendedURL = url; self.resumeTab(tab, show: true)
                self.homeView.isHidden = true; self.updateNavigation(); self.applyAddressChrome()
            }
            if let ids, ids.allSatisfy({ self.tab(id: $0)?.splitSurface != nil }) { self.renderSplit(ids) }
            self.refreshTabs(); self.scheduleSessionSave()
            if tab.isPinned { self.savePinnedTabs(for: self.displaySpace(for: tab)) }
        }
        let anchor: NSView = homeView.isHidden ? topAddressSurface : homeSearchSurface
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    @objc private func newTabWithOtherEngine() {
        let engine = (activeTab?.engine ?? BrowserEngine.defaultEngine).other
        addTab(select: true)
        activeTab?.engine = engine
        updateEngineAppearance(); if let tab = activeTab { refreshTabContent(tab) }
    }
}

extension BrowserApp {
    private struct EngineUIFailure: Error { let message: String }
    private func engineCheck(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw EngineUIFailure(message: message) }
    }
    private func waitForEngine(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            if Date() > deadline { throw EngineUIFailure(message: message) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func checkChromiumPasswordVault(fixture: BrowserSpace) async throws {
        let credential = BrowserCredential(host: "webby-password.test", username: "fixture-user", password: "fixture-password")
        let secureURL = URL(string: "https://webby-password.test/login")!
        try engineCheck(BrowserPasswordFill.script(for: credential, at: URL(string: "http://webby-password.test/login")!) == nil,
                        "Password fill accepted an insecure site")
        try engineCheck(BrowserPasswordFill.script(for: credential, at: URL(string: "https://other.webby-password.test/login")!) == nil,
                        "Password fill accepted a different host")
        try engineCheck(BrowserPasswordFill.origin(for: URL(string: "https://webby-password.test:443/login")!) == "https://webby-password.test",
                        "Default HTTPS port was not normalized")
        var lookups: [(UUID, String)] = []
        passwordLookup = { profile, host in
            lookups.append((profile, host))
            return profile == fixture.saved.id && host == credential.host ? [credential] : []
        }
        addTab(select: true)
        let login = activeTab!; login.engine = .chromium
        enginePasswordCheck = [:]
        navigate(secureURL.absoluteString, in: login)
        try await waitForEngine("Chromium did not autofill from Webby's profile vault") {
            self.enginePasswordCheck["origin"] as? String == "https://webby-password.test"
                && self.enginePasswordCheck["username"] as? Bool == true
                && self.enginePasswordCheck["password"] as? Bool == true
        }
        // The real menu action must work on Chromium as well as automatic fill.
        enginePasswordCheck = [:]
        _ = login.chromiumView!.runScript("document.querySelectorAll('input').forEach(e=>e.value='');console.debug('__webby_password_check:'+JSON.stringify({empty:true,origin:location.origin}));", expectedOrigin: "https://webby-password.test")
        try await waitForEngine("Could not reset the synthetic password form") { self.enginePasswordCheck["empty"] as? Bool == true }
        fillSavedPasswordForCurrentSite()
        try await waitForEngine("Fill Password menu action did not work in Chromium") {
            self.enginePasswordCheck["username"] as? Bool == true && self.enginePasswordCheck["password"] as? Bool == true
        }
        enginePasswordCheck = [:]
        navigate("https://other.webby-password.test/login", in: login)
        try await waitForEngine("Wrong-origin fixture failed to load") {
            !login.navigationInProgress && self.enginePasswordCheck["origin"] as? String == "https://other.webby-password.test"
        }
        let script = BrowserPasswordFill.script(for: credential, at: secureURL)!
        try engineCheck(!login.chromiumView!.runScript(script, expectedOrigin: "https://webby-password.test"),
                        "Native Chromium bridge accepted a stale origin")
        try engineCheck(enginePasswordCheck["empty"] as? Bool == true, "A different origin received a saved password")
        let otherProfile = BrowserSpace(.init(id: UUID(), name: "Other vault", chromeDirectory: nil, bookmarks: [], history: []))
        spaces.append(otherProfile)
        addTab(select: true)
        let otherLogin = activeTab!; otherLogin.engine = .chromium; otherLogin.ownerSpaceID = otherProfile.saved.id
        enginePasswordCheck = [:]
        navigate(secureURL.absoluteString, in: otherLogin)
        try await waitForEngine("Other-profile fixture failed to load") {
            !otherLogin.navigationInProgress && self.enginePasswordCheck["origin"] as? String == "https://webby-password.test"
                && lookups.contains(where: { $0.0 == otherProfile.saved.id && $0.1 == credential.host })
        }
        try engineCheck(enginePasswordCheck["empty"] as? Bool == true, "Password autofill crossed profile boundaries")
        closeTab(id: login.id); closeTab(id: otherLogin.id)
        try await waitForEngine("Password fixtures did not close") { !WBChromiumHasBrowsers() }
        print("PASS: Chromium shares Webby's vault for automatic/manual fill; HTTPS, origin, and profile boundaries preserved; synthetic credentials only")
    }
    fileprivate func runEngineUIChecks(base: String) async {
        do {
            let fixture = BrowserSpace(.init(id: UUID(), name: "Engine checks", chromeDirectory: nil, bookmarks: [], history: []))
            spaces = [fixture]
            var preferences: [String: Any] = ["webbyExperimentalProfileCycle": false,
                "webbyTabStackPlacement": "top", "webbyAddressPlacement": "strip",
                "webbyRestoreTabs": false, "webbyOffloadMinutes": 1,
                "webbyActionSounds": false, "webbyDefaultRenderingEngine": "webKit",
                "webbyWidgetCanvas.\(fixture.saved.id.uuidString)": Data("[]".utf8)]
            UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
            downloads = BrowserDownloads(destinationFolder: chromiumRoot.appendingPathComponent("Downloads"),
                defaults: UserDefaults(suiteName: "webby-engine-ui-\(ProcessInfo.processInfo.processIdentifier)")!)
            makeWindow(); makeSidebar(); makeMainArea(); makeHome(); installMenus()
            BrowserTheme.activate(fixture.saved.id)
            addTab(select: true)
            let empty = activeTab!
            try engineCheck(empty.engine == .webKit, "Default WebKit tab was not created")
            switchRenderingEngine()
            try engineCheck(empty.engine == .chromium && empty.pageView == nil && engineSwitchPopover == nil,
                            "Empty tab switching should be immediate")
            switchRenderingEngine()
            try engineCheck(empty.engine == .webKit, "Empty tab could not switch back")
            preferences["webbyDefaultRenderingEngine"] = "chromium"
            UserDefaults.standard.setVolatileDomain(preferences, forName: UserDefaults.argumentDomain)
            addTab(select: true)
            let chromium = activeTab!
            try engineCheck(chromium.engine == .chromium && empty.engine == .webKit, "New-tab default changed an existing tab")
            navigate(base + "/first?set=uiAlpha", in: chromium)
            try await waitForEngine("Chromium tab failed to load") { chromium.title == "first|empty" && !chromium.navigationInProgress }
            try engineCheck(chromium.chromiumView != nil && chromium.webView == nil && homeView.isHidden, "Chromium page was not presented")
            navigate(base + "/second", in: chromium)
            try await waitForEngine("Chromium navigation did not update toolbar history") { chromium.title == "second|uiAlpha" && !chromium.navigationInProgress }
            try engineCheck(backButton.isEnabled, "Chromium back button stayed disabled")
            goBack()
            try await waitForEngine("Chromium toolbar back action failed") { chromium.title.hasPrefix("first|") && !chromium.navigationInProgress }
            selectTab(empty)
            try engineCheck(chromium.pageView?.isHidden == true && !homeView.isHidden, "Background Chromium tab remained visible")
            navigate(base + "/first", in: empty)
            try await waitForEngine("WebKit fixture failed") { empty.navigationTiming.finished != nil }
            try engineCheck(empty.webView != nil && empty.chromiumView == nil, "WebKit default was not retained")
            selectTab(chromium)
            try engineCheck(chromium.pageView?.isHidden == false && empty.pageView?.isHidden == true && homeView.isHidden, "Mixed-engine selection failed")
            try engineCheck(splitTabs(sourceID: empty.id, targetID: chromium.id), "Mixed-engine split failed")
            try engineCheck(splitTabIDs?.count == 2, "Mixed-engine split did not contain both pages")
            endSplit(); activeTabID = nil; selectTab(chromium)
            // Exercise the real popover callbacks without any network beyond the fixture.
            window.orderBack(nil)
            switchRenderingEngine()
            try engineCheck(engineSwitchPopover?.isShown == true, "Engine confirmation popover was not shown")
            (engineSwitchPopover?.contentViewController as? EngineSwitchPrompt)?.onCancel?()
            try engineCheck(chromium.engine == .chromium, "Cancel changed the rendering engine")
            switchRenderingEngine()
            (engineSwitchPopover?.contentViewController as? EngineSwitchPrompt)?.onConfirm?()
            try await waitForEngine("Chromium to WebKit switch did not reload") { chromium.engine == .webKit && chromium.navigationTiming.finished != nil }
            try engineCheck(chromium.chromiumView == nil && chromium.webView != nil, "Old Chromium surface survived engine switch")
            switchRenderingEngine()
            (engineSwitchPopover?.contentViewController as? EngineSwitchPrompt)?.onConfirm?()
            try await waitForEngine("WebKit to Chromium switch did not reload") { chromium.engine == .chromium && chromium.chromiumView != nil && !chromium.navigationInProgress }
            try engineCheck(chromium.webView == nil, "Old WebKit surface survived engine switch")
            selectTab(empty); chromium.lastActiveAt = Date().addingTimeInterval(-120)
            try await waitForEngine("Activity probe did not make an idle page eligible") { self.canDiscard(chromium, cutoff: Date().addingTimeInterval(-60)) }
            checkDiscard(chromium, cutoff: Date().addingTimeInterval(-60))
            try engineCheck(chromium.chromiumView == nil && chromium.suspendedURL != nil && chromium.engine == .chromium, "Idle Chromium tab was not offloaded")
            selectTab(chromium)
            try await waitForEngine("Sleeping Chromium tab failed to resume") { chromium.chromiumView != nil && !chromium.navigationInProgress }
            navigate("http://127.0.0.1:1", in: chromium)
            try await waitForEngine("Chromium failure was not reported") { chromium.loadError != nil }
            try engineCheck(!homeView.isHidden && chromium.showsSearchView, "Chromium error did not expose recovery UI")
            navigate(base + "/second", in: chromium)
            try await waitForEngine("Chromium did not recover after a failed load") { chromium.loadError == nil && !chromium.navigationInProgress }
            let record = BrowserSessionRecord(pages: [.init(title: chromium.title, url: chromium.pageURL!.absoluteString,
                ownerSpaceID: fixture.saved.id, displaySpaceID: fixture.saved.id, groupID: nil, engine: chromium.engine)])
            let decoded = try JSONDecoder().decode(BrowserSessionRecord.self, from: JSONEncoder().encode(record))
            try engineCheck(decoded.pages.first?.engine == .chromium, "Session serialization lost its engine")
            closeTab(id: chromium.id)
            try engineCheck(!tabs.contains(where: { $0.id == chromium.id }), "Chromium tab remained after closing")
            try await waitForEngine("Chromium did not finish closing") { !WBChromiumHasBrowsers() }
            addTab(select: true)
            let schoology = activeTab!
            schoology.engine = .chromium
            navigate("https://webby-test.schoology.com/grades", in: schoology)
            try await waitForEngine("Chromium Schoology colors were not applied") {
                schoology.title == "Schoology dark ready" && !schoology.navigationInProgress
            }
            closeTab(id: schoology.id)
            try await waitForEngine("Schoology fixture did not close") { !WBChromiumHasBrowsers() }
            print("PASS: Chromium applies the bundled Schoology theme, including the course-grade summary")
            try await checkChromiumPasswordVault(fixture: fixture)
            print("PASS: actual Webby UI paths: default inheritance, empty-tab switching, both engines, toolbar navigation, selection, split, confirmation/cancel, switching both ways, offload/resume, session engine, close.")
            // Dispatch the real Quit command from inside CEF's event pump.
            // Direct shutdown/exit cannot catch the nested quit-loop deadlock.
            addTab(select: true)
            let quitTab = activeTab!
            quitTab.engine = .chromium
            navigate(base + "/first", in: quitTab)
            try await waitForEngine("Quit regression fixture did not load") { !quitTab.navigationInProgress }
            NSApp.delegate = self
            if ProcessInfo.processInfo.environment["WEBBY_ENGINE_MANUAL_UI"] == "1" {
                window.title = "Webby Engine Check — Temporary Profiles"
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                print("READY: manual engine UI check, fixture base \(base)")
                fflush(stdout)
                while true { try await Task.sleep(nanoseconds: 1_000_000_000) }
            }
            let originalHandler = quitTab.chromiumView!.eventHandler
            var quitSent = false
            quitTab.chromiumView!.eventHandler = { event, value in
                originalHandler?(event, value)
                guard event == "title", !quitSent else { return }
                quitSent = true
                guard let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: self.window.windowNumber,
                    context: nil, characters: "q", charactersIgnoringModifiers: "q", isARepeat: false, keyCode: 12),
                    NSApp.mainMenu?.performKeyEquivalent(with: key) == true else {
                    fputs("FAIL: real Quit menu command was not dispatched\n", stderr); exit(1)
                }
            }
            navigate(base + "/second", in: quitTab)
            try await waitForEngine("Actual Quit command did not finish") { false }
        } catch {
            fputs("FAIL: engine UI checks: \(error)\n", stderr)
            exit(1)
        }
    }
}

@main struct Main {
    static func main() {
        if BrowserEngineChecks.active {
            guard CommandLine.arguments.count == 3 else {
                fputs("Usage: Webby --check-engine-ui http://127.0.0.1:PORT\n", stderr)
                return
            }
            WBPrepareApplication()
            NSApp.setActivationPolicy(ProcessInfo.processInfo.environment["WEBBY_ENGINE_MANUAL_UI"] == "1" ? .regular : .prohibited)
            let checker = BrowserApp()
            DispatchQueue.main.async {
                Task { await checker.runEngineUIChecks(base: CommandLine.arguments[2]) }
            }
            NSApp.run()
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--check-calendar-feed",
           let profile = UUID(uuidString: CommandLine.arguments[2]) {
            Task.detached(priority: .utility) {
                do {
                    let snapshot = try await CalendarFeed.shared.load(profile: profile)
                    print("Calendar check passed: \(snapshot.events.count) occurrences, stale=\(snapshot.stale), limited=\(snapshot.limited).")
                    exit(0)
                } catch { fputs("Calendar check failed.\n", stderr); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--configure-calendar-feed",
           let profile = UUID(uuidString: CommandLine.arguments[2]) {
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                guard let text = String(data: data, encoding: .utf8) else { throw CalendarFeedError.invalid }
                try CalendarSubscription.save(text, profile: profile)
                print("Calendar feed saved securely for this profile.")
            } catch { fputs("Calendar setup failed.\n", stderr); exit(1) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--render-icon" {
            try? WebbyIcon.writeDefaultPNG(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            return
        }
        WBPrepareApplication()
        let app = NSApplication.shared
        let delegate = BrowserApp()
        app.delegate = delegate
        app.run()
    }
}


extension BrowserApp {
    private func toggleMiniWebby(){
        let hosts=miniTabs.keys.compactMap{floatingWindows[$0] as? MiniWebbyWindow}
        if let focused=NSApp.keyWindow as? MiniWebbyWindow,focused.isVisible,NSApp.isActive {
            for host in hosts {miniSuggestions[host.tabID]?.close();host.orderOut(nil)}
            if let previous=miniPreviousApps[focused.tabID],!previous.isTerminated {previous.activate(options:[.activateIgnoringOtherApps])}
            return
        }
        guard let recent=hosts.max(by:{$0.lastUsed<$1.lastUsed}) else {openMiniWebby();return}
        if let previous=NSWorkspace.shared.frontmostApplication,previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {miniPreviousApps[recent.tabID]=previous}
        if recent.isMiniaturized {recent.deminiaturize(nil)}
        NSApp.activate(ignoringOtherApps:true);recent.makeKeyAndOrderFront(nil);recent.lastUsed=Date()
        if miniTabs[recent.tabID]?.webView==nil {recent.makeFirstResponder(recent.addressField)}
    }
    @objc private func openMiniAction(){openMiniWebby()}
    @objc private func keepMiniAction(){(NSApp.keyWindow as? MiniWebbyWindow)?.promote()}
    @discardableResult private func openMiniWebby(url:URL?=nil,profile:UUID?=nil,popupConfiguration:WKWebViewConfiguration?=nil)->BrowserTab {
        let currentMiniOwner=(NSApp.keyWindow as? MiniWebbyWindow).flatMap{miniTabs[$0.tabID]?.ownerSpaceID}
        let tab=BrowserTab();tab.engine = .webKit;tab.ownerSpaceID=profile ?? currentMiniOwner ?? activeSpace.saved.id;tab.isFloating=true
        miniTabs[tab.id]=tab
        updateWidgetActivity()
        let pointer=NSEvent.mouseLocation
        let screen=NSScreen.screens.first{$0.frame.contains(pointer)} ?? window.screen
        let mini=MiniWebbyWindow(tabID:tab.id,profiles:spaces.map{($0.saved.id,$0.saved.name)},owner:tab.ownerSpaceID!,screen:screen)
        floatingWindows[tab.id]=mini;mini.delegate=self
        if let previous=NSWorkspace.shared.frontmostApplication,previous.processIdentifier != ProcessInfo.processInfo.processIdentifier {miniPreviousApps[tab.id]=previous}
        mini.addressField.identifier=NSUserInterfaceItemIdentifier(tab.id.uuidString);mini.addressField.target=self;mini.addressField.action=#selector(floatingAddressSubmitted(_:));mini.addressField.delegate=self
        mini.back.target=self;mini.back.action=#selector(goBack);mini.forward.target=self;mini.forward.action=#selector(goForward);mini.reload.target=self;mini.reload.action=#selector(reloadPage)
        mini.keepPage={ [weak self] destination in self?.promoteMiniWebby(tab.id,destination:destination) }
        mini.copyInProfile={ [weak self,weak tab,weak mini] profile in
            guard let self,let tab,let mini,self.spaces.contains(where:{$0.saved.id==profile}) else{return}
            let destination:MiniWebbyWindow?
            if let existing=self.miniTabs.values.first(where:{$0.ownerSpaceID==profile && $0.id != tab.id}),let host=self.floatingWindows[existing.id] as? MiniWebbyWindow {destination=host}
            else {let next=self.openMiniWebby(url:tab.pageURL,profile:profile);destination=self.floatingWindows[next.id] as? MiniWebbyWindow}
            guard let destination else{return}
            destination.positionForSwitch(from:mini);destination.animateProfileArrival(direction:mini.switchDirection);mini.orderOut(nil);destination.makeKeyAndOrderFront(nil)
        }
        if let configuration=popupConfiguration {tab.navigationInProgress=true;_ = makeWebView(for:tab,popupConfiguration:configuration);attachFloatingContent(for:tab);mini.expand()}
        if let url {mini.expand();navigate(url.absoluteString,in:tab)}
        NSApp.activate(ignoringOtherApps:true);mini.makeKeyAndOrderFront(nil)
        if url==nil && popupConfiguration==nil {mini.makeFirstResponder(mini.addressField)}
        else {mini.makeFirstResponder(tab.webView)}
        if Motion.enabled {Motion.basic(mini.contentView?.layer,key:"opacity",from:0,to:1,duration:0.16)}
        return tab
    }
    private func closeMiniWebby(_ id:UUID,restoreFocus:Bool=true){
        guard let tab=miniTabs.removeValue(forKey:id) else{return}
        updateWidgetActivity()
        miniSuggestions.removeValue(forKey:id)?.close()
        if let url=tab.pageURL,["http","https"].contains(url.scheme?.lowercased() ?? ""),let profile=tab.ownerSpaceID {
            var entries=MiniWebbyArchive.entries;entries.insert(MiniWebbyArchive(id:UUID(),title:tab.title,url:url.absoluteString,profile:profile,closed:Date()),at:0);MiniWebbyArchive.entries=entries
        }
        let previous=miniPreviousApps.removeValue(forKey:id)
        discardFloatingWindow(for:id);releaseWebView(for:tab)
        if restoreFocus,let previous,!previous.isTerminated,miniTabs.isEmpty {previous.activate(options:[.activateIgnoringOtherApps])}
    }
    private func promoteMiniWebby(_ id:UUID,destination:UUID){
        defer {Motion.reveal(pageArea,character:.split)}
        guard let tab=miniTabs[id],let target=spaces.first(where:{$0.saved.id==destination}) else{return}
        miniSuggestions.removeValue(forKey:id)?.close();miniPreviousApps.removeValue(forKey:id)
        target.tabs.append(tab);miniTabs.removeValue(forKey:id)
        if BrowserExperiment.cyclesNewTabProfiles {fusedTabOrder.append(tab.id)}
        dockFloatingTab(id:id,activate:true);scheduleSessionSave()
    }
    private func expireMiniWebby(_ id:UUID,hours:Int){
        guard let tab=miniTabs[id],!tab.hasUnsavedEdits,!tab.captureMayBeActive,!tab.hasPictureInPicture,!tab.discardCheckInFlight,!tab.navigationInProgress else{return}
        guard let view=tab.webView else {closeMiniWebby(id,restoreFocus:false);return}
        guard view.cameraCaptureState == .none,view.microphoneCaptureState == .none else{return}
        tab.discardCheckInFlight=true
        view.requestMediaPlaybackState { [weak self,weak tab,weak view] state in
            guard let self,let tab,let view else{return}
            guard state == .none || state == .paused else{tab.discardCheckInFlight=false;return}
            view.callAsyncJavaScript("return window.__webbyDiscardState?.() ?? null",arguments:[:],in:nil,in:BrowserPageActivity.world) { [weak self,weak tab] result in
                guard let self,let tab else{return};tab.discardCheckInFlight=false
                guard self.miniTabs[id] === tab,let mini=self.floatingWindows[id] as? MiniWebbyWindow,!mini.isKeyWindow,
                      Date().timeIntervalSince(mini.lastUsed)>Double(hours)*3600,!tab.hasUnsavedEdits,
                      let state=(try? result.get()) as? [String:Any],state["form"] as? Bool==false,
                      state["media"] as? Bool==false,state["embedded"] as? Bool==false else{return}
                self.closeMiniWebby(id,restoreFocus:false)
            }
        }
    }
    private func updateMiniChrome(_ tab:BrowserTab){
        guard let mini=floatingWindows[tab.id] as? MiniWebbyWindow else{return}
        mini.lastUsed=Date();mini.back.isEnabled=tab.webView?.canGoBack==true;mini.forward.isEnabled=tab.webView?.canGoForward==true
        let loading=tab.navigationInProgress && tab.webView?.isLoading==true
        mini.progress.isHidden = !loading;mini.progress.doubleValue=tab.webView?.estimatedProgress ?? 0
        mini.status.stringValue=loading ? "Loading…":(tab.pageURL?.host ?? "Quick lookup")
    }
    private func showMiniSuggestions(_ id:UUID){
        guard let tab=miniTabs[id],let mini=floatingWindows[id] as? MiniWebbyWindow else{return}
        let query=mini.addressField.stringValue.lowercased().trimmingCharacters(in:.whitespaces)
        let owner=ownerSpace(for:tab)
        var seen=Set<String>();var items:[BrowserSuggestion]=[]
        for (links,kind) in [(owner.saved.bookmarks,BrowserSuggestion.Kind.bookmark),(owner.saved.history,BrowserSuggestion.Kind.history)] {
            for link in links where query.isEmpty || link.title.lowercased().contains(query) || link.url.lowercased().contains(query) {
                if seen.insert(link.url).inserted {items.append(BrowserSuggestion(title:link.title,url:link.url,kind:kind,profileID:owner.saved.id,profileName:owner.saved.name))}
                if items.count==6 {break}
            }
            if items.count==6 {break}
        }
        let popup=miniSuggestions[id] ?? BrowserSuggestionPopup();miniSuggestions[id]=popup
        popup.onChoose={ [weak self,weak tab] item in guard let self,let tab else{return};self.miniSuggestions[id]?.close();(self.floatingWindows[id] as? MiniWebbyWindow)?.expand();self.navigate(item.url,in:tab) }
        popup.show(items,at:mini.addressField)
    }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy command:Selector)->Bool {
        guard let field=control as? NSTextField,let raw=field.identifier?.rawValue,let id=UUID(uuidString:raw),miniTabs[id] != nil else{return false}
        if command == #selector(NSResponder.moveDown(_:)){miniSuggestions[id]?.move(1);return true}
        if command == #selector(NSResponder.moveUp(_:)){miniSuggestions[id]?.move(-1);return true}
        if command == #selector(NSResponder.cancelOperation(_:)){miniSuggestions[id]?.close();field.window?.makeFirstResponder(nil);return true}
        return false
    }
    func windowDidBecomeKey(_ notification:Notification){
        if let host=notification.object as? NSWindow,!typographyWindows.contains(host),let root=host.contentView {
            WebbyTypography.apply(to:root);typographyWindows.add(host)
        }
        if let mini=notification.object as? MiniWebbyWindow {mini.lastUsed=Date()}
        updateWidgetActivity()
    }
    func application(_ application:NSApplication,open urls:[URL]){
        let valid=Array(urls.filter{["http","https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil}.prefix(20))
        guard window != nil else {pendingMiniURLs += valid;return}
        for url in valid {openExternalLink(url)}
    }
    private func openExternalLink(_ url:URL) {
        let profile=BrowserExternalLinks.resolvedProfile(available:spaces.map{$0.saved.id},current:activeSpace.saved.id)
        if MiniWebbySettings.externalLinks {openMiniWebby(url:url,profile:profile);return}
        guard let index=spaces.firstIndex(where:{$0.saved.id==profile}) else{return}
        if !BrowserExperiment.cyclesNewTabProfiles {switchToSpace(index)}
        let tab=BrowserTab();tab.ownerSpaceID=profile
        spaces[index].tabs.append(tab)
        if BrowserExperiment.cyclesNewTabProfiles {fusedTabOrder.append(tab.id)}
        selectTab(tab)
        navigate(url.absoluteString,in:tab,profileID:profile)
        scheduleSessionSave();showBrowserWindow()
    }
}

private final class WallpaperTabFrost:WebbyGlassBackdrop {
    override func hitTest(_ point:NSPoint)->NSView? {nil}
}

extension BrowserApp {
    private func applyWallpaperPresentation(){
        updateWidgetActivity()
        guard let wallpaper,let pageArea,let mainBackdrop,let sidebarBackdrop else{return}
        wallpaper.isSuppressed = windowStyle.hasColor
        wallpaper.refreshActivity()
        let full = !windowStyle.hasColor && wallpaper.fillsWindow
        let unifiedGlass = !windowStyle.hasColor && (full || BrowserWindowStyle.inset)
        let motionState="\(full)-\(wallpaper.tabBlurScope)"
        let artGeometry=wallpaperMotionState != motionState ? Motion.capture([wallpaper],in:content):.empty
        defer {if wallpaperMotionState != motionState {Motion.settle(artGeometry,views:[wallpaper],in:content,character:.art);Motion.change(sidebarBackdrop,character:.art);Motion.change(wallpaperPaneBlur,character:.art)};wallpaperMotionState=motionState}
        let host=full ? content!:pageArea
        if wallpaperChromeHost !== host {
            NSLayoutConstraint.deactivate(wallpaperConstraints);wallpaper.removeFromSuperview()
            host.addSubview(wallpaper,positioned:.below,relativeTo:host.subviews.first)
            wallpaperConstraints=[wallpaper.leadingAnchor.constraint(equalTo:host.leadingAnchor),wallpaper.trailingAnchor.constraint(equalTo:host.trailingAnchor),wallpaper.topAnchor.constraint(equalTo:host.topAnchor),wallpaper.bottomAnchor.constraint(equalTo:host.bottomAnchor)]
            NSLayoutConstraint.activate(wallpaperConstraints);wallpaperChromeHost=host
        }
        // Desktop glass sits below the artwork. Its opacity never tints or
        // fades the wallpaper; artwork keeps its independent visibility.
        if unifiedGlass && wallpaperWindowBackdrop==nil {
            let backdrop=WallpaperTabFrost();backdrop.translatesAutoresizingMaskIntoConstraints=false
            backdrop.material = .popover;backdrop.blendingMode = .behindWindow;backdrop.state = .active
            content.addSubview(backdrop,positioned:.below,relativeTo:full ? wallpaper : content.subviews.first)
            NSLayoutConstraint.activate([backdrop.leadingAnchor.constraint(equalTo:content.leadingAnchor),backdrop.trailingAnchor.constraint(equalTo:content.trailingAnchor),backdrop.topAnchor.constraint(equalTo:content.topAnchor),backdrop.bottomAnchor.constraint(equalTo:content.bottomAnchor)])
            wallpaperWindowBackdrop=backdrop
        }
        if full,let backdrop=wallpaperWindowBackdrop,
           let glassIndex=content.subviews.firstIndex(of:backdrop),let artIndex=content.subviews.firstIndex(of:wallpaper),glassIndex>artIndex {
            content.addSubview(backdrop,positioned:.below,relativeTo:wallpaper)
        }
        wallpaperWindowBackdrop?.isHidden = !unifiedGlass
        wallpaperWindowBackdrop?.alphaValue=1-BrowserGlass.backgroundTransparency
        mainBackdrop.isHidden = unifiedGlass || windowStyle.hasColor
        mainBackdrop.blendingMode = .behindWindow
        mainBackdrop.alphaValue=1-BrowserGlass.backgroundTransparency
        let tabFrost=wallpaper.tabBlurStrength*(1-BrowserGlass.sidebarTransparency*0.86)
        sidebarBackdrop.blendingMode=unifiedGlass || tabsPeekVisible ? .withinWindow:.behindWindow
        sidebarBackdrop.isHidden = windowStyle.hasColor
        sidebar.layer?.backgroundColor = windowStyle.hasColor && tabsPeekVisible
            ? windowStyle.representativeColor.cgColor : nil
        if windowStyle.hasColor {
            sidebarBackdrop.alphaValue = 0
        } else if full {
            sidebarBackdrop.alphaValue = wallpaper.tabBlurScope == 1 ? tabFrost : 0
        } else {
            sidebarBackdrop.alphaValue = 1 - BrowserGlass.sidebarTransparency * 0.86
        }
        if wallpaperPaneBlur==nil,let horizontalScroll {
            let frost=WallpaperTabFrost();frost.translatesAutoresizingMaskIntoConstraints=false;frost.material = .sidebar;frost.blendingMode = .withinWindow;frost.state = .active
            mainArea.addSubview(frost,positioned:.below,relativeTo:horizontalScroll)
            NSLayoutConstraint.activate([frost.leadingAnchor.constraint(equalTo:mainArea.leadingAnchor),frost.trailingAnchor.constraint(equalTo:mainArea.trailingAnchor),frost.topAnchor.constraint(equalTo:mainArea.topAnchor),frost.heightAnchor.constraint(equalToConstant:46)])
            wallpaperPaneBlur=frost
        }
        wallpaperPaneBlur?.isHidden = !full || wallpaper.tabBlurScope != 1 || BrowserTabPlacement.current != .horizontal || tabsHiddenByUser
        wallpaperPaneBlur?.alphaValue=tabFrost
        if BrowserGlass.matchWebsiteEdge, let edge=websiteEdgeBackdrop { mainArea.addSubview(edge, positioned: .below, relativeTo: horizontalScroll) }
        for group in Array(groupContainers.values)+Array(horizontalGroupContainers.values) {
            group.updateGlass(opacity:Double(full && wallpaper.tabBlurScope==0 ? tabFrost:0),material:BrowserGlass.matchPageGlassSidebar ? .popover:.sidebar)
        }
        let frostedIDs=Set(tabs.lazy.filter{$0.groupID==nil || $0.isPinned}.map(\.id))
        for row in Array(tabRows.values)+Array(horizontalRows.values) {
            let existing=row.subviews.first{$0 is WallpaperTabFrost} as? WallpaperTabFrost
            if !(BrowserGlass.matchWebsiteEdge && homeView?.isHidden == true && BrowserTabPlacement.current == .horizontal) && full && wallpaper.tabBlurScope==0 && frostedIDs.contains(row.tabID) {
                let frost=existing ?? WallpaperTabFrost(frame:row.bounds)
                if existing==nil {frost.material = .sidebar;frost.blendingMode = .withinWindow;frost.state = .active;frost.autoresizingMask=[.width,.height];frost.wantsLayer=true;frost.layer?.cornerRadius=10;frost.layer?.masksToBounds=true;row.addSubview(frost,positioned:.below,relativeTo:row.subviews.first)}
                frost.alphaValue=tabFrost;frost.isHidden=false;row.updateTabGlassMask()
            } else {existing?.isHidden=true}
        }
    }
}
