import Darwin
// Appended only to a temporary test copy of BrowserApp.swift by the test builder.
// Private access lets this exercise the actual browser paths, not a parallel model.
extension BrowserApp {
    private struct PerformanceTestFailure: Error { let message: String }
    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw PerformanceTestFailure(message: message) }
    }
    private func waitFor(_ message: String, timeout: Double = 8, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { throw PerformanceTestFailure(message: message) }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    private func loadFixture(_ path: String, base: String) async throws -> BrowserTab {
        addTab(select: true)
        let target = activeTab!
        navigate(base+path, in: target)
        try await waitFor("Page failed: "+path) { target.navigationTiming.finished != nil }
        return target
    }
    private func runPerformanceChecks(base: String, output: URL) async throws {
        try expect(Bundle.main.bundleIdentifier == "local.webby.performance-tests", "Test bundle identity is not isolated")
        BrowserExperiment.cyclesNewTabProfiles = false
        BrowserTabPlacement.current = .top
        UserDefaults.standard.set(true, forKey: "webbyRestoreTabs")
        UserDefaults.standard.set(1, forKey: "webbyOffloadMinutes")
        let a = BrowserSpace(.init(id: UUID(), name: "Fixture A", chromeDirectory: nil, bookmarks: [], history: []))
        let b = BrowserSpace(.init(id: UUID(), name: "Fixture B", chromeDirectory: nil, bookmarks: [], history: []))
        spaces = [a,b]
        for space in spaces { UserDefaults.standard.set(Data("[]".utf8), forKey: "webbyWidgetCanvas.\(space.saved.id.uuidString)") }
        if ProcessInfo.processInfo.environment["WEBBY_TEST_DOWNLOADS"] == "only" {
            let folder=output.deletingLastPathComponent().appendingPathComponent("downloads",isDirectory:true)
            downloads = BrowserDownloads(destinationFolder:folder,defaults:UserDefaults(suiteName:"webby-download-browser-test-"+UUID().uuidString)!)
        } else { downloads = BrowserDownloads() }
        if ProcessInfo.processInfo.environment["WEBBY_REAL_CORPUS"] != nil {
            BrowserGlass.pageInjectionEnabled = ProcessInfo.processInfo.environment["WEBBY_REAL_VARIANT"] != "webby-no-glass"
            appliedPageInjection = BrowserGlass.pageInjectionEnabled
            loadRules()
        }
        makeWindow(); makeSidebar(); makeMainArea(); makeHome()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .browserThemeChanged, object: nil)
        BrowserTheme.activate(a.saved.id)
        themeChanged()
        if ProcessInfo.processInfo.environment["WEBBY_TEST_LOADING_RIM"] == "only" {
            toolbar.resetProgress();toolbar.setProgress(0.4)
            content.layoutSubtreeIfNeeded()
            let strokes=(topAddressSurface.layer?.sublayers ?? []).compactMap { ($0 as? CAGradientLayer)?.mask as? CAShapeLayer }
            guard let beam=strokes.first(where:{abs($0.strokeEnd-0.4)<0.001}) else {throw PerformanceTestFailure(message:"Loading was not routed to address rim")}
            for size in [NSSize(width:180,height:34),NSSize(width:640,height:42)] {
                topAddressSurface.frame.size=size;topAddressSurface.needsLayout=true;topAddressSurface.layoutSubtreeIfNeeded()
                let expected=topAddressSurface.bounds.insetBy(dx:1.5,dy:1.5)
                try expect(beam.path?.boundingBoxOfPath == expected,"Loading rim escaped resized address field")
                try expect(beam.path?.contains(CGPoint(x:expected.minX,y:expected.minY)) == false,"Loading outline did not curve at corner")
            }
            try expect(!(toolbar.layer?.sublayers ?? []).contains(where:{$0 is CAGradientLayer}),"Toolbar-wide loading gradient remains")
            toolbar.setProgress(0.2);try expect(abs(beam.strokeEnd-0.4)<0.001,"Loading regressed")
            toolbar.setProgress(1);try expect(beam.strokeEnd==1,"Loading failed to finish")
            toolbar.hideProgress();try expect(beam.opacity==0,"Completed loading remained visible")
            toolbar.resetProgress();toolbar.setProgress(0.1);try expect(abs(beam.strokeEnd-0.1)<0.001,"Next navigation retained old progress")
            toolbar.resetProgress();try expect(beam.opacity==0,"Cancelled loading remained visible")
            try Data("{\"passed\":true,\"loadingRim\":true}".utf8).write(to:output)
            print("PASS: rounded address-only loading, compact/wide resize, monotonic progress, finish, cancellation and restart")
            exit(0)
        }
        if ProcessInfo.processInfo.environment["WEBBY_TEST_CALCULATOR_FOCUS"] == "only" {
            window.makeKeyAndOrderFront(nil)
            try expect(widgetCanvas.verifyCalculatorFocus(),"Calculator lost input focus during layout, refresh, resize or Return")
            try Data("{\"passed\":true,\"calculatorFocus\":true}".utf8).write(to:output)
            exit(0)
        }
        if let corpus=ProcessInfo.processInfo.environment["WEBBY_REAL_CORPUS"] {
            try await runRealCorpus(corpus:corpus,output:output)
            exit(0)
        }
        if ProcessInfo.processInfo.environment["WEBBY_TEST_FAST_LOAD"] == "only" {
            try await verifyFastLoading(base:base,output:output)
            exit(0)
        }
        if ProcessInfo.processInfo.environment["WEBBY_TEST_CHROME_TONE"] == "only" {
            try await verifyChromeTone(base:base)
            try Data("{\"passed\":true,\"websiteEdge\":true}".utf8).write(to:output)
            exit(0)
        }
        if ProcessInfo.processInfo.environment["WEBBY_TEST_DOWNLOADS"] == "only" {
            try await verifyDownloads(base:base,folder:output.deletingLastPathComponent().appendingPathComponent("downloads"))
            try Data("{\"passed\":true}".utf8).write(to:output)
            exit(0)
        }
        if ProcessInfo.processInfo.environment["WEBBY_TEST_LINKS"] == "only" {
            try await verifyLinkOpening(base:base)
            try Data("{\"passed\":true}".utf8).write(to:output)
            exit(0)
        }
        if ProcessInfo.processInfo.environment["WEBBY_TEST_GROUPS"] == "only" {
            try await verifyCommandGroups(base:base)
            try Data("{\"passed\":true,\"commandGroups\":true}".utf8).write(to:output)
            print("Command group checks passed");exit(0)
        }
        if ProcessInfo.processInfo.environment["WEBBY_TEST_EXTERNAL_LINKS"] == "only" {
            try await verifyExternalLinks(base:base)
            try Data("{\"passed\":true,\"externalLinks\":true}".utf8).write(to:output)
            print("External link checks passed");exit(0)
        }
        if ProcessInfo.processInfo.environment["WEBBY_TEST_MEDIA"] == "only" {
            try await verifyVideoPresentation(base:base)
            try Data("{\"passed\":true,\"nativeMedia\":true}".utf8).write(to:output)
            print("Native media checks passed");exit(0)
        }
        try expect(BrowserWallpaperView(frame:NSRect(x:0,y:0,width:200,height:100)).verifyChromeSampling(),"Homepage tab sampling failed")
        try verifyTabGlassShape()
        try expect(widgetCanvas.verifyAlignmentBounds(), "Widget alignment guides or canvas boundaries failed")
        try expect(widgetCanvas.verifyChatGPTInput(),"ChatGPT widget image paste, thumbnail removal, or prompt submission failed")
        try expect(widgetCanvas.verifyServiceBrands(),"Bundled service logos or responsive calendar placement failed")
        try expect(CodexAppWidgetView(usage:true).verifyUsageRing(),"Codex usage ring/logo layout failed")
        try expect(widgetCanvas.verifyCodexInput(),"Codex prompt cannot focus, type, or submit")
        try expect(widgetCanvas.verifyWidgetGlass(), "Widget glass opacity, profile isolation, or backdrop mode failed")
        let menuTest=BrowserMenuBar(showBrowser:{},addWidget:{},resetWidgets:{},
            currentSpaceName:{"Fixture A"},currentSpaceID:{a.saved.id},importChrome:{},deleteProfile:{},
            openBookmarks:{},openHistory:{},importPasswords:{},showPasswords:{},importSignIns:{},fillPassword:{},
            profiles:{[(a.saved.id,"Fixture A"),(b.saved.id,"Fixture B")]},openTerminal:{},
            experimentChanged:{},tabPlacementChanged:{},chooseGoogleClient:{},connectGoogle:{_ in},
            disconnectGoogle:{_ in},googleConnected:{_ in false})
        try expect(menuTest.verifyOrganization(),"Menu organization lost controls or actions")
        window.orderBack(nil)
        addTab(select: true)
        let home = activeTab!
        let pins = [PinnedTabRecord(title:"Sleeping pin",url:base+"/plain?pin=1",ownerSpaceID:a.saved.id,widthFraction:0.5,height:72,instanceClosed:false),
                    PinnedTabRecord(title:"Closed pin",url:base+"/plain?pin=2",ownerSpaceID:b.saved.id,widthFraction:0.5,height:72,instanceClosed:true)]
        UserDefaults.standard.set(try JSONEncoder().encode(pins),forKey:pinnedKey(for:a))
        _ = restorePinnedTabs()
        try expect(a.tabs.filter(\.isPinned).allSatisfy { $0.webView == nil }, "Pins loaded without selection")
        try expect(a.tabs.first { $0.title == "Closed pin" }!.pinnedInstanceClosed, "Closed-pin state was lost")
        let pages = (0..<80).map { index in
            BrowserSessionRecord.Page(title: "Sleeping \(index)", url: base+"/plain?tab=\(index)",
                ownerSpaceID: index%2 == 0 ? a.saved.id : b.saved.id, displaySpaceID: a.saved.id, groupID: nil)
        }
        UserDefaults.standard.set(try JSONEncoder().encode(BrowserSessionRecord(pages: pages)), forKey: "webbySessionTabs")
        restoreSessionTabs()
        let sleeping = a.tabs.filter { $0 !== home && !$0.isPinned }
        try expect(sleeping.count == 80 && sleeping.allSatisfy { $0.webView == nil }, "Restoration allocated a background webview")
        try await Task.sleep(nanoseconds: 1_800_000_000)
        try expect(sleeping.allSatisfy { $0.webView == nil }, "A delayed background restore still ran")
        selectTab(sleeping[0])
        try await waitFor("Selected restored tab did not load") { sleeping[0].navigationTiming.finished != nil }
        try expect(sleeping.dropFirst().allSatisfy { $0.webView == nil }, "Selecting one restored tab woke others")
        try expect(sleeping[1].ownerSpaceID == b.saved.id, "Restoration changed profile ownership")
        let slow = try await loadFixture("/slow", base: base)
        let timing = slow.navigationTiming
        try expect(timing.presented != nil && timing.finished! - timing.presented! > 1, "Slow subresource still delays page reveal")
        try expect(homeView.isHidden && slow.webView!.alphaValue == 1, "Presented page is obscured")
        try await verifyHoverChrome()
        let redirect = try await loadFixture("/redirect", base: base)
        try expect(redirect.webView!.url!.path == "/plain", "Redirect handling failed")
        addTab(select: true)
        let failure = activeTab!
        navigate("http://127.0.0.1:59998/unreachable", in: failure)
        do { try await waitFor("Failure did not show a recoverable search view") { failure.loadError != nil } }
        catch {
            print("Failure fixture state:",failure.navigationInProgress,failure.showsSearchView,failure.webView?.isLoading as Any,failure.webView?.url as Any,failure.currentNavigation as Any)
            throw error
        }
        try expect(failure.showsSearchView && !homeView.isHidden, "Provisional failure left an invisible page")
        let form = try await loadFixture("/form", base: base)
        try await form.webView!.callAsyncJavaScript("const e=document.getElementById('editor');e.value='unsaved';e.dispatchEvent(new Event('input',{bubbles:true}));", arguments: [:], in: nil, in: .page)
        try await waitFor("Edit protection was not delivered") { form.hasUnsavedEdits }
        selectTab(home); form.lastActiveAt = .distantPast
        try expect(!canDiscard(form, cutoff: Date()), "Edited page is discardable")
        let plain = try await loadFixture("/plain", base: base)
        try await verifyAddressUX()
        let second = try await loadFixture("/plain?second", base: base)
        for horizontal in [false,true] {
            let row=TabRow(tabID:plain.id,target:self)
            row.horizontal=horizontal;row.frame=NSRect(x:0,y:0,width:220,height:39)
            try expect(row.reorderEdge(at:NSPoint(x:110,y:19.5))==nil,"Direct tab overlap was treated as reorder")
            try expect(row.reorderEdge(at:horizontal ? NSPoint(x:2,y:19):NSPoint(x:110,y:2)) != nil,"Tab edge reorder target missing")
        }
        try expect(splitTabs(sourceID: plain.id, targetID: second.id), "Two-pane split failed")
        try expect(plain.webView!.isHidden == false && second.webView!.isHidden == false, "A split pane is hidden")
        plain.lastActiveAt = .distantPast
        try expect(!canDiscard(plain, cutoff: Date()), "Visible split is discardable")
        try expect(splitTabs(sourceID: redirect.id, targetID: second.id), "Three-pane split failed")
        try expect(splitTabs(sourceID: sleeping[0].id, targetID: second.id), "Four-pane split failed")
        for layout in SplitLayout.allCases {
            splitLayout = layout
            renderSplit([second.id,plain.id,redirect.id,sleeping[0].id])
            activeTabID = nil; selectTab(second)
            try expect(splitTabIDs!.allSatisfy { tab(id:$0)!.webView!.isHidden == false }, "Layout hid a pane: \(layout.rawValue)")
            try expect(splitTabIDs!.allSatisfy { tab(id:$0)!.webView!.bounds.width > 60 && tab(id:$0)!.webView!.bounds.height > 40 }, "Layout collapsed a pane: \(layout.rawValue)")
        }
        endSplit(); activeTabID = nil; selectTab(home)
        plain.lastActiveAt = .distantPast
        try expect(canDiscard(plain, cutoff: Date()), "Clean inactive page cannot be discarded")
        plain.isFloating = true
        try expect(!canDiscard(plain, cutoff: Date()), "Floating page is discardable")
        plain.isFloating = false; plain.captureMayBeActive = true
        try expect(!canDiscard(plain, cutoff: Date()), "Capture page is discardable")
        plain.captureMayBeActive = false
        let menu = NSMenuItem(); menu.representedObject = plain.id
        toggleKeepLoaded(menu)
        try expect(!canDiscard(plain, cutoff: Date()), "Keep-loaded preference was ignored")
        toggleKeepLoaded(menu)
        plain.isPinned = true; refreshTabs()
        checkDiscard(plain, cutoff: Date())
        try await waitFor("Clean inactive page was not discarded") { plain.webView == nil }
        try expect(plain.suspendedURL != nil && !plain.pinnedInstanceClosed, "Discard destroyed metadata or closed a pin")
        selectTab(plain)
        try await waitFor("Discarded page failed to resume") { plain.navigationTiming.finished != nil }
        try expect(plain.ownerSpaceID == a.saved.id, "Resume changed owner")
        let frame = try await loadFixture("/frame", base: base)
        selectTab(home); frame.lastActiveAt = .distantPast
        checkDiscard(frame, cutoff: Date())
        try await Task.sleep(nanoseconds: 200_000_000)
        try expect(frame.webView != nil, "Embedded app was discarded")
        // Verify stale callbacks cannot hide the start page after another tab wins.
        let stale = slow.navigationTiming.id
        selectTab(home)
        presentPage(slow, webView: slow.webView!, generation: stale)
        try expect(!homeView.isHidden, "A background reveal hid the active homepage")
        let old = slow.navigationTiming.id
        slow.navigationTiming = BrowserNavigationTiming()
        presentPage(slow, webView: slow.webView!, generation: old)
        try expect(!homeView.isHidden, "A stale document reveal changed the UI")
        let ide = BrowserTab(); ide.ownerSpaceID = a.saved.id; a.tabs.append(ide); attachIDE(to: ide)
        try expect(splitTabs(sourceID: ide.id, targetID: second.id), "IDE split failed")
        try expect(ide.ide!.view.isHidden == false && second.webView!.isHidden == false, "IDE split content is hidden")
        endSplit(); activeTabID = nil; selectTab(home)
        try expect(ide.ide!.view.superview === pageArea, "IDE did not dock after unsplitting")
        // UI selection checks use already loaded pages; untouched restored tabs stay asleep.
        tabSwitchTimes = []
        for _ in 0..<15 { selectTab(redirect); selectTab(second); selectTab(home) }
        let topTimes = tabSwitchTimes
        BrowserTabPlacement.current = .horizontal; applyTabPlacement()
        for _ in 0..<15 { selectTab(redirect); selectTab(second); selectTab(home) }
        let horizontalTimes = Array(tabSwitchTimes.dropFirst(topTimes.count))
        BrowserExperiment.cyclesNewTabProfiles = true; experimentalModeChanged()
        try expect(tab(id: sleeping[1].id)?.ownerSpaceID == b.saved.id, "Fuse changed owner")
        selectTab(second)
        BrowserExperiment.cyclesNewTabProfiles = false; experimentalModeChanged()
        try expect(second.ownerSpaceID == a.saved.id && activeTabID == second.id, "Fuse transition lost selection or owner")
        switchToSpace(1)
        try expect(b.tabs.allSatisfy { $0.webView == nil }, "Profile switch woke unrelated pages")
        switchToSpace(0)
        try expect(sleeping.dropFirst().allSatisfy { $0.webView == nil }, "Interaction woke untouched restored pages")
        // Metadata searches use fake icons, so no external favicon service is contacted.
        suggestions.knownFavicon = { _ in NSImage(size: NSSize(width:16,height:16)) }
        homeSearchField.abortEditing(); addressField.abortEditing()
        a.saved = SavedBrowserSpace(id:a.saved.id,name:a.saved.name,chromeDirectory:nil,bookmarks:[],history:[
            BrowserLink(title:"Site A",url:"https://site.example/a",visitedAt:Date().addingTimeInterval(-60))])
        b.saved = SavedBrowserSpace(id:b.saved.id,name:b.saved.name,chromeDirectory:nil,bookmarks:[],history:[
            BrowserLink(title:"Private only",url:"https://site.example/b",visitedAt:Date())])
        addressField.stringValue = "private only"; presentSuggestions(for:addressField); await suggestionTask?.value
        try expect(suggestions.selected() == nil,"An isolated profile leaked another profile's suggestion")
        addressField.stringValue = "site.example"; presentSuggestions(for:addressField); await suggestionTask?.value
        try expect(suggestions.selected()?.profileID == a.saved.id && suggestions.selectedIndex == 0,"Isolated suggestions or initial highlight failed")
        BrowserExperiment.cyclesNewTabProfiles = true; experimentalModeChanged()
        addressField.stringValue = "site.example"; presentSuggestions(for:addressField); await suggestionTask?.value
        try expect(suggestions.selected()?.profileID == b.saved.id,"Fuse lost recency or profile routing")
        BrowserExperiment.cyclesNewTabProfiles = false; experimentalModeChanged()
        var links: [BrowserLink] = []
        for index in 0..<10000 {
            links.append(BrowserLink(title:"Fixture article \(index)",url:"https://site.example/item/\(index)",visitedAt:Date().addingTimeInterval(-Double(index))))
        }
        a.saved = SavedBrowserSpace(id:a.saved.id,name:a.saved.name,chromeDirectory:nil,bookmarks:[],history:links)
        var suggestionTimes: [Double] = []
        var suggestionMainTimes:[Double]=[]
        for query in ["f","fi","fix","fixture","fixture article 9","fixture article 99","fixture article 999","site","site.example"] {
            addressField.stringValue=query
            let began=ProcessInfo.processInfo.systemUptime
            presentSuggestions(for:addressField)
            suggestionMainTimes.append((ProcessInfo.processInfo.systemUptime-began)*1000)
            await suggestionTask?.value
            suggestionTimes.append((ProcessInfo.processInfo.systemUptime-began)*1000)
            try expect(suggestions.selectedIndex == 0,"Typing lost automatic first selection")
        }
        addressField.stringValue="fixture article 99";presentSuggestions(for:addressField)
        try expect(suggestions.selected()==nil,"Old query remains selectable while new results are pending")
        addressField.stringValue="no-match-final-query";presentSuggestions(for:addressField)
        await suggestionTask?.value
        try expect(suggestions.selected()==nil && suggestionCompletedGeneration==suggestionGeneration,"Cancelled query overrode the latest result")
        addressField.stringValue="fixture";presentSuggestions(for:addressField);closeSuggestions()
        try await Task.sleep(nanoseconds:30_000_000)
        try expect(!suggestions.isShown,"A dismissed query reopened the popup")
        closeSuggestions()
        try await verifyMotionPrimitives()
        try await verifyChatGPTWidget(base:base)
        try verifyWallpaperPresentation()
        try expect(CodexAppTransport.startArguments()==["app-server","daemon","start"],"Codex fallback must use the shared daemon, never a private server")
        try expect(CodexAppData.link("invalid") == nil,"Codex link accepted an invalid chat id")
        try await verifyMiniWebby(base:base)
        try await verifyGeist(base:base)
        try await verifyVideoPresentation(base:base)
        try await verifyChromeTone(base:base)
        try await verifyProfileMotion()
        try await verifyLinkOpening(base:base)
        func p95(_ values: [Double]) -> Double { let a=values.sorted(); return a[max(0,min(a.count-1,Int(ceil(Double(a.count)*0.95))-1))] }
        var result: [String: Any] = [:]
        result["passed"] = true
        result["restoredTabs"] = 80
        result["untouchedTabsStillUnloaded"] = 79
        result["slowPageRevealSeconds"] = timing.presented! - timing.started
        result["slowPageFinishSeconds"] = timing.finished! - timing.started
        result["verticalSelectionCPUp95Ms"] = p95(topTimes)
        result["horizontalSelectionCPUp95Ms"] = p95(horizontalTimes)
        result["selectionSamplesPerLayout"] = 45
        result["rawSelectionMs"] = ["vertical":topTimes,"horizontal":horizontalTimes]
        result["percentileConvention"] = "nearest-rank ceil(n * 0.95) - 1"
        result["profileOwnershipPreserved"] = true
        result["suggestionCorpusSize"] = 10000
        result["optimization"]=Bundle.main.object(forInfoDictionaryKey:"WebbyTestOptimization") ?? "unknown"
        result["suggestionMainThreadP95Ms"]=p95(suggestionMainTimes)
        result["suggestionMainThreadMaxMs"]=suggestionMainTimes.max()!
        result["suggestionWorkP95Ms"] = p95(suggestionTimes)
        result["suggestionColdIndexMs"] = suggestionTimes.first!
        result["suggestionWarmP95Ms"] = p95(Array(suggestionTimes.dropFirst()))
        result["suggestionWorkMaxMs"] = suggestionTimes.max()!
        result["tested"] = ["profile-isolated suggestions", "Fuse suggestions", "10000-entry history", "automatic first suggestion", "lazy pinned restore", "pinned discard preserves pin", "four-pane geometry", "navigation failure", "theme notification path", "lazy restore","early reveal","redirect","dirty form","clean discard/resume","capture exclusion","floating exclusion","keep loaded","embedded app exclusion","stale callbacks","IDE split","Fuse","profile switch"]
        try JSONSerialization.data(withJSONObject: result, options:[.prettyPrinted,.sortedKeys]).write(to: output)
        if ProcessInfo.processInfo.environment["WEBBY_TEST_WORKBENCH"] == "1" {
            try await CodeWorkbench.verifyWorkbench(project: output.deletingLastPathComponent().appendingPathComponent("ide-fixture"), screenshot: output.deletingLastPathComponent().appendingPathComponent("workbench-native.png"))
        }
        print("Browser integration checks passed. Report: \(output.path)")
        exit(0)
    }
    private func verifyMotionPrimitives() async throws {
        let host=NSWindow(contentRect:NSRect(x:50,y:50,width:520,height:320),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        host.isReleasedWhenClosed=false
        let root=NSView(frame:NSRect(x:0,y:0,width:520,height:320));root.wantsLayer=true;host.contentView=root
        let pane=NSView(frame:NSRect(x:0,y:0,width:500,height:280));pane.wantsLayer=true;root.addSubview(pane)
        host.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        defer{host.close()}
        try await Task.sleep(nanoseconds:80_000_000)
        let before=Motion.capture([pane],in:root)
        pane.frame=NSRect(x:260,y:0,width:240,height:280)
        let final=pane.frame
        Motion.settle(before,views:[pane],in:root,character:.split)
        try expect(pane.frame==final,"Split animation mutated the model geometry")
        if Motion.enabled && host.occlusionState.contains(.visible) {try expect(pane.layer?.animation(forKey:"webbyGeometry") != nil,"Split geometry spring missing")}
        let interrupted=Motion.capture([pane],in:root);pane.frame=NSRect(x:0,y:0,width:500,height:280)
        Motion.settle(interrupted,views:[pane],in:root,character:.split)
        Motion.interact(pane)
        try expect(pane.layer?.animation(forKey:"webbyGeometry")==nil,"Drag did not cancel settling motion")
        let card=NSView(frame:NSRect(x:12,y:12,width:120,height:50));card.wantsLayer=true;root.addSubview(card)
        Motion.depart(card,character:.widget);card.removeFromSuperview()
        try await Task.sleep(nanoseconds:350_000_000)
        try expect(root.subviews.count==1,"Removal animation leaked a ghost overlay")
        pane.alphaValue=0.35;Motion.reveal(pane,character:.widget)
        if Motion.enabled && host.occlusionState.contains(.visible),let animation=pane.layer?.animation(forKey:"opacity") as? CABasicAnimation {
            try expect(abs(((animation.toValue as? NSNumber)?.doubleValue ?? -1)-0.35)<0.001,"Reveal overrides the user's transparency")
        }
        Motion.interact(pane)
        root.isHidden=true;Motion.reveal(pane,character:.widget)
        try expect(pane.layer?.animation(forKey:"webbyReveal")==nil,"Hidden surface started a reveal animation")
        print("PASS: compositor geometry, split interruption, direct drag cancellation, ghost cleanup, hidden motion suppression")
    }

    private func verifyChatGPTWidget(base:String) async throws {
        let prompt="Explain a & b? #c + café 😀"
        let route=ChatGPTWidgetRoute.url(prompt:prompt,hasImages:false)
        try expect(URLComponents(url:route,resolvingAgainstBaseURL:false)?.queryItems?.first?.value==prompt,"ChatGPT URL handoff lost prompt characters")
        try expect(route.absoluteString.contains("%2B"),"ChatGPT prompt plus became a space")
        try expect(ChatGPTWidgetRoute.url(prompt:prompt,hasImages:true).query==nil,"Attachment draft can race a native prompt submission")
        let target=try await loadFixture("/chatgpt",base:base)
        guard let view=target.webView,let path=Bundle.main.path(forResource:"ChatGPTWidget",ofType:"js") else {throw PerformanceTestFailure(message:"ChatGPT widget script missing")}
        _ = try await view.evaluateJavaScript("document.getElementById('prompt-textarea').id='mobile-composer-prompt'")
        let script=try String(contentsOfFile:path,encoding:.utf8).replacingOccurrences(of:"if (location.hostname !== 'chatgpt.com') return false;",with:"")
        let result:Any?=try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Any?,Error>) in
            view.callAsyncJavaScript(script,arguments:["draft":["text":"Test a / (b^2 + 4)","images":[["name":"test.png","data":"iVBORw0KGgo="]]]],in:nil,in:.page){result in
                switch result {case .success(let value):continuation.resume(returning:value);case .failure(let error):continuation.resume(throwing:error)}
            }
        }
        if result as? Bool != true {print("CHATGPT fixture",result as Any,try await view.evaluateJavaScript("document.body.innerHTML"))}
        try expect(result as? Bool==true,"ChatGPT handoff did not submit")
        let text=try await view.evaluateJavaScript("window.sent.text") as? String
        let count=try await view.evaluateJavaScript("window.sent.files.length") as? Int
        try expect(text=="Test a / (b^2 + 4)" && count==1,"ChatGPT prompt or image lost during handoff")
        print("PASS: ChatGPT widget prompt entry, File/DataTransfer image handoff, ready-state auto-submit")
    }

    private func verifyWallpaperPresentation() throws {
        let suffix=activeSpace.saved.id.uuidString
        let keys=["webbyWallpaperFullWindow.","webbyWallpaperTabBlurScope.","webbyWallpaperTabBlurStrength."].map{$0+suffix}
        let previous=keys.map{UserDefaults.standard.object(forKey:$0)}
        defer {for(i,key) in keys.enumerated(){if let value=previous[i]{UserDefaults.standard.set(value,forKey:key)}else{UserDefaults.standard.removeObject(forKey:key)}};applyWallpaperPresentation()}
        UserDefaults.standard.set(true,forKey:keys[0]);UserDefaults.standard.set(0,forKey:keys[1]);UserDefaults.standard.set(0.6,forKey:keys[2]);applyWallpaperPresentation()
        try expect(wallpaper.superview === content,"Full-window wallpaper did not extend behind chrome")
        try expect(wallpaperWindowBackdrop?.blendingMode == .behindWindow && mainBackdrop.isHidden,"Window transparency is tinting the wallpaper instead of revealing desktop glass")
        try expect(abs((wallpaperWindowBackdrop?.alphaValue ?? -1)-(1-BrowserGlass.backgroundTransparency))<0.001,"Desktop glass ignores window transparency")
        try expect(abs(mainBackdrop.alphaValue-(1-BrowserGlass.backgroundTransparency))<0.001 && sidebarBackdrop.alphaValue==0,"Tabs-only blur still frosts the entire pane")
        for row in tabRows.values {try expect(row.subviews.contains{$0 is WallpaperTabFrost && !$0.isHidden},"Individual tab frost missing")}
        UserDefaults.standard.set(1,forKey:keys[1]);applyWallpaperPresentation()
        try expect(abs(sidebarBackdrop.alphaValue-0.6*(1-BrowserGlass.sidebarTransparency*0.86))<0.001 && sidebarBackdrop.blendingMode == .withinWindow,"Pane frost does not sample the wallpaper")
        UserDefaults.standard.set(false,forKey:keys[0]);applyWallpaperPresentation()
        try expect(wallpaper.superview === pageArea,"Disabling full-window wallpaper did not restore the canvas")
        print("PASS: full-window wallpaper reparenting, individual-tab and pane frost, adjustable strength, reversible defaults")
    }

    private func verifyMiniWebby(base:String) async throws {
        let archive=MiniWebbyArchive.entries
        defer {MiniWebbyArchive.entries=archive;for id in Array(miniTabs.keys){closeMiniWebby(id,restoreFocus:false)}}
        let originalID=activeTabID
        let owner=activeSpace.saved.id
        let other=spaces.first{$0.saved.id != owner}!.saved.id
        let originalCount=spaces.flatMap(\.tabs).count
        let mini=openMiniWebby(url:URL(string:base+"/form")!,profile:owner)
        try await waitFor("Mini page failed") {mini.navigationTiming.finished != nil}
        try expect(activeTabID==originalID && spaces.flatMap(\.tabs).count==originalCount,"Mini lookup changed the main tab selection")
        try expect(!visibleSidebarTabs.contains{$0.id==mini.id} && mini.isFloating,"Mini window appeared in tab strip")
        let host=floatingWindows[mini.id] as! MiniWebbyWindow
        try expect(host.contentHost.subviews.contains(where:{$0===mini.webView}),"Mini page is not hosted in mini window")
        if let root=host.contentView,let bitmap=root.bitmapImageRepForCachingDisplay(in:root.bounds) {
            root.cacheDisplay(in:root.bounds,to:bitmap)
            if let png=bitmap.representation(using:.png,properties:[:]) {try png.write(to:URL(fileURLWithPath:"/private/tmp/mini-webby-preview.png"))}
        }
        let source=mini.webView!
        try await source.callAsyncJavaScript("document.getElementById('editor').value='keep this draft';document.getElementById('editor').dispatchEvent(new Event('input',{bubbles:true}));return true",arguments:[:],in:nil,in:.page)
        try await waitFor("Mini form edits were not protected"){mini.hasUnsavedEdits}
        host.lastUsed = .distantPast;host.orderBack(nil);expireMiniWebby(mini.id,hours:6)
        try expect(miniTabs[mini.id] != nil,"Auto-close discarded an edited form")
        source.configuration.preferences.javaScriptCanOpenWindowsAutomatically=true
        let old=Set(miniTabs.keys)
        _ = try await source.evaluateJavaScript("window.open('/plain?mini-popup=1','_blank');true")
        try await waitFor("Mini popup did not open") {self.miniTabs.values.contains{!old.contains($0.id) && $0.navigationTiming.finished != nil}}
        let popup=miniTabs.values.first{!old.contains($0.id)}!
        try expect(popup.webView!.configuration.userContentController === source.configuration.userContentController && popup.ownerSpaceID==owner,"Mini popup lost inherited configuration/account")
        closeMiniWebby(popup.id,restoreFocus:false)
        promoteMiniWebby(mini.id,destination:other)
        try expect(miniTabs[mini.id]==nil && mini.webView === source && !mini.isFloating,"Promotion recreated the page or retained mini state")
        try expect(ownerSpace(for:mini).saved.id==owner && displaySpace(for:mini).saved.id==other,"Promotion switched account rather than display profile")
        let draft=try await source.evaluateJavaScript("document.getElementById('editor').value") as? String
        try expect(draft=="keep this draft","Promotion lost form state")
        let closing=openMiniWebby(url:URL(string:base+"/plain?archive=1")!,profile:owner)
        try await waitFor("Archive fixture failed"){closing.navigationTiming.finished != nil}
        closeMiniWebby(closing.id,restoreFocus:false)
        try expect(tab(id:closing.id)==nil && MiniWebbyArchive.entries.first?.profile==owner,"Mini close retained view or lost archive account")
        let blank=openMiniWebby(profile:owner)
        try expect(blank.webView==nil,"Blank mini eagerly started WebKit")
        guard let blankHost=floatingWindows[blank.id] as? MiniWebbyWindow else {throw PerformanceTestFailure(message:"Blank mini window missing")}
        blankHost.contentView?.layoutSubtreeIfNeeded()
        let field=blankHost.addressField
        try expect(field.isEditable && field.isSelectable && field.isEnabled,"Mini search field is not editable")
        try expect(blankHost.makeFirstResponder(field),"Mini search cannot receive focus")
        guard let editor=field.currentEditor() as? NSTextView else {throw PerformanceTestFailure(message:"Mini search did not create a typing editor")}
        editor.insertText("typing check",replacementRange:NSRange(location:NSNotFound,length:0))
        try expect(editor.string=="typing check","Mini search rejected typing")
        editor.selectAll(nil);editor.insertText("",replacementRange:NSRange(location:NSNotFound,length:0))

        blankHost.makeKeyAndOrderFront(nil)
        try await waitFor("Mini did not become key for toggle check"){blankHost.isKeyWindow}
        let miniCount=miniTabs.count
        toggleMiniWebby()
        try expect(!blankHost.isVisible && miniTabs[blank.id] === blank,"Shortcut hid or discarded the wrong Mini page")
        toggleMiniWebby()
        try expect(blankHost.isVisible && miniTabs.count==miniCount,"Shortcut reopened a duplicate Mini window")
        try await waitFor("Reopened Mini did not receive focus"){blankHost.isKeyWindow}
        toggleMiniWebby();toggleMiniWebby()
        try expect(blankHost.isVisible && miniTabs.count==miniCount,"Repeated shortcut toggles leaked Mini windows")
        let compactSize=blankHost.frame.size
        let expandedHost=MiniWebbyWindow(tabID:UUID(),profiles:[(owner,"Fixture")],owner:owner,screen:blankHost.screen)
        expandedHost.expand()
        blankHost.positionForSwitch(from:expandedHost)
        try expect(blankHost.frame.size==compactSize,"Switching from a website enlarged the new-tab window")
        expandedHost.close()
        let sameAccount=openMiniWebby()
        try expect(sameAccount.ownerSpaceID==owner,"New mini changed the current mini account")
        closeMiniWebby(sameAccount.id,restoreFocus:false)
        closeMiniWebby(blank.id,restoreFocus:false)
        let settings=MiniWebbySettings();let menu=settings.menu()
        try expect(menu.items.contains{$0.title=="Change Shortcut…"},"Mini shortcut setting missing")
        let key=MiniWebbyHotKey();let registered=key.register(code:49,modifiers:2048);key.stop()
        print("Mini default Option-Space global registration:",registered ? "available":"occupied (settings exposes conflict)")
        print("PASS: tabless mini, stable main selection, account ownership, protected draft, inherited popup, live promotion, archive, lazy blank, shortcut configuration")
    }

    private func verifyGeist(base:String) async throws {
        let saved=UserDefaults.standard.object(forKey:"webbyGeistEnabled")
        defer {if let saved {UserDefaults.standard.set(saved,forKey:"webbyGeistEnabled")}else{UserDefaults.standard.removeObject(forKey:"webbyGeistEnabled")};geistChanged()}
        GlassPageInjector.geistEnabled=true
        let regular=WebbyTypography.font(ofSize:14)
        let bold=WebbyTypography.font(ofSize:14,weight:.bold)
        try expect(regular.familyName=="Geist" && bold.familyName=="Geist" && regular.fontName != bold.fontName,"Native Geist registration or weights failed")
        let native=NSView(),label=NSTextField(labelWithString:"Webby"),code=NSTextField(labelWithString:"let value = 42")
        label.font=bold;code.font = .monospacedSystemFont(ofSize:13,weight:.regular)
        native.addSubview(label);native.addSubview(code)
        let codeName=code.font?.fontName
        GlassPageInjector.geistEnabled=false;WebbyTypography.apply(to:native)
        try expect(label.font?.familyName != "Geist" && code.font?.fontName==codeName,"Native font toggle changed code or failed to restore system text")
        GlassPageInjector.geistEnabled=true;WebbyTypography.apply(to:native)
        try expect(label.font?.familyName=="Geist" && label.font?.pointSize==14 && code.font?.fontName==codeName,"Native font toggle lost size or monospace preservation")
        let controller=WKUserContentController()
        GlassPageInjector.installGeist(into:controller)
        GlassPageInjector.installGeist(into:controller)
        GlassPageInjector.installGeist(into:controller,replace:true)
        let fontScripts=controller.userScripts.filter{$0.source.hasPrefix("/* Webby local Geist v1 */")}
        try expect(fontScripts.count==1 && fontScripts[0].source.utf8.count<8192,"Typography startup payload grew or handlers duplicated")
        print("TYPOGRAPHY document-start bytes",fontScripts[0].source.utf8.count)
        let tab=try await loadFixture("/geist",base:base)
        guard let view=tab.webView else{throw PerformanceTestFailure(message:"Geist fixture missing")}
        var loaded=false
        for _ in 0..<80 {
            loaded=(try await view.evaluateJavaScript("document.fonts.check('16px \"Webby Geist\"') && getComputedStyle(document.getElementById('geist-text')).fontFamily.includes('Webby Geist')")) as? Bool ?? false
            if loaded {break};try await Task.sleep(nanoseconds:50_000_000)
        }
        try expect(loaded,"Bundled Geist failed to load on a CSP-restricted page")
        let preserved=try await view.evaluateJavaScript("!getComputedStyle(document.getElementById('geist-code')).fontFamily.includes('Webby Geist') && !getComputedStyle(document.getElementById('geist-icon')).fontFamily.includes('Webby Geist')") as? Bool
        try expect(preserved==true,"Geist overwrote code or icon fonts")
        let dynamic=try await view.evaluateJavaScript("document.getElementById('geist-input').value='keep draft';const p=document.createElement('p');p.textContent='new content';document.body.appendChild(p);getComputedStyle(p).fontFamily.includes('Webby Geist')") as? Bool
        try expect(dynamic==true,"New page content did not inherit Geist")
        GlassPageInjector.geistEnabled=false;geistChanged()
        let disabledController=WKUserContentController()
        GlassPageInjector.installGeist(into:disabledController)
        try expect(disabledController.userScripts.isEmpty,"Disabled website typography still injects the font payload")
        try await Task.sleep(nanoseconds:100_000_000)
        let off=try await view.evaluateJavaScript("!getComputedStyle(document.getElementById('geist-text')).fontFamily.includes('Webby Geist') && document.getElementById('geist-input').value==='keep draft'") as? Bool
        try expect(off==true,"Disabling Geist reloads the page or leaves the override applied")
        GlassPageInjector.geistEnabled=true;geistChanged()
        try await Task.sleep(nanoseconds:100_000_000)
        let on=try await view.evaluateJavaScript("getComputedStyle(document.getElementById('geist-text')).fontFamily.includes('Webby Geist')") as? Bool
        try expect(on==true,"Reenabling Geist failed")
        print("PASS: bundled local Geist, restrictive CSP, dynamic text, preserved code/icons, live toggle and retained draft")
    }

    private func verifyFastLoading(base:String,output:URL) async throws {
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        let oldRule=fastRule,oldEnabled=fastModeEnabled
        defer {fastRule=oldRule;fastModeEnabled=oldEnabled;if let oldRule {applyFastRule(oldRule)}}
        fastModeEnabled=false
        let unblocked=try await loadFixture("/plain?warm-network-process",base:base)
        navigate(base+"/tracking-page?plain",in:unblocked)
        try await waitFor("Warm unblocked fixture failed") {unblocked.navigationTiming.finished != nil}
        let regular=unblocked.navigationTiming.finished!-unblocked.navigationTiming.started
        let originalView=unblocked.webView!
        _ = try await originalView.evaluateJavaScript("document.querySelector('textarea').value='keep my draft';true")
        let owner=ownerSpace(for:unblocked).saved.id
        let rules="[{\"trigger\":{\"url-filter\":\".*/tracking-slow\\\\.js\"},\"action\":{\"type\":\"block\"}}]"
        let rule:WKContentRuleList=try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier:"WebbyFixtureFastRules",encodedContentRuleList:rules) { rule,error in
                if let rule {continuation.resume(returning:rule)} else {continuation.resume(throwing:error ?? PerformanceTestFailure(message:"Rule compile failed"))}
            }
        }
        fastRule=rule;fastModeEnabled=true
        applyFastRule(rule);applyFastRule(rule)
        try expect(unblocked.webView === originalView && ownerSpace(for:unblocked).saved.id==owner,"Late blocker changed view or account")
        let draft=try await originalView.evaluateJavaScript("document.querySelector('textarea').value") as? String
        try expect(draft=="keep my draft","Late blocker reloaded an editor")
        // Navigate the existing view: this specifically tests late rule attachment.
        unblocked.navigationTiming=BrowserNavigationTiming()
        unblocked.navigationInProgress=true
        unblocked.currentNavigation=originalView.load(URLRequest(url:URL(string:base+"/tracking-page?blocked")!))
        try await waitFor("Blocked fixture failed to finish") {unblocked.navigationTiming.finished != nil}
        let blocked=unblocked.navigationTiming.finished!-unblocked.navigationTiming.started
        let status=try await originalView.evaluateJavaScript("window.trackerRan===true") as? Bool
        try expect(status==false,"Existing view missed compiled blocker")
        try expect(blocked<regular,"Blocking failed to remove simulated tracker load delay")
        fastModeEnabled=false;applyFastRule(rule)
        let data:[String:Any]=["passed":true,"unblockedLoadSeconds":regular,"blockedLoadSeconds":blocked,"preservedDraft":true,"existingViewUpdated":true]
        try JSONSerialization.data(withJSONObject:data,options:[.prettyPrinted,.sortedKeys]).write(to:output)
        print("PASS: late compiled rule attachment, idempotence, account/draft preservation, tracker load removed; \(regular)s -> \(blocked)s")
    }

    private func verifyChromeTone(base:String) async throws {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        let edgeMatch=BrowserGlass.matchWebsiteEdge
        BrowserGlass.matchWebsiteEdge=true
        defer {BrowserGlass.matchWebsiteEdge=edgeMatch}
        let glass=BrowserGlass.pageInjectionEnabled
        BrowserGlass.pageInjectionEnabled=false
        defer {BrowserGlass.pageInjectionEnabled=glass}
        BrowserTabPlacement.current = .horizontal;configureHorizontalTabs()
        let target=try await loadFixture("/tone",base:base)
        let view=target.webView!
        func matches(_ rgb:[Double]) -> Bool {
            guard let c=pageChromeColors[target.id]?.usingColorSpace(.deviceRGB) else{return false}
            if activeTabID == target.id {
                guard let backdrop=(BrowserTabPlacement.current == .horizontal ? websiteEdgeBackdrop : sidebarEdgeBackdrop), !backdrop.isHidden, let sampled=pageChromeColors[target.id], backdrop.layer?.backgroundColor == sampled.cgColor else {return false}
            }
            return abs(c.redComponent*255-rgb[0])<2 && abs(c.greenComponent*255-rgb[1])<2 && abs(c.blueComponent*255-rgb[2])<2
        }
        try await waitFor("Initial top-edge color failed") {matches([40,80,120])}
        func addressMatchesTop() -> Bool {
            guard let backdrop=addressEdgeBackdrop,!backdrop.isHidden,let color=pageAddressColors[target.id] else{return false}
            return backdrop.layer?.backgroundColor == color.cgColor
        }
        try await waitFor("Address header did not match top edge") {addressMatchesTop()}

        let count=view.configuration.userContentController.userScripts.count
        BrowserChromeTone.install(into:view.configuration,handler:self)
        try expect(count == view.configuration.userContentController.userScripts.count,"Color probe duplicated popup handlers")
        _ = try await view.evaluateJavaScript("document.getElementById('tone').className='changed'; true")
        try await waitFor("Header theme mutation did not update tab") {matches([180,60,30])}
        if Motion.enabled {
            try expect(websiteEdgeBackdrop?.layer?.animation(forKey:"webbyChromeColor") != nil,"Horizontal color changed without an animation")
        }
        _ = try await view.evaluateJavaScript("document.getElementById('tone').style.opacity='0.5'; true")
        try await waitFor("Transparent header did not composite over page") {matches([101,48,40])}
        _ = try await view.evaluateJavaScript("document.getElementById('tone').style.opacity='1';window.scrollTo(0,500);true")
        try await waitFor("Sticky header scroll lost its color") {matches([180,60,30])}
        addTab(select:true)
        try expect(websiteEdgeBackdrop?.isHidden != false,"Homepage wallpaper was covered by horizontal edge matching")
        try expect(addressEdgeBackdrop?.isHidden != false,"Homepage wallpaper was covered by address header")
        BrowserTabPlacement.current = .top; configureHorizontalTabs()
        try expect(sidebarEdgeBackdrop?.isHidden != false,"Homepage wallpaper was covered by vertical edge matching")
        BrowserTabPlacement.current = .horizontal; configureHorizontalTabs()
        _ = try await view.evaluateJavaScript("document.getElementById('tone').className='';true")
        try await Task.sleep(nanoseconds:250_000_000)
        try expect(matches([180,60,30]),"Background tab kept sampling or changed active color")
        activeTabID=nil;selectTab(target)
        try await waitFor("Reselection did not refresh current color") {matches([40,80,120])}
        BrowserTabPlacement.current = .top; configureHorizontalTabs()
        try await waitFor("Vertical sidebar did not sample webpage left edge") { matches([21,35,49]) }
        try await waitFor("Vertical address header incorrectly used sidebar color") {addressMatchesTop() && pageAddressColors[target.id] != pageChromeColors[target.id]}
        _ = try await view.evaluateJavaScript("document.body.style.setProperty('background','rgb(220,230,240)','important');true")
        try await waitFor("Vertical sidebar did not follow left-edge mutation") { matches([220,230,240]) }
        if Motion.enabled {
            try expect(sidebarEdgeBackdrop?.layer?.animation(forKey:"webbyChromeColor") != nil,"Vertical color changed without an animation")
        }
        try expect(websiteEdgeBackdrop?.isHidden==true,"Horizontal edge backdrop remained in vertical mode")
        BrowserTabPlacement.current = .horizontal; configureHorizontalTabs()
        try await waitFor("Switching back to horizontal did not restore top-edge sampling") { matches([40,80,120]) }
        try expect(sidebarEdgeBackdrop?.isHidden==true,"Sidebar color remained after layout change")
        BrowserGlass.matchWebsiteEdge=false
        glassChanged() // Harness constructs the window without launch-time notification observers.
        try expect(websiteEdgeBackdrop?.isHidden==true,"Disabled edge matching left a colored bar")
        try expect(addressEdgeBackdrop?.isHidden != false,"Disabled matching left address background")
        BrowserTabPlacement.current = .top;configureHorizontalTabs()
        print("PASS: website-edge bar matching, live top-edge color, header mutations, alpha compositing, sticky scroll, inactive suspension, reselection, handler idempotence")
    }

    private func verifyProfileMotion() async throws {
        let host=NSView(frame:NSRect(x:0,y:0,width:300,height:320))
        let surface=NSView(frame:NSRect(x:0,y:0,width:280,height:300))
        surface.wantsLayer=true;host.addSubview(surface)
        let motion=ProfileSwitchMotion()
        let original=surface.frame
        motion.beginTracking(surface);motion.track(surface,distance:80)
        if Motion.enabled {
            let offset=(surface.layer!.value(forKeyPath:"transform.translation.x") as! NSNumber).doubleValue
            try expect(offset>0 && offset<80,"Gesture does not follow bounded finger displacement")
        }
        motion.cancel()
        motion.prepare(surface);motion.finish(direction:1)
        if Motion.enabled {try expect(surface.layer?.animation(forKey:"profileSlide") is CASpringAnimation,"Profile settle is not composited spring motion")}
        motion.prepare(surface);motion.finish(direction:-1)
        try expect(host.subviews.count<=2,"Rapid switching accumulated outgoing snapshots")
        motion.reset()
        try expect(surface.frame == original && host.subviews.count==1,"Profile motion altered layout or left an overlay")
        try expect((surface.layer!.value(forKeyPath:"transform.translation.x") as! NSNumber).doubleValue==0,"Cancelled swipe left a transformed view")
        motion.prepare(surface);motion.finish(direction:1)
        try await Task.sleep(nanoseconds:600_000_000)
        try expect(host.subviews.count==1,"Completed motion retained snapshot")
        print("PASS: finger tracking, cancellation, interrupted spring, snapshot cleanup, unchanged view geometry")
    }

    private func verifyDownloads(base:String,folder:URL) async throws {
        let source=try await loadFixture("/download-page",base:base)
        guard let view=source.webView else { throw PerformanceTestFailure(message:"Missing download web view") }
        for (index,link) in ["download","attribute","blank"].enumerated() {
            _ = try await view.evaluateJavaScript("document.getElementById('\(link)').click(); true")
            let name=index == 0 ? "webby-fixture.txt" : "webby-fixture \(index+1).txt"
            let destination=folder.appendingPathComponent(name)
            try await waitFor("Download did not finish: \(link)",timeout:20) {
                FileManager.default.fileExists(atPath:destination.path) && !self.downloads.hasActiveDownloads
            }
            let text=try String(contentsOf:destination,encoding:.utf8)
            try expect(text=="webby-integration-download\n","Download contents incorrect: \(link)")
        }
        _ = try await view.evaluateJavaScript("document.getElementById('once').click(); true")
        try await waitFor("One-use download failure was not reported",timeout:20) { self.downloads.widgetLines.contains { $0.contains("Failed:") } }
        try expect(!downloads.hasActiveDownloads,"Failed one-use download remained active")
        let foreignCookie=HTTPCookie(properties:[.domain:"localhost",.path:"/",.name:"webby_download_auth",.value:"ok"])!
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            view.configuration.websiteDataStore.httpCookieStore.setCookie(foreignCookie) { continuation.resume() }
        }
        let crossSite=base.replacingOccurrences(of:"127.0.0.1",with:"localhost")+"/download-fixture"
        let crossJS="(()=>{const a=document.createElement('a');a.href=\(String(data:try JSONEncoder().encode(crossSite),encoding:.utf8)!);a.download='cross.txt';document.body.append(a);a.click()})()"
        _ = try await view.evaluateJavaScript(crossJS)
        try await waitFor("Cross-site download did not reject the request without cookies",timeout:20) {
            self.downloads.widgetLines.filter { $0.contains("Failed:") }.count >= 2
        }
        try expect(!FileManager.default.fileExists(atPath:folder.appendingPathComponent("cross.txt").path),"Cross-site download unexpectedly received profile cookies")
        print("PASS: authenticated browser downloads, download attribute, target blank, duplicate names, one-use error, cross-site cookie isolation")
    }

    private func verifyLinkOpening(base:String) async throws {
        let source = try await loadFixture("/links",base:base)
        let view = source.webView!
        let profile = ownerSpace(for:source).saved.id
        let scripts = view.configuration.userContentController.userScripts.count
        BrowserPageActivity.install(into:view.configuration,handler:self)
        try expect(view.configuration.userContentController.userScripts.count == scripts,"Activity installation duplicated scripts")
        view.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        for iteration in 0..<4 {
            let before = Set(spaces.flatMap(\.tabs).map(\.id))
            let opener = activeTab!.webView!
            opener.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
            _ = try await opener.evaluateJavaScript("window.open('/links?nested=\(iteration)','_blank'); true")
            try await waitFor("Popup did not create a tab") { self.spaces.flatMap(\.tabs).contains { !before.contains($0.id) } }
            let created = spaces.flatMap(\.tabs).first { !before.contains($0.id) }!
            try await waitFor("Popup did not finish") { created.navigationTiming.finished != nil }
            try expect(created.id == activeTabID && created.webView != nil,"Foreground popup selected wrong view")
            try expect(ownerSpace(for:created).saved.id == profile,"Popup lost account ownership")
            try expect(created.webView!.configuration.userContentController === view.configuration.userContentController,"Popup replaced inherited controller")
            try expect(view.configuration.userContentController.userScripts.count == scripts,"Nested popup duplicated scripts")
        }
        activeTabID=nil;selectTab(source)
        for linkID in ["normal","blank"] {
            let before = Set(spaces.flatMap(\.tabs).map(\.id))
            let coordinates = try await view.evaluateJavaScript("(()=>{const r=document.getElementById('\(linkID)').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()") as! [Double]
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(view)
            let local=NSPoint(x:coordinates[0],y:view.isFlipped ? coordinates[1] : view.bounds.height-coordinates[1])
            let location=view.convert(local,to:nil)
            for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                let event=NSEvent.mouseEvent(with:type,location:location,modifierFlags:[.command],
                    timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,
                    eventNumber:1,clickCount:1,pressure:type == .leftMouseDown ? 1 : 0)!
                window.sendEvent(event)
            }
            try await waitFor("Command-click did not open a tab: "+linkID) { self.spaces.flatMap(\.tabs).contains { !before.contains($0.id) } }
            let opened = spaces.flatMap(\.tabs).first { !before.contains($0.id) }!
            try await waitFor("Command-click did not load") { opened.navigationTiming.finished != nil }
            try expect(spaces.flatMap(\.tabs).filter{!before.contains($0.id)}.count==1,"Command-click created duplicate tabs")
            try expect(opened.webView?.url?.query==(linkID=="normal" ? "normal=1":"blank=1"),"Command-click opened the wrong URL")
            try expect(view.url?.path=="/links","Command-click navigated the source page")
            try expect(activeTabID == source.id,"Command-click stole foreground selection")
            try expect(ownerSpace(for:opened).saved.id == profile,"Command-click lost profile")
            try expect(opened.groupID != nil && opened.groupID==source.groupID,"Same-site Command-click did not group its background tab")
            try await waitFor("Automatic website name missing") {self.tabGroups.first(where:{$0.id==source.groupID})?.name=="Fixture Site"}
            try expect(opened.webView?.isHidden==true && homeSearchField.currentEditor()==nil,"Background group stole page or search focus")
        }
        commandLinkIntent=(source.id,ProcessInfo.processInfo.systemUptime)
        let scriptBefore=Set(spaces.flatMap(\.tabs).map(\.id))
        _ = try await view.evaluateJavaScript("window.open('/plain?script-command=1','_blank');true")
        try await waitFor("Scripted Command-click did not open a tab") {self.spaces.flatMap(\.tabs).contains{!scriptBefore.contains($0.id)}}
        try expect(activeTabID==source.id,"Scripted Command-click stole selection")
        commandLinkIntent=nil
        let before = Set(spaces.flatMap(\.tabs).map(\.id))
        _ = try await view.evaluateJavaScript("document.getElementById('blank').click(); true")
        try await waitFor("Target blank link failed") { self.spaces.flatMap(\.tabs).contains { !before.contains($0.id) } }
        let blank = spaces.flatMap(\.tabs).first { !before.contains($0.id) }!
        try await waitFor("Target blank load failed") { blank.navigationTiming.finished != nil }
        activeTabID=nil;selectTab(source)
        _ = try await view.evaluateJavaScript("document.getElementById('normal').click(); true")
        try await waitFor("Same-tab link failed") { view.url?.query == "normal=1" && !source.navigationInProgress }
        goBack()
        try await waitFor("Back navigation failed") { view.url?.path == "/links" && source.navigationTiming.finished != nil && view.canGoForward }
        goForward()
        try await waitFor("Forward navigation failed") { view.url?.query == "normal=1" && source.navigationTiming.finished != nil }
        _ = try await blank.webView!.evaluateJavaScript("window.close(); true")
        try await waitFor("Script-closed popup remains registered") { self.tab(id:blank.id) == nil }
        SitePermission.set(2,for:.popups,host:"127.0.0.1",profile:profile)
        let blockedCount=spaces.flatMap(\.tabs).count
        let rejected=try await view.evaluateJavaScript("window.open('/links?blocked=1','_blank') === null") as? Bool
        try expect(rejected == true && spaces.flatMap(\.tabs).count == blockedCount,"Blocked popup created a tab")
        SitePermission.set(0,for:.popups,host:"127.0.0.1",profile:profile)
        let sourceSpace=displaySpace(for:source)
        let otherIndex=spaces.firstIndex { $0.saved.id != sourceSpace.saved.id }!
        switchToSpace(otherIndex)
        let otherActive=activeTabID
        let beforeHidden=Set(spaces.flatMap(\.tabs).map(\.id))
        _ = try await view.evaluateJavaScript("window.open('/links?hidden=1','_blank'); true")
        try await waitFor("Hidden-profile popup did not load") { self.spaces.flatMap(\.tabs).contains { !beforeHidden.contains($0.id) && $0.navigationTiming.finished != nil } }
        let hidden=spaces.flatMap(\.tabs).first { !beforeHidden.contains($0.id) }!
        try expect(activeTabID == otherActive && hidden.webView!.isHidden,"Hidden profile popup took over current profile")
        try expect(displaySpace(for:hidden) === sourceSpace && ownerSpace(for:hidden).saved.id == profile,"Hidden profile popup lost placement or owner")
        BrowserExperiment.cyclesNewTabProfiles = true;experimentalModeChanged()
        activeTabID=nil;selectTab(source)
        let beforeFuse=Set(spaces.flatMap(\.tabs).map(\.id))
        _ = try await view.evaluateJavaScript("window.open('/links?fuse=1','_blank'); true")
        try await waitFor("Fuse popup failed") { self.spaces.flatMap(\.tabs).contains { !beforeFuse.contains($0.id) && $0.navigationTiming.finished != nil } }
        let fused=spaces.flatMap(\.tabs).first { !beforeFuse.contains($0.id) }!
        try expect(ownerSpace(for:fused).saved.id == profile && fusedTabOrder.contains(fused.id),"Fuse popup lost profile/order")
        BrowserExperiment.cyclesNewTabProfiles = false;experimentalModeChanged()
        print("PASS: idempotent activity install, native Command-click (normal/target-blank), target-blank, nested window.open, inherited controller/session, normal navigation, window.close, popup blocking, hidden profiles, Fuse")
    }

    static func launchPerformanceChecks(base: String, output: URL) {
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        let browser = BrowserApp()
        Task { @MainActor in
            do {
                if ProcessInfo.processInfo.environment["WEBBY_TEST_IDE_WIDGET"] == "1" {
                    try IDEProjectWidgetChecks.run(output:output.deletingLastPathComponent().appendingPathComponent("ide-design"));exit(0)
                }
                if ProcessInfo.processInfo.environment["WEBBY_TEST_WORKBENCH"] == "only" {
                    try await CodeWorkbench.verifyWorkbench(project: output.deletingLastPathComponent().appendingPathComponent("ide-fixture"), screenshot: output.deletingLastPathComponent().appendingPathComponent("workbench-native.png")); exit(0)
                }
                try await browser.runPerformanceChecks(base: base, output: output)
            }
            catch { print("Browser integration check failed: \(error)"); exit(1) }
        }
        app.run(); withExtendedLifetime(browser) {}
    }
}

