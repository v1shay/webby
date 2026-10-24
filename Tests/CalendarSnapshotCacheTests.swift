import Foundation
@main struct CalendarCacheTests {
 static func main() {
 let profile=UUID(), other=UUID()
 defer { CalendarSnapshotCache.remove(profile);CalendarSnapshotCache.remove(other) }
 let url=URL(string:"https://calendar.google.com/calendar/ical/fixture/basic.ics")!
 let now=Date()
 let event=CalendarEvent(id:"fixture",title:"Upcoming fixture",location:"",start:now.addingTimeInterval(86400),end:now.addingTimeInterval(90000),allDay:false)
 let snapshot=CalendarSnapshot(month:now,events:[event],updated:now,stale:false,limited:false,upcoming:[event])
 CalendarSnapshotCache.save(snapshot,profile:profile,url:url)
 let restored=CalendarSnapshotCache.read(profile:profile,url:url,month:now)!
 assert(restored.events==[event] && restored.upcoming==[event] && restored.stale)
 assert(CalendarSnapshotCache.read(profile:other,url:url,month:now)==nil)
 assert(CalendarSnapshotCache.read(profile:profile,url:URL(string:"https://calendar.google.com/other.ics")!,month:now)==nil)
 assert(CalendarSnapshotCache.read(profile:profile,url:url,month:Calendar.current.date(byAdding:.month,value:1,to:now)!)==nil)
 let data=UserDefaults.standard.data(forKey:"webbyCalendarSnapshot.v1."+profile.uuidString)!
 assert(!String(data:data,encoding:.utf8)!.contains(url.absoluteString))
 CalendarSnapshotCache.remove(profile)
 assert(CalendarSnapshotCache.read(profile:profile,url:url,month:now)==nil)
 print("PASS: immediate event restoration, profile/source isolation, month isolation, URL secrecy, invalidation")
 }
}
