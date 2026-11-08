import AppKit
import WebKit

// Standalone WebKit integration probe. No account/profile/cookies are used.
// swiftc -parse-as-library -framework AppKit -framework WebKit Tests/SchoologyThemeChecks.swift -o /tmp/schoology-theme-checks
// /tmp/schoology-theme-checks "$PWD" /tmp/schoology-theme-preview
@main struct SchoologyThemeChecks {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.accessory)
        let runner = try Runner(root: URL(fileURLWithPath: CommandLine.arguments[1]), output: CommandLine.arguments[2])
        Task { @MainActor in
            do {try await runner.run();exit(0)}
            catch {print("FAIL: \(error)");exit(1)}
        }
        NSApplication.shared.run()
        withExtendedLifetime(runner) {}
    }
}
@MainActor final class Runner {
    let source: String, glassSource: String, fixture: String, output: String
    var window: NSWindow!, web: WKWebView!
    init(root: URL, output: String) throws {
        source = try String(contentsOf: root.appendingPathComponent("SchoologyDark.js"))
        glassSource = try String(contentsOf: root.appendingPathComponent("glass-page.js"))
        fixture = try String(contentsOf: root.appendingPathComponent("Tests/Fixtures/schoology-theme.html"))
        self.output = output
    }
    func check(_ condition: Bool, _ message: String) throws {
        if !condition {throw NSError(domain: "SchoologyTheme", code: 1, userInfo: [NSLocalizedDescriptionKey: message])}
    }
    func js(_ script: String) async throws -> [String: Any] {try await web.evaluateJavaScript(script) as! [String: Any]}
    func run() async throws {
        for mode in [false, true] {
            let config = WKWebViewConfiguration();config.websiteDataStore = .nonPersistent()
            config.userContentController.addUserScript(WKUserScript(source: "(() => {const webbySchoologyGlass = \(mode);\n" + source + "\n})();" + (mode ? glassSource : ""), injectionTime: .atDocumentStart, forMainFrameOnly: false))
            web = WKWebView(frame: NSRect(x: 0,y: 0,width: 1280,height: 960), configuration: config)
            window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false;window.contentView = web;window.orderFront(nil)
            web.loadHTMLString(fixture, baseURL: URL(string: "https://fuhsd.schoology.com/fixture"))
            try await Task.sleep(nanoseconds: 1_500_000_000)
            let result = try await js("""
            (() => {
              const s = (id,pseudo) => getComputedStyle(document.getElementById(id),pseudo);
              document.getElementById('draft').value='preserved';document.getElementById('action').click();
              return {root:s('page').backgroundColor,unknown:s('unknown').backgroundColor,inline:s('inline').backgroundColor,
                summary:s('course-summary').backgroundColor,summaryLabel:s('summary-label').color,summaryValue:s('summary-value').color,
                nested:s('nested').color,title:s('card-title').color,grade:s('grade').color,warning:s('warning').color,
                pseudo:getComputedStyle(document.getElementById('unknown'),'::before').backgroundColor,
                gradient:s('gradient').backgroundImage,image:s('art').backgroundImage,photoFilter:s('photo').filter,
                draft:document.getElementById('draft').value,clicked:window.clicked,cell:s('cell').backgroundColor,
                header:getComputedStyle(document.querySelector('#header header')).backgroundColor,
                border:s('unknown').borderTopColor,icon:s('icon').fontFamily,editor:s('editor').fontFamily,
                frame:document.getElementById('editor-frame').contentDocument.body ? getComputedStyle(document.getElementById('editor-frame').contentDocument.body).backgroundColor : 'missing',
                transparentBorder:s('triangle').borderLeftColor,sprite:s('sprite-path').fill,accent:s('sprite-accent').fill,
                genericGlass:document.querySelectorAll('[data-webby-glass-surface]').length};
            })()
            """)
            print("\(mode ? "GLASS" : "BLACK") \(result)");fflush(stdout)
            try check(result["root"] as? String == (mode ? "rgba(0, 0, 0, 0)" : "rgb(0, 0, 0)"), "wrong page background")
            let panel = mode ? "rgba(24, 24, 24, 0.1)" : "rgb(13, 13, 13)"
            for name in ["unknown","inline","pseudo","header","summary"] {try check(result[name] as? String == panel, "missed \(name): \(result)")}
            try check(result["summaryLabel"] as? String == "rgb(237, 237, 237)" && result["summaryValue"] as? String == "rgb(163, 163, 163)", "course summary contrast")
            try check(result["nested"] as? String == "rgb(237, 237, 237)", "nested dark text")
            try check(result["title"] as? String == "rgb(237, 237, 237)", "course card text")
            try check(result["grade"] as? String == "rgb(140, 221, 165)", "green grade contrast lost")
            try check(result["warning"] as? String == "rgb(17, 17, 17)", "colored badge contrast")
            try check(result["gradient"] as? String == "none", "white gradient retained")
            try check((result["image"] as? String)?.contains("data:image/svg+xml") == true, "course artwork removed")
            try check(result["photoFilter"] as? String == "none", "media filtered")
            try check(result["draft"] as? String == "preserved" && result["clicked"] as? Bool == true, "controls changed")
            try check(result["cell"] as? String == "rgba(0, 0, 0, 0)", "table nesting paints blotches")
            try check(result["icon"] as? String == "FixtureIcons" && result["editor"] as? String == "Georgia", "font exclusions lost")
            try check(result["transparentBorder"] as? String == "rgba(0, 0, 0, 0)", "transparent border geometry changed")
            try check(result["sprite"] as? String == "rgb(237, 237, 237)" && result["accent"] as? String == "rgb(0, 182, 239)", "UI sprite dark paths/accents")
            try check(result["genericGlass"] as? Int == 0, "two crawlers compete")
            try check(result["frame"] as? String == (mode ? "rgba(0, 0, 0, 0)" : "rgb(0, 0, 0)"), "blank editor frame unthemed")
            _ = try await web.evaluateJavaScript("""
            const dialog = document.createElement('div');dialog.id='late-menu';dialog.setAttribute('role','dialog');dialog.innerHTML='<h2>New dialog</h2><input id="late-input" placeholder="Search">';document.body.appendChild(dialog);
            const style = document.createElement('style');style.textContent='#late-component{background:#fff !important;color:#333 !important}';document.head.appendChild(style);
            const component = document.createElement('div');component.id='late-component';component.textContent='Async component';document.body.appendChild(component);
            document.getElementById('inline').style.setProperty('background-color','#eee','important');
            document.getElementById('unknown').classList.add('updated');true;
            """)
            try await Task.sleep(nanoseconds: 650_000_000)
            let dynamic = try await js("""
            (()=>{const s=id=>getComputedStyle(document.getElementById(id));return {menu:s('late-menu').backgroundColor,late:s('late-component').backgroundColor,ink:s('late-component').color,inline:s('inline').backgroundColor}})()
            """)
            try check(dynamic["menu"] as? String == (mode ? "rgba(18, 18, 18, 0.9)" : "rgb(24, 24, 24)"), "new dialog missed: \(dynamic)")
            try check(dynamic["late"] as? String == panel && dynamic["ink"] as? String == "rgb(237, 237, 237)" && dynamic["inline"] as? String == panel, "async stylesheet/class/inline changes missed: \(dynamic)")
            _ = try await web.evaluateJavaScript("window.themeWrites=0;window.themeObserver=new MutationObserver(r=>window.themeWrites+=r.length);themeObserver.observe(document,{subtree:true,attributes:true,childList:true});true;")
            try await Task.sleep(nanoseconds: 250_000_000)
            let idle = try await web.evaluateJavaScript("themeWrites") as! Int
            try check(idle == 0, "idle mutation loop: \(idle)")
            // Remove only fixture test dialogs for the exported dashboard preview.
            _ = try await web.evaluateJavaScript("document.getElementById('late-menu').remove();document.getElementById('late-component').remove();document.getElementById('checks').remove();true;")
            let snapshot = try await web.takeSnapshot(configuration: nil)
            if let tiff = snapshot.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {try png.write(to: URL(fileURLWithPath: output + (mode ? "-glass.png" : "-black.png")))}
            print("PASS: \(mode ? "glass" : "black") palette; nested text; legacy !important; generated decoration; dynamic menu/styles; grade contrast; artwork; editors; intact controls; no idle mutations")
            web.stopLoading();window.orderOut(nil)
        }
        web.loadHTMLString("<html><body id=outside style='background:white;color:black'>Unrelated website</body></html>", baseURL: URL(string:"https://example.com"))
        try await Task.sleep(nanoseconds: 400_000_000)
        let outside = try await js("({bg:getComputedStyle(document.body).backgroundColor,color:getComputedStyle(document.body).color})")
        try check(outside["bg"] as? String == "rgba(0, 0, 0, 0)", "generic glass integration should still run on other websites")
        // Site-specific script itself must not run outside the exact hostname boundary.
        _ = try await web.evaluateJavaScript(source + ";true;")
        let count = try await web.evaluateJavaScript("document.querySelectorAll('[data-webby-sgy-bg],[data-webby-sgy-ink]').length") as! Int
        try check(count == 0, "Schoology rules leak to unrelated websites")
        print("PASS: unrelated website keeps generic glass without Schoology theme")
    }
}