extension BrowserApp {
    private func verifyHoverChrome() async throws {
        let placement=BrowserTabPlacement.current,visible=sidebarVisible
        let keys=["sidebarHidden","horizontalTabsHidden","webbyLinkGlancesEnabled"]
        let old=keys.map{UserDefaults.standard.object(forKey:$0)}
        defer {
            hoverDwell?.cancel();hoverTarget="";tabsRetreatTimer?.invalidate();tabsPeekToken+=1;tabsPeekVisible=false;tabsRetreating=false
            hideToolbar(animated:false)
            for (i,key) in keys.enumerated(){if let value=old[i]{UserDefaults.standard.set(value,forKey:key)}else{UserDefaults.standard.removeObject(forKey:key)}}
            BrowserTabPlacement.current=placement;sidebarVisible=visible;configureHorizontalTabs();content.layoutSubtreeIfNeeded()
        }
        BrowserTabPlacement.current = .top;sidebarVisible=false;UserDefaults.standard.set(true,forKey:"sidebarHidden")
        configureHorizontalTabs();content.layoutSubtreeIfNeeded()
        try expect(tabHoverRegion(horizontal:false).contains(NSPoint(x:2,y:content.bounds.midY)) && !tabHoverRegion(horizontal:false).contains(NSPoint(x:120,y:content.bounds.midY)),"Vertical reveal is not restricted to the outer edge")
        let vertical=pageArea.convert(pageArea.bounds,to:content)
        revealTabsFromEdge()
        try expect(!sidebar.isHidden && sidebarWidth.constant==238,"Hidden vertical tabs failed to reveal")
        let plus=sidebarNewTab.convert(sidebarNewTab.bounds,to:content)
        let toggle=sidebarRevealToggle.convert(sidebarRevealToggle.bounds,to:content)
        try expect(!sidebarRevealToggle.isHidden && sidebarToggleButton.isHidden && !plus.intersects(toggle) && abs(plus.midY-toggle.midY)<0.01,"Revealed New Tab covers the sidebar toggle")
        sidebarRevealToggle.performClick(nil)
        try expect(sidebarVisible && !tabsPeekVisible && !sidebarToggleButton.isHidden && sidebarRevealToggle.isHidden,"Revealed toggle cannot pin tabs open")
        sidebarToggleButton.performClick(nil)
        try expect(!sidebarVisible,"Sidebar toggle cannot collapse pinned tabs")
        if Motion.enabled && window.occlusionState.contains(.visible) {
            try expect(!chromeDepartures.isEmpty,"Explicit close has no outgoing glass animation")
            try expect(chromeDepartures.allSatisfy{$0.hitTest(.zero)==nil},"Closing chrome intercepts clicks")
        }
        try await Task.sleep(nanoseconds:270_000_000)
        try expect(chromeDepartures.allSatisfy{$0.superview==nil},"Closing chrome left a frozen overlay")
        toggleSidebar();toggleSidebar();toggleSidebar()
        try expect(sidebarVisible && chromeDepartures.isEmpty,"Rapid toggles left stale outgoing chrome")
        toggleSidebar()

        let homeHidden=homeView.isHidden
        homeView.isHidden=false;content.layoutSubtreeIfNeeded()
        toggleSidebar()
        if Motion.enabled && window.occlusionState.contains(.visible) {
            try expect(homeCenter.layer?.animation(forKey:"webbyGeometry") != nil,"Homepage search jumps instead of moving with layout")
            try expect(sidebarToggleButton.layer?.animation(forKey:"webbyGeometry") != nil,"Sidebar button jumps instead of moving with layout")
        }
        toggleSidebar();homeView.isHidden=homeHidden;content.layoutSubtreeIfNeeded()
        revealTabsFromEdge()
        try expect(pageArea.convert(pageArea.bounds,to:content)==vertical,"Vertical hover resized/repositioned the website")
        retreatTabs()
        try expect(!(sidebar.layer?.animation(forKey:"webbyEdgeReveal") is CASpringAnimation),"Exit still uses a bouncing spring")
        try expect(sidebar.layer?.animation(forKey:"webbyEdgeOpacity")?.isRemovedOnCompletion==false,"Exit can snap visible before hiding")
        revealTabsFromEdge()
        try await Task.sleep(nanoseconds:240_000_000)
        try expect(tabsPeekVisible && !tabsRetreating,"A cancelled retreat hid the re-entered sidebar")
        retreatTabs();try await Task.sleep(nanoseconds:240_000_000)
        try expect(sidebar.isHidden && pageArea.convert(pageArea.bounds,to:content)==vertical,"Vertical retreat changed page geometry")
        BrowserTabPlacement.current = .horizontal;UserDefaults.standard.set(true,forKey:"horizontalTabsHidden")
        configureHorizontalTabs();content.layoutSubtreeIfNeeded()
        try expect(tabHoverRegion(horizontal:true).contains(NSPoint(x:mainArea.frame.midX,y:content.bounds.maxY-2)) && !tabHoverRegion(horizontal:true).contains(NSPoint(x:mainArea.frame.midX,y:content.bounds.maxY-28)),"Horizontal reveal is not restricted to the top edge")
        let horizontal=pageArea.convert(pageArea.bounds,to:content)
        try expect(horizontalChrome.allSatisfy(\.isHidden) && pageAreaTop.constant==42,"Horizontal tabs cannot be put away")
        revealTabsFromEdge()
        try expect(horizontalChrome.allSatisfy{!$0.isHidden},"Hidden horizontal tabs failed to reveal")
        try expect(pageArea.convert(pageArea.bounds,to:content)==horizontal,"Horizontal hover resized the website")
        retreatTabs();try await Task.sleep(nanoseconds:240_000_000)
        try expect(horizontalChrome.allSatisfy(\.isHidden),"Horizontal tabs remained interactive after retreat")
        let responder=window.firstResponder
        showToolbar()
        try expect(toolbarVisible && window.firstResponder === responder,"Address reveal stole keyboard focus")
        toolbarHideTimerFired()
        try expect(toolbarVisible && !toolbar.isHidden,"Persistent address bar auto-dismissed")
        let popover=NSPopover();let controller=NSViewController();controller.view=NSView()
        let preview=WKWebView(frame:.zero,configuration:WKWebViewConfiguration());controller.view.addSubview(preview);popover.contentViewController=controller
        linkPreview=popover;linkPreviewWebView=preview;linkPreviewOwnerID=activeSpace.saved.id
        BrowserHoverPreferences.glancesEnabled=false;linkGlancesChanged()
        try expect(linkPreview==nil && linkPreviewWebView==nil && linkPreviewOwnerID==nil && preview.superview==nil,"Disabling glances left a hidden media webview alive")
        print("PASS: horizontal/vertical edge overlays preserve page geometry, retreat interruption, hover address focus, glance teardown")
    }
}

