import AppKit
import WebKit
@main struct Checks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let runner = Runner(); runner.run(); NSApplication.shared.run()
        withExtendedLifetime(runner) {}
    }
}
@MainActor final class Runner: NSObject, WKNavigationDelegate {
    var window: NSWindow!, view: WKWebView!
    func run() {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: NSRect(x:0,y:0,width:900,height:650), configuration:config)
        view.navigationDelegate = self
        window = NSWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView = view; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        view.loadHTMLString("<html><head><style>#mail{display:none}</style></head><body><div id=mail></div><div id=notice style='width:800px;height:35px'>This browser version is no longer supported. Please upgrade to a supported browser.</div><div id=security>Security warning: account access requires attention</div><textarea id=editor>Keep draft</textarea></body></html>",baseURL:URL(string:"https://mail.google.com/"))
        DispatchQueue.main.asyncAfter(deadline:.now()+20) { print("FAIL: filter test timeout"); exit(1) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                let source = try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
                // WebKit may suppress rAF in a CLI-hosted/occluded test window. Use a
                // deterministic asynchronous scheduler to check work budgeting, not FPS.
                _ = try await view.evaluateJavaScript("window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 0); document.getElementById('mail').innerHTML='<span>Mailbox text</span>'.repeat(20000); Object.defineProperty(document,'hidden',{configurable:true,value:true}); true")
                _ = try await view.evaluateJavaScript(source+";true")
                try await Task.sleep(nanoseconds:150_000_000)
                let paused = try await view.evaluateJavaScript("getComputedStyle(document.getElementById('notice')).display!=='none'") as? Bool
                guard paused == true else { throw Failure.failed("Filter ran in hidden document") }
                _ = try await view.evaluateJavaScript("window.framesSeen=0;function count(){window.framesSeen++;if(window.framesSeen<200)requestAnimationFrame(count)}requestAnimationFrame(count);Object.defineProperty(document,'hidden',{configurable:true,value:false});document.dispatchEvent(new Event('visibilitychange'));true")
                let deadline = Date().addingTimeInterval(12)
                var done = false
                while Date()<deadline {
                    done = try await view.evaluateJavaScript("getComputedStyle(document.getElementById('notice')).display==='none'") as? Bool == true
                    if done { break }
                    try await Task.sleep(nanoseconds:50_000_000)
                }
                guard done else {
                    print("Probe state", try await view.evaluateJavaScript("({frames:window.framesSeen,hidden:document.hidden,host:location.hostname,notice:document.getElementById('notice').getBoundingClientRect().height})"))
                    throw Failure.failed("Notice was not removed after bounded traversal")
                }
                let state = try await view.evaluateJavaScript("({frames:window.framesSeen,safe:getComputedStyle(document.getElementById('security')).display!=='none'&&document.getElementById('editor').value==='Keep draft'})") as? [String:Any]
                guard state?["safe"] as? Bool == true, (state?["frames"] as? Int ?? 0)>10 else { throw Failure.failed("Scan blocked frames or removed content") }
                print("PASS: 20,000-node mailbox yields across scheduled batches; hidden page paused; security notice and draft preserved; batches",state?["frames"] ?? 0)
                exit(0)
            } catch { print("FAIL:",error);exit(1) }
        }
    }
    enum Failure:Error { case failed(String) }
}
