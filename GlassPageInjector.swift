import Foundation
import WebKit

enum GlassPageInjector {
    private static let marker = "/* Webby glass-page v1 */"

    static func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
        guard !controller.userScripts.contains(where: { $0.source.hasPrefix(marker) }),
              let url = Bundle.main.url(forResource: "glass-page", withExtension: "js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { return }
        controller.addUserScript(WKUserScript(source: marker + "\n" + source,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))
    }

    static func makeWebViewTransparent(_ view: WKWebView) {
        // underPageBackgroundColor only controls the color behind/around the
        // page. On macOS 13 WebKit can still draw an opaque view backing. There
        // is no public macOS drawsBackground setter, so keep this KVC workaround
        // isolated here and use it only for the existing browser web views.
        view.underPageBackgroundColor = .clear
        view.setValue(false, forKey: "drawsBackground")
    }
}
