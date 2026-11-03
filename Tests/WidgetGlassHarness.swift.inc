extension GlassWidgetCard {
    func verifyCalculatorInput() -> Bool {
        guard calculatorField.isEditable, calculatorField.isSelectable else { return false }
        frame = NSRect(x: 0, y: 0, width: 340, height: 240)
        needsLayout = true; layoutSubtreeIfNeeded()
        guard let window, window.makeFirstResponder(calculatorField) else { return false }
        calculatorField.selectText(nil)
        guard let editor = calculatorField.currentEditor() as? NSTextView else { return false }
        editor.insertText("9 / (2^2 + 4)", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        guard calculatorField.stringValue == "9 / (2^2 + 4)" else { return false }
        controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: calculatorField))
        guard calculatorAnswer.stringValue == "1.125" else { return false }
        let selection = editor.selectedRange()
        needsLayout = true; layoutSubtreeIfNeeded()
        guard calculatorField.currentEditor() === editor, window.firstResponder === editor,
              editor.selectedRange() == selection else { return false }
        setCalculatorHistory(["3 + 4 = 7"]);layoutSubtreeIfNeeded()
        guard calculatorField.currentEditor() === editor, editor.selectedRange() == selection else { return false }
        for size in [NSSize(width:200,height:90),NSSize(width:360,height:260)] {
            frame.size=size;needsLayout=true;layoutSubtreeIfNeeded()
            guard calculatorField.currentEditor() === editor else{return false}
        }
        var saved: String?
        let previousCallback=calculatorCalculated
        defer {calculatorCalculated=previousCallback}
        calculatorCalculated = { [weak self] line in
            saved=line
            self?.setCalculatorHistory([line]);self?.layoutSubtreeIfNeeded()
        }
        let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
        window.sendEvent(enter)
        guard saved == "9 / (2^2 + 4) = 1.125", calculatorField.currentEditor() === editor,
              window.firstResponder === editor else { return false }
        editor.setSelectedRange(NSRange(location:editor.string.utf16.count,length:0))
        editor.insertText(" + 1",replacementRange:editor.selectedRange())
        needsLayout=true;layoutSubtreeIfNeeded()
        guard editor.string == "9 / (2^2 + 4) + 1",calculatorField.currentEditor() === editor else{return false}
        window.sendEvent(enter)
        guard saved == "9 / (2^2 + 4) + 1 = 2.125",calculatorField.currentEditor() === editor else{return false}
        for (input, expected) in [("sqrt(81)", "9"), ("ans*2", "18"), ("2+3*4", "14"), ("sin(pi/2)", "1"), ("2(3+4)", "14"), ("5!", "120")] {
            editor.insertText(input, replacementRange:NSRange(location:0,length:editor.string.utf16.count))
            controlTextDidChange(Notification(name:NSControl.textDidChangeNotification,object:calculatorField))
            window.sendEvent(enter)
            guard calculatorAnswer.stringValue == expected,calculatorField.currentEditor() === editor else{return false}
            if input.contains("sqrt") && !editor.string.contains("√") {return false}
            if input.contains("pi") && !editor.string.contains("π") {return false}
        }
        // Clicking/focusing another control must still leave the calculator normally.
        let other=NSTextField(string:"");other.frame=NSRect(x:0,y:0,width:100,height:24);addSubview(other)
        guard window.makeFirstResponder(other),calculatorField.currentEditor()==nil else{return false}
        other.removeFromSuperview()
        calculatorField.stringValue = "1 / 0"; calculatePressed()
        guard calculatorAnswer.stringValue == "Check expression" else { return false }
        calculatorField.stringValue = "2^(3^2)"; calculatePressed()
        guard calculatorAnswer.stringValue == "512" else { return false }
        print("PASS: calculator input/caret survives live layout, history refresh, resize, repeated Enter and continued typing; normal focus exit; nested expressions, invalid input and powers")
        return true
    }
    func verifyMusicLayouts() -> Bool {
        setMusic(SpotifySnapshot(title:"Summers Over Interlude",artist:"Drake",album:"Views",artworkURL:"",position:20,duration:180,isPlaying:true))
        albumArt.image=NSImage(size:NSSize(width:64,height:64))
        var smallCover:CGFloat=0
        for (w,h) in [(64,64),(170,160),(200,140),(260,170),(340,270),(340,440),(600,220),(800,600)] {
            frame=NSRect(x:0,y:0,width:w,height:h);needsLayout=true;layoutSubtreeIfNeeded()
            guard abs(albumArt.frame.width-albumArt.frame.height)<0.01, bounds.contains(albumArt.frame),spotifyBrand.image != nil,bounds.contains(spotifyBrand.frame) else{return false}
            if w>=180 && h>=120 && spotifyBrand.frame.intersects(albumArt.frame){return false}
            for view in [trackTitle,trackArtist,musicPrevious,musicToggle,musicNext,musicProgress] where !view.isHidden {
                guard bounds.contains(view.frame), !view.frame.intersects(albumArt.frame) else{return false}
            }
            if w==340 && h==270 {smallCover=albumArt.frame.width;guard smallCover>125 else{return false}}
            if w==340 && h==440 {guard albumArt.frame.width>smallCover*1.7 else{return false}}
            if !musicProgress.isHidden {
                guard !musicProgress.frame.intersects(musicToggle.frame), !trackArtist.frame.intersects(musicProgress.frame) else{return false}
            }
        }
        return true
    }
    func verifyFeedCache() -> Bool {
        let p=glassProfile
        defer {for kind in ["weather","stocks"] {UserDefaults.standard.removeObject(forKey:"webbyWidgetSnapshot.v1.\(p.uuidString).\(kind)")}}
        prepareFeed(query:"Cache test city",refreshing:true)
        guard showSkeleton && weather==nil else{return false}
        let weather=WeatherSnapshot(city:"Cache test city",temperature:72,high:80,low:60,humidity:40,code:0,isDay:true,hours:[])
        WidgetSnapshotCache.save(weather,profile:p,kind:"weather",query:"Cache test city",updated:Date().addingTimeInterval(-600))
        let restored=GlassWidgetCard(kind:.weather,frame:frame);restored.glassProfile=p
        restored.prepareFeed(query:" CACHE TEST CITY ",refreshing:false)
        guard restored.weather==weather && !restored.showSkeleton && !restored.feedStatus.stringValue.isEmpty else{return false}
        restored.prepareFeed(query:"Cache test city",refreshing:true)
        guard restored.weather==weather && !restored.showSkeleton else{return false}
        restored.failFeed("Offline test")
        guard restored.weather==weather && restored.feedStatus.stringValue.hasPrefix("Offline") else{return false}
        let different=GlassWidgetCard(kind:.weather,frame:frame);different.glassProfile=p
        different.prepareFeed(query:"A different city",refreshing:false)
        guard different.showSkeleton && different.weather==nil else{return false}
        guard WidgetSnapshotCache.read(WeatherSnapshot.self,profile:UUID(),kind:"weather",query:"Cache test city")==nil else{return false}
        let stock=StockSnapshot(symbol:"TEST",price:"$123.45",changePercent:2,asOf:"Fixture date",chart:[1,2,3])
        WidgetSnapshotCache.save(stock,profile:p,kind:"stocks",query:"TEST")
        let stockCard=GlassWidgetCard(kind:.stocks,frame:frame);stockCard.glassProfile=p
        stockCard.prepareFeed(query:"TEST",refreshing:true)
        guard stockCard.stock==stock && !stockCard.showSkeleton else{return false}
        stockCard.failFeed("Offline test");guard stockCard.stock==stock else{return false}
        stockCard.frame=NSRect(x:0,y:0,width:250,height:160);stockCard.needsLayout=true;stockCard.layoutSubtreeIfNeeded()
        let chartFrame=stockCard.sparkline.frame
        stockCard.setStock(stock,animated:true);stockCard.finishFeed();stockCard.layoutSubtreeIfNeeded()
        guard stockCard.sparkline.frame==chartFrame else{return false}
        restored.setFeedVisible(false)
        restored.setWeather(weather,animated:true);restored.finishFeed()
        guard !restored.showSkeleton && restored.layer?.animation(forKey:"feedUpdate")==nil && restored.weatherIcon.layer?.animation(forKey:"weatherFloat")==nil else{return false}
        print("PASS: first-load skeleton, persisted weather/stock, query/profile isolation, stale refresh, offline retention, hidden animation suppression")
        return true
    }
    func verifyGlass(_ opacity:Double) -> Bool {
        glass.blendingMode == .withinWindow && abs(glass.alphaValue-opacity)<0.001 && alphaValue==1
            && glass.hitTest(NSPoint(x:2,y:2))==nil && close.alphaValue==1
    }
}
extension WidgetCanvas {
    func verifyWidgetGlass() -> Bool {
        let calculator = GlassWidgetCard(kind: .calculator, frame: NSRect(x: 0, y: 0, width: 340, height: 240))
        addSubview(calculator)
        let calculatorPassed = calculator.verifyCalculatorInput()
        window?.makeFirstResponder(nil)
        calculator.removeFromSuperview()
        guard calculatorPassed else { return false }
        let p=profile
        let originalCards=cards
        cards=[.weather:GlassWidgetCard(kind:.weather,frame:NSRect(x:0,y:0,width:320,height:208)),
               .stocks:GlassWidgetCard(kind:.stocks,frame:NSRect(x:340,y:0,width:320,height:208))]
        for card in cards.values {card.glassProfile=p}
        defer {
            cards=originalCards
            UserDefaults.standard.removeObject(forKey:"webbyWidgetGlassOpacity.\(p.uuidString)")
            UserDefaults.standard.removeObject(forKey:"webbyWidgetGlassOpacity.\(p.uuidString).weather")
            updateGlassOpacity()
        }
        BrowserGlass.setWidgetOpacity(0.2,profile:p)
        guard cards.values.allSatisfy({$0.verifyGlass(0.2)}) else {return false}
        BrowserGlass.setWidgetOpacity(0.75,profile:p,kind:"weather")
        guard cards[.weather]?.verifyGlass(0.75)==true,
              cards[.stocks]?.verifyGlass(0.2)==true else{return false}
        BrowserGlass.setWidgetOpacity(0,profile:p,kind:"weather")
        guard cards[.weather]?.verifyGlass(0)==true else{return false}
        BrowserGlass.resetWidgetOpacity(profile:p,kind:"weather")
        guard cards[.weather]?.verifyGlass(0.2)==true else{return false}
        let other=UUID()
        guard BrowserGlass.widgetOpacity(profile:other)==0.45 else{return false}
        let player=GlassWidgetCard(kind:.music,frame:NSRect(x:0,y:0,width:340,height:270))
        guard player.verifyMusicLayouts() else{return false}
        let feed=GlassWidgetCard(kind:.weather,frame:NSRect(x:0,y:0,width:320,height:208));feed.glassProfile=p
        guard feed.verifyFeedCache() else{return false}
        return true
    }
}

