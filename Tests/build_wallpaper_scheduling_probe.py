from pathlib import Path
import sys
source=Path(sys.argv[1]).read_text().replace('    private var timer: Timer?','    private var timer: Timer?\n    private var probeTicks=0',1).replace('    private func tick() {','    private func tick() {\n        probeTicks += 1',1)
source+='''
// Only the unused settings typography/transitions are stubbed in this standalone
// scheduling probe. The actual renderer, timers, decoders and event hooks run.
enum WebbyTypography {static func font(ofSize size:CGFloat,weight:NSFont.Weight = .regular)->NSFont {NSFont.systemFont(ofSize:size,weight:weight)}}
enum Motion {enum Character {case art};static var enabled:Bool {true};static func change(_ view:NSView?,character:Character){}}
extension BrowserWallpaperView {
    func probe(directory:URL) async throws -> [String:Any] {
        var result:[String:Any]=[:]
        let host=NSWindow(contentRect:NSRect(x:100,y:100,width:520,height:360),styleMask:[.titled],backing:.buffered,defer:false)
        host.isReleasedWhenClosed=false
        let root=NSView(frame:host.contentView!.bounds);host.contentView=root
        frame=root.bounds;root.addSubview(self)
        let home=NSView();root.addSubview(home);homepage=home
        host.makeKeyAndOrderFront(nil)
        func image(_ color:NSColor)->CGImage {
            let c=CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:256,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.setFillColor(color.cgColor);c.fill(CGRect(x:0,y:0,width:64,height:64));return c.makeImage()!
        }
        let png=directory.appendingPathComponent("still.png")
        let out=CGImageDestinationCreateWithURL(png as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(out,image(.red),nil);precondition(CGImageDestinationFinalize(out))
        settings.path=png.path;settings.kind="image";settings.fade=0;settings.opacity=1;resetSource()
        try await Task.sleep(nanoseconds:700_000_000)
        precondition(cachedFrame != nil,"Still frame not rendered")
        var start=probeTicks
        try await Task.sleep(nanoseconds:2_000_000_000)
        result["visibleStillTicksIn2Seconds"]=probeTicks-start
        let gif=directory.appendingPathComponent("motion.gif")
        let g=CGImageDestinationCreateWithURL(gif as CFURL,"com.compuserve.gif" as CFString,2,nil)!
        for color in [NSColor.red,.blue] {CGImageDestinationAddImage(g,image(color),[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:0.1]] as CFDictionary)}
        precondition(CGImageDestinationFinalize(g))
        settings.path=gif.path;resetSource();try await Task.sleep(nanoseconds:700_000_000)
        start=probeTicks;try await Task.sleep(nanoseconds:1_000_000_000)
        result["visibleGIFTimerTicksIn1Second"]=probeTicks-start
        precondition(probeTicks>start && cachedDelay>0,"Animation did not run")
        home.isHidden=true;tick();start=probeTicks
        try await Task.sleep(nanoseconds:2_000_000_000)
        result["hiddenWallpaperTicksIn2Seconds"]=probeTicks-start
        home.isHidden=false;tick();start=probeTicks
        try await Task.sleep(nanoseconds:500_000_000)
        precondition(probeTicks>start && cachedFrame != nil,"Animation did not resume")
        result["resumedGIF"]=true
        settings.motion=false;tick();start=probeTicks
        try await Task.sleep(nanoseconds:1_000_000_000)
        result["pausedGIFTicksIn1Second"]=probeTicks-start
        let oldSize=cachedFrame?.width
        frame.size=NSSize(width:360,height:240);layout();tick()
        try await Task.sleep(nanoseconds:500_000_000)
        result["resizePreserved"]=cachedFrame?.width != oldSize
        precondition(cachedFrame?.width != oldSize,"Still wallpaper failed to resize")
        let invalid=directory.appendingPathComponent("broken.mov")
        try Data("not a movie".utf8).write(to:invalid)
        settings.path=invalid.path;settings.kind="video";settings.motion=true;resetSource()
        try await Task.sleep(nanoseconds:1_000_000_000)
        precondition(player?.currentItem?.status == .failed,"Invalid video fixture must reach terminal failure")
        start=probeTicks;try await Task.sleep(nanoseconds:1_000_000_000)
        result["failedVideoTicksIn1Second"]=probeTicks-start
        precondition(probeTicks == start,"Failed movie must not keep polling")
        settings.path=png.path;settings.kind="image";resetSource()
        try await Task.sleep(nanoseconds:500_000_000)
        precondition(cachedFrame != nil,"Replacing a failed movie must recover")
        timer?.invalidate();host.orderOut(nil)
        result["optimization"]="-O"
        return result
    }
}
@main struct Main {
    static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.accessory)
        Task {@MainActor in
            do {
                let directory=URL(fileURLWithPath:CommandLine.arguments[1]);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                let result=try await BrowserWallpaperView(frame:.zero).probe(directory:directory)
                try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:directory.appendingPathComponent("result.json"))
                exit(0)
            }catch{print(error);exit(1)}
        }
        app.run()
    }
}
'''
Path(sys.argv[2]).write_text(source)
