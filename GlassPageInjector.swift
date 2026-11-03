import Foundation
import WebKit

@MainActor enum GlassPageInjector {
    private static let marker = "/* Webby glass-page v1 */"

    private static let promptSource = Bundle.main.url(forResource: "GooglePromptFilter", withExtension: "js").flatMap { try? String(contentsOf: $0) }
    private static let glassSource = Bundle.main.url(forResource: "glass-page", withExtension: "js").flatMap { try? String(contentsOf: $0) }

    static var geistEnabled:Bool {
        get {UserDefaults.standard.object(forKey:"webbyGeistEnabled")==nil || UserDefaults.standard.bool(forKey:"webbyGeistEnabled")}
        set {UserDefaults.standard.set(newValue,forKey:"webbyGeistEnabled");NotificationCenter.default.post(name:Notification.Name("WebbyGeistChanged"),object:nil)}
    }
    // Keep document-start source small. Font bytes are requested only after
    // the page gets a paint opportunity, through an isolated local-only bridge.
    private static let geistSource = Bundle.main.url(forResource:"GeistPage",withExtension:"js").flatMap { try? String(contentsOf:$0) }
    static func installGeist(into controller:WKUserContentController,replace:Bool=false){
        let marker="/* Webby local Geist v1 */"
        if controller.userScripts.contains(where:{$0.source.hasPrefix(marker)}) {
            guard replace else{return}
            let kept=controller.userScripts.filter{!$0.source.hasPrefix(marker)}
            controller.removeAllUserScripts();kept.forEach{controller.addUserScript($0)}
        }
        guard geistEnabled,let source=geistSource else{return}
        controller.removeScriptMessageHandler(forName:"webbyGeistFont",contentWorld:.defaultClient)
        controller.addScriptMessageHandler(GeistFontReply.shared,contentWorld:.defaultClient,name:"webbyGeistFont")
        controller.addUserScript(WKUserScript(source:source+"\n globalThis.__webbySetGeist(\(geistEnabled));",injectionTime:.atDocumentStart,forMainFrameOnly:false,in:.defaultClient))
    }

    static func applyGeist(to view:WKWebView) {
        guard geistEnabled else {
            view.evaluateJavaScript("globalThis.__webbySetGeist?.(false)",in:nil,in:.defaultClient,completionHandler:nil);return
        }
        guard let source=geistSource else{return}
        let script="if (typeof globalThis.__webbySetGeist === 'function') { globalThis.__webbySetGeist(true); } else {\n"+source+"\n globalThis.__webbySetGeist(true); }"
        view.evaluateJavaScript(script,in:nil,in:.defaultClient,completionHandler:nil)
    }

    static func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        installGeist(into:controller)
        let promptMarker = "/* Webby Google prompt filter */"
        if !controller.userScripts.contains(where: { $0.source.hasPrefix(promptMarker) }),
           let source = promptSource {
            controller.addUserScript(WKUserScript(source: promptMarker + "\n" + source,
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        guard BrowserGlass.pageInjectionEnabled else { return }
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }),
              let source = glassSource else { return }
        controller.addUserScript(WKUserScript(source: marker + "\n" + source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
    }

    static func makeWebViewTransparent(_ view: WKWebView) {
        guard BrowserGlass.pageInjectionEnabled else { return }
        // underPageBackgroundColor only controls the color behind/around the
        // page. On macOS 13 WebKit can still draw an opaque view backing. There
        // is no public macOS drawsBackground setter, so keep this KVC workaround
        // isolated here and use it only for the existing browser web views.
        view.underPageBackgroundColor = .clear
        view.setValue(false, forKey: "drawsBackground")
    }
}

// No page content, networking, file paths or profile data enters this bridge.
@MainActor private final class GeistFontReply:NSObject,WKScriptMessageHandlerWithReply {
    static let shared=GeistFontReply()
    private var encoded:[String:String]=[:]
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage,replyHandler:@escaping (Any?,String?)->Void) {
        guard let face=message.body as? String,["regular","italic"].contains(face) else {replyHandler(nil,"Unknown bundled face");return}
        if let cached=encoded[face] {replyHandler(cached,nil);return}
        let file=face=="regular" ? "Geist-VariableFont_wght":"Geist-Italic-VariableFont_wght"
        guard let url=Bundle.main.url(forResource:file,withExtension:"ttf",subdirectory:"Fonts/Geist"),
              let data=try? Data(contentsOf:url),data.count<1_000_000 else {replyHandler(nil,"Bundled face unavailable");return}
        let value=data.base64EncodedString();encoded[face]=value
        replyHandler(value,nil)
    }
}
