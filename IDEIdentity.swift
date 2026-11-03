import AppKit

// A folded portal: native vector geometry, crisp from favicon to hero size.
@MainActor enum IDEIdentity {
    static func image(size: CGFloat = 128) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let scale = min(rect.width, rect.height) / 100
            let transform = NSAffineTransform(); transform.translateX(by: rect.minX, yBy: rect.minY-2.5*scale); transform.scale(by: scale)
            NSGraphicsContext.saveGraphicsState(); transform.concat()
            func face(_ points: [NSPoint], _ color: NSColor) {
                let path = NSBezierPath(); path.move(to: points[0]); for point in points.dropFirst() { path.line(to: point) }; path.close(); color.setFill(); path.fill()
            }
            face([.init(x:50,y:6),.init(x:91,y:29),.init(x:74,y:39),.init(x:50,y:25),.init(x:26,y:39),.init(x:9,y:29)], NSColor(calibratedWhite:0.98,alpha:1))
            face([.init(x:9,y:29),.init(x:26,y:39),.init(x:26,y:66),.init(x:50,y:80),.init(x:50,y:99),.init(x:9,y:75)], NSColor(calibratedRed:0.68,green:0.72,blue:0.82,alpha:1))
            face([.init(x:91,y:29),.init(x:91,y:75),.init(x:50,y:99),.init(x:50,y:80),.init(x:74,y:66),.init(x:74,y:39)], NSColor(calibratedRed:0.40,green:0.38,blue:0.60,alpha:1))
            face([.init(x:43,y:43),.init(x:66,y:56),.init(x:43,y:69)], NSColor(calibratedWhite:1,alpha:1))
            NSGraphicsContext.restoreGraphicsState(); return true
        }
        image.isTemplate = false
        return image
    }
}

extension Notification.Name { static let webbyIDEProjectsChanged = Notification.Name("webbyIDEProjectsChanged") }

@MainActor enum IDERecentProjects {
    private static let key = "webbyIDERecentProjects.v1"
    private static var legacyStarted = false
    static var urls: [URL] { (UserDefaults.standard.stringArray(forKey:key) ?? []).prefix(40).map { URL(fileURLWithPath:$0) } }
    static func normalized(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return Array(urls.filter(\.isFileURL).map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }.prefix(40))
    }
    static func record(_ url: URL) {
        guard url.isFileURL else { return }
        let paths = normalized([url] + urls).map(\.path)
        guard paths != UserDefaults.standard.stringArray(forKey:key) else { return }
        UserDefaults.standard.set(paths,forKey:key)
        NotificationCenter.default.post(name:.webbyIDEProjectsChanged,object:nil)
    }
    static func forget(_ url: URL) {
        UserDefaults.standard.set(urls.filter { $0.standardizedFileURL != url.standardizedFileURL }.map(\.path),forKey:key)
        NotificationCenter.default.post(name:.webbyIDEProjectsChanged,object:nil)
    }
    static func importLegacy() {
        guard !legacyStarted, Bundle.main.bundleIdentifier != "local.webby.performance-tests" else { return }; legacyStarted = true
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Webby IDE/projects.json")
        Task {
            let paths = await Task.detached(priority:.utility) { () -> [String] in
                var paths: [String] = []
                if let data=try? Data(contentsOf:file),data.count<500_000 { paths=(try? JSONDecoder().decode([String].self,from:data)) ?? [] }
                let last=file.deletingLastPathComponent().appendingPathComponent("Workbench/coder.json")
                if let data=try? Data(contentsOf:last),data.count<500_000,let json=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let query=json["query"] as? [String:Any],let path=query["folder"] as? String,path.hasPrefix("/") {paths.insert(path,at:0)}
                return paths
            }.value
            let combined = normalized(urls + paths.map { URL(fileURLWithPath:$0) })
            if combined.map(\.path) != urls.map(\.path) {
                UserDefaults.standard.set(combined.map(\.path),forKey:key)
                NotificationCenter.default.post(name:.webbyIDEProjectsChanged,object:nil)
            }
        }
    }
}

