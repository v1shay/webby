import SwiftUI
import WidgetKit
import AppIntents

@main struct Checks {
    @MainActor static func main() async throws {
        let profiles=[DesktopProfile(id:UUID(),name:"Fixture One",city:"San Francisco",stock:"AAPL",note:"First profile"),DesktopProfile(id:UUID(),name:"Fixture Two",city:"San Jose",stock:"MSFT",note:"Second profile")]
        try DesktopStorage.write(profiles,to:DesktopStorage.configuration)
        let w=WeatherSnapshot(city:"San Francisco",temperature:67,high:72,low:54,humidity:60,code:0,isDay:true,hours:(0..<5).map{WeatherHour(label:"\($0+1)p",temperature:67+$0,code:0)})
        try DesktopStorage.write(w,to:DesktopStorage.cache(profiles[0].id,"weather"))
        var config=ProfileIntent();config.profile=ProfileEntity(id:profiles[0].id.uuidString,name:profiles[0].name)
        let first=Provider(kind:"weather").cached(config)
        precondition(first.weather?.temperature==67)
        config.profile=ProfileEntity(id:profiles[1].id.uuidString,name:profiles[1].name)
        let second=Provider(kind:"weather").cached(config)
        precondition(second.weather==nil && second.profile?.note=="Second profile")
        config.profile=ProfileEntity(id:UUID().uuidString,name:"Deleted")
        precondition(Provider(kind:"weather").cached(config).profile==nil)
        var usage=DesktopLocal();usage.usage=DesktopUsage(chats:[],windows:[.init(used:37,minutes:300,resets:nil)],updated:Date(),usageUpdated:Date())
        let stock=StockSnapshot(symbol:"AAPL",price:"$240.00",changePercent:1.25,asOf:"Fixture",chart:[1,3,2,5,4,7])
        let event=CalendarEvent(id:"fixture",title:"Upcoming event",location:"",start:Date().addingTimeInterval(86400),end:Date().addingTimeInterval(90000),allDay:false)
        let calendar=CalendarSnapshot(month:Date(),events:[event],updated:Date(),stale:false,limited:false,upcoming:[event])
        let destination=DesktopStorage.directory.appendingPathComponent("renders")
        try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
        var count=0
        for kind in NativeWidget.names.keys.sorted() {
            for (family,size) in [(WidgetFamily.systemSmall,CGSize(width:160,height:170)),(.systemMedium,CGSize(width:350,height:170)),(.systemLarge,CGSize(width:350,height:370))] {
                var entry=WidgetEntry(profile:profiles[0],kind:kind)
                entry.weather=w;entry.stock=stock;entry.calendar=calendar;entry.local=usage
                entry.github=GitHubWidgetSnapshot(login:"fixture",rows:[.init(title:"Repository",detail:"Fixture repository",url:"https://github.com/example/repo",symbol:"book")],total:1,updated:Date())
                entry.battery=BatterySnapshot(percentage:68,charging:false,timeRemaining:nil,name:"Mac")
                let view=WidgetView(entry:entry,family:family).environment(\.colorScheme,.dark).padding(16).frame(width:size.width,height:size.height)
                let renderer=ImageRenderer(content:view);renderer.scale=2
                guard let image=renderer.nsImage,let tiff=image.tiffRepresentation,let rep=NSBitmapImageRep(data:tiff),let png=rep.representation(using:.png,properties:[:]) else {fatalError("Render failed: \(kind)")}
                try png.write(to:destination.appendingPathComponent("\(kind)-\(family.rawValue).png"))
                count+=1
            }
        }
        let flat=Sparkline(values:[2,2,2]).path(in:CGRect(x:0,y:0,width:100,height:50))
        precondition(!flat.isEmpty)
        let invalid=Sparkline(values:[Double.nan,Double.infinity]).path(in:CGRect(x:0,y:0,width:100,height:50))
        precondition(invalid.isEmpty)
        print("PASS: cached startup, profile isolation, deleted profiles, finite chart handling, \(count) native widget renders")
    }
}