extension BrowserApp {
    private func verifyTabGlassShape() throws {
        let row=TabRow(tabID:UUID(),target:self);row.frame=NSRect(x:0,y:0,width:210,height:38)
        let frost=WallpaperTabFrost(frame:row.bounds);frost.wantsLayer=true;frost.autoresizingMask=[.width,.height];row.addSubview(frost)
        for width in [210.0,300.0] {
            row.frame.size.width=width
            row.update(title:"New Tab",selected:true,favicon:nil,splitFavicons:nil,isTerminal:false,isPinned:false,loadingProgress:nil)
            row.setHorizontal(pinned:false,color:.red);row.needsLayout=true;row.layoutSubtreeIfNeeded()
            guard let mask=frost.layer?.mask as? CAShapeLayer,let path=mask.path else{throw PerformanceTestFailure(message:"Horizontal tab glass has no shape mask")}
            try expect(path.contains(NSPoint(x:width/2,y:20)) && !path.contains(NSPoint(x:1,y:36)),"Tab glass protrudes into the shoulder cutout")
            for x in stride(from:0.5,to:width,by:3) {for y in stride(from:0.5,to:38.0,by:3) {
                let point=NSPoint(x:x,y:y)
                try expect(path.contains(point)==row.horizontalTabPath().contains(point),"Glass and tab silhouettes differ")
            }}
        }
        row.horizontal=false
        row.update(title:"Devpost",selected:false,favicon:nil,splitFavicons:nil,isTerminal:false,isPinned:false,loadingProgress:nil)
        row.needsLayout=true;row.layoutSubtreeIfNeeded()
        let short=row.verticalGlassRect()
        try expect(short.width<row.bounds.width*0.7 && short.height<row.bounds.height,"Vertical glass still fills the entire tab row")
        try expect((frost.layer?.mask as? CAShapeLayer)?.path?.boundingBoxOfPath==short,"Vertical glass does not follow the title-sized mask")
        row.update(title:"A very long title that needs truncation near the close button",selected:true,favicon:nil,splitFavicons:nil,isTerminal:false,isPinned:false,loadingProgress:nil)
        row.needsLayout=true;row.layoutSubtreeIfNeeded()
        try expect(row.verticalGlassRect().width>short.width && row.bounds.contains(row.verticalGlassRect()),"Vertical glass fails to grow safely with the title")
        print("PASS: horizontal glass follows the exact tab silhouette at multiple widths; vertical glass restored")
    }
}

