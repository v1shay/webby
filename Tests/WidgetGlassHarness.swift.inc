extension GlassWidgetCard {
    func verifyMusicLayouts() -> Bool {
        setMusic(SpotifySnapshot(title:"Summers Over Interlude",artist:"Drake",album:"Views",artworkURL:"",position:20,duration:180,isPlaying:true))
        albumArt.image=NSImage(size:NSSize(width:64,height:64))
        var smallCover:CGFloat=0
        for (w,h) in [(64,64),(170,160),(200,140),(260,170),(340,270),(340,440),(600,220),(800,600)] {
            frame=NSRect(x:0,y:0,width:w,height:h);needsLayout=true;layoutSubtreeIfNeeded()
            guard abs(albumArt.frame.width-albumArt.frame.height)<0.01, bounds.contains(albumArt.frame) else{return false}
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
