import AppKit
import WebKit

struct PetGradientProfile { var gradients = Gradients(); var palette = Palette(); struct Gradients { var ambient = 0; var working = 0 }; struct Palette { var highlight = 0 } }
enum BrowserTheme {
    static let profile = PetGradientProfile()
    static func apply(_ value: Int, to: CAGradientLayer, alpha: CGFloat = 1) {}
    static func color(_ value: Int, alpha: CGFloat) -> NSColor { .white }
}
enum Motion {
    static let enabled = true
    static func basic(_ layer: CALayer?, key: String, from: Float, to: Float, duration: Double) {}
}
final class FileGlyphLayer: CAShapeLayer { func setOpen(_ open: Bool, animated: Bool) {} }

@MainActor final class DownloadTest: NSObject, WKNavigationDelegate {
    let downloads: BrowserDownloads
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
    init(folder: URL, defaults: UserDefaults) {
        downloads = BrowserDownloads(destinationFolder: folder, defaults: defaults)
        super.init()
        web.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(.download)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { downloads.attach(download) }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { downloads.attach(download) }
}

@main struct Main {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let suite = "webby-download-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let test = DownloadTest(folder: root, defaults: defaults)
        let url = URL(string: CommandLine.arguments[2])!
        for expected in ["probe.txt", "probe 2.txt"] {
            test.web.load(URLRequest(url: url))
            let target = root.appendingPathComponent(expected)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                if FileManager.default.fileExists(atPath: target.path), !test.downloads.hasActiveDownloads { break }
            }
            guard let content = try? String(contentsOf: target, encoding: .utf8), content == "webby-download-test\n", !test.downloads.hasActiveDownloads else {
                fputs("Download failed: \(expected)\n", stderr); exit(1)
            }
        }
        guard defaults.stringArray(forKey: "browserRecentDownloads")?.count == 2 else { fputs("Download history missing\n", stderr); exit(1) }
        let invalidFolder = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: invalidFolder)
        let failure = DownloadTest(folder: invalidFolder, defaults: defaults)
        failure.web.load(URLRequest(url: url))
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline && !failure.downloads.widgetLines.contains(where: { $0.contains("Failed:") }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard !failure.downloads.hasActiveDownloads, failure.downloads.widgetLines.contains(where: { $0.contains("Failed:") }) else {
            fputs("Download destination failure was not handled\n", stderr); exit(1)
        }
        print("PASS: real WebKit downloads, duplicate filenames, content, completion, history and destination failure")
    }
}
