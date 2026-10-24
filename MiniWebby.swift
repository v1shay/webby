import AppKit
import Carbon

struct MiniWebbyArchive: Codable {
    let id:UUID
    let title:String
    let url:String
    let profile:UUID
    let closed:Date
    static var entries:[Self] {
        get { guard let data=UserDefaults.standard.data(forKey:"webbyMiniArchive.v1"),data.count<500_000 else{return []};return (try? JSONDecoder().decode([Self].self,from:data)) ?? [] }
        set {UserDefaults.standard.set(try? JSONEncoder().encode(Array(newValue.prefix(100))),forKey:"webbyMiniArchive.v1")}
    }
}

@MainActor final class MiniWebbyHotKey {
    private var hotKey:EventHotKeyRef?
    private var handler:EventHandlerRef?
    var invoke:(()->Void)?
    private(set) var available=false
    static var keyCode:UInt32 {UInt32(UserDefaults.standard.integer(forKey:"webbyMiniShortcut.code"))}
    static var savedCode:UInt32 {UserDefaults.standard.object(forKey:"webbyMiniShortcut.code")==nil ? 49 : keyCode}
    static var modifiers:UInt32 {UInt32(UserDefaults.standard.object(forKey:"webbyMiniShortcut.modifiers") as? Int ?? optionKey)}
    static var label:String {UserDefaults.standard.string(forKey:"webbyMiniShortcut.label") ?? "⌥ Space"}
    func register(code:UInt32?=nil,modifiers:UInt32?=nil)->Bool {
        let code=code ?? Self.savedCode,modifiers=modifiers ?? Self.modifiers
        if handler==nil {
            var spec=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
            let status=InstallEventHandler(GetApplicationEventTarget(),{ _,_,context in
                guard let context else{return OSStatus(eventNotHandledErr)}
                MainActor.assumeIsolated {Unmanaged<MiniWebbyHotKey>.fromOpaque(context).takeUnretainedValue().invoke?()}
                return noErr
            },1,&spec,Unmanaged.passUnretained(self).toOpaque(),&handler)
            guard status==noErr else{return false}
        }
        var candidate:EventHotKeyRef?
        let status=RegisterEventHotKey(code,modifiers,EventHotKeyID(signature:0x57424D49,id:1),GetApplicationEventTarget(),0,&candidate)
        guard status==noErr else{return false}
        if let hotKey {UnregisterEventHotKey(hotKey)}
        hotKey=candidate;available=true;return true
    }
    func stop(){if let hotKey {UnregisterEventHotKey(hotKey)};hotKey=nil;if let handler {RemoveEventHandler(handler)};handler=nil;available=false}
}

@MainActor private final class MiniShortcutRecorder:NSButton {
    var record:((NSEvent)->Void)?
    override var acceptsFirstResponder:Bool {true}
    override func mouseDown(with event:NSEvent){title="Press two keys…";window?.makeFirstResponder(self)}
    override func keyDown(with event:NSEvent){if event.keyCode==53 {window?.makeFirstResponder(nil);title=MiniWebbyHotKey.label}else{record?(event)}}
    override func performKeyEquivalent(with event:NSEvent)->Bool {guard window?.firstResponder === self else{return false};keyDown(with:event);return true}
}