// Verify real AppKit frames and the actual shared field, not a mock layout model.
extension BrowserApp {
    private func verifyAddressUX() async throws {
        try await waitFor("Address fixture has not presented its webpage") { self.activeTab?.showsSearchView == false && self.homeView.isHidden }
        let oldMode = BrowserAddressPlacement.current
        let oldTabs = BrowserTabPlacement.current
        let oldHidden = UserDefaults.standard.bool(forKey: "horizontalTabsHidden")
        defer {
            addressField.abortEditing();window.makeFirstResponder(activeWebView)
            BrowserAddressPlacement.current = oldMode; BrowserTabPlacement.current = oldTabs
            UserDefaults.standard.set(oldHidden, forKey: "horizontalTabsHidden")
            configureHorizontalTabs();applyAddressChrome()
        }
        for placement in [BrowserTabPlacement.top, .bottom, .horizontal] {
            BrowserTabPlacement.current = placement
            UserDefaults.standard.set(false, forKey: "horizontalTabsHidden")
            configureHorizontalTabs()
            for mode in BrowserAddressPlacement.allCases {
                BrowserAddressPlacement.current = mode; addressPlacementChanged()
                content.layoutSubtreeIfNeeded()
                let page = pageArea.convert(pageArea.bounds, to: mainArea)
                let chrome = toolbar.convert(toolbar.bounds, to: mainArea)
                try expect(!toolbar.isHidden && chrome.width >= 220, "Address chrome missing")
                try expect(!page.intersects(chrome), "Address chrome blocks website hit targets")
                try expect(chromeToggle.isHidden, "Old floating icon still covers page")
                try expect(toolbar.materialView.isHidden, "Second address panel still draws the white rim")
                if placement != .horizontal && mode == .strip {
                    let field = topAddressSurface.convert(topAddressSurface.bounds, to: content)
                    for view in [sidebarNewTab!, spaceLabel!, downloads.button, sidebarToggleButton!] {
                        let rect = view.convert(view.bounds, to: content)
                        try expect(abs(rect.midY - field.midY) < 0.5, "Sidebar header and address are vertically misaligned")
                    }
                    let header = sidebarNewTab.convert(sidebarNewTab.bounds, to: content)
                    let list = sidebarTabScroll.convert(sidebarTabScroll.bounds, to: content)
                    try expect(abs(header.minY-list.maxY-4) < 0.5, "Tabs do not start directly beneath address row")
                    try expect(sidebarSeparator.isHidden, "Old header separator remains visible")
                }
                if placement != .horizontal && mode == .tabBar {
                    try expect(toolbar.superview === sidebarAddressHost && pageAreaTop.constant == 0, "Sidebar URL consumes webpage height")
                    let field = topAddressSurface.convert(topAddressSurface.bounds,to:content)
                    let list = sidebarTabScroll.convert(sidebarTabScroll.bounds,to:content)
                    try expect(abs(field.minY-list.maxY-8) < 0.5, "Sidebar address is not directly above pins/tabs")
                    try expect(backButton.isHidden && forwardButton.isHidden, "Wide navigation controls overflow sidebar URL")
                    if let bitmap=content.bitmapImageRepForCachingDisplay(in:content.bounds) {
                        content.cacheDisplay(in:content.bounds,to:bitmap)
                        if let png=bitmap.representation(using:.png,properties:[:]) {try png.write(to:URL(fileURLWithPath:"/private/tmp/webby-pane-address.png"))}
                    }
                }
                let url = topAddressSurface.convert(topAddressSurface.bounds, to: content)
                for button in [backButton!, forwardButton!] where !button.isHidden {
                    try expect(!url.intersects(button.convert(button.bounds,to:content)), "Address field extends over navigation button")
                }
                for fuse in [true, false] {
                    let selected = activeTabID
                    BrowserExperiment.cyclesNewTabProfiles = fuse; activeTabID = selected
                    applyAddressChrome();content.layoutSubtreeIfNeeded()
                    let button = newTerminalButton.convert(newTerminalButton.bounds,to:mainArea)
                    try expect(newTerminalButton.isHidden || !page.intersects(button), "Fuse terminal button intercepts website: \(placement) \(mode) fuse=\(fuse) page=\(page) button=\(button) top=\(sidebarControlTop.constant) hidden=\(newTerminalButton.isHidden)")
                }
                try expect(!toolbar.hasAmbiguousLayout && !topAddressSurface.hasAmbiguousLayout, "Ambiguous address layout")
                let responder = window.firstResponder
                toolbarHideTimerFired()
                try expect(!toolbar.isHidden && window.firstResponder === responder, "Idle timer flickered or stole focus")
                focusAddress(); content.layoutSubtreeIfNeeded()
                try expect(addressField.currentEditor() != nil, "Cmd-L cannot focus address")
                addressField.currentEditor()?.string = "draft.invalid/test"
                updateNavigation()
                try expect(addressField.currentEditor()?.string == "draft.invalid/test", "Navigation overwrote typed URL")
                try expect(toolbarHideTimer == nil, "Address auto-hide timer was restarted")
                addressField.abortEditing(); window.makeFirstResponder(activeWebView)
                hideToolbar(animated: false); content.layoutSubtreeIfNeeded()
                if mode == .tabBar && placement == .horizontal {
                    try expect(horizontalTabsTrailing.constant == -300 && pageAreaTop.constant == 44, "Compact URL did not share tab row")
                }
                if let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds), placement == .horizontal {
                    content.cacheDisplay(in:content.bounds,to:bitmap)
                    if let png=bitmap.representation(using:.png,properties:[:]) {
                        try png.write(to:URL(fileURLWithPath:"/private/tmp/webby-address-"+mode.rawValue+".png"))
                    }
                }
            }
        }
        let savedAddressPreference=UserDefaults.standard.object(forKey:"webbyAddressPlacement")
        UserDefaults.standard.set("floating",forKey:"webbyAddressPlacement")
        try expect(BrowserAddressPlacement.current == .tabBar,"Old floating preference was not migrated")
        if let savedAddressPreference {UserDefaults.standard.set(savedAddressPreference,forKey:"webbyAddressPlacement")}
        else {UserDefaults.standard.removeObject(forKey:"webbyAddressPlacement")}
        BrowserAddressPlacement.current = .tabBar
        BrowserTabPlacement.current = .top
        configureHorizontalTabs()
        if sidebarVisible {toggleSidebar()}
        focusAddress()
        try expect(sidebarVisible && addressField.currentEditor() != nil,"Cmd-L did not reveal/focus sidebar URL")
        toggleSidebar()
        try expect(addressField.currentEditor() == nil,"Collapsed sidebar retained invisible typing focus")
        toggleSidebar()
        let target=activeTab!
        target.showsSearchView=true;applyAddressChrome();content.layoutSubtreeIfNeeded()
        try expect(pageAreaTop.constant==0 && !toolbar.isHidden,"Homepage sidebar URL is missing or reserves webpage space")
        target.showsSearchView=false;applyAddressChrome()
        BrowserTabPlacement.current = .horizontal
        UserDefaults.standard.set(true, forKey: "horizontalTabsHidden")
        configureHorizontalTabs();content.layoutSubtreeIfNeeded()
        let frame=pageArea.frame
        revealTabsFromEdge();content.layoutSubtreeIfNeeded()
        try expect(pageArea.frame == frame, "Tab hover moved the address strip or webpage")
        retreatTabs();try await Task.sleep(nanoseconds:240_000_000)
        addressField.stringValue = activeWebView?.url?.absoluteString ?? ""
        focusAddress();openAddress()
        try expect(addressField.currentEditor() == nil, "Submitting address did not return keyboard focus to page")
        print("PASS: 6 address layouts, sidebar URL above pins, full page height, unified strip header, single glass surface, Fuse, typing, submission, no auto-hide, hidden-tab geometry")
    }
}