extension GlassWidgetCard {
    func verifyCodexComposer()->Bool {
        frame=NSRect(x:0,y:0,width:380,height:280);needsLayout=true;layoutSubtreeIfNeeded()
        return codexAppWidget?.verifyComposer() == true
    }
}
extension WidgetCanvas {
    func verifyCodexInput()->Bool {
        let card=GlassWidgetCard(kind:.codex,frame:NSRect(x:0,y:0,width:320,height:208))
        let host=NSWindow(contentRect:card.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        host.isReleasedWhenClosed=false;host.contentView=card;host.makeKeyAndOrderFront(nil)
        defer{host.close()}
        return card.verifyCodexComposer()
    }
}

extension GlassWidgetCard {
    func verifyChatGPTComposer()->Bool {
        let board=NSPasteboard.withUniqueName();defer{board.releaseGlobally()}
        let image=NSImage(size:NSSize(width:16,height:16));image.lockFocus();NSColor.systemBlue.setFill();NSRect(x:0,y:0,width:16,height:16).fill();image.unlockFocus()
        board.writeObjects([image]);guard acceptImages(board),chatImages.count==1 else{return false}
        needsLayout=true;layoutSubtreeIfNeeded()
        guard promptField.isEditable,!promptField.isHidden,!attachmentStrip.isHidden,attachmentStrip.arrangedSubviews.count==1 else{return false}
        var submitted=false
        submitChatGPT={text,images in submitted=text=="Describe this image" && images.count==1 && NSImage(data:images[0].data) != nil}
        promptField.stringValue="Describe this image";promptPressed()
        guard submitted,chatImages.isEmpty,promptField.stringValue.isEmpty else{return false}
        for _ in 0..<6 {_ = acceptImages(board)}
        guard chatImages.count==4 else{return false}
        let remove=NSButton();remove.tag=0;removeAttachment(remove)
        return chatImages.count==3
    }
}
extension WidgetCanvas {
    func verifyChatGPTInput()->Bool {
        let card=GlassWidgetCard(kind:.chatgpt,frame:NSRect(x:0,y:0,width:320,height:208))
        let host=NSWindow(contentRect:card.frame,styleMask:[.titled,.closable],backing:.buffered,defer:false)
        host.isReleasedWhenClosed=false;host.contentView=card;host.makeKeyAndOrderFront(nil);defer{host.close()}
        return card.verifyChatGPTComposer()
    }
}

extension WidgetCanvas {
    func verifyAlignmentBounds() -> Bool {
        let area = NSRect(x: 0, y: 0, width: 1000, height: 700)
        for x in [-500.0, 0, 7, 349, 500, 990, 2000] {
            for y in [-1000.0, 0, 5, 249, 400, 690, 3000] {
                let proposed = NSRect(x: x, y: y, width: 300, height: 200)
                for resize in [false, true] {
                    let result = WidgetAlignment.adjusted(proposed, in: area, resizing: resize)
                    guard area.contains(result), result.width >= 64, result.height >= 64 else { return false }
                }
            }
        }
        let centered = WidgetAlignment.adjusted(NSRect(x: 346, y: 247, width: 300, height: 200), in: area, resizing: false)
        guard centered.midX == area.midX, centered.midY == area.midY else { return false }
        let edge = WidgetAlignment.adjusted(NSRect(x: 694, y: 497, width: 300, height: 200), in: area, resizing: false)
        guard edge.maxX == area.maxX, edge.maxY == area.maxY else { return false }
        let huge = WidgetAlignment.fit(NSRect(x: -100, y: 900, width: 3000, height: 2000), in: area)
        guard huge == area else { return false }
        let resized = WidgetAlignment.adjusted(NSRect(x: 700, y: 500, width: 999, height: 999), in: area, resizing: true)
        guard area.contains(resized), resized.origin == NSPoint(x:700,y:500), resized.size == NSSize(width:300,height:200) else { return false }
        let reference=NSSize(width:1000,height:700)
        for width in [762.0,1000,1238,1800] {for height in [500.0,656,700,900] {
            let viewport=NSRect(x:0,y:0,width:width,height:height)
            for (x,right) in [(12.0,false),(688.0,true)] {for (y,bottom) in [(12.0,false),(488.0,true)] {
                let anchored=WidgetAlignment.anchored(NSRect(x:x,y:y,width:300,height:200),reference:reference,in:viewport)
                guard viewport.contains(anchored),abs((right ? viewport.maxX-anchored.maxX:anchored.minX)-12)<0.001,
                      abs((bottom ? viewport.maxY-anchored.maxY:anchored.minY)-12)<0.001 else{return false}
            }}
            let centered=WidgetAlignment.anchored(NSRect(x:350,y:250,width:300,height:200),reference:reference,in:viewport)
            guard centered.midX==viewport.midX && centered.midY==viewport.midY else{return false}
        }}
        // Adjacent cards on the same side must translate identically, even
        // when one is closer to center and the other is closer to the edge.
        let clusterReference=NSSize(width:1700,height:1100)
        let music=NSRect(x:1010,y:20,width:300,height:260)
        let stocks=NSRect(x:1330,y:20,width:350,height:260)
        let events=NSRect(x:1010,y:660,width:300,height:220)
        let usage=NSRect(x:1010,y:900,width:300,height:180)
        for viewport in [NSRect(x:0,y:0,width:1938,height:1144),NSRect(x:0,y:0,width:1700,height:1056)] {
            let a=WidgetAlignment.anchored(music,reference:clusterReference,in:viewport)
            let b=WidgetAlignment.anchored(stocks,reference:clusterReference,in:viewport)
            let c=WidgetAlignment.anchored(events,reference:clusterReference,in:viewport)
            let d=WidgetAlignment.anchored(usage,reference:clusterReference,in:viewport)
            guard abs((a.minX-music.minX)-(b.minX-stocks.minX))<0.001,
                  abs((b.minX-a.maxX)-(stocks.minX-music.maxX))<0.001,
                  abs((c.minY-events.minY)-(d.minY-usage.minY))<0.001,
                  abs((d.minY-c.maxY)-(usage.minY-events.maxY))<0.001,
                  !a.intersects(b),!c.intersects(d) else{return false}
        }
        // A neighboring pair crossing the midpoint must keep its spacing.
        // The old per-card anchors moved one by zero and the other by delta.
        let middle=[NSRect(x:300,y:200,width:180,height:140),NSRect(x:500,y:200,width:180,height:140),
                    NSRect(x:500,y:360,width:180,height:140)]
        for width in [762.0,1000,1238,1700] {for height in [540.0,700,1000] {
            let viewport=NSRect(x:0,y:0,width:width,height:height)
            let moved=WidgetAlignment.arrangement(middle,reference:reference,in:viewport)
            guard moved.allSatisfy({viewport.contains($0)}),
                  abs(moved[1].minX-moved[0].maxX-20)<0.001,
                  abs(moved[2].minY-moved[1].maxY-20)<0.001,
                  moved.map(\.size)==middle.map(\.size) else{return false}
            guard WidgetAlignment.arrangement(middle,reference:reference,in:NSRect(origin:.zero,size:reference))==middle else{return false}
        }}
        // A right-hand cluster clamps together when shrinking, preserving the
        // gap even when only its outside card would previously hit the edge.
        let edgePair=[NSRect(x:600,y:30,width:170,height:140),NSRect(x:790,y:30,width:190,height:140)]
        let narrow=WidgetAlignment.arrangement(edgePair,reference:reference,in:NSRect(x:0,y:0,width:650,height:500))
        guard narrow[1].minX-narrow[0].maxX==20,narrow[1].maxX==630 else{return false}
        let padded=WidgetAlignment.paddedBounds(area)
        let bottomSnap=WidgetAlignment.adjusted(NSRect(x:701,y:498,width:280,height:190),in:padded,resizing:false)
        guard bottomSnap.maxX==area.maxX-12,bottomSnap.maxY==area.maxY-12 else{return false}
        let chain=[NSRect(x:12,y:12,width:200,height:200),NSRect(x:12,y:230,width:200,height:200),NSRect(x:12,y:448,width:200,height:240)]
        for height in [700.0,800,950] {
            let viewport=NSRect(x:0,y:0,width:1000,height:height)
            let moved=WidgetAlignment.paddedArrangement(chain,reference:reference,in:viewport)
            guard moved[0].minY==12,moved[2].maxY==height-12,
                  moved.allSatisfy({WidgetAlignment.paddedBounds(viewport).contains($0)}),
                  moved[2].minY-moved[1].maxY==18 else{return false}
        }
        let fixedScroll=WidgetCanvasScrollView(frame:NSRect(x:0,y:0,width:800,height:600))
        let fixedCanvas=WidgetCanvas(frame:fixedScroll.bounds)
        fixedScroll.documentView=fixedCanvas;fixedScroll.layoutSubtreeIfNeeded()
        let scrollOrigin=fixedScroll.contentView.bounds.origin
        if let cg=CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:160,wheel2:0,wheel3:0),let event=NSEvent(cgEvent:cg) {
            fixedScroll.scrollWheel(with:event)
            guard fixedScroll.contentView.bounds.origin==scrollOrigin else{return false}
        } else{return false}
        guard fixedScroll.verticalScrollElasticity == .none,fixedScroll.horizontalScrollElasticity == .none else{return false}
        print("PASS: fixed homepage scrolling, padded edge snaps, independent bottom anchor and group spacing")
        // Reproduce the reported overlap: startup saved a 900x680 reference,
        // while the untouched arrangement actually occupied 1225x936.
        let raw=[NSRect(x:574,y:0,width:260,height:417),NSRect(x:844,y:0,width:381,height:375),
                 NSRect(x:739,y:601,width:486,height:335),NSRect(x:868,y:379,width:357,height:207)]
        let repaired=WidgetAlignment.repairedReference(NSSize(width:900,height:680),frames:raw)
        let offset=WidgetAlignment.legacyTranslation(NSSize(width:900,height:680),frames:raw)
        guard repaired==NSSize(width:1440,height:936),offset==215 else{return false}
        let normalized=raw.map{$0.offsetBy(dx:offset,dy:0)}
        let recovered=normalized.map{WidgetAlignment.anchored($0,reference:repaired,in:NSRect(x:0,y:0,width:1700,height:1100))}
        guard !recovered[0].intersects(recovered[1]),!recovered[2].intersects(recovered[3]),
              abs((recovered[1].minX-recovered[0].maxX)-10)<0.001,
              abs((recovered[2].minY-recovered[3].maxY)-15)<0.001 else{return false}
        for frame in normalized {guard WidgetAlignment.anchored(frame,reference:repaired,in:NSRect(origin:.zero,size:repaired))==frame else{return false}}
        let centeredPR=NSRect(x:295+offset,y:660,width:420,height:275)
        let movedPR=WidgetAlignment.anchored(centeredPR,reference:repaired,in:NSRect(x:0,y:0,width:1700,height:1100))
        guard movedPR.midX==850 else{return false}
        print("PASS: startup reference repair preserves untouched coordinates and restores adjacent widget spacing")
        showAlignmentGuides(for: bounds.insetBy(dx: bounds.width / 4, dy: bounds.height / 4))
        guard !alignmentGuides.isHidden, alignmentGuides.path?.isEmpty == false,
              alignmentGuides.animationKeys()?.isEmpty != false else { return false }
        hideAlignmentGuides()
        guard alignmentGuides.isHidden, alignmentGuides.path == nil else { return false }
        print("PASS: widget center/edge snapping, all viewport boundaries, oversized restoration, resize bounds, nonanimated guide cleanup")
        return true
    }
}

