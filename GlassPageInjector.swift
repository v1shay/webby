import Foundation
import WebKit

@MainActor enum GlassPageInjector {
    private static let marker = "/* Webby glass-page v1 */"

    private static let promptSource = Bundle.main.url(forResource: "GooglePromptFilter", withExtension: "js").flatMap { try? String(contentsOf: $0) }
    private static let glassSource = Bundle.main.url(forResource: "glass-page", withExtension: "js").flatMap { try? String(contentsOf: $0) }

    static func install(into configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController
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