extension BrowserApp {
    private func videoJS(_ view:WKWebView,_ expression:String) async throws -> Any {
        let value:Any? = try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Any?,Error>) in
            view.callAsyncJavaScript("return ("+expression+")",arguments:[:],in:nil,in:WKContentWorld.world(name:"WebbyVideo")) { result in
                switch result {
                case .success(let value): continuation.resume(returning:value)
                case .failure(let error): continuation.resume(throwing:error)
                }
            }
        }
        return value ?? NSNull()
    }
    private func waitForVideo(_ view:WKWebView,_ expression:String,timeout:Double=10) async throws {
        let deadline=Date().addingTimeInterval(timeout)
        while (try await videoJS(view,expression)) as? Bool != true {
            if Date()>deadline {
                let state=try? await videoJS(view,"(()=>{const v=document.querySelector('video')||document.querySelector('iframe')?.contentDocument?.querySelector('video');return {ready:v?.readyState,network:v?.networkState,error:v?.error?.message,code:v?.error?.code,src:v?.currentSrc,paused:v?.paused,mode:v?.webkitPresentationMode,volume:v?.volume,time:v?.currentTime,clicks:window.videoClicks,full:!!document.fullscreenElement,fullscreenError:window.fullscreenError,viewport:[innerWidth,innerHeight],supported:!!v?.webkitSupportsPresentationMode?.('picture-in-picture'),ended:v?.ended,hidden:document.hidden}})()")
                throw PerformanceTestFailure(message:"Video wait timed out: "+expression+" state="+String(describing:state))
            }
            try await Task.sleep(nanoseconds:50_000_000)
        }
    }
    private func clickVideoControl(_ view:WKWebView,_ expression:String) async throws {
        view.window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        // WebKit's embedding API supplies a user gesture for this evaluation.
        // Hit-test the real rendered button, then run its normal DOM click handler.
        let script="(()=>{const p=("+expression+");const target=document.elementFromPoint(p[0],p[1]);if(!target)throw new Error('No media hit target');target.click();return true})()"
        let _:Any? = try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Any?,Error>) in
            view.evaluateJavaScript(script) { value,error in
                if let error {continuation.resume(throwing:error)} else {continuation.resume(returning:value)}
            }
        }
    }
    private func verifyCommandGroups(base:String) async throws {
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        let first=try await loadFixture("/plain?group-one",base:base)
        let second=try await loadFixture("/plain?group-two",base:base)
        selectTab(first)
        let ownerA=first.ownerSpaceID
        guard let button=tabRows[second.id]?.titleButton else{throw PerformanceTestFailure(message:"Missing tab row")}
        button.testCommandClick()
        guard let groupID=first.groupID else{throw PerformanceTestFailure(message:"Command-click failed to create group")}
        try expect(second.groupID==groupID && activeTabID==first.id,"Command-click lost selection or failed membership")
        try expect(tabGroups.count==1 && first.ownerSpaceID==ownerA && second.ownerSpaceID==ownerA,"Grouping changed account ownership")
        try await Task.sleep(nanoseconds:50_000_000)
        guard let header=groupHeaders[groupID] else{throw PerformanceTestFailure(message:"Group glass header missing")}
        try expect(header.nameField.stringValue==URL(string:base)?.host,"Same-site group did not use its website name")
        header.focusName()
        guard let nameEditor=header.nameField.currentEditor() as? NSTextView else{throw PerformanceTestFailure(message:"Group name did not focus")}
        nameEditor.string="Research"
        let returnKey=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:"\r",charactersIgnoringModifiers:"\r",isARepeat:false,keyCode:36)!
        window.sendEvent(returnKey)
        try expect(header.nameField.currentEditor()==nil && tabGroups.first(where:{$0.id==groupID})?.name=="Research","Return did not save and unfocus group name")
        guard let container=groupContainers[groupID] else{throw PerformanceTestFailure(message:"Missing connected group")}
        try expect(header.superview === container && tabRows[first.id]?.superview === container.members && container.clip.layer?.masksToBounds==true,"Group members are not connected inside a clipped container")
        content.layoutSubtreeIfNeeded()
        try expect(container.clip.frame.minX>=20,"Group members are not indented")
        header.onToggle?()
        try expect(container.clip.frame.height<1,"Collapsed group still occupies member space")
        if Motion.enabled && window.occlusionState.contains(.visible) {try expect(container.clip.layer?.animation(forKey:"groupFold.bounds") != nil,"Fold-in animation missing")}
        try expect(!visibleSidebarTabs.contains{$0.id==first.id || $0.id==second.id},"Collapsed group leaked members")
        header.onToggle?()
        try expect(container.clip.frame.height>60,"Expanded group did not restore member space")
        if Motion.enabled && window.occlusionState.contains(.visible) {try expect(container.clip.layer?.animation(forKey:"groupFold.bounds") != nil,"Fold-out animation missing")}
        try expect(visibleSidebarTabs.contains{$0.id==first.id},"Expanded group did not restore members")
        let pin=BrowserTab();pin.ownerSpaceID=ownerA;pin.isPinned=true;tabs.append(pin);refreshTabs()
        commandGroupTab(pin.id)
        try expect(pin.groupID==nil && pin.isPinned,"Command-click unpinned a pin")
        addTab(select:false);let solo=tabs.last!;commandGroupTab(solo.id)
        guard let discardedGroup=solo.groupID else{throw PerformanceTestFailure(message:"Single-tab group missing")}
        selectTab(first);commandGroupTab(solo.id)
        try expect(solo.groupID==groupID && !tabGroups.contains{$0.id==discardedGroup},"Moving last group member left an empty shell")
        BrowserTabPlacement.current = .horizontal;configureHorizontalTabs();refreshTabs()
        try expect(horizontalGroups[groupID]?.nameField.stringValue=="Research","Horizontal group name missing")
        BrowserExperiment.cyclesNewTabProfiles=true;experimentalModeChanged();selectTab(first)
        let foreign=BrowserTab();foreign.ownerSpaceID=spaces[1].saved.id;spaces[1].tabs.append(foreign)
        commandGroupTab(foreign.id)
        try expect(foreign.groupID==groupID && foreign.ownerSpaceID==spaces[1].saved.id,"Fuse grouping changed profile")
        selectTab(foreign)
        assignSearchProfile(foreign,to:spaces[0])
        try expect(foreign.groupID==groupID,"Fuse route removed new tab from its group")
        assignSearchProfile(foreign,to:spaces[1]);selectTab(first)
        BrowserExperiment.cyclesNewTabProfiles=false;experimentalModeChanged();switchToSpace(1)
        try expect(visibleTabGroups.contains{$0.id==groupID},"Cross-profile group lost its accessible header")
        groupHeaders[groupID]?.onToggle?()
        try expect(!visibleSidebarTabs.contains{$0.id==foreign.id},"Cross-profile collapse failed")
        groupHeaders[groupID]?.onToggle?()
        try expect(visibleSidebarTabs.contains{$0.id==foreign.id},"Cross-profile group became inaccessible")
        switchToSpace(0);selectTab(first)
        let pane=try await loadFixture("/plain?group-split",base:base)
        try expect(splitTabs(sourceID:first.id,targetID:pane.id),"Group split fixture failed")
        selectTab(pane);commandGroupTab(second.id)
        try expect(first.groupID==groupID && pane.groupID==groupID && splitTabIDs?.count==2,"Grouping damaged a split or left one pane out")
        saveSessionTabs(wait: true)
        let data=UserDefaults.standard.data(forKey:"webbySessionTabs")!
        let saved=try JSONDecoder().decode(BrowserSessionRecord.self,from:data)
        try expect(saved.pages.filter{$0.url.contains("group-")}.allSatisfy{$0.groupID==groupID},"Grouped page metadata did not persist")
        endSplit();refreshTabs();groupHeaders[groupID]?.onDelete?()
        try expect(!tabGroups.contains{$0.id==groupID} && spaces.flatMap(\.tabs).allSatisfy{$0.groupID != groupID},"Deleting a group closed members or left stale metadata")
        createGroupFromEmptySpace()
        guard let created=tabGroups.last,let member=tabs.first(where:{$0.groupID==created.id}) else {
            throw PerformanceTestFailure(message:"New group must start with a tab")
        }
        closeTab(id:member.id)
        try expect(!tabGroups.contains{$0.id==created.id},"Closing last member left an empty group")
        let orphan=TabGroupRecord(id:UUID(),profileID:activeSpace.saved.id,name:"Orphan",collapsed:true)
        tabGroups.append(orphan);refreshTabs()
        try expect(!tabGroups.contains{$0.id==orphan.id},"Saved empty group survived refresh")
        let persisted=try JSONDecoder().decode([TabGroupRecord].self,from:UserDefaults.standard.data(forKey:"webbyTabGroups")!)
        try expect(!persisted.contains{$0.id==orphan.id || $0.id==created.id},"Empty groups remained in saved settings")
        print("PASS: Command-click grouping, immediate editable name, collapse, horizontal layout, pins preserved, split unit, cross-profile Fuse ownership, reachable shared headers, persistence, empty-shell cleanup, ungroup/delete, last-member close and orphan cleanup")
    }

    private func verifyExternalLinks(base:String) async throws {
        let a=spaces[0].saved.id,b=spaces[1].saved.id
        BrowserExternalLinks.profileID=b
        UserDefaults.standard.set(true,forKey:"webbyMiniExternalLinks")
        application(NSApp,open:[URL(string:base+"/plain?external-mini")!])
        guard let mini=miniTabs.values.first else{throw PerformanceTestFailure(message:"External link did not open Mini Webby")}
        try expect(mini.ownerSpaceID==b,"Mini external link used the wrong profile")
        try await waitFor("Mini external link did not load") {mini.webView?.url?.query=="external-mini"}
        UserDefaults.standard.set(false,forKey:"webbyMiniExternalLinks")
        application(NSApp,open:[URL(string:base+"/plain?external-main")!])
        try expect(activeTab?.ownerSpaceID==b && activeSpace.saved.id==b,"Main external link used the wrong profile")
        try await waitFor("Main external link did not load") {self.activeTab?.webView?.url?.query=="external-main"}
        BrowserExperiment.cyclesNewTabProfiles=true;experimentalModeChanged()
        BrowserExternalLinks.profileID=a
        application(NSApp,open:[URL(string:base+"/plain?external-fuse")!])
        try expect(activeTab?.ownerSpaceID==a && BrowserExperiment.cyclesNewTabProfiles,"External profile routing broke Fuse")
        try await waitFor("Fuse external link did not load") {self.activeTab?.webView?.url?.query=="external-fuse"}
        BrowserExternalLinks.profileID=UUID()
        try expect(BrowserExternalLinks.resolvedProfile(available:[a,b],current:b)==b,"Deleted-profile fallback failed")
        BrowserExternalLinks.profileID=nil
        try expect(BrowserExternalLinks.resolvedProfile(available:[a,b],current:a)==a,"Last-used-profile fallback failed")
        let before=tabs.count+miniTabs.count
        application(NSApp,open:[URL(string:"file:///private/tmp/not-a-web-link")!,URL(string:"javascript:alert(1)")!])
        try expect(tabs.count+miniTabs.count==before,"Invalid external scheme was accepted")
        print("PASS: external link profile routing in Mini Webby, main window, Fuse; deleted-profile fallback; invalid schemes")
    }

    private func verifyVideoPresentation(base:String) async throws {
        let previousPolicy=NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer {NSApp.setActivationPolicy(previousPolicy)}
        let media=try await loadFixture("/video",base:base)
        let view=media.webView!
        try await waitFor("Video page has not painted"){!media.showsSearchView}
        try expect(view.configuration.preferences.isElementFullscreenEnabled,"Fullscreen preference disabled")
        try expect(!view.configuration.userContentController.userScripts.contains{$0.source.contains("video-pip-fallback")},"Whole-tab PiP fallback is still installed")
        try await waitForVideo(view,"document.querySelector('video').readyState>=1")
        let capabilities=try await videoJS(view,"(()=>{const v=document.querySelector('video');return {native:!!v.webkitSupportsPresentationMode?.('picture-in-picture'),standard:!!document.pictureInPictureEnabled,full:!!document.fullscreenEnabled}})()")
        print("MEDIA capabilities",capabilities)
        try await clickVideoControl(view,"(()=>{const r=document.querySelector('#start').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
        try await waitForVideo(view,"!document.querySelector('video').paused")
        _ = try await videoJS(view,"(()=>{const v=document.querySelector('video'),r=v.getBoundingClientRect();v.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:r.x+30,clientY:r.y+30}));return true})()")
        try await waitForVideo(view,"!!document.querySelector('#__webby-video-controls') && getComputedStyle(document.querySelector('#__webby-video-controls')).display==='flex'")
        let previousTime=try await videoJS(view,"document.querySelector('video').currentTime") as! Double
        let webViewIdentity=view
        try await clickVideoControl(view,"(()=>{const r=document.querySelector('[data-webby-video-action=pip]').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
        try await waitForVideo(view,"document.querySelector('video').webkitPresentationMode==='picture-in-picture' || document.pictureInPictureElement===document.querySelector('video')")
        try expect(!media.isFloating && media.webView === webViewIdentity,"PiP floated or replaced entire tab")
        try await waitForVideo(view,"(()=>{const v=document.querySelector('video');return v.volume===.37 && !v.muted && v.playbackRate===1.25 && v.currentTime>=\(previousTime) && !v.paused})()")
        print("MEDIA native PiP windows",NSApp.windows.filter{$0.isVisible}.map{String(describing:type(of:$0))+":"+$0.title})
        try await waitFor("Native PiP delegate state not recorded"){media.hasPictureInPicture}
        if let pip=NSApp.windows.first(where:{$0.isVisible && String(describing:type(of:$0)).lowercased().contains("pip")}) {
            let before=pip.frame
            pip.setFrame(NSRect(x:before.minX+10,y:before.minY+10,width:before.width*0.9,height:before.height*0.9),display:true)
            try expect(pip.frame != before,"Native PiP window could not move/resize")
            try expect(pipWindowMotion.isMonitoring,"PiP drag monitor is not wired to native video state")
            if let root=pip.contentView {
                let candidates=[0.2,0.4,0.6,0.8].flatMap { x in [0.2,0.4,0.6,0.8].map { y in
                    root.convert(NSPoint(x:root.bounds.width*x,y:root.bounds.height*y),to:nil)
                }}
                guard let clear=candidates.first(where:{NativePiPWindowMotion.canDrag(pip,at:$0)}) else {throw PerformanceTestFailure(message:"Native PiP has no draggable video surface")}
                func verifyControls(_ view:NSView) throws {
                    if view is NSControl, !view.isHiddenOrHasHiddenAncestor, view.bounds.width>1,view.bounds.height>1 {
                        let p=view.convert(NSPoint(x:view.bounds.midX,y:view.bounds.midY),to:nil)
                        try expect(!NativePiPWindowMotion.canDrag(pip,at:p),"PiP drag handler steals a native playback control")
                    }
                    for child in view.subviews {try verifyControls(child)}
                }
                try verifyControls(root)
                for type in [NSEvent.EventType.leftMouseDown,.leftMouseUp] {
                    let event=NSEvent.mouseEvent(with:type,location:clear,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:pip.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
                    try expect(pipWindowMotion.handle(event)==nil,"Custom PiP drag leaked to native corner snapping")
                }
            }
            let bounds=NativePiPWindowMotion.screenBounds(for:NSPoint(x:pip.frame.midX,y:pip.frame.midY),window:pip)
            let center=NSPoint(x:bounds.midX-pip.frame.width/2,y:bounds.midY-pip.frame.height/2)
            let bottomLeft=NSPoint(x:bounds.minX+14,y:bounds.minY+14)
            let right=NativePiPWindowMotion.directionalCorner(origin:bottomLeft,delta:NSPoint(x:12,y:1),size:pip.frame.size,bounds:bounds)
            let up=NativePiPWindowMotion.directionalCorner(origin:bottomLeft,delta:NSPoint(x:1,y:12),size:pip.frame.size,bounds:bounds)
            try expect(right.x>bounds.midX && right.y==bottomLeft.y,"Small right drag lost horizontal intent")
            try expect(up.y>bounds.midY && up.x==bottomLeft.x,"Small up drag lost vertical intent")
            pip.setFrameOrigin(center)
            let mouse=NSPoint(x:bounds.midX,y:bounds.midY)
            pipWindowMotion.begin(pip,point:mouse,time:1)
            pipWindowMotion.move(point:NSPoint(x:mouse.x+25,y:mouse.y+15),time:1.3)
            try expect(pipWindowMotion.finish(point:NSPoint(x:mouse.x+25,y:mouse.y+15),time:1.6),"Small slow drag did not snap directionally")
            let smallTarget=NativePiPWindowMotion.directionalCorner(origin:center,delta:NSPoint(x:25,y:15),size:pip.frame.size,bounds:bounds)
            try await Task.sleep(nanoseconds:650_000_000)
            try expect(hypot(pip.frame.minX-smallTarget.x,pip.frame.minY-smallTarget.y)<1,"Small directional drag did not settle")
            try expect(!NativePiPWindowMotion.canDrag(pip,at:.zero),"Custom motion steals native resize edge")
            pipWindowMotion.begin(pip,point:mouse,time:2)
            pipWindowMotion.move(point:NSPoint(x:mouse.x+120,y:mouse.y+40),time:2.03)
            try expect(pipWindowMotion.finish(point:NSPoint(x:mouse.x+240,y:mouse.y+80),time:2.06),"Long fast swipe did not fling")
            let target=NativePiPWindowMotion.directionalCorner(origin:smallTarget,delta:NSPoint(x:240,y:80),size:pip.frame.size,bounds:bounds)
            try await Task.sleep(nanoseconds:650_000_000)
            try expect(hypot(pip.frame.minX-target.x,pip.frame.minY-target.y)<1,"PiP spring did not settle at predicted corner")
            print("PASS: native PiP resize, small directional drag, spring fling, native resize edge")
        }
        // Pausing in PiP must not make the background tab eligible for eviction.
        _ = try await videoJS(view,"(()=>{document.querySelector('video').pause();return true})()")
        addTab(select:true);media.lastActiveAt = .distantPast
        checkDiscard(media,cutoff:Date())
        try await waitFor("Paused PiP discard check stuck"){!media.discardCheckInFlight}
        try expect(media.webView === webViewIdentity,"Paused PiP was discarded in background")
        _ = try await videoJS(view,"(()=>{document.querySelector('video').volume=.62;return true})()")
        selectTab(media)
        try expect(pageArea.layer?.animation(forKey:"webbyGeometry")==nil,"Selected page inherited previous page position")
        try await waitForVideo(view,"document.querySelector('video').webkitPresentationMode!=='picture-in-picture' && !document.pictureInPictureElement")
        try await waitForVideo(view,"document.querySelector('video').volume===.62")
        activeTabID=nil;selectTab(media)
        let inlineHost=view.superview
        try await waitFor("PiP UI has not finished closing"){!media.hasPictureInPicture}
        try await Task.sleep(nanoseconds:350_000_000)
        // Exercise the website's own fullscreen button, not just Webby's overlay.
        try await clickVideoControl(view,"(()=>{const r=document.querySelector('#full').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()")
        try await waitForVideo(view,"(document.fullscreenElement===document.querySelector('video') || document.querySelector('video').webkitPresentationMode==='fullscreen') && innerWidth>0 && innerHeight>0")
        try await waitFor("Native fullscreen animation did not settle"){view.fullscreenState == .inFullscreen}
        print("MEDIA fullscreen state",view.fullscreenState.rawValue,NSApp.windows.filter{$0.isVisible}.map{String(describing:type(of:$0))+":"+NSStringFromRect($0.frame)})
        _ = try await videoJS(view,"(async()=>{if(document.fullscreenElement)await document.exitFullscreen();else document.querySelector('video').webkitSetPresentationMode('inline');return true})()")
        try await waitFor("Native fullscreen never exited"){view.fullscreenState == .notInFullscreen}
        try expect(view.superview === inlineHost && view.bounds.width>0 && view.bounds.height>0,"Fullscreen did not restore original page geometry")
        try await waitForVideo(view,"(()=>{const v=document.querySelector('video');return v.volume===.62 && v.playbackRate===1.25})()")
        // Pause before changing tabs so automatic follow-video does not race the explicit test.
        _ = try await videoJS(view,"(()=>{document.querySelector('video').pause();return true})()")
        // Native presentation must not dissolve Webby's split arrangement.
        let other=try await loadFixture("/plain?video-split",base:base)
        try expect(splitTabs(sourceID:other.id,targetID:media.id),"Video could not join split")
        let ids=splitTabIDs
        _ = try await videoJS(view,"(async()=>{await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)));await document.querySelector('video').play();return true})()")
        try await waitForVideo(view,"!document.querySelector('video').paused && !!document.querySelector('video').webkitSupportsPresentationMode?.('picture-in-picture')")
        _ = try await videoJS(view,"(()=>{const v=document.querySelector('video');v.webkitSetPresentationMode('picture-in-picture');return true})()")
        try await waitForVideo(view,"document.querySelector('video').webkitPresentationMode==='picture-in-picture'")
        try await waitFor("Split PiP did not enter"){media.hasPictureInPicture}
        try expect(splitTabIDs==ids && !media.isFloating && view.superview != nil,"PiP dismantled split layout")
        selectTab(other)
        try await waitFor("Split PiP did not return"){!media.hasPictureInPicture}
        _ = try await videoJS(view,"(()=>{document.querySelector('video').pause();return true})()")
        endSplit()
        // This player lives in a real iframe, where the isolated controls must also be installed.
        let embedded=try await loadFixture("/video-frame",base:base)
        let embeddedView=embedded.webView!
        try await waitForVideo(embeddedView,"!!document.querySelector('iframe').contentDocument?.querySelector('video') && document.querySelector('iframe').contentDocument.querySelector('video').readyState>=2")
        _ = try await videoJS(embeddedView,"(()=>{const v=document.querySelector('iframe').contentDocument.querySelector('video'),r=v.getBoundingClientRect();v.volume=.48;v.muted=true;v.playbackRate=.75;v.dispatchEvent(new PointerEvent('pointermove',{bubbles:true,clientX:r.x+30,clientY:r.y+30}));return true})()")
        try await waitForVideo(embeddedView,"!!document.querySelector('iframe').contentDocument.querySelector('[data-webby-video-action=pip]')")
        _ = try await videoJS(embeddedView,"(()=>{document.querySelector('iframe').contentDocument.querySelector('[data-webby-video-action=pip]').click();return true})()")
        try await waitFor("Iframe native PiP did not enter"){embedded.hasPictureInPicture}
        try await waitForVideo(embeddedView,"(()=>{const v=document.querySelector('iframe').contentDocument.querySelector('video');return v.webkitPresentationMode==='picture-in-picture' && v.volume===.48 && v.muted && v.playbackRate===.75})()")
        try expect(!embedded.isFloating,"Iframe PiP floated entire page")
        selectTab(embedded)
        try await waitFor("Iframe native PiP did not close"){!embedded.hasPictureInPicture}
        _ = try await videoJS(embeddedView,"(()=>{document.querySelector('iframe').contentDocument.querySelector('video').pause();return true})()")
        print("PASS: real native PiP, move/resize, exact volume/mute/rate/time, paused background protection, fullscreen/inline restoration, preserved split, iframe controls")
    }
}

private extension TabActionButton {
    func testCommandClick() {
        let event=NSEvent.mouseEvent(with:.leftMouseDown,location:convert(NSPoint(x:bounds.midX,y:bounds.midY),to:nil),modifierFlags:[.command],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window!.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)!
        mouseDown(with:event)
    }
}

// Accepts arbitrary public URLs. No host-specific success criteria or timing thresholds.
extension BrowserApp {
    private func runRealCorpus(corpus:String,output:URL) async throws {
        let urls=try JSONDecoder().decode([String].self,from:Data(contentsOf:URL(fileURLWithPath:corpus)))
        let repeats=max(1,min(10,Int(ProcessInfo.processInfo.environment["WEBBY_REAL_REPEATS"] ?? "3") ?? 3))
        let variant=ProcessInfo.processInfo.environment["WEBBY_REAL_VARIANT"] ?? "webby"
        try expect(!urls.isEmpty && urls.allSatisfy{ let u=URL(string:$0); return u?.scheme=="https" && u?.host != nil },"Corpus must contain HTTPS URLs")
        window.makeKeyAndOrderFront(nil)
        var samples:[[String:Any]]=[]
        let store=WKWebsiteDataStore.nonPersistent()
        // Give the asynchronous compiled-rule lookup a bounded preparation window.
        try await Task.sleep(nanoseconds:200_000_000)
        content.layoutSubtreeIfNeeded()
        func cpuMilliseconds()->Double {
            var usage=rusage();getrusage(RUSAGE_SELF,&usage)
            return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)*1000 + Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1000
        }
        for round in 0..<repeats {
            // Rotate order so a single host is not always tested first.
            for offset in urls.indices {
                let address=urls[(offset+round)%urls.count]
                let started=ProcessInfo.processInfo.systemUptime
                let startedCPU=cpuMilliseconds()
                var row:[String:Any]=["url":address,"round":round,"variant":variant,"cache":round==0 ? "fresh ephemeral store; OS caches uncontrolled":"reused ephemeral store; server cache policy respected"]
                addTab(select:true)
                let target=activeTab!
                let view:WKWebView
                if variant=="minimal-wk" {
                    let config=WKWebViewConfiguration();config.websiteDataStore=store
                    view=WKWebView(frame:pageArea.bounds,configuration:config)
                    target.webView=view;pageArea.addSubview(view)
                    target.showsSearchView=false
                    homeView.isHidden=true;globe.engine.hide()
                    applyAddressChrome();content.layoutSubtreeIfNeeded()
                    view.frame=pageArea.bounds;view.autoresizingMask=[.width,.height]
                    view.load(URLRequest(url:URL(string:address)!))
                } else {
                    view=makeWebView(for:target)
                    // Keep a single ephemeral store per run in the test builder.
                    navigate(address,in:target)
                }
                let deadline=ProcessInfo.processInfo.systemUptime+25
                while (view.isLoading || view.url == nil) && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(nanoseconds:20_000_000)}
                row["nativeLoadWaitMs"]=(ProcessInfo.processInfo.systemUptime-started)*1000
                row["browserHostCPUUntilLoadMs"]=cpuMilliseconds()-startedCPU
                row["effects"]=["glass":variant != "minimal-wk" && BrowserGlass.pageInjectionEnabled,"geist":variant != "minimal-wk" && GlassPageInjector.geistEnabled,"fastRule":variant != "minimal-wk" && fastModeEnabled && fastRule != nil,"injectedScriptBytes":view.configuration.userContentController.userScripts.reduce(0){$0+$1.source.utf8.count}]
                var usage=rusage();getrusage(RUSAGE_SELF,&usage)
                row["browserHostCumulativePeakRSSBytes"]=usage.ru_maxrss
                row["timedOut"]=view.isLoading || view.url == nil
                row["finalURL"]=view.url?.absoluteString ?? ""
                row["navigationError"]=target.loadError ?? ""
                if !view.isLoading {
                    do {
                        row["page"]=try await view.evaluateJavaScript("""
                        (()=>{const n=performance.getEntriesByType('navigation')[0];return {title:document.title,readyState:document.readyState,navigation:n?JSON.parse(JSON.stringify(n.toJSON())):null,paint:performance.getEntriesByType('paint').map(e=>({name:e.name,startTime:e.startTime})),resourceCount:performance.getEntriesByType('resource').length,domElements:document.getElementsByTagName('*').length,viewport:{width:innerWidth,height:innerHeight}}})()
                        """)
                        row["frameOpportunityGapsMs"]=try await view.callAsyncJavaScript("""
                        return await new Promise(resolve=>{let last=null,gaps=[];function frame(t){if(last!==null)gaps.push(t-last);last=t;if(gaps.length>=60)resolve(gaps);else requestAnimationFrame(frame)}requestAnimationFrame(frame);setTimeout(()=>resolve(gaps),3000)})
                        """,arguments:[:],in:nil,contentWorld:.defaultClient)
                    } catch {row["measurementError"]=String(describing:error)}
                }
                samples.append(row)
                let report:[String:Any]=["samples":samples,"optimization":Bundle.main.object(forInfoDictionaryKey:"WebbyTestOptimization") ?? "unknown","limitations":["Logged-out isolated profiles; no production sign-ins","rAF gaps are frame opportunities, not compositor FPS or GPU time","OS DNS/TLS caches and server/network variance uncontrolled","No cold-cache claim; failures and timeouts included","Host CPU/RSS excludes WebKit content/network/GPU processes","Load completion does not prove a functional signed-in or challenge-free page"]]
                try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
                releaseWebView(for:target)
                activeSpace.tabs.removeAll{$0.id==target.id}
                print("CORPUS \(variant) round \(round) \(address) \(row["nativeLoadWaitMs"]!)ms")
            }
        }
    }
}
