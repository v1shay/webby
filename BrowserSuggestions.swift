import AppKit

struct BrowserSuggestion: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case pinned, bookmark, history, cookie }
    let title: String
    let url: String
    let kind: Kind
    var profileID: UUID? = nil
    var profileName: String? = nil
}

// Value-only snapshots cross the actor boundary; AppKit/WebKit objects stay on
// the main actor. Indexing, URL parsing, sorting and ranking run on this actor.
struct SuggestionSearchSource: Sendable {
    let id:UUID
    let identity:ObjectIdentifier
    let revision:Int
    let name:String
    let bookmarks:[BrowserLink]
    let history:[BrowserLink]
    let pins:[BrowserLink]
    let cookies:[String]
}
struct SuggestionSearchResult: Sendable {
    let items:[BrowserSuggestion]
    let routes:[String:UUID]
}
actor BrowserSuggestionIndex {
    private struct Record {
        let title:String, url:String, titleKey:String, urlKey:String, host:String
        let kind:BrowserSuggestion.Kind
        let asciiSearch:Data?
        let titleByteCount:Int
        var visited:Date
        init?(_ link:BrowserLink,kind:BrowserSuggestion.Kind,preparedHost:String?=nil) {
            let lowerURL=link.url.lowercased()
            guard lowerURL.hasPrefix("http://") || lowerURL.hasPrefix("https://"),let host=preparedHost ?? URL(string:link.url)?.host else{return nil}
            title=link.title;url=link.url;titleKey=link.title.lowercased();urlKey=lowerURL
            titleByteCount=titleKey.utf8.count
            asciiSearch=titleKey.utf8.allSatisfy{$0<128} && lowerURL.utf8.allSatisfy{$0<128} ? Data((titleKey+"\0"+lowerURL).utf8):nil
            self.host=host.lowercased();self.kind=kind;visited=link.visitedAt ?? .distantPast
        }
    }
    private struct Prepared {
        let identity:ObjectIdentifier, revision:Int
        let bookmarks:[Record],history:[Record],byURL:[String:Record]
    }
    private var profiles:[UUID:Prepared]=[:]
    private var hosts:[String:String]=[:]
    private struct RoutingRevision:Equatable {let identity:ObjectIdentifier;let revision:Int}
    private var routingRevision:[RoutingRevision]=[]
    private var cachedRoutes:[String:UUID]=[:]
    private func record(_ link:BrowserLink,kind:BrowserSuggestion.Kind)->Record? {
        let lower=link.url.lowercased()
        let count=lower.hasPrefix("https://") ? 8:lower.hasPrefix("http://") ? 7:0
        guard count>0 else{return nil}
        let origin=String(lower.prefix(count))+lower.dropFirst(count).prefix{!"/?#".contains($0)}
        let host:String
        if let cached=hosts[origin] {host=cached}
        else {
            guard let parsed=URL(string:link.url)?.host else{return nil}
            host=parsed
            if hosts.count<2048 {hosts[origin]=host}
        }
        return Record(link,kind:kind,preparedHost:host)
    }

    func search(_ query:String,sources:[SuggestionSearchSource],fuse:Bool)->SuggestionSearchResult {
        assert(!Thread.isMainThread,"Suggestion work must not run on the UI thread")
        for source in sources {
            if profiles[source.id]?.identity != source.identity || profiles[source.id]?.revision != source.revision {
                let old=profiles[source.id]
                var byURL:[String:Record]=[:]
                let records=source.history.compactMap { link -> Record? in
                    var record:Record?
                    if let cached=old?.byURL[link.url],cached.title==link.title {record=cached;record?.visited=link.visitedAt ?? .distantPast}
                    else {record=self.record(link,kind:.history)}
                    if let record {byURL[link.url]=record}
                    return record
                }.sorted{$0.visited>$1.visited}
                profiles[source.id]=Prepared(identity:source.identity,revision:source.revision,
                    bookmarks:source.bookmarks.compactMap{record($0,kind:.bookmark)},history:records,byURL:byURL)
            }
        }
        if profiles.count>16 {for id in Array(profiles.keys) where !sources.contains(where:{$0.id==id}) {profiles.removeValue(forKey:id)}}
        if Task.isCancelled {return .init(items:[],routes:[:])}
        var routes:[String:UUID]=[:]
        if fuse {
            let revision=sources.map{RoutingRevision(identity:$0.identity,revision:$0.revision)}
            if revision==routingRevision {routes=cachedRoutes}
            else {
                var dates:[String:Date]=[:],ambiguous=Set<String>()
                for source in sources {for record in profiles[source.id]?.history ?? [] {
                    if let date=dates[record.host] {
                        if record.visited>date {dates[record.host]=record.visited;routes[record.host]=source.id;ambiguous.remove(record.host)}
                        else if date==record.visited && routes[record.host] != source.id {ambiguous.insert(record.host)}
                    } else {dates[record.host]=record.visited;routes[record.host]=source.id}
                }}
                for host in ambiguous {routes.removeValue(forKey:host)}
                routingRevision=revision;cachedRoutes=routes
            }
        }
        let asciiQuery=query.utf8.allSatisfy{$0<128} ? Data(query.utf8):nil
        var ranked:[(item:BrowserSuggestion,rank:Int,date:Date)]=[],seen=Set<String>()
        func append(_ record:Record,_ source:SuggestionSearchSource) {
            if !query.isEmpty && ranked.count==8 {
                let kind:Int
                switch record.kind {case .pinned:kind=0;case .bookmark:kind=1;case .history:kind=2;case .cookie:kind=3}
                let bestPossible=(record.host==query ? 0:record.host.hasPrefix(query) ? 1:2)*10+kind
                let worst=ranked[7]
                if bestPossible>worst.rank || (bestPossible==worst.rank && (record.kind != .history || record.visited<=worst.date)) {return}
            }
            if !query.isEmpty {
                if let bytes=record.asciiSearch,let needle=asciiQuery {
                    guard bytes.range(of:needle) != nil else{return}
                } else if !record.titleKey.contains(query) && !record.urlKey.contains(query) {return}
            }
            // URL paths, queries and fragments can be case-sensitive. The lowercase
            // key is for matching only; distinct destinations must stay selectable.
            let identity=record.url+(fuse ? "|"+source.id.uuidString:"")
            guard !seen.contains(identity) else{return}
            let titlePrefix:Bool
            if let bytes=record.asciiSearch,let needle=asciiQuery {titlePrefix=needle.count<=record.titleByteCount && bytes.starts(with:needle)}
            else {titlePrefix=record.titleKey.hasPrefix(query)}
            let match=record.host==query ? 0:record.host.hasPrefix(query) ? 1:titlePrefix ? 2:3
            let kind:Int
            switch record.kind {case .pinned:kind=0;case .bookmark:kind=1;case .history:kind=2;case .cookie:kind=3}
            let rank=query.isEmpty ? kind:match*10+kind
            func precedes(_ other:(item:BrowserSuggestion,rank:Int,date:Date))->Bool {
                rank<other.rank || (rank==other.rank && record.kind == .history && record.visited>other.date)
            }
            if ranked.count==8 && !precedes(ranked[7]) {return}
            seen.insert(identity)
            let item=BrowserSuggestion(title:record.title,url:record.url,kind:record.kind,profileID:source.id,profileName:fuse ? source.name:nil)
            let index=ranked.firstIndex{precedes($0)} ?? ranked.count
            ranked.insert((item,rank,record.visited),at:index)
            if ranked.count>8 {ranked.removeLast()}
        }
        for source in sources {
            for link in source.pins {if let record=record(link,kind:.pinned) {append(record,source)}}
        }
        for source in sources {for record in profiles[source.id]?.bookmarks ?? [] {append(record,source)}}
        for source in sources {
            for (index,record) in (profiles[source.id]?.history ?? []).enumerated() {
                if index%64==0 && Task.isCancelled {return .init(items:[],routes:[:])}
                if query.isEmpty && ranked.count==8 && (ranked[7].rank<2 || (ranked[7].rank==2 && record.visited<=ranked[7].date)) {break}
                append(record,source)
            }
        }
        if !query.isEmpty {
            for source in sources {for host in source.cookies {
                if let record=Record(.init(title:host,url:"https://"+host,visitedAt:nil),kind:.cookie) {append(record,source)}
            }}
        }
        return .init(items:ranked.map{$0.item},routes:routes)
    }
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
        headline.font = WebbyTypography.font(ofSize: 14, weight: featured ? .semibold : .medium)
        headline.textColor = .labelColor
        headline.lineBreakMode = .byTruncatingTail
        detail.stringValue = (URL(string: item.url)?.host ?? item.url)
            + (item.profileName.map { " · " + $0 } ?? "")
        detail.font = WebbyTypography.font(ofSize: 11)
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

    func update(item:BrowserSuggestion,index:Int,accent:NSColor) {
        self.accent=accent;featured=index==0;hovered=false;selected=false;hasFavicon=false
        setAccessibilityLabel("\(item.title), \(item.url)");toolTip=item.url
        selectionGlow.colors=[accent.withAlphaComponent(0.24).cgColor,NSColor.white.withAlphaComponent(0.07).cgColor,accent.withAlphaComponent(0.10).cgColor]
        icon.image=NSImage(systemSymbolName:Self.symbol(for:item.kind),accessibilityDescription:nil)
        headline.stringValue=item.title
        headline.font=WebbyTypography.font(ofSize:14,weight:featured ? .semibold:.medium)
        detail.stringValue=(URL(string:item.url)?.host ?? item.url)+(item.profileName.map{" · "+$0} ?? "")
        needsLayout=true;restyle()
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
        if selected != value {Motion.change(self,character:.panel)}
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
    private var rowPool:[SuggestionRow]=[]
    private var selectionValid=false
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
        if let panel {Motion.depart(panel,character:.panel)}
        (anchor as? GlassAddressSurface)?.setSuggestionsAttached(false)
        outline.removeFromSuperlayer()
        entranceAura.removeFromSuperlayer()
        entranceBeam.removeFromSuperlayer()
        panel?.removeFromSuperview()
        panel = nil
        scroll = nil
        document = nil
        rows.forEach{$0.removeFromSuperview()}
        rowPool=rows
        rows.removeAll()
        suggestions.removeAll()
        selectedIndex = -1
        selectionValid=false
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
        if opening {applyTheme(BrowserTheme.profile)}
        (anchor as? GlassAddressSurface)?.setSuggestionsAttached(true)
        let next = Array(items.prefix(8))
        selectionValid=true
        if !opening, suggestions == next {
            selectedIndex = 0
            for (index, row) in rows.enumerated() { row.setSelected(index == 0, featureWhenIdle: false) }
            return
        }
        suggestions = next
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
        guard selectionValid,!suggestions.isEmpty else { return }
        selectedIndex = min(suggestions.count - 1, max(0, selectedIndex + delta))
        for (index, row) in rows.enumerated() {
            row.setSelected(index == selectedIndex, featureWhenIdle: selectedIndex < 0 && index == 0)
        }
        if rows.indices.contains(selectedIndex) {
            rows[selectedIndex].scrollToVisible(rows[selectedIndex].bounds)
        }
    }

    func invalidateSelection() {
        selectionValid=false;selectedIndex = -1
        for row in rows {row.setSelected(false,featureWhenIdle:false)}
    }

    func selected() -> BrowserSuggestion? {
        selectionValid && suggestions.indices.contains(selectedIndex) ? suggestions[selectedIndex] : nil
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
        let view = WebbyGlassBackdrop()
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
        let reusable=rows.isEmpty ? rowPool:rows
        rows = suggestions.enumerated().map { index, item in
            let row:SuggestionRow
            if reusable.indices.contains(index) {row=reusable[index];row.update(item:item,index:index,accent:accent)}
            else {row=SuggestionRow(item:item,index:index,accent:accent)}
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
        for row in reusable where !rows.contains(where:{$0 === row}) {row.removeFromSuperview()}
        rowPool=[]
        let content = document ?? NSView()
        for row in rows where row.superview !== content { content.addSubview(row) }
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
        guard selectionValid,suggestions.indices.contains(index) else { return }
        let item = suggestions[index]
        close()
        onChoose?(item)
    }
}
