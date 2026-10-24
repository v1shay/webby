import AppKit
import WebKit
import AVFoundation
import ImageIO
import CoreImage
import UniformTypeIdentifiers

@_silgen_name("webby_code_background")
private func codeBackground(_ bytes: UnsafeMutablePointer<UInt8>, _ width: UInt32, _ height: UInt32,
    _ effect: UInt32, _ fade: UInt32, _ start: Float, _ end: Float, _ soften: Bool, _ empty: Bool) -> Bool

private struct WallpaperSettings: Codable {
    var path: String? = nil
    var kind = "image"
    var effect = 0
    var fade = 1
    var start = 0.0
    var end = 0.92
    var blur = 0.0
    var opacity = 0.4
    var pageOpacity = 0.28
    var homeOnly = true
    var soften = true
    var fit = 0
    var motion = true
    mutating func normalize() {
        effect=max(0,min(5,effect));fade=max(0,min(6,fade));fit=max(0,min(2,fit))
        start=start.isFinite ? max(0,min(0.9,start)):0
        end=end.isFinite ? max(start+0.01,min(1,end)):0.92
        blur=blur.isFinite ? max(0,min(40,blur)):0
        opacity=opacity.isFinite ? max(0,min(1,opacity)):0.4
        pageOpacity=pageOpacity.isFinite ? max(0,min(1,pageOpacity)):0.28
    }
}

private final class WallpaperSurface: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }
}
private final class WallpaperVideoFrame: @unchecked Sendable {
    let pixel: CVPixelBuffer
    init(_ pixel: CVPixelBuffer) { self.pixel=pixel }
}
private final class WallpaperDocument: NSView { override var isFlipped: Bool { true } }

