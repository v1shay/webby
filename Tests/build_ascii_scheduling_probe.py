from pathlib import Path
import sys
p=Path(sys.argv[1]);s=p.read_text();isnew='func refreshActivity()' in s
s=s.replace('    private var timer: Timer?','    private var timer: Timer?\n    private var probeTicks=0',1).replace('MainActor.assumeIsolated {','MainActor.assumeIsolated {\n                    self?.probeTicks += 1',1)
s+='''
struct PetGradientProfile {struct Palette {var primary="#FFFFFF";var highlight="#FFFFFF"};var palette=Palette()}
enum BrowserTheme {static func profile(for:UUID)->PetGradientProfile{PetGradientProfile()};static func color(_ s:String)->NSColor{.white}}
enum Motion {enum Character{case art};static var enabled:Bool{true};static func change(_ v:NSView?,character:Character){};static func basic(_ layer:CALayer?,key:String,from:Any,to:Any,duration:Double){}}
extension ASCIIBackgroundCanvas {
 func probe() async throws->[String:Any] {
  let host=NSWindow(contentRect:NSRect(x:100,y:100,width:500,height:300),styleMask:[.titled],backing:.buffered,defer:false);host.isReleasedWhenClosed=false
  let root=NSView(frame:host.contentView!.bounds);host.contentView=root;frame=root.bounds;root.addSubview(self);host.makeKeyAndOrderFront(nil)
  placements=[Placement(id:"icosahedron",x:10,y:10,width:300,height:200)];rebuild()
  precondition(renderer != nil && cards["icosahedron"] != nil)
  try await Task.sleep(nanoseconds:500_000_000)
  var result:[String:Any]=[:];var start=probeTicks
  try await Task.sleep(nanoseconds:1_000_000_000)
  result["visibleTicksIn1Second"]=probeTicks-start;precondition(probeTicks>start)
  isHidden=true;REFRESH;start=probeTicks
  try await Task.sleep(nanoseconds:2_000_000_000)
  result["hiddenTicksIn2Seconds"]=probeTicks-start
  isHidden=false;REFRESH;start=probeTicks
  try await Task.sleep(nanoseconds:500_000_000)
  result["resumed"]=probeTicks>start;precondition(probeTicks>start)
  dragID="icosahedron";REFRESH;start=probeTicks
  try await Task.sleep(nanoseconds:1_000_000_000)
  result["draggingTicksIn1Second"]=probeTicks-start
  dragID=nil;REFRESH;start=probeTicks
  try await Task.sleep(nanoseconds:500_000_000)
  result["resumedAfterDrag"]=probeTicks>start;precondition(probeTicks>start)
  result["cachedCardPreserved"]=cards["icosahedron"] != nil
  timer?.invalidate();host.orderOut(nil);return result
 }
}
@main struct Main {static func main(){let app=NSApplication.shared;app.setActivationPolicy(.accessory);Task {@MainActor in do {let r=try await ASCIIBackgroundCanvas(frame:.zero).probe();try JSONSerialization.data(withJSONObject:r,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]));exit(0)}catch{print(error);exit(1)}};app.run()}}
'''.replace('REFRESH','refreshActivity()' if isnew else '')
Path(sys.argv[2]).write_text(s.replace(';;',';'))