@MainActor private final class IDEProjectButton: NSButton {
    var project: URL?
    var compact = false { didSet { needsDisplay = true } }
    private var hovered = false
    private static let folder = NSWorkspace.shared.icon(for: .folder)
    override var isFlipped: Bool { true }
    init(project: URL) {
        self.project = project
        super.init(frame:.zero)
        isBordered = false; wantsLayer = true
        toolTip = project.path; setAccessibilityLabel("Open project " + project.lastPathComponent)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil))
    }
    override func mouseEntered(with event:NSEvent) { hovered = true; updateHover() }
    override func mouseExited(with event:NSEvent) { hovered = false; updateHover() }
    private func updateHover() {
        layer?.cornerRadius = 9
        layer?.backgroundColor = NSColor.white.withAlphaComponent(hovered ? 0.11 : 0.035).cgColor
        if hovered { Motion.springScale(layer,from:0.98,to:1) }
        needsDisplay = true
    }
    override func draw(_ dirtyRect:NSRect) {
        let folderSide: CGFloat = compact ? min(24,bounds.height-6) : 25
        let x:CGFloat = compact ? (bounds.width-folderSide)/2 : 8
        Self.folder.draw(in:NSRect(x:x,y:(bounds.height-folderSide)/2,width:folderSide,height:folderSide),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
        guard !compact, let project else { return }
        let paragraph = NSMutableParagraphStyle(); paragraph.lineBreakMode = .byTruncatingMiddle
        let name = project.lastPathComponent.isEmpty ? project.path : project.lastPathComponent
        let twoLines = bounds.height >= 42
        (name as NSString).draw(in:NSRect(x:43,y:twoLines ? 6 : (bounds.height-16)/2,width:max(1,bounds.width-51),height:17),withAttributes:[.font:WebbyTypography.font(ofSize:12,weight:.medium),.foregroundColor:NSColor.labelColor,.paragraphStyle:paragraph])
        if twoLines {
            (project.deletingLastPathComponent().abbreviatingWithTildeInPath as NSString).draw(in:NSRect(x:43,y:24,width:max(1,bounds.width-51),height:14),withAttributes:[.font:WebbyTypography.font(ofSize:9),.foregroundColor:NSColor.secondaryLabelColor,.paragraphStyle:paragraph])
        }
    }
    override func rightMouseDown(with event:NSEvent) {
        let menu = NSMenu(); let item = menu.addItem(withTitle:"Remove from Recents",action:#selector(forget),keyEquivalent:"");item.target=self
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    @objc private func forget() { if let project { IDERecentProjects.forget(project) } }
}

@MainActor final class IDEProjectWidgetView: NSView {
    enum Layout: String { case icon, strip, columns, stacked }
    var openProject: ((URL?) -> Void)?
    private let logo = NSButton()
    private let heading = NSTextField(labelWithString:"WORKSPACE")
    private let caption = NSTextField(labelWithString:"Pick up where we left off")
    private let empty = NSTextField(wrappingLabelWithString:"Our next project starts here.")
    private let more = NSButton(title:"All projects  ↗",target:nil,action:nil)
    private var rows: [IDEProjectButton] = []
    private(set) var mode: Layout = .stacked
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override init(frame:NSRect) {
        super.init(frame:frame); wantsLayer = true
        logo.image = IDEIdentity.image(); logo.imageScaling = .scaleProportionallyUpOrDown; logo.isBordered=false
        logo.target=self;logo.action=#selector(openLogo);logo.toolTip="Open Webby IDE";logo.setAccessibilityLabel("Open Webby IDE")
        heading.font = WebbyTypography.font(ofSize:9,weight:.semibold);heading.textColor = .secondaryLabelColor
        caption.font = WebbyTypography.font(ofSize:11,weight:.medium);caption.textColor = .secondaryLabelColor;caption.lineBreakMode = .byTruncatingTail
        empty.font = WebbyTypography.font(ofSize:11);empty.textColor = .secondaryLabelColor;empty.alignment = .center
        more.isBordered=false;more.font = WebbyTypography.font(ofSize:10,weight:.medium);more.contentTintColor = .secondaryLabelColor;more.target=self;more.action=#selector(showProjects)
        [logo,heading,caption,empty,more].forEach(addSubview)
        NotificationCenter.default.addObserver(self,selector:#selector(refreshProjects),name:.webbyIDEProjectsChanged,object:nil)
        IDERecentProjects.importLegacy();refreshProjects()
    }
    required init?(coder:NSCoder) { fatalError() }
    deinit { NotificationCenter.default.removeObserver(self) }
    static func layoutMode(size:NSSize) -> Layout {
        if size.width < 110 && size.height < 140 { return .icon }
        if size.height < 90 { return .strip }
        if size.width >= 270 && size.width >= size.height*1.18 { return .columns }
        return .stacked
    }
    @objc private func refreshProjects() {
        rows.forEach { $0.removeFromSuperview() }
        rows = IDERecentProjects.urls.map { url in
            let row = IDEProjectButton(project:url);row.target=self;row.action=#selector(openRow(_:));addSubview(row);return row
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let next = Self.layoutMode(size:bounds.size)
        if mode != next { mode = next; Motion.change(self,character:.widget) }
        [heading,caption,empty,more].forEach { $0.isHidden = true }
        rows.forEach { $0.isHidden = true }
        guard width > 0, height > 0 else { return }
        if mode == .icon {
            let side = min(width,height,66); logo.frame=NSRect(x:(width-side)/2,y:(height-side)/2,width:side,height:side);return
        }
        if mode == .strip {
            let side = min(44,height);logo.frame=NSRect(x:0,y:(height-side)/2,width:side,height:side)
            let available = width-side-8
            let count = min(rows.count,max(0,Int(available/38)))
            if count > 0 {
                let cell=min(112,available/CGFloat(count))
                for index in 0..<count { let row=rows[index];row.compact=cell<90;row.isHidden=false;row.frame=NSRect(x:side+8+CGFloat(index)*cell,y:(height-32)/2,width:cell-4,height:32) }
            } else { caption.isHidden=false;caption.stringValue="Open IDE";caption.frame=NSRect(x:side+8,y:(height-18)/2,width:max(1,available),height:18) }
            return
        }
        let projects: NSRect
        let titleY: CGFloat
        if mode == .columns {
            let sidebar = min(245,width*0.55)
            let side = min(width-sidebar-26,height-38,132)
            logo.frame=NSRect(x:sidebar+(width-sidebar-side)/2,y:(height-side)/2-8,width:max(1,side),height:max(1,side))
            caption.stringValue="Webby IDE";caption.alignment = .center;caption.isHidden=false
            caption.frame=NSRect(x:sidebar,y:min(height-18,logo.frame.maxY+10),width:width-sidebar,height:18)
            titleY=4;projects=NSRect(x:0,y:24,width:sidebar-10,height:max(0,height-46))
        } else {
            let side = min(110,width*0.48,height*0.31)
            logo.frame=NSRect(x:(width-side)/2,y:2,width:side,height:side)
            titleY=logo.frame.maxY+12;projects=NSRect(x:0,y:titleY+21,width:width,height:max(0,height-titleY-44))
        }
        heading.isHidden=projects.width < 100;heading.frame=NSRect(x:projects.minX+8,y:titleY,width:projects.width-8,height:14)
        let rowHeight:CGFloat = width >= 210 && height >= 220 ? 48 : 34
        let count=min(rows.count,max(0,Int(projects.height/(rowHeight+4))))
        for index in 0..<count { let row=rows[index];row.compact=projects.width < 115;row.isHidden=false;row.frame=NSRect(x:projects.minX,y:projects.minY+CGFloat(index)*(rowHeight+4),width:max(1,projects.width),height:rowHeight) }
        more.isHidden=false;more.title=projects.width < 115 ? "•••" : (rows.isEmpty ? "Open a workspace  ↗" : "All projects  ↗");more.setAccessibilityLabel("All IDE projects")
        more.frame=NSRect(x:projects.minX,y:max(0,height-20),width:projects.width,height:20)
        if rows.isEmpty {
            empty.isHidden=projects.width < 115;empty.frame=NSRect(x:projects.minX+4,y:projects.midY-15,width:max(1,projects.width-8),height:30)
        }
    }
    func containsControl(_ point:NSPoint) -> Bool {
        ([logo,more] + rows).contains { !$0.isHidden && $0.frame.contains(point) }
    }
    @objc private func openRow(_ sender:IDEProjectButton) { if let url=sender.project { openProject?(url) } }
    @objc private func openLogo() { if mode == .icon || mode == .strip { showProjects() } else { openProject?(nil) } }
    @objc private func showProjects() {
        let menu=NSMenu()
        let fresh=menu.addItem(withTitle:"Open IDE…",action:#selector(openBlank),keyEquivalent:"");fresh.target=self;fresh.image=IDEIdentity.image(size:18)
        if !rows.isEmpty {menu.addItem(.separator())}
        for row in rows {
            guard let url=row.project else {continue}
            let entry=menu.addItem(withTitle:url.lastPathComponent+"  ·  "+url.deletingLastPathComponent().abbreviatingWithTildeInPath,action:#selector(openMenuProject(_:)),keyEquivalent:"")
            entry.target=self;entry.representedObject=url;entry.image=NSWorkspace.shared.icon(for:.folder)
        }
        menu.popUp(positioning:nil,at:NSPoint(x:0,y:bounds.maxY),in:self)
    }
    @objc private func openBlank() {openProject?(nil)}
    @objc private func openMenuProject(_ item:NSMenuItem) {if let url=item.representedObject as? URL {openProject?(url)}}
}

private extension URL { var abbreviatingWithTildeInPath:String { (path as NSString).abbreviatingWithTildeInPath } }
