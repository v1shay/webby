extension CodeWorkbench {
    static func verifyWorkbench(project: URL, screenshot: URL) async throws {
        struct Check: Error { let message: String }
        let custom = "// Keep this { comment\n{\n  \"java.jdt.ls.vmargs\": \"-Xmx3G\", // our choice\n  \"editor.minimap.enabled\": true,\n  \"sampleURL\": \"https://example.com/a,}\",\n} // end"
        let merged = try WorkbenchEnergyDefaults.applying(to: custom)
        guard merged.contains("// Keep this { comment"), merged.contains("// our choice"), merged.contains("-Xmx3G"), merged.contains("https://example.com/a,}"), try WorkbenchEnergyDefaults.applying(to: merged) == merged else { throw Check(message: "Energy defaults damaged JSONC or explicit preferences") }
        guard try WorkbenchEnergyDefaults.applying(to: "{/* empty */}").contains("files.watcherExclude") else { throw Check(message: "Empty commented settings failed") }
        let startup = WorkbenchStartupOutput()
        guard startup.consume(Data("HTTP server listening on http://127.0.0.1:52".utf8)) == nil,
              startup.consume(Data("818/\n".utf8))?.port == 52818,
              startup.consume(Data("http://127.0.0.1:1234/".utf8)) == nil else { throw Check(message: "Startup output parsing or one-shot delivery failed") }
        print("PASS: JSONC preferences preserved, defaults idempotent, split log chunks, one-shot readiness")
        let cancelledID = UUID()
        var cancellationDelivered = false
        CodeWorkbenchRuntime.shared.acquire(cancelledID) { _ in cancellationDelivered = true }
        CodeWorkbenchRuntime.shared.stop(); CodeWorkbenchRuntime.shared.release(cancelledID)
        try await Task.sleep(nanoseconds: 150_000_000)
        guard !cancellationDelivered, CodeWorkbenchRuntime.shared.process == nil else { throw Check(message: "Cancelled background preparation started a backend") }
        let host = CodeWorkbench()
        let window = NSWindow(contentRect: NSRect(x: 0,y: 0,width: 1100,height: 760),styleMask: [.titled,.resizable],backing: .buffered,defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host.view; window.makeKeyAndOrderFront(nil)
        let file = project.appendingPathComponent("Main.java")
        try "public class Main { public static void main(String[] args) { int value = \"bad\"; System.out.println(value); } }\n".write(to: file, atomically: true, encoding: .utf8)
        host.openFolder(project); host.start()
        defer { host.shutdown(); CodeWorkbenchRuntime.shared.stop(); window.orderOut(nil) }
        let deadline = Date().addingTimeInterval(80)
        var ready = false
        while Date() < deadline {
            if (try? await host.web.evaluateJavaScript("!!document.querySelector('.monaco-workbench')")) as? Bool == true { ready = true; break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard ready else { throw Check(message: "Workbench failed: " + host.message.stringValue + " " + (host.web.url?.absoluteString ?? "nil")) }
        let sharedPID = CodeWorkbenchRuntime.shared.process?.processIdentifier
        let second = CodeWorkbench(); second.start()
        guard CodeWorkbenchRuntime.shared.clients.count == 2, CodeWorkbenchRuntime.shared.process?.processIdentifier == sharedPID else { throw Check(message: "IDE tabs did not share one backend") }
        second.shutdown()
        guard CodeWorkbenchRuntime.shared.clients.count == 1, CodeWorkbenchRuntime.shared.process?.isRunning == true else { throw Check(message: "Closing one IDE stopped another workspace") }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        _ = try await host.web.evaluateJavaScript("Array.from(document.querySelectorAll('a,button')).find(e=>e.textContent.trim()==='Yes, I trust the authors')?.click();true")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        _ = try await host.web.evaluateJavaScript("(()=>{const e=Array.from(document.querySelectorAll('.label-name')).find(e=>e.textContent==='Main.java'); if(e){e.dispatchEvent(new MouseEvent('dblclick',{bubbles:true}));e.click();}return !!e})()")
        let diagnosticsDeadline = Date().addingTimeInterval(90)
        let diagnostic = "Type mismatch: cannot convert from String to int"
        let showProblems = """
        (() => {
          const panel = document.querySelector('.markers-panel');
          if (!panel?.getClientRects().length) document.getElementById('status.problems')?.querySelector('a.statusbar-item-label')?.click();
          return document.querySelector('.markers-panel')?.innerText ?? '';
        })()
        """
        var diagnosed = false
        while Date() < diagnosticsDeadline {
            _ = try? await host.web.evaluateJavaScript("Array.from(document.querySelectorAll('a,button')).find(e=>e.textContent.trim().startsWith('Yes, I trust the authors'))?.click();true")
            let text = (try? await host.web.evaluateJavaScript("document.body.innerText")) as? String ?? ""
            if text.contains("Language Support for Java") && text.contains("Reload") { print("JAVA reload requested",text.suffix(2000)) }
            let problems = (try? await host.web.evaluateJavaScript(showProblems)) as? String ?? ""
            if problems.contains("Main.java") && problems.contains(diagnostic) { diagnosed = true; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        print("JAVA diagnostics",diagnosed)
        guard diagnosed else { print("DIAGNOSTIC STATE",try await host.web.evaluateJavaScript("document.body.innerText")); throw Check(message: "Java error diagnostics did not appear") }
        try "public class Main {\n    public static void main(String[] args) {\n        int value = 9;\n        System.out.println(value);\n    }\n}\n".write(to: file, atomically: true, encoding: .utf8)
        var refreshed = false
        for _ in 0..<40 {
            let problems = (try? await host.web.evaluateJavaScript(showProblems)) as? String ?? ""
            let cleared = (try? await host.web.evaluateJavaScript(#"""
            (() => {
              const status = document.getElementById('status.problems')?.querySelector('a.statusbar-item-label');
              const editor = document.querySelector('.monaco-editor .view-lines');
              return status?.innerText.trim().split(/\s+/)[0] === '0' && /int\s+value\s*=\s*9/.test(editor?.innerText ?? '');
            })()
            """#)) as? Bool == true
            if cleared && !problems.contains(diagnostic) { refreshed = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        guard refreshed else { throw Check(message: "Java diagnostics did not clear after fixing the file") }
        _ = try await host.web.evaluateJavaScript("document.getElementById('status.problems')?.querySelector('a.statusbar-item-label')?.click();true")
        window.makeFirstResponder(host.web)
        _ = try await host.web.evaluateJavaScript("document.querySelector('.monaco-editor textarea')?.focus();true")
        func key(_ code:UInt16,_ character:UInt32,_ flags:NSEvent.ModifierFlags = []) {
            host.web.keyDown(with:NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:String(UnicodeScalar(character)!),charactersIgnoringModifiers:String(UnicodeScalar(character)!),isARepeat:false,keyCode:code)!)
        }
        key(126,0xF700,[.command])
        for _ in 0..<3 { key(125,0xF701) }
        key(101,0xF70C)
        try await Task.sleep(nanoseconds: 500_000_000)
        print("BREAKPOINT STATE",try await host.web.evaluateJavaScript("document.body.innerText.slice(-1500)"))
        key(96,0xF708)
        var paused = false
        for _ in 0..<90 {
            if (try? await host.web.evaluateJavaScript("Array.from(document.querySelectorAll('.debug-toolbar [aria-label]')).some(e=>e.getAttribute('aria-label').startsWith('Continue'))")) as? Bool == true { paused = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        print("JAVA paused at breakpoint",paused)
        print("DEBUG STATE",try await host.web.evaluateJavaScript("document.body.innerText.slice(-6000)"))
        _ = try await host.web.evaluateJavaScript("Array.from(document.querySelectorAll('.debug-toolbar [aria-label]')).find(e=>e.getAttribute('aria-label').startsWith('Stop'))?.click();true")
        guard paused else { throw Check(message: "Java debugger did not pause at a breakpoint") }
        host.shortcut("f",keyCode:3)
        try await Task.sleep(nanoseconds: 500_000_000)
        guard (try await host.web.evaluateJavaScript("!!document.querySelector('.find-widget.visible')")) as? Bool == true else { throw Check(message: "Native Find shortcut was not delivered to IDE") }
        print("PASS: Java type diagnostics, diagnostic clearing, real breakpoint pause, debugger stop, and native Find routing")

        if let seconds = ProcessInfo.processInfo.environment["WEBBY_IDE_SAMPLE_IDLE_SECONDS"].flatMap(Double.init), seconds > 0 {
            print("IDE_IDLE_BEGIN"); fflush(stdout)
            try await Task.sleep(nanoseconds: UInt64(min(seconds, 30) * 1_000_000_000))
            print("IDE_IDLE_END"); fflush(stdout)
        }
        let state = try await host.web.evaluateJavaScript("({text:document.body.innerText.slice(0,10000), editors:document.querySelectorAll('.monaco-editor').length})")
        print("WORKBENCH", state)
        if let bitmap = host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds) {
            host.view.cacheDisplay(in: host.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: screenshot)
        }
        guard host.web.configuration.websiteDataStore.isPersistent == false else { throw Check(message: "Workbench leaked into persistent browser store") }
        print("PASS: real authenticated VS Code workbench loaded in native WKWebView with isolated cookies")
    }
}
