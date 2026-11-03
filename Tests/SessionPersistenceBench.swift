import Foundation
struct Record:Codable {let title:String;let url:String;let owner:UUID;let group:UUID?}
@main struct Bench {
static func main() throws {
let suite="local.webby.session-benchmark.\(UUID().uuidString)"
let defaults=UserDefaults(suiteName:suite)!
defer {defaults.removePersistentDomain(forName:suite)}
let writer=BrowserSnapshotWriter()
var rows:[[String:Any]]=[]
for count in [80,800,5000] {
let values=(0..<count).map{Record(title:"Tab \($0)",url:"https://public.invalid/page/\($0)",owner:UUID(),group:nil)}
var before:[Double]=[],after:[Double]=[]
for _ in 0..<50 {
var t=ProcessInfo.processInfo.systemUptime
let data=try JSONEncoder().encode(values);defaults.set(data,forKey:"old")
before.append((ProcessInfo.processInfo.systemUptime-t)*1000)
t=ProcessInfo.processInfo.systemUptime
writer.save(values,defaults:defaults,key:"new")
after.append((ProcessInfo.processInfo.systemUptime-t)*1000)
writer.flush()
let saved=try JSONDecoder().decode([Record].self,from:defaults.data(forKey:"new")!)
precondition(saved.count==count)
}
func p95(_ x:[Double])->Double{x.sorted()[Int(ceil(Double(x.count)*0.95))-1]}
rows.append(["pages":count,"mainThreadBeforeP95Ms":p95(before),"mainThreadAfterP95Ms":p95(after)])
}
for revision in 0..<1000 {writer.save([revision],defaults:defaults,key:"race")}
writer.flush();let newest=try JSONDecoder().decode([Int].self,from:defaults.data(forKey:"race")!);precondition(newest == [999])
writer.save([1000],defaults:defaults,key:"race",wait:true)
let final=try JSONDecoder().decode([Int].self,from:defaults.data(forKey:"race")!);precondition(final == [1000])
for gib in [4,8,16,24,32,64,128] {
    let memory=UInt64(gib)*1024*1024*1024
    let target=BrowserWorkingSet.residentTarget(physicalMemory:memory)
    precondition(target>=12 && target<=48)
    for loaded in 0..<500 {
        let budget=BrowserWorkingSet.discardBatch(loaded:loaded,physicalMemory:memory,pressure:false)
        precondition((2...4).contains(budget))
        precondition(BrowserWorkingSet.discardBatch(loaded:loaded,physicalMemory:memory,pressure:true)==4)
        if loaded<=target {precondition(budget==2)}
    }
}
print(String(data:try JSONSerialization.data(withJSONObject:["workingSetBoundChecks":3500,"samples":rows,"coalescingAndShutdownPassed":true,"optimization":"-O"],options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
}}
