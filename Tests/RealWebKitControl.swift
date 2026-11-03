import AppKit
import WebKit
import Darwin
@MainActor final class Control {
 let host=NSWindow(contentRect:NSRect(x:100,y:60,width:1472,height:930),styleMask:[.titled],backing:.buffered,defer:false)
 func run(corpus:URL,output:URL,rounds:Int,width:Double,height:Double) async throws {
  let urls=try JSONDecoder().decode([String].self,from:Data(contentsOf:corpus))
  host.isReleasedWhenClosed=false;host.setContentSize(NSSize(width:width,height:height));host.makeKeyAndOrderFront(nil)
  let store=WKWebsiteDataStore.nonPersistent();var samples:[[String:Any]]=[]
  func cpu()->Double{var u=rusage();getrusage(RUSAGE_SELF,&u);return Double(u.ru_utime.tv_sec+u.ru_stime.tv_sec)*1000+Double(u.ru_utime.tv_usec+u.ru_stime.tv_usec)/1000}
  for round in 0..<rounds {for offset in urls.indices {
   let address=urls[(offset+round)%urls.count],start=ProcessInfo.processInfo.systemUptime,startCPU=cpu()
   let config=WKWebViewConfiguration();config.websiteDataStore=store
   let web=WKWebView(frame:NSRect(x:0,y:0,width:width,height:height),configuration:config)
   host.contentView=web
   web.load(URLRequest(url:URL(string:address)!))
   let deadline=ProcessInfo.processInfo.systemUptime+25
   while (web.isLoading || web.url==nil) && ProcessInfo.processInfo.systemUptime<deadline {try await Task.sleep(nanoseconds:20_000_000)}
   var row:[String:Any]=["url":address,"round":round,"variant":"minimal-wk-matched-viewport","nativeLoadWaitMs":(ProcessInfo.processInfo.systemUptime-start)*1000,"browserHostCPUUntilLoadMs":cpu()-startCPU,"timedOut":web.isLoading || web.url==nil,"finalURL":web.url?.absoluteString ?? "","navigationError":"not captured by this delegate-free control","effects":["glass":false,"geist":false,"fastRule":false,"injectedScriptBytes":0]]
   if !web.isLoading {do {
    row["page"]=try await web.evaluateJavaScript("""
    (()=>{const n=performance.getEntriesByType('navigation')[0];return {title:document.title,readyState:document.readyState,navigation:n?JSON.parse(JSON.stringify(n.toJSON())):null,paint:performance.getEntriesByType('paint').map(e=>({name:e.name,startTime:e.startTime})),resourceCount:performance.getEntriesByType('resource').length,domElements:document.getElementsByTagName('*').length,viewport:{width:innerWidth,height:innerHeight}}})()
    """)
    row["frameOpportunityGapsMs"]=try await web.callAsyncJavaScript("""
    return await new Promise(resolve=>{let last=null,gaps=[];function frame(t){if(last!==null)gaps.push(t-last);last=t;if(gaps.length>=60)resolve(gaps);else requestAnimationFrame(frame)}requestAnimationFrame(frame);setTimeout(()=>resolve(gaps),3000)})
    """,arguments:[:],in:nil,contentWorld:.defaultClient)
   }catch{row["measurementError"]=String(describing:error)}}
   samples.append(row)
   try JSONSerialization.data(withJSONObject:["samples":samples,"optimization":"-O","limitations":["Separate minimal WK host, same content viewport; not Safari","OS DNS/TLS and network/server variance uncontrolled","No production sign-ins","No total WebKit CPU/GPU or compositor FPS measurement","Load completion does not establish usable-page success"]],options:[.prettyPrinted,.sortedKeys]).write(to:output,options:.atomic)
   web.stopLoading();print(address,round,flush:true)
  }}
 }
}
func print(_ address:String,_ round:Int,flush:Bool){Swift.print(address,round);fflush(stdout)}
@main struct Main {
 static func main(){let app=NSApplication.shared;app.setActivationPolicy(.accessory);let control=Control();Task {@MainActor in do {try await control.run(corpus:URL(fileURLWithPath:CommandLine.arguments[1]),output:URL(fileURLWithPath:CommandLine.arguments[2]),rounds:Int(CommandLine.arguments[3])!,width:Double(CommandLine.arguments[4])!,height:Double(CommandLine.arguments[5])!);exit(0)}catch{Swift.print(error);exit(1)}};app.run();withExtendedLifetime(control){}}
}
