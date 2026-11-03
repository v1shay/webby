import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor private final class WebbyDockTileView: NSView {
    var icon: NSImage?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        icon?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)
    }
}

@MainActor private final class WebbyDockAnimator {
    private let tileView = WebbyDockTileView(frame:NSRect(x:0,y:0,width:128,height:128))
    private var frames:[NSImage]=[],durations:[Double]=[]
    private var loaders:[Int:()->NSImage?]=[:]
    private var cachedFrames:Set<Int>=[]
    private var persistence:DispatchWorkItem?
    private var generation=0
    private var index=0
    private var timer:Timer?
    private var loop=false
    private var persistedSignature=""
    private var configuredSignature=""
    private var sleeping=false
    private var observers:[NSObjectProtocol]=[]
    init() {
        let center=NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification,NSWorkspace.willSleepNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated {self?.sleeping=true;self?.timer?.invalidate();self?.timer=nil}})
        }
        for name in [NSWorkspace.screensDidWakeNotification,NSWorkspace.didWakeNotification,NSWorkspace.accessibilityDisplayOptionsDidChangeNotification] {
            observers.append(center.addObserver(forName:name,object:nil,queue:.main){[weak self] _ in MainActor.assumeIsolated {
                guard let self else{return};self.sleeping=false;self.timer?.invalidate();self.timer=nil
                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {self.tileView.icon=self.frames.first;self.tileView.needsDisplay=true;NSApp.dockTile.display()} else {self.scheduleNext()}
            }})
        }
    }

    func configure(profile:PetGradientProfile,petID:String,customPetURL:URL?) {
        let settings=WebbyIconSettings.value
        let signature=(String(data:(try? JSONEncoder().encode(settings)) ?? Data(),encoding:.utf8) ?? "")+petID+profile.palette.primary+(customPetURL?.path ?? "")
        let configuration=signature+String(WebbyIcon.isStarting)
        guard configuration != configuredSignature else{return}
        configuredSignature=configuration
        timer?.invalidate();timer=nil;persistence?.cancel();persistence=nil;generation+=1;index=0;frames=[];durations=[];loaders=[:];cachedFrames=[]
        let startup=WebbyIcon.isStarting && settings.animateStartup && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var still:NSImage
        if settings.mode=="indicator" {
            still=WebbyIconSettings.compose(WebbyIconSettings.indicatorImage(profile:profile,time:0),profile:profile)
            if startup {
                frames=Array(repeating:NSImage(size:NSSize(width:128,height:128)),count:18)
                for i in frames.indices {loaders[i]={WebbyIcon.dockRaster(WebbyIconSettings.compose(WebbyIconSettings.indicatorImage(profile:profile,time:Double(i)/12),profile:profile))}}
                durations=Array(repeating:1.0/12,count:frames.count)
            }
            loop=startup
        } else if settings.mode=="image",let path=settings.imagePath,let image=NSImage(contentsOfFile:path) {
            still=WebbyIconSettings.compose(image,profile:profile)
            if settings.animateGIF,let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),CGImageSourceGetCount(source)>1 {
                // Bound decoded memory: at most 90 thumbnails, 256px each (~23 MB).
                let count=CGImageSourceGetCount(source),step=max(1,Int(ceil(Double(count)/90)))
                for i in stride(from:0,to:count,by:step) {
                    let options:[CFString:Any]=[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceThumbnailMaxPixelSize:256,kCGImageSourceCreateThumbnailWithTransform:true]
                    let index=frames.count
                    frames.append(NSImage(size:NSSize(width:128,height:128)))
                    loaders[index]={
                        guard let cg=CGImageSourceCreateThumbnailAtIndex(source,i,options as CFDictionary) else{return nil}
                        return WebbyIcon.dockRaster(WebbyIconSettings.compose(NSImage(cgImage:cg,size:.zero),profile:profile))
                    }
                    var duration=0.0
                    for j in i..<min(count,i+step) {
                        let properties=CGImageSourceCopyPropertiesAtIndex(source,j,nil) as? [CFString:Any]
                        let gif=properties?[kCGImagePropertyGIFDictionary] as? [CFString:Any]
                        duration += max(0.02,(gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1)
                    }
                    durations.append(max(0.08,duration))
                }
            }
            loop=true
        } else {
            still=WebbyIcon.image(profile:profile,petID:petID,customPetURL:customPetURL)
            if customPetURL==nil,let url=Bundle.main.url(forResource:"durations",withExtension:"json",subdirectory:"PetsWorking"),let data=try? Data(contentsOf:url),let all=try? JSONDecoder().decode([String:[Int]].self,from:data) {
                let times=all[petID] ?? [120]
                frames=times.indices.map{_ in NSImage(size:NSSize(width:128,height:128))}
                for i in frames.indices {loaders[i]={WebbyIcon.dockRaster(WebbyIcon.image(profile:profile,petID:petID,frameIndex:i))}}
                durations=times.map{max(0.09,Double($0)/1000)}
            }
            loop=true
        }
        let raster=WebbyIcon.dockRaster(still)
        if frames.isEmpty {frames=[raster];durations=[0.1]}
        if startup && frames.count==1 {
            frames=(0..<16).map {i in
                let t=Double(i)/15
                let scale=1-0.16*exp(-5*t)*cos(8*t)
                return NSImage(size:NSSize(width:128,height:128),flipped:false){_ in
                    raster.draw(in:NSRect(x:64-64*scale,y:64-64*scale,width:128*scale,height:128*scale),from:.zero,operation:.sourceOver,fraction:1);return true
                }
            }
            durations=Array(repeating:0.065,count:frames.count);loop=false
        }
        tileView.icon=frame(at:0);tileView.needsDisplay=true
        NSApp.dockTile.contentView=tileView;NSApp.dockTile.display()
        // A saved Finder icon already survives quit. Rewrite only on artwork or bundle changes.
        let modified=(try? Bundle.main.executableURL?.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let identity=signature+Bundle.main.bundlePath+String(modified)
        let savedKey="webbyAppIconPersistedIdentity"
        if UserDefaults.standard.string(forKey:savedKey) != identity,Bundle.main.bundleURL.pathExtension=="app" {
            let version=generation
            let work=DispatchWorkItem { [weak self] in
                guard let self,self.generation==version else{return}
                self.persistence=nil
                if NSWorkspace.shared.setIcon(still,forFile:Bundle.main.bundlePath,options:[]) {
                    // Finder can change the folder's modification date while saving its icon.
                    let date=(try? Bundle.main.executableURL?.resourceValues(forKeys:[.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
                    UserDefaults.standard.set(signature+Bundle.main.bundlePath+String(date),forKey:savedKey)
                } else {NSLog("Webby could not persist its app icon at %@",Bundle.main.bundlePath)}
            }
            persistence=work
            DispatchQueue.main.asyncAfter(deadline:.now()+0.8,execute:work)
        }
        scheduleNext()
    }
    private func frame(at index:Int)->NSImage? {
        guard frames.indices.contains(index) else{return nil}
        if !cachedFrames.contains(index),let load=loaders[index] {
            if let image=load() {frames[index]=image}
            cachedFrames.insert(index);loaders.removeValue(forKey:index)
        }
        return frames[index]
    }
    private func scheduleNext() {
        guard !sleeping,frames.count>1,!NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,loop || index<frames.count-1 else{return}
        let next=Timer(timeInterval:durations[index],repeats:false){[weak self] _ in
            MainActor.assumeIsolated {
                guard let self else{return}
                self.index=(self.index+1)%self.frames.count
                self.tileView.icon=self.frame(at:self.index);self.tileView.needsDisplay=true;NSApp.dockTile.display();self.scheduleNext()
            }
        }
        next.tolerance=0.015;timer=next;RunLoop.main.add(next,forMode:.common)
    }
    func stop() {timer?.invalidate();timer=nil;if let persistence,!persistence.isCancelled {persistence.perform()};persistence=nil;observers.forEach{NSWorkspace.shared.notificationCenter.removeObserver($0)};observers=[];}
}

@MainActor private final class WebbyMenuPetView:NSView {
    var image:NSImage? {didSet {needsDisplay=true}}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func draw(_ dirtyRect:NSRect) {
        image?.draw(in:NSRect(x:(bounds.width-24)/2,y:(bounds.height-22)/2,width:24,height:22),from:.zero,operation:.sourceOver,fraction:1)
    }
}

@MainActor final class WebbyMenuPetAnimator: NSObject {
    private weak var button: NSStatusBarButton?
    private let artwork=WebbyMenuPetView(frame:.zero)
    private var frames: [NSImage] = []
    private var durations: [TimeInterval] = []
    private var index = 0
    private var timer: Timer?
    private var sleeping = false

    init(button: NSStatusBarButton) {
        self.button = button
        super.init()
        // Set intrinsic menu width once; ticks repaint only this fixed view.
        button.image=NSImage(size:NSSize(width:24,height:22))
        artwork.frame=button.bounds;artwork.autoresizingMask=[.width,.height]
        button.addSubview(artwork)
        NotificationCenter.default.addObserver(self, selector: #selector(configure),
            name: .browserThemeChanged, object: nil)
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(sleep), name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(wake), name: NSWorkspace.screensDidWakeNotification, object: nil)
        workspace.addObserver(self, selector: #selector(motionChanged), name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        configure()
    }

    deinit {
        timer?.invalidate()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func configure() {
        timer?.invalidate(); timer = nil; index = 0
        let petID = BrowserTheme.petID
        let custom = BrowserTheme.customPetURL
        let allDurations: [String: [Int]] = {
            guard let url = Bundle.main.url(forResource: "durations", withExtension: "json", subdirectory: "PetsWorking"),
                  let data = try? Data(contentsOf: url) else { return [:] }
            return (try? JSONDecoder().decode([String: [Int]].self, from: data)) ?? [:]
        }()
        let millis = custom == nil ? (allDurations[petID] ?? [120]) : [120]
        durations = millis.map { max(0.09, TimeInterval($0) / 1000) }
        frames = millis.indices.compactMap { frame in
            let animated = Bundle.main.url(forResource: String(frame), withExtension: "png", subdirectory: "PetsWorking/\(petID)")
            let fallback = Bundle.main.url(forResource: petID, withExtension: "png", subdirectory: "Pets")
            guard let source = (custom ?? animated ?? fallback).flatMap(NSImage.init(contentsOf:)),
                  source.size.width > 0, source.size.height > 0,
                  let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 48, pixelsHigh: 44,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                  let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
            // Rasterize once at Retina menu-bar size; each tick only swaps an image.
            let scale = min(48 / source.size.width, 44 / source.size.height)
            let size = NSSize(width: source.size.width * scale, height: source.size.height * scale)
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: 48, height: 44))
            source.draw(in: NSRect(x: (48-size.width)/2, y: (44-size.height)/2,
                                  width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            let image = NSImage(size: NSSize(width: 24, height: 22))
            image.addRepresentation(bitmap); image.isTemplate = false
            return image
        }
        artwork.image = frames.first
        button?.contentTintColor = nil
        scheduleNext()
    }

    @objc private func sleep() { sleeping = true; timer?.invalidate(); timer = nil }
    @objc private func wake() { sleeping = false; scheduleNext() }
    @objc private func motionChanged() {
        timer?.invalidate(); timer = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            index = 0; artwork.image = frames.first
        } else { scheduleNext() }
    }

    private func scheduleNext() {
        timer?.invalidate(); timer = nil
        guard !sleeping, frames.count > 1, button != nil,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let next = Timer(timeInterval: durations[min(index, durations.count-1)], repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.sleeping else { return }
                self.index = (self.index + 1) % self.frames.count
                self.artwork.image = self.frames[self.index]
                self.scheduleNext()
            }
        }
        next.tolerance = 0.02
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }
}

@MainActor enum WebbyIcon {
    private static let animator = WebbyDockAnimator()
    private(set) static var isStarting=true
    private static var ready=false
    private static var pending:DispatchWorkItem?
    static func finishStartup() {
        // The already-persisted icon remains visible while the browser creates its window.
        // Do not instantiate the animator, decode artwork or contact Finder on the launch path.
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15) {
            ready=true;updateDockIcon()
            DispatchQueue.main.asyncAfter(deadline:.now()+1.2) {
                isStarting=false
                if WebbyIconSettings.value.mode=="indicator" {updateDockIcon()}
            }
        }
    }
    static func stop() {pending?.cancel();pending=nil;if ready {animator.stop()}}

    static func image(profile: PetGradientProfile, petID: String,
                      customPetURL: URL? = nil, frameIndex: Int = 0) -> NSImage {
        let workingFrame=Bundle.main.url(forResource:String(frameIndex),withExtension:"png",subdirectory:"PetsWorking/\(petID)")
        let fallback=Bundle.main.url(forResource:petID,withExtension:"png",subdirectory:"Pets")
        let pet=(customPetURL ?? workingFrame ?? fallback).flatMap(NSImage.init(contentsOf:))
        return WebbyIconSettings.compose(pet,profile:profile,pet:true)
    }

    static func dockRaster(_ source:NSImage)->NSImage {
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:256,pixelsHigh:256,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),
              let context=NSGraphicsContext(bitmapImageRep:bitmap) else{return source}
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=context
        source.draw(in:NSRect(x:0,y:0,width:256,height:256),from:.zero,operation:.sourceOver,fraction:1)
        NSGraphicsContext.restoreGraphicsState()
        let image=NSImage(size:NSSize(width:128,height:128));image.addRepresentation(bitmap);return image
    }

    static func updateDockIcon() {
        guard ready else{return}
        pending?.cancel()
        let work=DispatchWorkItem {
            animator.configure(profile:BrowserTheme.profile,petID:BrowserTheme.petID,customPetURL:BrowserTheme.customPetURL)
        }
        pending=work
        DispatchQueue.main.async(execute:work)
    }

    static func writeDefaultPNG(to url: URL) throws {
        guard let data = image(profile: BrowserTheme.profile, petID: BrowserTheme.petID).tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: data),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "WebbyIcon", code: 1)
        }
        try png.write(to: url, options: .atomic)
    }
}


