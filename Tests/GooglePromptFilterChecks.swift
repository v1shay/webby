import AppKit
import WebKit
@main struct Checks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        let runner=Runner();runner.run()
        NSApplication.shared.run()
        withExtendedLifetime(runner) {}
    }
}
@MainActor final class Runner:NSObject,WKNavigationDelegate {
    var window:NSWindow!;var view:WKWebView!;var legacy=CommandLine.arguments.count > 2
    let fixedSource = CommandLine.arguments.count > 1
        ? URL(fileURLWithPath:CommandLine.arguments[1])
        : URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("GooglePromptFilter.js")
    func run() {
        let config=WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
        view=WKWebView(frame:NSRect(x:0,y:0,width:1000,height:700),configuration:config)
        view.navigationDelegate=self
        window=NSWindow(contentRect:view.frame,styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView=view;window.makeKeyAndOrderFront(nil)
        load()
    }
    func load() {
        view.loadHTMLString("""
        <html><head><style>body{margin:0}#shell{height:130px;width:100%}#notice{height:32px;width:100%}#tools{height:90px}#document{height:1000px}</style></head><body>
        <div id=shell><div id=notice><span id=nag>This browser version is no longer supported. Please upgrade to a supported browser.</span></div>
        <div id=tools><input id=title value='My Slides'><button id=file>File</button><button id=edit>Edit</button><button id=present>Slideshow</button></div></div>
        <main id=document>Document canvas<textarea id=editor></textarea></main>
        <div id=security role=alert>Security warning: account access requires attention</div>
        </body></html>
        """,baseURL:URL(string:"https://docs.google.com/presentation/test"))
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        Task { @MainActor in
            do {
                let script=try String(contentsOf:legacy ? URL(fileURLWithPath:CommandLine.arguments[2]) : fixedSource,encoding:.utf8)
                _ = try await view.evaluateJavaScript(script+";true")
                try await Task.sleep(nanoseconds:200_000_000)
                let state=try await view.evaluateJavaScript("""
                ({host:location.hostname,shell:getComputedStyle(document.getElementById('shell')).display,
                tools:document.getElementById('tools').getBoundingClientRect().height,
                hidden:getComputedStyle(document.getElementById('nag')).display==='none'||getComputedStyle(document.getElementById('notice')).display==='none',
                security:getComputedStyle(document.getElementById('security')).display,
                top:document.getElementById('tools').getBoundingClientRect().top})
                """) as! [String:Any]
                guard state["host"] as? String == "docs.google.com" else {throw Failure.failed("Wrong fixture origin")}
                if legacy {
                    guard state["shell"] as? String == "none" else {throw Failure.failed("Legacy filter did not reproduce toolbar removal: \(state)")}
                    print("PASS: reproduced original filter hiding entire Google-style title/menu/toolbar container")
                    legacy=false;load()
                } else {
                    guard state["shell"] as? String != "none",(state["tools"] as? Double ?? 0)>0,
                          state["hidden"] as? Bool == false,state["security"] as? String != "none",
                          (state["top"] as? Double ?? -1)>=0 else {throw Failure.failed("Fixed header regression: \(state)")}
                    _ = try await view.evaluateJavaScript("document.getElementById('editor').value='still editable';document.getElementById('file').click();true")
                    print("PASS: Docs filtering disabled: notice, title, menus, toolbar, document and security notice preserved")
                    exit(0)
                }
            } catch {print("FAIL: \(error)");exit(1)}
        }
    }
    enum Failure:Error {case failed(String)}
}