@MainActor final class MiniWebbySettings:NSObject {
    let hotKey=MiniWebbyHotKey()
    var open:(()->Void)?
    var restore:((MiniWebbyArchive)->Void)?
    private var preferences:NSWindow?
    private var feedback:NSTextField?
    static var externalLinks:Bool {UserDefaults.standard.object(forKey:"webbyMiniExternalLinks")==nil || UserDefaults.standard.bool(forKey:"webbyMiniExternalLinks")}
    static var archiveHours:Int {UserDefaults.standard.object(forKey:"webbyMiniArchiveHours")==nil ? 6 : UserDefaults.standard.integer(forKey:"webbyMiniArchiveHours")}
    func start(){hotKey.invoke={ [weak self] in self?.open?() };_ = hotKey.register()}
    func menu()->NSMenu {
        let menu=NSMenu(title:"Mini Webby")
        let launch=menu.addItem(withTitle:"Open Mini Webby · \(MiniWebbyHotKey.label)",action:#selector(launch),keyEquivalent:"");launch.target=self
        let shortcut=menu.addItem(withTitle:"Change Shortcut…",action:#selector(showShortcut),keyEquivalent:"");shortcut.target=self
        if !hotKey.available {let warning=menu.addItem(withTitle:"Shortcut unavailable · choose another",action:nil,keyEquivalent:"");warning.isEnabled=false}
        menu.addItem(.separator())
        let external=menu.addItem(withTitle:"Open External Links in Mini Webby",action:#selector(toggleExternal),keyEquivalent:"");external.target=self;external.state=Self.externalLinks ? .on:.off
        let expiry=NSMenuItem(title:"Auto-close Inactive Mini Windows",action:nil,keyEquivalent:"")
        let times=NSMenu(title:expiry.title)
        for hours in [0,6,12,24] {let item=times.addItem(withTitle:hours==0 ? "Never":"After \(hours) Hours",action:#selector(setExpiry(_:)),keyEquivalent:"");item.tag=hours;item.target=self;item.state=hours==Self.archiveHours ? .on:.off}
        expiry.submenu=times;menu.addItem(expiry)
        let history=NSMenuItem(title:"Recently Closed Mini Windows",action:nil,keyEquivalent:"")
        let recent=NSMenu(title:history.title)
        for entry in MiniWebbyArchive.entries.prefix(20) {let item=recent.addItem(withTitle:String(entry.title.prefix(70)),action:#selector(reopen(_:)),keyEquivalent:"");item.target=self;item.representedObject=entry}
        if recent.items.isEmpty {let item=recent.addItem(withTitle:"No closed mini windows",action:nil,keyEquivalent:"");item.isEnabled=false}
        else {recent.addItem(.separator());let clear=recent.addItem(withTitle:"Clear Mini History",action:#selector(clearArchive),keyEquivalent:"");clear.target=self}
        history.submenu=recent;menu.addItem(history)
        return menu
    }
    @objc private func launch(){open?()}
    @objc private func toggleExternal(){UserDefaults.standard.set(!Self.externalLinks,forKey:"webbyMiniExternalLinks")}
    @objc private func setExpiry(_ item:NSMenuItem){UserDefaults.standard.set(item.tag,forKey:"webbyMiniArchiveHours")}
    @objc private func reopen(_ item:NSMenuItem){if let entry=item.representedObject as? MiniWebbyArchive {restore?(entry)}}
    @objc private func clearArchive(){MiniWebbyArchive.entries=[]}
    @objc func showShortcut(){
        if let preferences {preferences.makeKeyAndOrderFront(nil);return}
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:430,height:210),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel.title="Mini Webby Shortcut";panel.isReleasedWhenClosed=false
        let glass=NSVisualEffectView(frame:NSRect(x:0,y:0,width:430,height:210));glass.material = .hudWindow;glass.blendingMode = .behindWindow;glass.state = .active;panel.contentView=glass
        let heading=NSTextField(labelWithString:"A quick window, from anywhere.");heading.font = .systemFont(ofSize:18,weight:.semibold);heading.frame=NSRect(x:24,y:155,width:385,height:26);glass.addSubview(heading)
        let hint=NSTextField(wrappingLabelWithString:"Click the shortcut, then press Command, Option, or Control plus one key. Escape cancels.");hint.frame=NSRect(x:24,y:110,width:382,height:38);glass.addSubview(hint)
        let recorder=MiniShortcutRecorder(title:MiniWebbyHotKey.label,target:nil,action:nil);recorder.bezelStyle = .rounded;recorder.frame=NSRect(x:24,y:59,width:200,height:38);glass.addSubview(recorder)
        let status=NSTextField(wrappingLabelWithString:hotKey.available ? "Two keys. No Accessibility permission needed.":"That shortcut is unavailable. Let’s choose another.");status.font = .systemFont(ofSize:11);status.textColor = .secondaryLabelColor;status.frame=NSRect(x:24,y:15,width:382,height:35);glass.addSubview(status);feedback=status
        recorder.record={ [weak self,weak recorder] event in
            guard let self else{return}
            let flags=event.modifierFlags.intersection([.command,.option,.control,.shift])
            let mapping:[(NSEvent.ModifierFlags,UInt32,String)]=[(.command,UInt32(cmdKey),"⌘"),(.option,UInt32(optionKey),"⌥"),(.control,UInt32(controlKey),"⌃")]
            guard let modifier=mapping.first(where:{$0.0==flags}),event.keyCode<128 else{self.feedback?.stringValue="Use one modifier and one key—for example ⌥ Space.";return}
            let text=event.keyCode==49 ? "Space":(event.charactersIgnoringModifiers ?? "").uppercased()
            guard !text.isEmpty,!CharacterSet.controlCharacters.contains(event.charactersIgnoringModifiers?.unicodeScalars.first ?? "\0") || event.keyCode==49 else {self.feedback?.stringValue="Let’s use a letter, number, or Space.";return}
            if event.keyCode==MiniWebbyHotKey.savedCode && modifier.1==MiniWebbyHotKey.modifiers {recorder?.title=MiniWebbyHotKey.label;panel.makeFirstResponder(nil);return}
            // Reserve familiar browser commands rather than silently taking them away.
            if flags == .command && [0,6,7,8,9,12,13,14,15,17,31,34,35,37,40,45,46,47,48].contains(Int(event.keyCode)){self.feedback?.stringValue="That Command shortcut is already used for browsing. Try Option plus a key.";return}
            guard self.hotKey.register(code:UInt32(event.keyCode),modifiers:modifier.1) else{self.feedback?.stringValue="Another app or macOS is using that shortcut. The previous shortcut still works.";return}
            let label=modifier.2+" "+text
            UserDefaults.standard.set(Int(event.keyCode),forKey:"webbyMiniShortcut.code");UserDefaults.standard.set(Int(modifier.1),forKey:"webbyMiniShortcut.modifiers");UserDefaults.standard.set(label,forKey:"webbyMiniShortcut.label")
            recorder?.title=label;self.feedback?.stringValue="Saved. Press \(label) from any app.";panel.makeFirstResponder(nil)
        }
        preferences=panel;panel.center();NSApp.activate(ignoringOtherApps:true);panel.makeKeyAndOrderFront(nil)
    }
}

@MainActor final class MiniWebbyWindow:FloatingTabWindow {
    let back=NSButton(),forward=NSButton(),reload=NSButton()
    let keep=NSPopUpButton(),account=NSPopUpButton()
    let status=NSTextField(labelWithString:"")
    let progress=NSProgressIndicator()
    var keepPage:((UUID)->Void)?
    var copyInProfile:((UUID)->Void)?
    var lastUsed=Date()
    private let tint=CAGradientLayer()
    private let wallpaper=BrowserWallpaperView(frame:.zero)
    private let home=NSView()
    private let indicator=NSButton()
    private let engine=NotchIndicatorEngine()
    private var homeConstraints:[NSLayoutConstraint]=[]
    private var pageConstraints:[NSLayoutConstraint]=[]
    private var expanded=false
    private var swipeDistance:CGFloat=0
    private var swipeLocked=false
    private var lastSwipe:TimeInterval=0
    private(set) var switchDirection:CGFloat=1
    override func sendEvent(_ event:NSEvent){
        guard event.type == .scrollWheel,!expanded,account.numberOfItems>1 else {super.sendEvent(event);return}
        let horizontal=abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY)*1.25
        guard horizontal || swipeDistance != 0 else {super.sendEvent(event);return}
        guard event.momentumPhase.isEmpty else{return}
        if event.phase.contains(.began) || (event.phase.isEmpty && event.timestamp-lastSwipe>0.3){swipeDistance=0;swipeLocked=false}
        lastSwipe=event.timestamp
        if event.phase.contains(.cancelled){swipeDistance=0;swipeLocked=false;return}
        if !swipeLocked {
            swipeDistance+=event.scrollingDeltaX
            if abs(swipeDistance)>=56 {swipeLocked=true;cycleProfile(swipeDistance<0 ? 1:-1)}
        }
        if event.phase.contains(.ended){swipeDistance=0;swipeLocked=false}
    }
    func animateProfileArrival(direction:CGFloat){
        swipeLocked=true;swipeDistance=0;lastSwipe=ProcessInfo.processInfo.systemUptime
        guard Motion.enabled,let layer=contentView?.layer else{return}
        let slide=CASpringAnimation(keyPath:"transform.translation.x")
        slide.fromValue=direction*18;slide.toValue=0;slide.mass=1;slide.stiffness=320;slide.damping=34;slide.duration=0.3
        layer.add(slide,forKey:"miniProfileSlide")
        Motion.basic(layer,key:"opacity",from:0.55,to:1,duration:0.18)
    }
    init(tabID:UUID,profiles:[(UUID,String)],owner:UUID,screen:NSScreen?) {
        super.init(tabID:tabID,title:"Mini Webby",screen:screen)
        let available=(screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:800)
        let width=min(640,available.width-40),height=min(360,available.height-40)
        styleMask.insert(.fullSizeContentView)
        for kind in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton]{standardWindowButton(kind)?.isHidden=true}
        isMovableByWindowBackground=true
        setFrame(NSRect(x:available.midX-width/2,y:available.midY-height/2,width:width,height:height),display:false)
        minSize=NSSize(width:380,height:260);titleVisibility = .hidden;collectionBehavior=[.moveToActiveSpace,.fullScreenAuxiliary]
        contentHost.removeFromSuperview();addressField.removeFromSuperview()
        let root=MiniGlassRoot();root.material = .underWindowBackground;root.blendingMode = .behindWindow;root.state = .active;root.wantsLayer=true;contentView=root
        root.layer?.cornerRadius=22;root.layer?.masksToBounds=true;root.layer?.borderWidth=0.7;root.layer?.borderColor=NSColor.white.withAlphaComponent(0.22).cgColor
        for view in [wallpaper,home,contentHost]{view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view)}
        wallpaper.homepage=home;wallpaper.show(profile:owner)
        for view in [wallpaper,home]{NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:root.leadingAnchor),view.trailingAnchor.constraint(equalTo:root.trailingAnchor),view.topAnchor.constraint(equalTo:root.topAnchor),view.bottomAnchor.constraint(equalTo:root.bottomAnchor)])}
        let search=NSVisualEffectView();search.material = .hudWindow;search.blendingMode = .withinWindow;search.state = .active;search.wantsLayer=true;search.layer?.cornerRadius=22;search.layer?.masksToBounds=true;search.layer?.borderWidth=1;search.layer?.borderColor=NSColor.white.withAlphaComponent(0.3).cgColor
        for view in [search,indicator,progress]{view.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(view)}
        addressField.translatesAutoresizingMaskIntoConstraints=false;search.addSubview(addressField)
        addressField.cell=MiniSearchCell(textCell:"");addressField.isEditable=true;addressField.isSelectable=true;addressField.isEnabled=true;addressField.usesSingleLineMode=true;addressField.cell?.isScrollable=true;addressField.alignment = .center;addressField.placeholderString="Search or enter a URL";addressField.font = .systemFont(ofSize:16);addressField.focusRingType = .none;addressField.isBordered=false;addressField.drawsBackground=false
        indicator.title="";indicator.isBordered=false;indicator.wantsLayer=true;indicator.layer?.addSublayer(engine.layer)
        engine.setProfile(BrowserTheme.profile(for:owner),wave:false);engine.showScene(BrowserExperiment.scene(for:owner,index:profiles.firstIndex{$0.0==owner} ?? 0))
        indicator.toolTip=profiles.first{$0.0==owner}?.1;indicator.target=self;indicator.action=#selector(chooseProfile)
        root.arrange={ [weak self] in
            guard let self else{return};CATransaction.begin();CATransaction.setDisableActions(true)
            self.engine.layer.position=CGPoint(x:self.indicator.bounds.midX,y:self.indicator.bounds.midY)
            let scale:CGFloat=self.expanded ? 1:3.4;self.engine.layer.setAffineTransform(CGAffineTransform(scaleX:scale,y:scale));self.engine.layout();CATransaction.commit()
        }
        account.addItems(withTitles:profiles.map{$0.1});keep.addItems(withTitles:profiles.map{$0.1})
        for(i,p) in profiles.enumerated(){account.item(at:i)?.representedObject=p.0;keep.item(at:i)?.representedObject=p.0}
        account.selectItem(at:profiles.firstIndex{$0.0==owner} ?? 0);keep.selectItem(at:profiles.firstIndex{$0.0==owner} ?? 0)
        let close=NSButton();close.target=self;close.action=#selector(closeMini)
        let promote=NSButton();promote.target=self;promote.action=#selector(MiniWebbyWindow.promote)
        for (button,symbol,label) in [(back,"chevron.left","Back"),(forward,"chevron.right","Forward"),(reload,"arrow.clockwise","Reload"),(promote,"arrow.up.right.square","Keep in Webby · ⌘O"),(close,"xmark","Close")] {
            button.image=NSImage(systemSymbolName:symbol,accessibilityDescription:label);button.isBordered=false;button.toolTip=label;button.translatesAutoresizingMaskIntoConstraints=false;root.addSubview(button)
        }
        for button in [back,forward,reload,promote]{button.isHidden=true}
        progress.isIndeterminate=false;progress.minValue=0;progress.maxValue=1;progress.style = .bar;progress.isHidden=true
        NSLayoutConstraint.activate([
            close.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-12),close.topAnchor.constraint(equalTo:root.topAnchor,constant:12),close.widthAnchor.constraint(equalToConstant:24),close.heightAnchor.constraint(equalToConstant:24),
            search.heightAnchor.constraint(equalToConstant:44),addressField.leadingAnchor.constraint(equalTo:search.leadingAnchor,constant:18),addressField.trailingAnchor.constraint(equalTo:search.trailingAnchor,constant:-18),addressField.centerYAnchor.constraint(equalTo:search.centerYAnchor),addressField.heightAnchor.constraint(equalToConstant:40),
            contentHost.leadingAnchor.constraint(equalTo:root.leadingAnchor),contentHost.trailingAnchor.constraint(equalTo:root.trailingAnchor),contentHost.topAnchor.constraint(equalTo:root.topAnchor,constant:62),contentHost.bottomAnchor.constraint(equalTo:root.bottomAnchor),
            progress.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:16),progress.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-16),progress.topAnchor.constraint(equalTo:root.topAnchor,constant:60),progress.heightAnchor.constraint(equalToConstant:2)])
        homeConstraints=[search.centerXAnchor.constraint(equalTo:root.centerXAnchor),search.centerYAnchor.constraint(equalTo:root.centerYAnchor,constant:-42),search.widthAnchor.constraint(equalTo:root.widthAnchor,constant:-64),indicator.centerXAnchor.constraint(equalTo:root.centerXAnchor),indicator.centerYAnchor.constraint(equalTo:root.centerYAnchor,constant:48),indicator.widthAnchor.constraint(equalToConstant:112),indicator.heightAnchor.constraint(equalToConstant:80)]
        pageConstraints=[search.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:132),search.trailingAnchor.constraint(equalTo:root.trailingAnchor,constant:-88),search.topAnchor.constraint(equalTo:root.topAnchor,constant:8),indicator.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:12),indicator.topAnchor.constraint(equalTo:root.topAnchor,constant:14),indicator.widthAnchor.constraint(equalToConstant:32),indicator.heightAnchor.constraint(equalToConstant:32)]
        for(i,button) in [back,forward,reload].enumerated(){NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo:root.leadingAnchor,constant:48+CGFloat(i)*26),button.topAnchor.constraint(equalTo:root.topAnchor,constant:16),button.widthAnchor.constraint(equalToConstant:24)])}
        NSLayoutConstraint.activate([promote.trailingAnchor.constraint(equalTo:close.leadingAnchor,constant:-8),promote.centerYAnchor.constraint(equalTo:close.centerYAnchor),promote.widthAnchor.constraint(equalToConstant:28)])
        NSLayoutConstraint.activate(homeConstraints);contentHost.isHidden=true
    }
    override func setFrame(_ frameRect:NSRect,display flag:Bool){super.setFrame(frameRect,display:flag);tint.frame=contentView?.bounds ?? .zero}
    func expand(){guard !expanded else{return};expanded=true;home.isHidden=true;contentHost.isHidden=false;NSLayoutConstraint.deactivate(homeConstraints);NSLayoutConstraint.activate(pageConstraints);for button in contentView?.subviews.compactMap({$0 as? NSButton}) ?? [] {button.isHidden=false};contentView?.needsLayout=true;let available=screen?.visibleFrame ?? frame;let height=min(580,available.height-40);var rect=frame;rect.origin.y=max(available.minY+20,rect.maxY-height);rect.size.height=height;setFrame(rect,display:true,animate:Motion.enabled)}
    // Share placement between profiles, never the page/home window dimensions.
    func positionForSwitch(from previous:MiniWebbyWindow){
        let available=previous.screen?.visibleFrame ?? screen?.visibleFrame ?? previous.frame
        var rect=frame
        rect.origin.x=min(max(available.minX,previous.frame.midX-rect.width/2),max(available.minX,available.maxX-rect.width))
        rect.origin.y=min(max(available.minY,previous.frame.maxY-rect.height),max(available.minY,available.maxY-rect.height))
        setFrame(rect,display:true)
    }
    override func cancelOperation(_ sender:Any?){performClose(sender)}
    @objc func promote(){if let id=keep.selectedItem?.representedObject as? UUID {keepPage?(id)}}
    @objc private func closeMini(){performClose(nil)}
    @objc private func chooseProfile(){
        cycleProfile(1)
    }
    private func cycleProfile(_ direction:Int){
        guard account.numberOfItems>1 else{return}
        switchDirection=CGFloat(direction)
        let next=(account.indexOfSelectedItem+direction+account.numberOfItems)%account.numberOfItems
        if let id=account.item(at:next)?.representedObject as? UUID {copyInProfile?(id)}
    }
    @objc private func selectProfile(_ item:NSMenuItem){if let id=item.representedObject as? UUID {copyInProfile?(id)}}
    override func close(){engine.hide();super.close()}
    @objc private func copyAccount(){if let id=account.selectedItem?.representedObject as? UUID {copyInProfile?(id)}}
}

@MainActor private final class MiniGlassRoot:NSVisualEffectView {
    var arrange:(()->Void)?
    override func layout(){super.layout();arrange?()}
    override var mouseDownCanMoveWindow:Bool {true}
    override func mouseDown(with event:NSEvent){window?.performDrag(with:event)}
}

private final class MiniSearchCell:NSTextFieldCell {
    override func drawingRect(forBounds rect:NSRect)->NSRect {
        var content=super.drawingRect(forBounds:rect)
        let height=min(content.height,cellSize.height)
        content.origin.y+=(content.height-height)/2;content.size.height=height
        return content
    }
    override func edit(withFrame rect:NSRect,in view:NSView,editor:NSText,delegate:Any?,event:NSEvent?){super.edit(withFrame:drawingRect(forBounds:rect),in:view,editor:editor,delegate:delegate,event:event)}
    override func select(withFrame rect:NSRect,in view:NSView,editor:NSText,delegate:Any?,start:Int,length:Int){super.select(withFrame:drawingRect(forBounds:rect),in:view,editor:editor,delegate:delegate,start:start,length:length)}
}
