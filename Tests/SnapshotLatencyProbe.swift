import AppKit
import WebKit
import CryptoKit
@MainActor final class Probe:NSObject,WKNavigationDelegate {
 var web:WKWebView!;var host:NSWindow!
 func start(){let c=WKWebViewConfiguration();c.websiteDataStore = .nonPersistent();web=WKWebView(frame:NSRect(x:0,y:0,width:1000,height:700),configuration:c);web.navigationDelegate=self;host=NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false);host.isReleasedWhenClosed=false;host.contentView=web;host.makeKeyAndOrderFront(nil);web.load(URLRequest(url:URL(string:CommandLine.arguments[1])!))}
 func webView(_ w:WKWebView,didFinish n:WKNavigation!){Task{@MainActor in
  do {try await Task.sleep(nanoseconds:500_000_000)
   var samples:[[String:Any]]=[]
   for i in 0..<40 {
    let wait=i%4==0 || i%4==3
    let c=WKSnapshotConfiguration();c.rect=NSRect(x:0,y:0,width:850,height:500);c.afterScreenUpdates=wait
    let start=ProcessInfo.processInfo.systemUptime
    let image=try await w.takeSnapshot(configuration:c)
    let elapsed=(ProcessInfo.processInfo.systemUptime-start)*1000
    let bitmap=NSBitmapImageRep(cgImage:image.cgImage(forProposedRect:nil,context:nil,hints:nil)!)
    let data=bitmap.representation(using:.png,properties:[:])!
    samples.append(["afterScreenUpdates":wait,"milliseconds":elapsed,"pixelWidth":bitmap.pixelsWide,"pixelHeight":bitmap.pixelsHigh,"sha256":SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()])
   }
   let result:[String:Any]=["url":CommandLine.arguments[1],"samples":samples,"optimization":"-O","measurement":"WK snapshot callback latency; alternating ABBA order; same image dimensions; no total-GPU-time claim"]
   try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[2]));exit(0)
  }catch{print(error);exit(1)}
 }}
}
@main struct Main {static func main(){let app=NSApplication.shared;app.setActivationPolicy(.accessory);let p=Probe();p.start();DispatchQueue.main.asyncAfter(deadline:.now()+45){exit(2)};app.run();withExtendedLifetime(p){}}}