// Decode, crop, pixel effects, blur and fades share one bounded background queue.
// The original Code pixel routines are linked from Vendor/CodeBackground.
@MainActor final class BrowserWallpaperView: NSView {
    weak var homepage: NSView?
    var presentationChanged:(()->Void)?
    var fillsWindow:Bool {UserDefaults.standard.bool(forKey:"webbyWallpaperFullWindow.\(profile.uuidString)")}
    var tabBlurScope:Int {UserDefaults.standard.object(forKey:"webbyWallpaperTabBlurScope.\(profile.uuidString)")==nil ? 1:UserDefaults.standard.integer(forKey:"webbyWallpaperTabBlurScope.\(profile.uuidString)")}
    var tabBlurStrength:Double {UserDefaults.standard.object(forKey:"webbyWallpaperTabBlurStrength.\(profile.uuidString)") as? Double ?? 0.85}
    private var profile = UUID()
    private var settings = WallpaperSettings()
    private let surface = WallpaperSurface()
    private let worker = DispatchQueue(label: "local.webby.wallpaper", qos: .utility)
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private var generation = 0
    private var busy = false
    private var dirty = true
    private var lastSize = NSSize.zero
    private var timer: Timer?
    private var tickInterval = 0.0
    private var settingsWindow: NSWindow?
    private var controls = [String: NSControl]()
    private var source: CGImageSource?
    private var sourcePath: String?
    private var gifIndex = 0
    private var nextFrame = 0.0
    private var player: AVPlayer?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var videoEnd: NSObjectProtocol?
    private var html: WKWebView?
    private var lastVisible = false
    private var errorText: NSTextField?
    private var statusText: NSTextField?
    private var cachedFrame: CGImage?
    private var decodedStatic: CGImage?
    private var cachedDelay = 0.1
    private var lastWasHome = true
    private var pendingSettingsSave: DispatchWorkItem?
    private var importToken = UUID()
    private var key: String { "webbyWallpaper.\(profile.uuidString)" }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        surface.wantsLayer = true
        surface.layer?.contentsGravity = .resize
        addSubview(surface)
    }
    private func updateTicker(_ interval: Double) {
        guard tickInterval != interval else { return }
        timer?.invalidate();timer=nil;tickInterval=interval
        guard interval > 0 else { return }
        timer=Timer.scheduledTimer(withTimeInterval:interval,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance=interval * 0.2
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { timer?.invalidate(); if let videoEnd { NotificationCenter.default.removeObserver(videoEnd) } }

    func show(profile: UUID) {
        guard self.profile != profile else { return }
        if pendingSettingsSave != nil { save() }
        pendingSettingsSave?.cancel(); pendingSettingsSave = nil
        self.profile = profile;importToken=UUID()
        settings = UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(WallpaperSettings.self, from: $0) } ?? WallpaperSettings()
        settings.normalize()
        settingsWindow?.close(); settingsWindow = nil; controls.removeAll()
        resetSource()
        presentationChanged?()
    }
    override func layout() {
        super.layout()
        surface.frame = bounds; html?.frame = bounds
        if lastSize != bounds.size { lastSize = bounds.size; dirty = true; generation += 1 }
    }
    private func resetSource() {
        generation += 1; dirty = true; gifIndex = 0; nextFrame = 0; cachedFrame = nil; decodedStatic = nil
        source = nil; sourcePath = nil
        player?.pause(); player = nil; videoOutput = nil
        if let videoEnd { NotificationCenter.default.removeObserver(videoEnd) }; videoEnd = nil
        html?.stopLoading(); html?.removeFromSuperview(); html = nil
        surface.layer?.contents = nil
        errorText?.stringValue = ""
        tick()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: key) }
    }
    private func tick() {
        let home = homepage?.isHidden == false
        let visibility = home ? settings.opacity : settings.pageOpacity
        let visible = settings.path != nil && visibility > 0.001 && (!settings.homeOnly || home || fillsWindow) && window?.occlusionState.contains(.visible) == true
        let animated = settings.kind != "image" || cachedDelay > 0
        updateTicker(settings.path == nil ? 0 : (visible && animated && settings.motion && Motion.enabled ? 0.05 : 0.25))
        isHidden = !visible
        alphaValue = visibility
        if visible != lastVisible {
            lastVisible = visible
            if !visible {
                player?.pause(); html?.stopLoading(); html?.removeFromSuperview(); html = nil
            } else { dirty = true; nextFrame = 0 }
        }
        if home != lastWasHome { lastWasHome = home; dirty = true; generation += 1 }
        guard visible, let path = settings.path, bounds.width > 1, bounds.height > 1 else { return }
        if settings.kind == "html" {
            showHTML(path)
            guard !busy, let html, !html.isLoading,
                  dirty || (settings.motion && Motion.enabled && CACurrentMediaTime() >= nextFrame) else { return }
            busy = true
            let token = generation
            let configuration = WKSnapshotConfiguration(); configuration.snapshotWidth = NSNumber(value: min(640,bounds.width))
            html.takeSnapshot(with: configuration) { [weak self] image, error in
                guard let self else { return }
                self.busy = false
                guard self.generation == token, self.lastVisible else { return }
                guard let snapshot = image?.cgImage(forProposedRect:nil,context:nil,hints:nil) else {
                    self.nextFrame = CACurrentMediaTime() + 1
                    self.errorText?.stringValue = "We couldn’t render this HTML background."
                    return
                }
                self.render(path:path,pixel:nil,home:home,snapshot:snapshot)
            }
            return
        }
        if settings.kind == "video" {
            if player == nil { makeVideo(path) }
            let moving = settings.motion && Motion.enabled
            if moving && player?.rate == 0 { player?.play() }
            if !moving { player?.pause() }
            guard !busy, let output = videoOutput, let player else { return }
            let time = player.currentTime()
            guard dirty || (moving && output.hasNewPixelBuffer(forItemTime: time)),
                  let pixel = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
            render(path: path, pixel: pixel, home: home)
        } else if !busy && (dirty || (settings.motion && Motion.enabled && CACurrentMediaTime() >= nextFrame && cachedDelay > 0)) {
            render(path: path, pixel: nil, home: home)
        }
    }
    private func makeVideo(_ path: String) {
        let item = AVPlayerItem(url: URL(fileURLWithPath: path))
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output); videoOutput = output
        let player = AVPlayer(playerItem: item); player.isMuted = true; player.actionAtItemEnd = .none
        self.player = player
        videoEnd = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak player] _ in
            player?.seek(to: .zero)
        }
        if settings.motion && Motion.enabled { player.play() }
        else { player.seek(to: .zero) }
    }
    private func showHTML(_ path: String) {
        guard html == nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        let view = WKWebView(frame: bounds, configuration: configuration)
        view.setValue(false, forKey: "drawsBackground")
        // The host never accepts mouse/key events, keeping widgets above interactive.
        addSubview(view, positioned: .below, relativeTo: surface)
        html = view; surface.layer?.contents = nil
        let url = URL(fileURLWithPath: path)
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        view.alphaValue = 0.001
        // Only the processed snapshot is visible. All six Code effects apply to HTML too.
    }
    private func render(path: String, pixel: CVPixelBuffer?, home: Bool, snapshot: CGImage? = nil) {
        busy = true; dirty = false
        let token = generation, options = settings, size = bounds.size
        let index = gifIndex
        let cached = sourcePath == path ? source : nil
        let decoded = sourcePath == path ? decodedStatic : nil
        let context = ci
        let videoFrame = pixel.map(WallpaperVideoFrame.init)
        let hasVideo = videoFrame != nil
        worker.async { [weak self] in
            var src = cached
            var image: CGImage?
            var delay = 0.0
            var frames = 1
            if let snapshot { image = snapshot; delay = 0.1 }
            else if let frame=videoFrame { let input=CIImage(cvPixelBuffer:frame.pixel);image=context.createCGImage(input,from:input.extent) }
            else {
                if src == nil { src = CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL, nil) }
                if let src {
                    frames = CGImageSourceGetCount(src)
                    let frame = index % max(1,frames)
                    image = decoded ?? CGImageSourceCreateThumbnailAtIndex(src, frame, [kCGImageSourceCreateThumbnailFromImageAlways:true,
                        kCGImageSourceThumbnailMaxPixelSize:2048,kCGImageSourceCreateThumbnailWithTransform:true,
                        kCGImageSourceShouldCacheImmediately:true] as CFDictionary)
                    if frames > 1 {
                        let properties = CGImageSourceCopyPropertiesAtIndex(src,frame,nil) as? [String:Any]
                        let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String:Any]
                        delay = max(0.05,(gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double) ?? (gif?[kCGImagePropertyGIFDelayTime as String] as? Double) ?? 0.1)
                    }
                }
            }
            let animated = hasVideo || snapshot != nil || frames > 1
            let limit: CGFloat = animated ? 640 : 2048
            let scale = min(1,limit/max(size.width,size.height))
            let width = max(1,Int(size.width*scale)), height = max(1,Int(size.height*scale))
            var bytes = [UInt8](repeating:0,count:width*height*4)
            var result: CGImage?
            if let image {
                bytes.withUnsafeMutableBytes { raw in
                    guard let context = CGContext(data:raw.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,
                        space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
                    context.interpolationQuality = .high
                    let sx=CGFloat(width)/CGFloat(image.width),sy=CGFloat(height)/CGFloat(image.height)
                    let factor = options.fit == 1 ? min(sx,sy) : max(sx,sy)
                    let rect = options.fit == 2 ? CGRect(x:0,y:0,width:width,height:height) : CGRect(x:(CGFloat(width)-CGFloat(image.width)*factor)/2,y:(CGFloat(height)-CGFloat(image.height)*factor)/2,width:CGFloat(image.width)*factor,height:CGFloat(image.height)*factor)
                    context.draw(image,in:rect)
                }
                // Core Graphics is premultiplied; Code operates on straight RGBA.
                for i in stride(from:0,to:bytes.count,by:4) {
                    let alpha=Int(bytes[i+3]); if alpha > 0 && alpha < 255 {
                        for c in 0..<3 {bytes[i+c]=UInt8(min(255,Int(bytes[i+c])*255/alpha))}
                    }
                }
                _ = bytes.withUnsafeMutableBufferPointer { codeBackground($0.baseAddress!,UInt32(width),UInt32(height),UInt32(options.effect),UInt32(options.fade),Float(options.start),Float(options.end),options.soften,home) }
                for i in stride(from:0,to:bytes.count,by:4) {let a=Int(bytes[i+3]);for c in 0..<3 {bytes[i+c]=UInt8(Int(bytes[i+c])*a/255)}}
                if let provider=CGDataProvider(data:Data(bytes) as CFData) {
                    result=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent)
                    if options.blur > 0, let original=result {
                        let input=CIImage(cgImage:original)
                        let blurred=input.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:options.blur*Double(scale)])
                        result=context.createCGImage(blurred,from:input.extent)
                    }
                }
            }
            let output=result, source=src, frameCount=frames, frameDelay=delay
            let decodedImage = frames == 1 && !hasVideo && snapshot == nil ? image : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy=false
                guard self.generation == token else { self.dirty=true; return }
                self.source=source;self.sourcePath=path;self.cachedDelay=frameDelay;self.decodedStatic=decodedImage
                self.gifIndex=(index+1)%max(1,frameCount);self.nextFrame=CACurrentMediaTime()+frameDelay
                if let output {
                    CATransaction.begin();CATransaction.setDisableActions(true)
                    self.surface.layer?.contents=output;CATransaction.commit();self.cachedFrame=output
                    self.errorText?.stringValue=""
                } else { self.errorText?.stringValue="We couldn’t decode this file. Let’s choose another image or movie." }
            }
        }
    }

    func openSettings() {
        if let settingsWindow {settingsWindow.makeKeyAndOrderFront(nil);return}
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:510,height:740),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title="Background · Let’s make it yours";window.isReleasedWhenClosed=false
        let glass=NSVisualEffectView();glass.material = .hudWindow;glass.blendingMode = .behindWindow;glass.state = .active
        window.contentView=glass
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=false;scroll.translatesAutoresizingMaskIntoConstraints=false
        let document=WallpaperDocument();document.translatesAutoresizingMaskIntoConstraints=false;scroll.documentView=document;glass.addSubview(scroll)
        let stack=NSStackView();stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=false
        document.addSubview(stack)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo:glass.leadingAnchor),scroll.trailingAnchor.constraint(equalTo:glass.trailingAnchor),scroll.topAnchor.constraint(equalTo:glass.topAnchor),scroll.bottomAnchor.constraint(equalTo:glass.bottomAnchor),
            document.widthAnchor.constraint(equalTo:scroll.contentView.widthAnchor),stack.leadingAnchor.constraint(equalTo:document.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:document.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:document.topAnchor,constant:24),stack.bottomAnchor.constraint(equalTo:document.bottomAnchor,constant:-24)])
        let heading=NSTextField(labelWithString:"Your canvas, in motion.");heading.font = .systemFont(ofSize:24,weight:.semibold);stack.addArrangedSubview(heading)
        let subtitle=NSTextField(wrappingLabelWithString:"Code’s original effects, behind our widgets and search.");subtitle.textColor = .secondaryLabelColor;stack.addArrangedSubview(subtitle)
        let choose=NSButton(title:"Choose image, GIF, movie or HTML…",target:self,action:#selector(chooseSource));choose.bezelStyle = .rounded;stack.addArrangedSubview(choose)
        let status=NSTextField(labelWithString:settings.path.map{URL(fileURLWithPath:$0).lastPathComponent} ?? "No background selected");status.lineBreakMode = .byTruncatingMiddle;stack.addArrangedSubview(status);statusText=status
        popup("effect","Effect",["Original","Dither","ASCII","Halftone","Scanlines","Haze"],settings.effect,stack)
        popup("fade","Fade",["None","Fade down · Code","Fade up","Fade left","Fade right","Fade edges","Fade center"],settings.fade,stack)
        popup("fit","Fit",["Fill / cover","Fit / contain","Stretch"],settings.fit,stack)
        check("fullWindow","Extend wallpaper across the entire window",fillsWindow,stack)
        popup("tabBlurScope","Tab glass",["Behind individual tabs","Behind the entire tab pane"],min(1,max(0,tabBlurScope)),stack)
        slider("tabBlurStrength","Tab frost strength",tabBlurStrength,0,1,stack)
        slider("start","Fade starts",settings.start,0,0.9,stack)
        slider("end","Fade ends",settings.end,0.1,1,stack)
        slider("blur","Blur",settings.blur,0,40,stack)
        slider("opacity","New tab visibility",settings.opacity,0,1,stack)
        slider("pageOpacity","Webpage visibility",settings.pageOpacity,0,1,stack)
        check("soften","Soften detail through the fade",settings.soften,stack)
        check("homeOnly","Show only on the new tab canvas",settings.homeOnly,stack)
        check("motion","Animate GIFs and movies · muted",settings.motion,stack)
        let clear=NSButton(title:"Remove background",target:self,action:#selector(clearSource));clear.bezelStyle = .rounded;stack.addArrangedSubview(clear)
        let error=NSTextField(wrappingLabelWithString:"");error.textColor = .systemOrange;stack.addArrangedSubview(error);errorText=error
        let note=NSTextField(wrappingLabelWithString:"All effects work on images, GIFs, movies and local HTML. We pause hidden artwork; motion respects Reduce Motion. HTML runs in a separate, temporary browser store.");note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor;stack.addArrangedSubview(note)
        settingsWindow=window;window.center();window.makeKeyAndOrderFront(nil)
    }
    private func row(_ title:String,_ control:NSControl,_ key:String,_ stack:NSStackView) {
        let label=NSTextField(labelWithString:title);label.font = .systemFont(ofSize:12,weight:.medium);label.widthAnchor.constraint(equalToConstant:140).isActive=true
        let row=NSStackView(views:[label,control]);row.spacing=12;row.distribution = .fill;row.translatesAutoresizingMaskIntoConstraints=false
        stack.addArrangedSubview(row);row.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive=true
        control.identifier=NSUserInterfaceItemIdentifier(key);control.target=self;control.action=#selector(changed(_:));controls[key]=control
    }
    private func popup(_ key:String,_ title:String,_ items:[String],_ selected:Int,_ stack:NSStackView) {
        let popup=NSPopUpButton();popup.addItems(withTitles:items);popup.selectItem(at:max(0,min(items.count-1,selected)));row(title,popup,key,stack)
    }
    private func slider(_ key:String,_ title:String,_ value:Double,_ min:Double,_ max:Double,_ stack:NSStackView) {row(title,NSSlider(value:value,minValue:min,maxValue:max,target:nil,action:nil),key,stack)}
    private func check(_ key:String,_ title:String,_ value:Bool,_ stack:NSStackView) {
        let button=NSButton(checkboxWithTitle:title,target:self,action:#selector(changed(_:)));button.state=value ? .on : .off;button.identifier=NSUserInterfaceItemIdentifier(key);controls[key]=button;stack.addArrangedSubview(button)
    }
    @objc private func changed(_ sender:NSControl) {
        guard let key=sender.identifier?.rawValue else{return}
        switch key {
        case "fullWindow":UserDefaults.standard.set((sender as! NSButton).state == .on,forKey:"webbyWallpaperFullWindow.\(profile.uuidString)");presentationChanged?();tick();return
        case "tabBlurScope":UserDefaults.standard.set((sender as! NSPopUpButton).indexOfSelectedItem,forKey:"webbyWallpaperTabBlurScope.\(profile.uuidString)");presentationChanged?();return
        case "tabBlurStrength":UserDefaults.standard.set(sender.doubleValue,forKey:"webbyWallpaperTabBlurStrength.\(profile.uuidString)");presentationChanged?();return
        case "effect":settings.effect=(sender as! NSPopUpButton).indexOfSelectedItem
        case "fade":settings.fade=(sender as! NSPopUpButton).indexOfSelectedItem
        case "fit":settings.fit=(sender as! NSPopUpButton).indexOfSelectedItem
        case "start":settings.start=min(sender.doubleValue,settings.end-0.01)
        case "end":settings.end=max(sender.doubleValue,settings.start+0.01)
        case "blur":settings.blur=sender.doubleValue
        case "opacity":settings.opacity=sender.doubleValue
        case "pageOpacity":settings.pageOpacity=sender.doubleValue
        case "soften":settings.soften=(sender as! NSButton).state == .on
        case "homeOnly":settings.homeOnly=(sender as! NSButton).state == .on
        case "motion":settings.motion=(sender as! NSButton).state == .on
        default:return
        }
        generation+=1;dirty=true;nextFrame=0
        if key=="motion" {player?.pause()}
        pendingSettingsSave?.cancel()
        let work=DispatchWorkItem{[weak self] in self?.save()};pendingSettingsSave=work
        DispatchQueue.main.asyncAfter(deadline:.now()+0.15,execute:work)
        tick()
    }
    @objc private func chooseSource() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.image,.movie,.html];panel.canChooseDirectories=false;panel.allowsMultipleSelection=false
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let type=(try? url.resourceValues(forKeys:[.contentTypeKey]).contentType)
            let kind=type?.conforms(to:.html) == true ? "html" : (type?.conforms(to:.movie) == true ? "video":"image")
            if kind == "image", ((try url.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) > 32 * 1024 * 1024 {
                errorText?.stringValue="Let’s use an image under 32 MB.";return
            }
            importToken=UUID()
            if kind == "html" {
                if let old=settings.path {
                    let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("WebbyBackgrounds/\(profile.uuidString)")
                    if URL(fileURLWithPath:old).deletingLastPathComponent().standardizedFileURL==directory.standardizedFileURL {worker.async {try? FileManager.default.removeItem(atPath:old)}}
                }
                settings.path=url.path;settings.kind=kind;save();statusText?.stringValue=url.lastPathComponent;resetSource()
                return
            }
            let requestedProfile=profile, token=importToken
            let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("WebbyBackgrounds/\(profile.uuidString)",isDirectory:true)
            let destination=directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            statusText?.stringValue="We’re importing \(url.lastPathComponent)…"
            worker.async { [weak self] in
                do {
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    try FileManager.default.copyItem(at:url,to:destination)
                    DispatchQueue.main.async { [weak self] in
                        guard let self,self.profile==requestedProfile,self.importToken==token else {try? FileManager.default.removeItem(at:destination);return}
                        let old=self.settings.path
                        self.settings.path=destination.path;self.settings.kind=kind;self.save()
                        self.statusText?.stringValue=url.lastPathComponent;self.resetSource()
                        if let old,URL(fileURLWithPath:old).deletingLastPathComponent().standardizedFileURL==directory.standardizedFileURL {try? FileManager.default.removeItem(atPath:old)}
                    }
                } catch {
                    try? FileManager.default.removeItem(at:destination)
                    let message=error.localizedDescription
                    DispatchQueue.main.async { [weak self] in
                        guard let self,self.profile==requestedProfile,self.importToken==token else {return}
                        self.errorText?.stringValue="We couldn’t import that file: \(message)"
                    }
                }
            }
        } catch {errorText?.stringValue="We couldn’t import that file: \(error.localizedDescription)"}
    }
    @objc private func clearSource() {
        importToken=UUID()
        if let path=settings.path {
            let directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("WebbyBackgrounds/\(profile.uuidString)")
            if URL(fileURLWithPath:path).deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL {try? FileManager.default.removeItem(atPath:path)}
        }
        settings.path=nil;save();statusText?.stringValue="No background selected";resetSource()
    }
}
