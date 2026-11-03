import SwiftUI
import WidgetKit
import AppIntents
import CoreText

struct ProfileEntity:AppEntity {
    static var typeDisplayRepresentation:TypeDisplayRepresentation="Webby profile"
    static var defaultQuery=ProfileQuery()
    var id:String
    var name:String
    var displayRepresentation:DisplayRepresentation { .init(title:"\(name)") }
}
struct ProfileQuery:EntityQuery {
    func entities(for identifiers:[String]) async throws->[ProfileEntity] {DesktopStorage.profiles().filter{identifiers.contains($0.id.uuidString)}.map{.init(id:$0.id.uuidString,name:$0.name)}}
    func suggestedEntities() async throws->[ProfileEntity] {DesktopStorage.profiles().map{.init(id:$0.id.uuidString,name:$0.name)}}
    func defaultResult() async->ProfileEntity? {DesktopStorage.profiles().first.map{.init(id:$0.id.uuidString,name:$0.name)}}
}
struct ProfileIntent:WidgetConfigurationIntent {
    static var title:LocalizedStringResource="Webby profile"
    static var description=IntentDescription("Choose which profile this widget belongs to.")
    @Parameter(title:"Profile") var profile:ProfileEntity?
}
struct WidgetEntry:TimelineEntry {
    var date=Date()
    var profile:DesktopProfile?
    var kind:String
    var weather:WeatherSnapshot?
    var stock:StockSnapshot?
    var calendar:CalendarSnapshot?
    var github:GitHubWidgetSnapshot?
    var local:DesktopLocal?
    var battery:BatterySnapshot?
    var memory:String?
    var disk:String?
    var artwork:Data?
    var status=""
    var updated:Date?
}
struct Provider:AppIntentTimelineProvider {
    var kind:String
    func placeholder(in context:Context)->WidgetEntry { WidgetEntry(kind:kind,status:"Connect in Webby → Widgets & Backgrounds → Desktop Widgets") }
    func snapshot(for configuration:ProfileIntent,in context:Context) async->WidgetEntry { cached(configuration) }
    func timeline(for configuration:ProfileIntent,in context:Context) async->Timeline<WidgetEntry> {
        var entry=cached(configuration)
        guard let profile=entry.profile else{return Timeline(entries:[entry],policy:.after(Date().addingTimeInterval(900)))}
        do {
            switch kind {
            case "weather":
                entry.weather=try await WidgetFeeds.weather(city:profile.city).weather
                if let value=entry.weather {try DesktopStorage.write(value,to:DesktopStorage.cache(profile.id,kind))}
            case "stocks":
                entry.stock=try await WidgetFeeds.stock(symbol:profile.stock).stock
                if let value=entry.stock {try DesktopStorage.write(value,to:DesktopStorage.cache(profile.id,kind))}
            case "calendar":
                entry.calendar=try await CalendarFeed.shared.load(profile:profile.id)
                if let value=entry.calendar {try DesktopStorage.write(value,to:DesktopStorage.cache(profile.id,kind))}
            case let key where key.hasPrefix("github-"):
                if let service=GitHubWidgetKind(rawValue:String(key.dropFirst(7))),service != .recent {
                    entry.github=try await GitHubWidgetStore.shared.refresh(profile:profile.id,kind:service)
                    if let value=entry.github {try DesktopStorage.write(value,to:DesktopStorage.cache(profile.id,kind))}
                }
            default:break
            }
            if ["weather","stocks","calendar"].contains(kind) || (kind.hasPrefix("github-") && kind != "github-recent") {entry.updated=Date();entry.status=""}
        } catch {
            entry.status="Saved · refresh unavailable"
            if entry.weather == nil && entry.stock == nil && entry.calendar == nil && entry.github == nil {entry.status="Connect this profile in Webby’s Desktop Widgets settings"}
        }
        if kind=="music",let text=entry.local?.music?.artworkURL,let url=URL(string:text),url.scheme=="https" {
            let artFile=DesktopStorage.directory.appendingPathComponent("spotify-art.json")
            struct Art:Codable {var url:String;var data:Data}
            if let art=DesktopStorage.read(Art.self,from:artFile),art.url==text {entry.artwork=art.data}
            else if let (data,response)=try? await URLSession.shared.data(for:URLRequest(url:url,timeoutInterval:10)),(response as? HTTPURLResponse)?.statusCode==200,data.count<1_000_000,NSImage(data:data) != nil {
                entry.artwork=data;try? DesktopStorage.write(Art(url:text,data:data),to:artFile)
            }
        }
        // WidgetKit owns scheduling; no background polling loops or browser launch.
        return Timeline(entries:[entry],policy:.after(Date().addingTimeInterval(kind=="weather" ? 1800:900)))
    }
    func cached(_ configuration:ProfileIntent)->WidgetEntry {
        let profiles=DesktopStorage.profiles()
        let profile:DesktopProfile?
        if let id=configuration.profile?.id {profile=profiles.first{$0.id.uuidString==id}}
        else {profile=profiles.first}
        var entry=WidgetEntry(profile:profile,kind:kind)
        guard let profile else {entry.status="Enable Desktop Widgets in Webby";return entry}
        entry.weather=DesktopStorage.read(WeatherSnapshot.self,from:DesktopStorage.cache(profile.id,"weather"))
        entry.stock=DesktopStorage.read(StockSnapshot.self,from:DesktopStorage.cache(profile.id,"stocks"))
        entry.calendar=DesktopStorage.read(CalendarSnapshot.self,from:DesktopStorage.cache(profile.id,"calendar"))
        if kind.hasPrefix("github-"){entry.github=DesktopStorage.read(GitHubWidgetSnapshot.self,from:DesktopStorage.cache(profile.id,kind))}
        entry.local=DesktopStorage.read(DesktopLocal.self,from:DesktopStorage.directory.appendingPathComponent("local.json"))
        if kind=="battery"{entry.battery=WidgetSystemData.battery()}
        if kind=="systemMonitor"{entry.memory=WidgetSystemData.memory();entry.disk=WidgetSystemData.disk()}
        if ["music","codex","codexUsage","downloads","github-recent"].contains(kind) {entry.status="Saved · sync when Webby opens";entry.updated=entry.local?.updated}
        return entry
    }
}
enum NativeTypography {
    static let register:Void = {
        for name in ["Geist-VariableFont_wght","Geist-Italic-VariableFont_wght"] {
            if let url=Bundle.main.url(forResource:name,withExtension:"ttf") {CTFontManagerRegisterFontsForURL(url as CFURL,.process,nil)}
        }
    }()
}
struct WidgetView:View {
    var entry:WidgetEntry
    @Environment(\.widgetFamily) private var family
    var small:Bool {family == .systemSmall}
    var title:String {NativeWidget.names[entry.kind] ?? "Webby"}
    var body:some View {
        let _=NativeTypography.register
        VStack(alignment:.leading,spacing:10) {
            if entry.profile == nil {Image(systemName:"square.grid.2x2").font(.largeTitle);Text("Webby").bold();Text(entry.status).font(.caption).foregroundStyle(.secondary)}
            else {
                content
                if !entry.status.isEmpty {Text(entry.status).font(.custom("Geist",size:10)).foregroundStyle(.secondary).lineLimit(2)}
            }
        }
        .font(.custom("Geist",size:13)).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        .containerBackground(for:.widget) {
            Rectangle().fill(.ultraThinMaterial).overlay(LinearGradient(colors:[.white.opacity(0.12),.white.opacity(0.015)],startPoint:.topLeading,endPoint:.bottomTrailing))
        }
        .widgetURL(destination)
    }
    var destination:URL? {
        switch entry.kind {
        case "calendar":URL(string:"https://calendar.google.com")
        case "music":URL(string:"spotify:")
        case "codex","codexUsage":URL(string:"codex:")
        case "gmail":URL(string:"https://mail.google.com")
        case "drive":URL(string:"https://drive.google.com")
        case "chatgpt":URL(string:"https://chatgpt.com")
        case "stocks":URL(string:"https://www.nasdaq.com/market-activity/stocks/"+(entry.profile?.stock.lowercased() ?? "aapl"))
        case let value where value.hasPrefix("github-"):URL(string:"https://github.com")
        default:nil
        }
    }
    @ViewBuilder var content:some View {
        switch entry.kind {
        case "weather":weather
        case "stocks":stocks
        case "calendar":calendar
        case "music":music
        case "codexUsage":usage
        case "codex":chats
        case "battery":battery
        case "systemMonitor":system
        case "note":Text("Quick Note").font(.headline);Text(entry.profile?.note.isEmpty == false ? entry.profile!.note:"Add a note in Webby").frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.topLeading)
        case "downloads":heading("arrow.down.to.line");ForEach(Array((entry.local?.downloads ?? []).prefix(small ? 2:5)),id:\.self){path in Text(URL(fileURLWithPath:path).lastPathComponent).lineLimit(1)}
        case let value where value.hasPrefix("github-"):github
        default:heading("arrow.up.forward.app");Spacer();Text("Open \(title)").font(.headline);Text("Available in Webby").font(.caption).foregroundStyle(.secondary);Spacer()
        }
    }
    func heading(_ symbol:String)->some View {HStack {Image(systemName:symbol);Text(title).font(.headline);Spacer()}}
    func brand(_ name:String)->some View {Group {if let url=Bundle.main.url(forResource:name,withExtension:name=="GoogleCalendar" ? "svg":"png"),let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().scaledToFit().frame(width:22,height:22)}}}
    func weatherSymbol(_ code:Int)->String {
        switch code {case 0:return "sun.max.fill";case 1,2:return "cloud.sun.fill";case 3:return "cloud.fill";case 45,48:return "cloud.fog.fill";case 71...77,85,86:return "cloud.snow.fill";case 95...99:return "cloud.bolt.rain.fill";default:return "cloud.rain.fill"}
    }
    @ViewBuilder var weather:some View {
        if let w=entry.weather {
            HStack(spacing:16) {Image(systemName:weatherSymbol(w.code)).symbolRenderingMode(.multicolor).font(.system(size:small ? 36:55));VStack(alignment:.leading,spacing:4){Text(w.city).font(.headline);Text("\(w.temperature)°").font(.custom("Geist",size:small ? 36:46));if !small {Text("\(w.condition) · H \(w.high ?? w.temperature)° L \(w.low ?? w.temperature)°").font(.caption)}}}
            Spacer(minLength:0)
            HStack {ForEach(Array(w.hours.prefix(small ? 3:5).enumerated()),id:\.offset){_,hour in VStack(spacing:5){Image(systemName:weatherSymbol(hour.code)).symbolRenderingMode(.multicolor);Text(hour.label).foregroundStyle(.secondary);Text("\(hour.temperature)°")}.font(.caption).frame(maxWidth:.infinity)}}
        } else {heading("cloud.sun.fill");Spacer();Text(entry.status.isEmpty ? "Refreshing weather…":entry.status).foregroundStyle(.secondary);Spacer()}
    }
    @ViewBuilder var stocks:some View {
        if let s=entry.stock {HStack {Text(s.symbol).font(.headline);Spacer();Text(String(format:"%+.2f%%",s.changePercent)).font(.caption.bold()).foregroundStyle(s.changePercent>=0 ? .green:.red)};Text(s.price).font(.custom("Geist",size:small ? 30:40));Sparkline(values:s.chart).stroke(s.changePercent>=0 ? Color.green:Color.red,lineWidth:2).frame(maxHeight:.infinity);if !small {Text(s.asOf).font(.caption2).foregroundStyle(.secondary).lineLimit(1)}}
        else {heading("chart.line.uptrend.xyaxis");Spacer();Text("Refreshing quote…").foregroundStyle(.secondary);Spacer()}
    }
    @ViewBuilder var calendar:some View {
        HStack {brand("GoogleCalendar");Text(Date(),format:.dateTime.month(.wide).year()).font(.headline);Spacer()}
        let cal=Calendar.current
        let start=cal.date(from:cal.dateComponents([.year,.month],from:entry.date)) ?? entry.date
        let days=cal.range(of:.day,in:.month,for:start) ?? 1..<29
        let offset=(cal.component(.weekday,from:start)-cal.firstWeekday+7)%7
        VStack(spacing:family == .systemLarge ? 6:2) {
            HStack(spacing:2) {ForEach(0..<7,id:\.self){i in Text(cal.veryShortWeekdaySymbols[(cal.firstWeekday-1+i)%7]).foregroundStyle(.secondary).frame(maxWidth:.infinity)}}
            ForEach(0..<((offset+days.count+6)/7),id:\.self){row in
                HStack(spacing:2) {ForEach(0..<7,id:\.self){column in
                    let day=row*7+column-offset+1
                    let date=cal.date(byAdding:.day,value:day-1,to:start) ?? start
                    let valid=days.contains(day)
                    let today=valid && cal.isDateInToday(date)
                    Text(valid ? "\(day)":" ").frame(maxWidth:.infinity).padding(.vertical,family == .systemLarge ? 2:0).background(today ? Color.cyan:Color.clear,in:RoundedRectangle(cornerRadius:6))
                }}
            }
        }.font(.custom("Geist",size:family == .systemLarge ? 12:9))
        if family == .systemLarge {ForEach(Array((entry.calendar?.upcoming ?? []).filter{$0.end>entry.date}.prefix(family == .systemLarge ? 3:1)),id:\.id){event in HStack {RoundedRectangle(cornerRadius:2).fill(.cyan).frame(width:3);VStack(alignment:.leading){Text(event.title).lineLimit(1);Text(event.start,format:.dateTime.month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)}}.frame(height:40)}}
        if entry.calendar == nil {Text("Connect your calendar in Webby").font(.caption2).foregroundStyle(.secondary)}
    }
    @ViewBuilder var music:some View {
        HStack {brand("Spotify");Text("Spotify").font(.headline);Spacer()}
        if let track=entry.local?.music {
            HStack(spacing:12) {if let data=entry.artwork,let image=NSImage(data:data){Image(nsImage:image).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius:10)).frame(maxWidth:small ? 70:130,maxHeight:130)};VStack(alignment:.leading,spacing:6){Text(track.title).font(.headline).lineLimit(2);Text(track.artist+" · "+track.album).foregroundStyle(.secondary).lineLimit(2)}}.frame(maxHeight:.infinity)
            ProgressView(value:max(0,min(track.position,track.duration)),total:max(1,track.duration)).tint(.white)
        } else {Spacer();Text("Play a track in Spotify, then sync in Webby.").foregroundStyle(.secondary);Spacer()}
    }
    @ViewBuilder var usage:some View {
        Text("Codex Usage").font(.headline)
        GeometryReader {g in
            let side=max(20,min(g.size.width,g.size.height)-12)
            ZStack {Circle().stroke(.white.opacity(0.12),lineWidth:6)
                if let used=entry.local?.usage?.windows.first?.used,used.isFinite {Circle().trim(from:0,to:max(0,min(100,used))/100).stroke(.mint,style:StrokeStyle(lineWidth:6,lineCap:.round)).rotationEffect(.degrees(-90))}
                if let url=Bundle.main.url(forResource:"CodexWhiteIcon",withExtension:"png"),let image=NSImage(contentsOf:url){Image(nsImage:image).resizable().scaledToFit().padding(side*0.23)}
            }.frame(width:side,height:side).frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
    @ViewBuilder var chats:some View {heading("chevron.left.forwardslash.chevron.right");ForEach(Array((entry.local?.usage?.chats ?? []).prefix(small ? 3:5)),id:\.id){chat in if let url=URL(string:"codex://threads/"+chat.id){Link(chat.title,destination:url).lineLimit(1)}};Spacer(minLength:0)}
    @ViewBuilder var github:some View {
        heading("chevron.left.forwardslash.chevron.right")
        if let gh=entry.github {
            if entry.kind=="github-contributions" {
                Text("\(gh.total) contributions").font(.headline)
                let columns=small ? 12:25
                LazyHGrid(rows:Array(repeating:GridItem(.flexible(),spacing:3),count:7),spacing:3){ForEach(Array(gh.days.suffix(columns*7).enumerated()),id:\.offset){_,day in RoundedRectangle(cornerRadius:2).fill(Color.green.opacity(day.contributionCount==0 ? 0.10:min(1,0.25+Double(day.contributionCount)*0.12))).aspectRatio(1,contentMode:.fit)}}
            } else {ForEach(Array(gh.rows.prefix(small ? 3:5).enumerated()),id:\.offset){_,row in if let url=URL(string:row.url),url.scheme=="https",url.host=="github.com" {Link(destination:url){VStack(alignment:.leading,spacing:3){Text(row.title).lineLimit(1);if !small {Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)}}}}};if gh.rows.isEmpty {Text("Nothing here yet").foregroundStyle(.secondary)}}
        } else {Spacer();Text("Connect GitHub in Webby").foregroundStyle(.secondary)}
        Spacer(minLength:0)
    }
    @ViewBuilder var battery:some View {heading("battery.100percent");Spacer();if let b=entry.battery {Text("\(b.percentage)%").font(.custom("Geist",size:48));ProgressView(value:Double(b.percentage),total:100).tint(.green);Text(b.charging ? "Charging":"On battery").foregroundStyle(.secondary)}else{Text("No battery detected")};Spacer()}
    @ViewBuilder var system:some View {heading("waveform.path.ecg");Spacer();LabeledContent("Memory",value:entry.memory ?? "—");LabeledContent("Disk",value:entry.disk ?? "—");Spacer();Text("Updated on macOS’s schedule").font(.caption2).foregroundStyle(.secondary)}
}
struct Sparkline:Shape {
    var values:[Double]
    func path(in rect:CGRect)->Path {
        let values=values.filter(\.isFinite)
        guard values.count>1,let low=values.min(),let high=values.max() else{return Path()}
        let span=max(0.001,high-low)
        return Path {p in for (i,y) in values.enumerated(){let point=CGPoint(x:rect.minX+CGFloat(i)/CGFloat(values.count-1)*rect.width,y:rect.maxY-CGFloat((y-low)/span)*rect.height);if i==0{p.move(to:point)}else{p.addLine(to:point)}}}
    }
}
struct NativeWidget:Widget {
    static let names=["weather":"Weather","stocks":"Stocks","calendar":"Google Calendar","music":"Spotify","codexUsage":"Codex Usage","codex":"Codex Chats","battery":"Battery","systemMonitor":"System Monitor","note":"Quick Note","downloads":"Downloads","github-prs":"Open PRs","github-contributions":"Contributions","github-recent":"Recently Visited","github-repos":"Repositories","github-issues":"Assigned Issues","github-stars":"Starred Repos","github-news":"GitHub Activity"]
    var source:String="weather"
    var body:some WidgetConfiguration {
        AppIntentConfiguration(kind:"Webby."+source,intent:ProfileIntent.self,provider:Provider(kind:source)){entry in WidgetView(entry:entry)}
            .configurationDisplayName(Self.names[source] ?? source)
            .description("Your Webby profile on your desktop.")
            .supportedFamilies([.systemSmall,.systemMedium,.systemLarge])
    }
}
@main struct WebbyWidgets:WidgetBundle {
    var body:some Widget {CoreWidgets().body;GitHubWidgets().body;LocalWidgets().body}
}
struct CoreWidgets:WidgetBundle {var body:some Widget {NativeWidget(source:"weather");NativeWidget(source:"stocks");NativeWidget(source:"calendar");NativeWidget(source:"music");NativeWidget(source:"codexUsage");NativeWidget(source:"codex")}}
struct GitHubWidgets:WidgetBundle {var body:some Widget {NativeWidget(source:"github-prs");NativeWidget(source:"github-contributions");NativeWidget(source:"github-recent");NativeWidget(source:"github-repos");NativeWidget(source:"github-issues");NativeWidget(source:"github-stars");NativeWidget(source:"github-news")}}
struct LocalWidgets:WidgetBundle {var body:some Widget {NativeWidget(source:"battery");NativeWidget(source:"systemMonitor");NativeWidget(source:"note");NativeWidget(source:"downloads")}}
