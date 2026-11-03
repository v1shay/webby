extension BrowserWallpaperView {
    func verifyChromeSampling()->Bool {
        guard let context=CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return false}
        context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:0,width:32,height:32))
        cachedFrame=context.makeImage();settings.path="/fixture/solid-red.png";settings.opacity=1
        guard let red=chromeColor(at:NSPoint(x:100,y:100)),red.redComponent>0.98,red.greenComponent<0.02 else{return false}
        settings.opacity=0.5
        guard let faded=chromeColor(at:NSPoint(x:-100,y:500)),abs(faded.redComponent-0.565)<0.02,abs(faded.greenComponent-0.065)<0.02 else{return false}
        cachedFrame=nil
        guard chromeColor(at:.zero)==nil else{return false}
        print("PASS: homepage tab samples processed wallpaper, composites visibility, clamps edge samples, handles missing artwork")
        return true
    }
}