/// App-wide artwork is copied into Application Support; the original can be moved.
@MainActor final class WebbyIconSettings: NSObject {
    static let shared = WebbyIconSettings()
    static let key = "webbyAppIcon.v1"
    struct Settings: Codable {
        var mode = "pet"
        var imagePath: String?
        var background = "default"
        var backgroundPath: String?
        var indicator = "agents"
        var animateStartup = true
        var animateGIF = true
    }
    static var value: Settings {
        get { UserDefaults.standard.data(forKey:key).flatMap { try? JSONDecoder().decode(Settings.self,from:$0) } ?? Settings() }
        set { if let data=try? JSONEncoder().encode(newValue) {UserDefaults.standard.set(data,forKey:key)} }
    }
    static let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Webby/AppIcon",isDirectory:true)

    static func importArtwork(_ url:URL, background:Bool) throws {
        let access=url.startAccessingSecurityScopedResource();defer {if access {url.stopAccessingSecurityScopedResource()}}
        let data=try Data(contentsOf:url,options:.mappedIfSafe)
        guard data.count<=32*1024*1024,let image=NSImage(data:data),image.size.width>0,image.size.height>0 else {
            throw NSError(domain:"WebbyIcon",code:3,userInfo:[NSLocalizedDescriptionKey:"Choose a readable image or SVG smaller than 32 MB."])
        }
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let target=folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
        try data.write(to:target,options:.atomic)
        var settings=value
        let old=background ? settings.backgroundPath : settings.imagePath
        if background {settings.backgroundPath=target.path;settings.background="image"}
        else {settings.imagePath=target.path;if settings.mode=="pet",settings.background=="default" {settings.background="transparent"};settings.mode="image"}
        value=settings
        if let old,old != target.path,URL(fileURLWithPath:old).deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL {try? FileManager.default.removeItem(atPath:old)}
        WebbyIcon.updateDockIcon()
    }