extension GlassWidgetCard {
    func verifyCalendarBrand()->Bool {
        guard WidgetBrandImages.googleCalendar != nil else{return false}
        for size in [(64,64),(200,140),(320,208),(420,480)] {
            frame=NSRect(x:0,y:0,width:size.0,height:size.1);needsLayout=true;layoutSubtreeIfNeeded()
            calendarView.needsLayout=true;calendarView.layoutSubtreeIfNeeded()
            guard let brand=calendarView.subviews.compactMap({$0 as? NSImageView}).first,
                  brand.image != nil,calendarView.bounds.contains(brand.frame) else{return false}
            for button in calendarView.subviews.compactMap({$0 as? NSButton}) where !button.isHidden {
                if button.frame.intersects(brand.frame){return false}
            }
        }
        return true
    }
}
extension WidgetCanvas {
    func verifyServiceBrands()->Bool {
        let card=GlassWidgetCard(kind:.calendar,frame:NSRect(x:0,y:0,width:320,height:208))
        return card.verifyCalendarBrand() && WidgetBrandImages.spotify != nil
    }
}

extension WidgetCanvas {
    func verifyCalculatorFocus() -> Bool {
        let card=GlassWidgetCard(kind:.calculator,frame:NSRect(x:0,y:0,width:340,height:240))
        addSubview(card)
        defer {window?.makeFirstResponder(nil);card.removeFromSuperview()}
        return card.verifyCalculatorInput()
    }
}
