@MainActor enum IDEProjectWidgetChecks {
    static func pure() throws {
        struct Failure:Error {let message:String}
        let cases:[(NSSize,IDEProjectWidgetView.Layout)]=[(NSSize(width:48,height:48),.icon),(NSSize(width:360,height:60),.strip),(NSSize(width:372,height:184),.columns),(NSSize(width:192,height:334),.stacked),(NSSize(width:36,height:400),.stacked)]
        for (size,expected) in cases {guard IDEProjectWidgetView.layoutMode(size:size)==expected else {throw Failure(message:"Responsive breakpoint mismatch")}}
        let one=URL(fileURLWithPath:"/tmp/Projects/../Studio α + β"),two=URL(fileURLWithPath:"/tmp/Studio α + β")
        guard IDERecentProjects.normalized([one,two,URL(string:"https://example.com")!]) == [two], IDERecentProjects.normalized((0..<80).map {URL(fileURLWithPath:"/tmp/project-\($0)")}).count==40 else {throw Failure(message:"Path normalization, deduplication, or limits failed")}
        print("PASS: IDE responsive modes, Unicode/path normalization, deduplication, local-only paths, recent limit")
    }
    static func run(output:URL) throws {
        struct Failure:Error {let message:String}
        let key="webbyIDERecentProjects.v1", old=UserDefaults.standard.object(forKey:"webbyIDERecentProjects.v1")
        defer {if let old {UserDefaults.standard.set(old,forKey:key)}else{UserDefaults.standard.removeObject(forKey:key)}}
        let fixtures=[URL(fileURLWithPath:"/Users/demo/Projects/Webby"),URL(fileURLWithPath:"/Users/demo/School/Java Studio"),URL(fileURLWithPath:"/Users/demo/Research/Webby"),URL(fileURLWithPath:"/Users/demo/Experiments/Shader Lab")]
        UserDefaults.standard.set([],forKey:key)
        for url in fixtures.reversed(){IDERecentProjects.record(url)}
        IDERecentProjects.record(fixtures[0])
        guard IDERecentProjects.urls==fixtures else {throw Failure(message:"Recent order or deduplication failed")}
        let widget=IDEProjectWidgetView(frame:.zero)
        var opened:URL?;widget.openProject={opened=$0}
        for (w,h) in [(48,48),(92,80),(360,60),(372,184),(192,334),(36,400),(900,600),(140,140)] {
            widget.frame=NSRect(x:0,y:0,width:w,height:h);widget.needsLayout=true;widget.layoutSubtreeIfNeeded()
            for child in widget.subviews where !child.isHidden {
                guard child.frame.minX >= -0.5,child.frame.minY >= -0.5,child.frame.maxX <= CGFloat(w)+0.5,child.frame.maxY <= CGFloat(h)+0.5 else {throw Failure(message:"Control overflow at \(w)x\(h): \(child.frame)")}
            }
            for row in widget.subviews.compactMap({$0 as? IDEProjectButton}) where !row.isHidden {
                opened=nil;row.performClick(nil)
                guard opened==row.project,widget.containsControl(NSPoint(x:row.frame.midX,y:row.frame.midY)) else {throw Failure(message:"Project row not clickable")}
            }
        }
        IDERecentProjects.forget(fixtures[0]);guard !IDERecentProjects.urls.contains(fixtures[0]) else {throw Failure(message:"Forget failed")}
        IDERecentProjects.record(fixtures[0])
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:620),styleMask:[.titled],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false
        let root=NSView(frame:NSRect(x:0,y:0,width:1000,height:620));root.wantsLayer=true;root.layer?.backgroundColor=NSColor(calibratedRed:0.09,green:0.14,blue:0.18,alpha:1).cgColor
        window.contentView=root;window.orderBack(nil)
        for (frame,name) in [(NSRect(x:24,y:330,width:440,height:246),"Wide"),(NSRect(x:500,y:140,width:230,height:436),"Stacked"),(NSRect(x:24,y:180,width:440,height:100),"Short"),(NSRect(x:784,y:472,width:94,height:94),"Tiny"),(NSRect(x:784,y:180,width:76,height:250),"Skinny")] {
            let card=GlassWidgetCard(kind:.ide,frame:frame);root.addSubview(card);card.needsLayout=true;card.layoutSubtreeIfNeeded()
            let label=NSTextField(labelWithString:name);label.font = .systemFont(ofSize:11,weight:.medium);label.textColor = .secondaryLabelColor;label.frame=NSRect(x:frame.minX,y:frame.maxY+8,width:frame.width,height:16);root.addSubview(label)
        }
        if let bitmap=root.bitmapImageRepForCachingDisplay(in:root.bounds) {root.cacheDisplay(in:root.bounds,to:bitmap);try bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent("ide-widget-layouts.png"))}
        let mark=IDEIdentity.image(size:256)
        if let data=mark.tiffRepresentation,let bitmap=NSBitmapImageRep(data:data) {try bitmap.representation(using:.png,properties:[:])?.write(to:output.appendingPathComponent("ide-logo.png"))}
        window.orderOut(nil)
        print("PASS: IDE recent order/deduplication, remove, all responsive bounds, project clicks, native previews")
    }
}
