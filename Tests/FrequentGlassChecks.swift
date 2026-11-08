import AppKit
import WebKit
@main struct Checks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let source=try String(contentsOfFile:CommandLine.arguments[1])
        let schoology=try String(contentsOf:URL(fileURLWithPath:CommandLine.arguments[1]).deletingLastPathComponent().appendingPathComponent("SchoologyDark.js"))
        let check=Runner(source,schoology:schoology);check.start();NSApplication.shared.run();withExtendedLifetime(check){}
    }
}
@MainActor final class Runner:NSObject,WKNavigationDelegate {
    let source:String
    let schoology:String
    let hosts=["chatgpt.com","github.com","www.youtube.com","mail.google.com","calendar.google.com","drive.google.com","docs.google.com","www.google.com","www.linkedin.com","www.instagram.com","www.tiktok.com","x.com","www.reddit.com","devpost.com","fuhsd.schoology.com"]
    var index=0;var window:NSWindow!;var web:WKWebView!
    init(_ source:String,schoology:String){self.source=source;self.schoology=schoology}
    func start(){
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        let instrumentation="""
        window.reads={styles:0,rects:0};window.nativeStyle=getComputedStyle.bind(window);
        window.getComputedStyle=(...args)=>{reads.styles++;return nativeStyle(...args)};
        const rect=Element.prototype.getBoundingClientRect;
        Element.prototype.getBoundingClientRect=function(){reads.rects++;return rect.call(this)};
        """
        config.userContentController.addUserScript(WKUserScript(source:instrumentation+"\n(() => { const webbySchoologyGlass = true;\n"+schoology+"\n})();\n"+source,injectionTime:.atDocumentStart,forMainFrameOnly:false))
        web=WKWebView(frame:NSRect(x:0,y:0,width:1000,height:700),configuration:config);web.navigationDelegate=self
        window=NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false);window.contentView=web;window.makeKeyAndOrderFront(nil)
        load()
    }
    func load(){
        web.loadHTMLString("""
        <html><head><style>:root{--main-surface-primary:white;--bgColor-default:white;--yt-spec-base-background:white;--text-primary:black}body{margin:0;background:white}header{height:70px;background:white}.tokenpanel{background:var(--main-surface-primary);color:var(--text-primary)}canvas{width:200px;height:100px}#paper{background:white;color:black}</style></head><body>
        <header class='AppHeader docs-titlebar global-nav nH'><input id=draft value='original'><button id=action onclick='window.clicked=true'>File</button></header>
        <main id=main><section class=tokenpanel>Readable text</section><canvas width=200 height=100></canvas><article id=paper>Document content</article><img id=photo alt=art><video id=media></video><pre><code>let value = 42</code></pre></main>
        <script>document.documentElement.classList.add('hydrated');const p=document.createElement('section');p.className='tokenpanel';p.id='late';p.textContent='New content';document.getElementById('main').appendChild(p)</script>
        </body></html>
        """,baseURL:URL(string:"https://\(hosts[index])/fixture"))
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!){
        Task{@MainActor in
            do {
                try await Task.sleep(nanoseconds:150_000_000)
                let value=try await web.evaluateJavaScript("""
                (()=>{
                const s=nativeStyle;document.querySelector('#draft').focus();document.querySelector('#draft').value='preserved';document.querySelector('#action').click();
                const paper=document.querySelector('#paper');
                return {host:location.hostname,reads,root:s(document.body).backgroundColor,draft:document.querySelector('#draft').value,
                clicked:window.clicked,header:s(document.querySelector('header')).display,headerHeight:s(document.querySelector('header')).height,
                canvas:[document.querySelector('canvas').width,document.querySelector('canvas').height],paper:s(paper).backgroundColor,
                photoFilter:s(document.querySelector('#photo')).filter,mediaFilter:s(document.querySelector('#media')).filter,
                late:s(document.querySelector('#late')).backgroundColor};})()
                """) as! [String:Any]
                let declarative=["chatgpt.com","github.com","www.youtube.com","calendar.google.com","drive.google.com","docs.google.com","www.linkedin.com","www.reddit.com"].contains(hosts[index])
                guard let reads=value["reads"] as? [String:Int], (!declarative || (reads["styles"]==0 && reads["rects"]==0)),
                      value["root"] as? String == "rgba(0, 0, 0, 0)",value["draft"] as? String == "preserved",
                      value["clicked"] as? Bool == true,value["canvas"] as? [Int] == [200,100],value["header"] as? String != "none",value["headerHeight"] as? String == "70px",
                      value["photoFilter"] as? String == "none",value["mediaFilter"] as? String == "none",
                      (hosts[index] != "docs.google.com" || value["paper"] as? String == "rgb(255, 255, 255)") else {throw Failure.bad("\(value)")}
                if hosts[index]=="chatgpt.com" {guard value["late"] as? String == "rgba(42, 47, 51, 0.09)" else {throw Failure.bad("SPA token not styled")}}
                print("PASS: \(hosts[index]) early CSS, bounded/declarative styling, editable controls, intact header/document/media, SPA content")
                index+=1
                if index==hosts.count {exit(0)}else{load()}
            }catch{print("FAIL: \(hosts[index]): \(error)");exit(1)}
        }
    }
    enum Failure:Error{case bad(String)}
}
