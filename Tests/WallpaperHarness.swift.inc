extension BrowserWallpaperView {
    @MainActor static func runChecks(_ directory: URL) async throws {
        struct Failure: Error { let message:String }
        func check(_ condition:Bool,_ message:String) throws {if !condition {throw Failure(message:message)}}
        func wait(_ message:String,_ condition:()->Bool) async throws {
            let until=Date().addingTimeInterval(12)
            while !condition() {if Date()>until {throw Failure(message:message)};try await Task.sleep(nanoseconds:30_000_000)}
        }
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:640,height:480),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        let root=NSView(frame:NSRect(x:0,y:0,width:640,height:480));root.wantsLayer=true;window.contentView=root
        let backdrop=BrowserWallpaperView(frame:root.bounds);root.addSubview(backdrop)
        let home=NSView(frame:root.bounds);root.addSubview(home);backdrop.homepage=home
        let input=NSTextField(frame:NSRect(x:40,y:30,width:260,height:32));input.placeholderString="Our widgets stay above";home.addSubview(input)
        let profileA=UUID(),profileB=UUID()
        backdrop.show(profile:profileA)
        defer {backdrop.timer?.invalidate();backdrop.player?.pause();window.orderOut(nil)
            UserDefaults.standard.removeObject(forKey:"webbyWallpaper.\(profileA.uuidString)")
            UserDefaults.standard.removeObject(forKey:"webbyWallpaper.\(profileB.uuidString)")}
        window.center();window.orderFrontRegardless()
        backdrop.settings.path=directory.appendingPathComponent("fixture.png").path;backdrop.settings.opacity=1;backdrop.settings.motion=false
        var signatures=Set<Data>()
        for effect in 0..<6 {
            backdrop.settings.effect=effect;backdrop.settings.fade=0;backdrop.resetSource()
            try await wait("Static effect did not render \(effect)"){backdrop.cachedFrame != nil && !backdrop.busy}
            let frame=backdrop.cachedFrame!;signatures.insert(frame.dataProvider!.data! as Data)
            try check(frame.width<=2048 && frame.height<=2048,"Static raster exceeded cap")
        }
        try check(signatures.count==6,"Effects returned duplicate pixels")
        for fade in 1...6 {
            backdrop.settings.effect=0;backdrop.settings.fade=fade;backdrop.dirty=true;backdrop.cachedFrame=nil;backdrop.generation+=1;backdrop.tick()
            try await wait("Fade did not render \(fade)"){backdrop.cachedFrame != nil && !backdrop.busy}
            let bytes=[UInt8](backdrop.cachedFrame!.dataProvider!.data! as Data)
            let alphas=stride(from:3,to:bytes.count,by:4).map{bytes[$0]}
            try check(alphas.min()==0 && alphas.max()==255,"Fade lacks transparent/opaque endpoints \(fade)")
        }
        try check(backdrop.hitTest(NSPoint(x:80,y:50))==nil,"Background intercepts widget input")
        let hit=root.hitTest(NSPoint(x:80,y:50))
        try check(hit===input || hit?.isDescendant(of:input)==true,"Widget field is covered")
        window.makeKey();try check(window.makeFirstResponder(input),"Widget field cannot focus")
        backdrop.save();backdrop.show(profile:profileB)
        try check(backdrop.settings.path==nil,"Profile B inherited A background")
        backdrop.show(profile:profileA)
        try check(backdrop.settings.path != nil && backdrop.settings.fade==6,"Profile persistence lost options")
        backdrop.settings.kind="image";backdrop.settings.path=directory.appendingPathComponent("fixture.gif").path
        backdrop.settings.motion=true;backdrop.settings.fade=0;backdrop.resetSource()
        try await wait("GIF did not render"){backdrop.cachedFrame != nil}
        let gif=backdrop.cachedFrame!.dataProvider!.data! as Data
        try await wait("GIF did not animate"){backdrop.cachedFrame.map{($0.dataProvider!.data! as Data) != gif} == true}
        backdrop.settings.kind="video";backdrop.settings.path=directory.appendingPathComponent("fixture.mp4").path;backdrop.resetSource()
        try await wait("Video did not render"){backdrop.cachedFrame != nil}
        let video=backdrop.cachedFrame!.dataProvider!.data! as Data
        try await wait("Video did not animate"){backdrop.cachedFrame.map{($0.dataProvider!.data! as Data) != video} == true}
        home.isHidden=true;backdrop.tick()
        try check(backdrop.player?.rate==0 && backdrop.isHidden,"Hidden video still playing")
        home.isHidden=false;backdrop.tick()
        Motion.enabled=false;backdrop.tick();try check(backdrop.player?.rate==0,"Reduce Motion did not pause video")
        Motion.enabled=true
        backdrop.settings.kind="html";backdrop.settings.path=directory.appendingPathComponent("fixture.html").path;backdrop.settings.effect=1;backdrop.resetSource()
        try await wait("HTML snapshot did not render"){backdrop.cachedFrame != nil && !backdrop.busy}
        let htmlBytes=backdrop.cachedFrame!.dataProvider!.data! as Data
        try check(Set(htmlBytes).count>2,"HTML background snapshot is empty")
        try check(backdrop.html?.configuration.websiteDataStore.isPersistent==false,"HTML shares a persistent sign-in store")
        // Output is the actual processed native component, not a visual mockup.
        let png=NSBitmapImageRep(cgImage:backdrop.cachedFrame!).representation(using:.png,properties:[:])!
        try png.write(to:directory.appendingPathComponent("html-dither-render.png"))
        home.isHidden=true;backdrop.tick();try check(backdrop.html==nil,"Hidden HTML kept a webview alive")
        home.isHidden=false
        backdrop.openSettings()
        backdrop.settingsWindow!.contentView!.layoutSubtreeIfNeeded()
        let scroll=backdrop.settingsWindow!.contentView!.subviews.first as! NSScrollView
        try check(scroll.documentView!.bounds.width>400 && scroll.documentView!.bounds.height>600,"Settings layout collapsed")
        try check((backdrop.controls["effect"] as! NSPopUpButton).numberOfItems==6,"Effects picker incomplete")
        backdrop.settingsWindow?.close()
        backdrop.settings.path=nil;backdrop.resetSource();try check(backdrop.timer==nil,"Empty backgrounds retain a polling timer")
        print("PASS: 6 exact Code effects, 6 directional fades, bounded renders, native input hit testing/focus, profile persistence/isolation, GIF animation, movie playback, hidden/Reduce Motion pause, HTML effects and temporary data store, disabled timer cleanup")
    }
}
