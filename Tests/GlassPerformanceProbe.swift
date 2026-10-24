import AppKit
import WebKit

@MainActor final class Probe: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    var window: NSWindow!
    var web: WKWebView!
    let source: String
    init(source: String) { self.source = source; super.init() }
    func start() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "result")
        web = WKWebView(frame: NSRect(x: 0,y: 0,width: 1000,height: 700), configuration: config)
        web.navigationDelegate = self
        window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web; window.orderBack(nil)
        web.loadHTMLString("<html><head><style>body{background:#fff;color:#202124}.panel{background:#eee;color:#333;padding:8px}.alternate{background:#ddd}</style></head><body><main id='app'></main></body></html>", baseURL: nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let instrument = """
        window.metrics={styles:0,rects:0,cpu:0,longest:0,frames:0};
        const gcs=window.getComputedStyle.bind(window); window.getComputedStyle=(...a)=>{metrics.styles++;return gcs(...a)};
        const rect=Element.prototype.getBoundingClientRect;
        Element.prototype.getBoundingClientRect=function(){metrics.rects++;return rect.call(this)};
        const raf=window.requestAnimationFrame.bind(window);
        window.requestAnimationFrame=callback=>raf(t=>{let a=performance.now();callback(t);let dt=performance.now()-a;metrics.cpu+=dt;metrics.longest=Math.max(metrics.longest,dt);metrics.frames++});
        for(let i=0;i<600;i++){let p=document.createElement('section');p.className='panel';p.innerHTML='<span>Readable text</span><button>Action</button>';app.appendChild(p)}
        """
        let workload = """
        let last=0,quiet=0,phase=0,ticks=0; const results=[];
        const check=setInterval(()=>{
          ticks++;if(metrics.styles===last)quiet++;else quiet=0;last=metrics.styles;
          if(quiet>=5 && window.__glassPending()===0){results.push({...metrics});if(phase===0){
            phase=1;quiet=0;for(let i=0;i<12;i++)document.documentElement.className='theme'+i;
            for(const p of [...document.querySelectorAll('.panel')].slice(0,100))p.classList.add('alternate');
          }else{clearInterval(check);webkit.messageHandlers.result.postMessage(JSON.stringify({results,timeout:false,surface:gcs(document.querySelector('.panel')).backgroundColor,text:gcs(document.querySelector('.panel')).color}));}}
          if(ticks>1200){clearInterval(check);webkit.messageHandlers.result.postMessage(JSON.stringify({results,timeout:true,metrics}));}
        },20);
        """
        let measuredSource = source.replacingOccurrences(of: "  function flush() {", with: "  window.__glassPending = () => pending.size + trees.length + (typeof documentRefreshTimer !== 'undefined' && documentRefreshTimer !== null ? 1 : 0);\n  function flush() {")
        webView.evaluateJavaScript(instrument + measuredSource + workload) { _, error in
            if error != nil { print("Probe JavaScript failed"); exit(1) }
        }
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        print(message.body); window.orderOut(nil); NSApp.terminate(nil)
    }
}
@main struct RunProbe {
    static func main() throws {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let probe = Probe(source: try String(contentsOfFile: CommandLine.arguments[1])); probe.start()
        DispatchQueue.main.asyncAfter(deadline: .now()+35) { print("Probe timed out"); exit(1) }
        app.run(); withExtendedLifetime(probe) {}
    }
}
