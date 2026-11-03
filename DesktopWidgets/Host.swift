import AppKit
import WidgetKit

@MainActor enum DesktopWidgetBridge {
    static func configure() {
        let alert=NSAlert()
        alert.messageText="Webby on your desktop"
        alert.informativeText="Let’s make your profiles available in macOS Edit Widgets. Calendar and GitHub may ask for Keychain authorization once. We leave your original credentials untouched. macOS schedules refreshes even when Webby is quit. Music, Codex and downloads use saved snapshots."
        alert.addButton(withTitle:"Enable Desktop Widgets")
        alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        do {
            let result=try importProfiles(authorize:true)
            UserDefaults.standard.set(true,forKey:"webbyDesktopWidgetsEnabled")
            WidgetCenter.shared.reloadAllTimelines()
            let done=NSAlert();done.messageText="Let’s add your widgets"
            done.informativeText="Right-click your desktop → Edit Widgets → Webby. Choose a widget, then edit it to select a profile. Connected \(result.profiles.count) profiles and authorized \(result.credentials) Calendar/GitHub connections. You can fully quit Webby afterward."
            done.runModal()
        } catch {
            let failed=NSAlert();failed.messageText="Desktop widget setup didn’t finish";failed.informativeText=error.localizedDescription;failed.runModal()
        }
    }
    static func syncIfEnabled() {
        guard UserDefaults.standard.bool(forKey:"webbyDesktopWidgetsEnabled") else{return}
        // No Keychain prompts, networking, clipboard reads or browser changes here.
        do {_ = try importProfiles(authorize:false);WidgetCenter.shared.reloadAllTimelines()}
        catch {NSLog("Desktop widget snapshot sync failed")}
    }
    private static func importProfiles(authorize:Bool) throws -> (profiles:[DesktopProfile],credentials:Int) {
        struct Source:Decodable {let id:UUID;let name:String}
        let url=DesktopStorage.home.appendingPathComponent("Library/Application Support/WebKit Browser/ChromeSpaces.json")
        let sources=try JSONDecoder().decode([Source].self,from:Data(contentsOf:url))
        guard !sources.isEmpty else {throw NSError(domain:"WebbyWidgets",code:1,userInfo:[NSLocalizedDescriptionKey:"Open Webby once to create a profile."])}
        let defaults=UserDefaults.standard
        let extensionPath=Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/WebbyWidgets.appex").path
        var result:[DesktopProfile]=[],connections=0
        for s in sources {
            let p=DesktopProfile(id:s.id,name:s.name,city:defaults.string(forKey:"webbyWeatherCity.\(s.id.uuidString)") ?? "San Francisco",stock:defaults.string(forKey:"webbyStockSymbol.\(s.id.uuidString)") ?? "AAPL",note:defaults.string(forKey:"webbyNote.\(s.id.uuidString)") ?? "")
            result.append(p)
            for service in ["local.plainwebkit.calendar-feed","local.plainwebkit.github-widgets"] {
                if authorize,try DesktopCredentials.copy(service:service,profile:s.id,extensionPath:extensionPath){connections+=1}
            }
            for kind in ["weather","stocks"] {
                if let data=defaults.data(forKey:"webbyWidgetSnapshot.v1.\(s.id.uuidString).\(kind)"),let record=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let value=record["value"],let valueData=try? JSONSerialization.data(withJSONObject:value) {
                    if kind=="weather",let value=try? JSONDecoder().decode(WeatherSnapshot.self,from:valueData){try DesktopStorage.write(value,to:DesktopStorage.cache(s.id,kind))}
                    if kind=="stocks",let value=try? JSONDecoder().decode(StockSnapshot.self,from:valueData){try DesktopStorage.write(value,to:DesktopStorage.cache(s.id,kind))}
                }
            }
            if let data=defaults.data(forKey:"webbyCalendarSnapshot.v1.\(s.id.uuidString)"),let record=try? JSONSerialization.jsonObject(with:data) as? [String:Any],let value=record["snapshot"],let bytes=try? JSONSerialization.data(withJSONObject:value),let snapshot=try? JSONDecoder().decode(CalendarSnapshot.self,from:bytes) {try DesktopStorage.write(snapshot,to:DesktopStorage.cache(s.id,"calendar"))}
            for kind in GitHubWidgetKind.allCases {
                let source=DesktopStorage.home.appendingPathComponent("Library/Application Support/Webby/GitHub Widgets/\(s.id.uuidString)-\(kind.rawValue).json")
                if let value=DesktopStorage.read(GitHubWidgetSnapshot.self,from:source){try DesktopStorage.write(value,to:DesktopStorage.cache(s.id,"github-"+kind.rawValue))}
            }
        }
        DesktopCredentials.prune(profiles:Set(result.map(\.id)))
        var local=DesktopLocal()
        if let data=defaults.data(forKey:"webbyLastSpotifyTrack"){local.music=try? JSONDecoder().decode(DesktopMusic.self,from:data)}
        local.usage=DesktopStorage.read(DesktopUsage.self,from:DesktopStorage.home.appendingPathComponent("Library/Application Support/Webby/Codex App/widgets.json"))
        // Clipboard is never read on startup/quit. Native clipboard monitoring is not supported.
        local.downloads=WidgetSystemData.recentDownloads().map(\.path)
        try DesktopStorage.write(local,to:DesktopStorage.directory.appendingPathComponent("local.json"))
        try DesktopStorage.write(result,to:DesktopStorage.configuration)
        return (result,connections)
    }
}