    func menuItem()->NSMenuItem {
        let root=NSMenuItem(title:"App Icon",action:nil,keyEquivalent:"")
        let menu=NSMenu(title:"App Icon");root.submenu=menu
        func add(_ title:String,_ action:Selector,_ object:String?=nil,_ checked:Bool=false,into target:NSMenu?=nil) {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:"");item.target=self;item.representedObject=object;item.state=checked ? .on:.off;(target ?? menu).addItem(item)
        }
        let settings=Self.value
        add("Profile Pet",#selector(mode(_:)),"pet",settings.mode=="pet")
        add("Choose Image, GIF or SVG…",#selector(chooseImage))
        if settings.imagePath != nil {add("Use Custom Artwork",#selector(mode(_:)),"image",settings.mode=="image")}
        let indicator=NSMenuItem(title:"Notch Indicator",action:nil,keyEquivalent:"")
        indicator.state=settings.mode=="indicator" ? .on:.off
        let choices=NSMenu(title:indicator.title);indicator.submenu=choices
        for id in IndicatorScenes.cycleIDs {add(id.capitalized,#selector(indicator(_:)),id,settings.mode=="indicator" && settings.indicator==id,into:choices)}
        menu.addItem(indicator)
        menu.addItem(.separator())
        let background=NSMenuItem(title:"Background",action:nil,keyEquivalent:"")
        let backgrounds=NSMenu(title:background.title);background.submenu=backgrounds
        add("Original Sky",#selector(background(_:)),"default",settings.background=="default",into:backgrounds)
        add("Transparent",#selector(background(_:)),"transparent",settings.background=="transparent",into:backgrounds)
        add("Choose Background Image…",#selector(chooseBackground),into:backgrounds)
        if settings.backgroundPath != nil {add("Use Saved Background",#selector(background(_:)),"image",settings.background=="image",into:backgrounds)}
        menu.addItem(background)
        add("Animate on Startup",#selector(toggleStartup),nil,settings.animateStartup)
        add("Animate GIF While Running",#selector(toggleGIF),nil,settings.animateGIF)
        menu.addItem(.separator());add("Restore Original Icon",#selector(reset))
        return root
    }
    @objc private func mode(_ item:NSMenuItem) {var s=Self.value;s.mode=item.representedObject as? String ?? "pet";Self.value=s;WebbyIcon.updateDockIcon()}
    @objc private func background(_ item:NSMenuItem) {var s=Self.value;s.background=item.representedObject as? String ?? "default";Self.value=s;WebbyIcon.updateDockIcon()}
    @objc private func indicator(_ item:NSMenuItem) {var s=Self.value;s.mode="indicator";s.indicator=item.representedObject as? String ?? "agents";Self.value=s;WebbyIcon.updateDockIcon()}
    @objc private func toggleStartup() {var s=Self.value;s.animateStartup.toggle();Self.value=s;WebbyIcon.updateDockIcon()}
    @objc private func toggleGIF() {var s=Self.value;s.animateGIF.toggle();Self.value=s;WebbyIcon.updateDockIcon()}
    @objc private func reset() {Self.value=Settings();WebbyIcon.updateDockIcon()}
    @objc private func chooseImage() {choose(background:false)}
    @objc private func chooseBackground() {choose(background:true)}
    private func choose(background:Bool) {
        let panel=NSOpenPanel();panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        panel.allowedContentTypes=[.png,.jpeg,.gif,.svg,.webP,.tiff,.heic]
        panel.message=background ? "Choose a background for Webby’s app icon.":"Choose Webby’s full app icon. Transparent artwork stays transparent."
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {try Self.importArtwork(url,background:background)} catch {let alert=NSAlert();alert.messageText="We couldn’t use that image";alert.informativeText=error.localizedDescription;alert.runModal()}
    }

    static func compose(_ artwork:NSImage?,profile:PetGradientProfile,pet:Bool=false)->NSImage {
        let settings=value
        let sky=settings.background=="default" ? Bundle.main.url(forResource:"SkyBackground",withExtension:"png").flatMap(NSImage.init(contentsOf:)):nil
        let background=settings.background=="image" ? settings.backgroundPath.flatMap{NSImage(contentsOfFile:$0)}:nil
        return NSImage(size:NSSize(width:1024,height:1024),flipped:false){_ in
            guard let c=NSGraphicsContext.current?.cgContext else{return false}
            c.saveGState();defer {c.restoreGState()}
            let rect=CGRect(x:94,y:94,width:836,height:836)
            // A full replacement defaults to transparent; only explicit backgrounds add a tile.
            let drawBackground=settings.background != "transparent"
            if drawBackground {
                c.saveGState();c.addPath(CGPath(roundedRect:rect,cornerWidth:154,cornerHeight:154,transform:nil));c.clip()
                let source=settings.background=="image" ? background:sky
                if let source {drawFit(source,in:rect,fill:true)}
                if settings.background=="default" {c.setBlendMode(.color);c.setFillColor(BrowserTheme.color(profile.palette.primary,alpha:0.52).cgColor);c.fill(rect);c.setBlendMode(.normal)}
                c.restoreGState()
            }
            if let artwork {
                let target=pet ? CGRect(x:314,y:141,width:395,height:428):rect
                drawFit(artwork,in:target)
            }
            return true
        }
    }
    private static func drawFit(_ image:NSImage,in rect:CGRect,fill:Bool=false) {
        guard image.size.width>0,image.size.height>0 else{return}
        let scale=fill ? max(rect.width/image.size.width,rect.height/image.size.height):min(rect.width/image.size.width,rect.height/image.size.height)
        let size=CGSize(width:image.size.width*scale,height:image.size.height*scale)
        image.draw(in:CGRect(x:rect.midX-size.width/2,y:rect.midY-size.height/2,width:size.width,height:size.height),from:.zero,operation:.sourceOver,fraction:1)
    }

    static func indicatorImage(profile:PetGradientProfile,time:Double)->NSImage {
        let scene=IndicatorScenes.all[value.indicator] ?? IndicatorScenes.thinking
        return NSImage(size:NSSize(width:512,height:512),flipped:false){_ in
            guard let c=NSGraphicsContext.current?.cgContext else{return false}
            c.saveGState();defer {c.restoreGState()}
            c.translateBy(x:32,y:112);c.scaleBy(x:16,y:16)
            let path=CGMutablePath()
            for track in scene.tracks {
                let period=max(0.1,scene.duration)
                let phase=(time/period+track.phase).truncatingRemainder(dividingBy:1)
                let keys=track.keyTimes.map(\.doubleValue)
                var i=0;while i+1<keys.count-1 && phase>keys[i+1] {i+=1}
                let a=track.poses[min(i,track.poses.count-1)],b=track.poses[min(i+1,track.poses.count-1)]
                let t=CGFloat(max(0,min(1,(phase-keys[i])/max(0.001,keys[min(i+1,keys.count-1)]-keys[i]))))
                let eased=t*t*(3-2*t)
                func mix(_ x:CGFloat,_ y:CGFloat)->CGFloat{x+(y-x)*eased}
                guard mix(a.opacity,b.opacity)>0.05 else{continue}
                let w=mix(a.width,b.width),h=mix(a.height,b.height)
                let transform=CGAffineTransform(translationX:mix(a.x,b.x),y:mix(a.y,b.y)).rotated(by:mix(a.rotation,b.rotation)).translatedBy(x:-w/2,y:-h/2)
                let shape:CGPath
                if a.shape == .capsule {shape=CGPath(roundedRect:CGRect(x:0,y:0,width:w,height:h),cornerWidth:mix(a.radius,b.radius),cornerHeight:mix(a.radius,b.radius),transform:nil)}
                else {
                    var pose=a;pose.width=w;pose.height=h
                    shape=shapePath(pose).copy(strokingWithWidth:a.lineWidth,lineCap:.round,lineJoin:.round,miterLimit:2)
                }
                path.addPath(shape,transform:transform)
            }
            c.addPath(path);c.clip()
            let stops=profile.gradients.ambient.stops
            if let gradient=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:stops.map{BrowserTheme.color($0.color).cgColor} as CFArray,locations:stops.map{CGFloat($0.location)}) {c.drawLinearGradient(gradient,start:CGPoint(x:0,y:0),end:CGPoint(x:28,y:18),options:[.drawsBeforeStartLocation,.drawsAfterEndLocation])}
            return true
        }
    }
    private static func shapePath(_ pose: IndicatorPose) -> CGPath {
        let w=pose.width, h=pose.height, inset=pose.lineWidth/2, path=CGMutablePath()
        switch pose.shape {
        case .ellipse: path.addEllipse(in:CGRect(x:inset,y:inset,width:max(0.1,w-pose.lineWidth),height:max(0.1,h-pose.lineWidth)))
        case .question:
            path.move(to:CGPoint(x:w*0.1,y:h*0.72)); path.addCurve(to:CGPoint(x:w*0.52,y:h*0.96),control1:CGPoint(x:w*0.16,y:h),control2:CGPoint(x:w*0.46,y:h))
            path.addCurve(to:CGPoint(x:w*0.88,y:h*0.66),control1:CGPoint(x:w*0.78,y:h*0.94),control2:CGPoint(x:w*0.9,y:h*0.82))
            path.addCurve(to:CGPoint(x:w*0.5,y:h*0.38),control1:CGPoint(x:w*0.86,y:h*0.5),control2:CGPoint(x:w*0.53,y:h*0.54)); path.addLine(to:CGPoint(x:w*0.5,y:h*0.22))
        case .hourglassLeft:
            path.move(to:CGPoint(x:0,y:h)); path.addCurve(to:CGPoint(x:w,y:h/2),control1:CGPoint(x:w*0.08,y:h*0.78),control2:CGPoint(x:w*0.92,y:h*0.62)); path.addCurve(to:CGPoint(x:0,y:0),control1:CGPoint(x:w*0.92,y:h*0.38),control2:CGPoint(x:w*0.08,y:h*0.22))
        case .hourglassRight:
            path.move(to:CGPoint(x:w,y:h)); path.addCurve(to:CGPoint(x:0,y:h/2),control1:CGPoint(x:w*0.92,y:h*0.78),control2:CGPoint(x:w*0.08,y:h*0.62)); path.addCurve(to:CGPoint(x:w,y:0),control1:CGPoint(x:w*0.08,y:h*0.38),control2:CGPoint(x:w*0.92,y:h*0.22))
        case .capsule: break
        }
        return path
    }


}
