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
        downloads = BrowserDownloads()
        makeWindow(); makeSidebar(); makeMainArea(); makeHome()
        NotificationCenter.default.addObserver(self, selector: #selector(themeChanged), name: .browserThemeChanged, object: nil)
        BrowserTheme.activate(a.saved.id)
        themeChanged()
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
        let second = try await loadFixture("/plain?second", base: base)
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
        addressField.stringValue = "private only"; presentSuggestions(for:addressField)
        try expect(suggestions.selected() == nil,"An isolated profile leaked another profile's suggestion")
        addressField.stringValue = "site.example"; presentSuggestions(for:addressField)
        try expect(suggestions.selected()?.profileID == a.saved.id && suggestions.selectedIndex == 0,"Isolated suggestions or initial highlight failed")
        BrowserExperiment.cyclesNewTabProfiles = true; experimentalModeChanged()
        addressField.stringValue = "site.example"; presentSuggestions(for:addressField)
        try expect(suggestions.selected()?.profileID == b.saved.id,"Fuse lost recency or profile routing")
        BrowserExperiment.cyclesNewTabProfiles = false; experimentalModeChanged()
        var links: [BrowserLink] = []
        for index in 0..<10000 {
            links.append(BrowserLink(title:"Fixture article \(index)",url:"https://site.example/item/\(index)",visitedAt:Date().addingTimeInterval(-Double(index))))
        }
        a.saved = SavedBrowserSpace(id:a.saved.id,name:a.saved.name,chromeDirectory:nil,bookmarks:[],history:links)
        var suggestionTimes: [Double] = []
        for query in ["f","fi","fix","fixture","fixture article 9","fixture article 99","fixture article 999","site","site.example"] {
            addressField.stringValue=query
            let began=ProcessInfo.processInfo.systemUptime
            presentSuggestions(for:addressField)
            suggestionTimes.append((ProcessInfo.processInfo.systemUptime-began)*1000)
            try expect(suggestions.selectedIndex == 0,"Typing lost automatic first selection")
        }
        suggestions.close()
        try verifyWallpaperPresentation()
        try await verifyMiniWebby(base:base)
        try await verifyChromeTone(base:base)
        try await verifyProfileMotion()
        try await verifyLinkOpening(base:base)
        func p95(_ values: [Double]) -> Double { let a=values.sorted(); return a[min(a.count-1,Int(Double(a.count-1)*0.95))] }
        var result: [String: Any] = [:]
        result["passed"] = true
        result["restoredTabs"] = 80
        result["untouchedTabsStillUnloaded"] = 79
        result["slowPageRevealSeconds"] = timing.presented! - timing.started
        result["slowPageFinishSeconds"] = timing.finished! - timing.started
        result["verticalSelectionCPUp95Ms"] = p95(topTimes)
        result["horizontalSelectionCPUp95Ms"] = p95(horizontalTimes)
        result["selectionSamplesPerLayout"] = 45
        result["profileOwnershipPreserved"] = true
        result["suggestionCorpusSize"] = 10000
        result["suggestionWorkP95Ms"] = p95(suggestionTimes)
        result["suggestionColdIndexMs"] = suggestionTimes.first!
        result["suggestionWarmP95Ms"] = p95(Array(suggestionTimes.dropFirst()))
        result["suggestionWorkMaxMs"] = suggestionTimes.max()!
        result["tested"] = ["profile-isolated suggestions", "Fuse suggestions", "10000-entry history", "automatic first suggestion", "lazy pinned restore", "pinned discard preserves pin", "four-pane geometry", "navigation failure", "theme notification path", "lazy restore","early reveal","redirect","dirty form","clean discard/resume","capture exclusion","floating exclusion","keep loaded","embedded app exclusion","stale callbacks","IDE split","Fuse","profile switch"]
        try JSONSerialization.data(withJSONObject: result, options:[.prettyPrinted,.sortedKeys]).write(to: output)
        print("Browser integration checks passed. Report: \(output.path)")
        exit(0)
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

    private func verifyChromeTone(base:String) async throws {
        let glass=BrowserGlass.pageInjectionEnabled
        BrowserGlass.pageInjectionEnabled=false
        defer {BrowserGlass.pageInjectionEnabled=glass}
        BrowserTabPlacement.current = .horizontal;configureHorizontalTabs()
        let target=try await loadFixture("/tone",base:base)
        let view=target.webView!
        func matches(_ rgb:[Double]) -> Bool {
            guard let c=pageChromeColors[target.id]?.usingColorSpace(.deviceRGB) else{return false}
            return abs(c.redComponent*255-rgb[0])<2 && abs(c.greenComponent*255-rgb[1])<2 && abs(c.blueComponent*255-rgb[2])<2
        }
        try await waitFor("Initial top-edge color failed") {matches([40,80,120])}
        let count=view.configuration.userContentController.userScripts.count
        BrowserChromeTone.install(into:view.configuration,handler:self)
        try expect(count == view.configuration.userContentController.userScripts.count,"Color probe duplicated popup handlers")
        _ = try await view.evaluateJavaScript("document.getElementById('tone').className='changed'; true")
        try await waitFor("Header theme mutation did not update tab") {matches([180,60,30])}
        _ = try await view.evaluateJavaScript("document.getElementById('tone').style.opacity='0.5'; true")
        try await waitFor("Transparent header did not composite over page") {matches([101,48,40])}
        _ = try await view.evaluateJavaScript("document.getElementById('tone').style.opacity='1';window.scrollTo(0,500);true")
        try await waitFor("Sticky header scroll lost its color") {matches([180,60,30])}
        addTab(select:true)
        _ = try await view.evaluateJavaScript("document.getElementById('tone').className='';true")
        try await Task.sleep(nanoseconds:250_000_000)
        try expect(matches([180,60,30]),"Background tab kept sampling or changed active color")
        activeTabID=nil;selectTab(target)
        try await waitFor("Reselection did not refresh current color") {matches([40,80,120])}
        BrowserTabPlacement.current = .top;configureHorizontalTabs()
        print("PASS: live top-edge color, header mutations, alpha compositing, sticky scroll, inactive suspension, reselection, handler idempotence")
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
            try expect(activeTabID == source.id,"Command-click stole foreground selection")
            try expect(ownerSpace(for:opened).saved.id == profile,"Command-click lost profile")
        }
        let before = Set(spaces.flatMap(\.tabs).map(\.id))
        _ = try await view.evaluateJavaScript("document.getElementById('blank').click(); true")
        try await waitFor("Target blank link failed") { self.spaces.flatMap(\.tabs).contains { !before.contains($0.id) } }
        let blank = spaces.flatMap(\.tabs).first { !before.contains($0.id) }!
        try await waitFor("Target blank load failed") { blank.navigationTiming.finished != nil }
        activeTabID=nil;selectTab(source)
        _ = try await view.evaluateJavaScript("document.getElementById('normal').click(); true")
        try await waitFor("Same-tab link failed") { view.url?.query == "normal=1" && !source.navigationInProgress }
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
            do { try await browser.runPerformanceChecks(base: base, output: output) }
            catch { print("Browser integration check failed: \(error)"); exit(1) }
        }
        app.run(); withExtendedLifetime(browser) {}
    }
}
