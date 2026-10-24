import Foundation
import AppKit
import CryptoKit
import WebKit

// Per-document timing avoids mixing concurrent background loads with the active tab.
struct BrowserNavigationTiming {
    let id = UUID()
    let started = ProcessInfo.processInfo.systemUptime
    var committed: TimeInterval?
    var presented: TimeInterval?
    var finished: TimeInterval?
}

@MainActor enum BrowserPageActivity {
    static let world = WKContentWorld.world(name: "WebbyLifecycle")
    static let source = """
    (() => {
      let edited = false;
      function noteEdit(event) {
        const element = event.target;
        if (edited || !(element instanceof Element)) return;
        if (element.matches('input, textarea, select') || element.isContentEditable) {
          edited = true;
          window.webkit.messageHandlers.browserPageActivity.postMessage('edited');
        }
      }
      document.addEventListener('input', noteEdit, true);
      document.addEventListener('change', noteEdit, true);
      window.__webbyDiscardState = () => ({
        edited,
        // Protect embedded apps rather than guessing about cross-origin editor state.
        embedded: !!document.querySelector('iframe, frame'),
        media: !!document.pictureInPictureElement || !!document.fullscreenElement ||
          [...document.querySelectorAll('audio,video')].some(m => !m.paused && !m.ended),
        form: !!document.querySelector('input[type=file]') ||
          [...document.querySelectorAll('input,textarea,select')].some(e => {
            if (e instanceof HTMLSelectElement) return [...e.options].some(o => o.selected !== o.defaultSelected);
            if (e.type === 'checkbox' || e.type === 'radio') return e.checked !== e.defaultChecked;
            return e.value !== e.defaultValue;
          }) || document.designMode === 'on' || !!document.querySelector('[contenteditable="true"]'),
        x: scrollX, y: scrollY
      });
    })();
    """
    static func install(into configuration: WKWebViewConfiguration, handler: WKScriptMessageHandler) {
        guard !configuration.userContentController.userScripts.contains(where: {
            $0.source == source
        }) else { return }
        configuration.userContentController.add(handler, contentWorld: world, name: "browserPageActivity")
        configuration.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
                                                                      forMainFrameOnly: false, in: world))
    }
}

// Small, profile-scoped artwork only: no page loads, cookies, or credentials.
@MainActor final class BrowserFaviconStore {
    private let directory: URL
    private let queue = DispatchQueue(label: "local.webby.favicon-disk", qos: .utility)
    private let images = NSCache<NSString, NSImage>()
    private var pending: [String: [(NSImage?) -> Void]] = [:]
    private var saved: [String: Data] = [:]
    private var pruneScheduled = false

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("local.plainwebkit.browser/Favicons", isDirectory: true)
        images.countLimit = 256
    }

    private func key(_ url: URL, profile: UUID) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        let origin = "\(profile.uuidString)|\(scheme)://\(host):\(url.port ?? (scheme == "https" ? 443 : 80))"
        return SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func load(for url: URL, profile: UUID, completion: @escaping (NSImage?) -> Void) {
        guard let key = key(url, profile: profile) else { completion(nil); return }
        if let image = images.object(forKey: key as NSString) { DispatchQueue.main.async { completion(image) }; return }
        if pending[key] != nil { pending[key]!.append(completion); return }
        pending[key] = [completion]
        let file = directory.appendingPathComponent(key + ".png")
        queue.async { [weak self] in
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let data = size > 0 && size <= 65536 ? try? Data(contentsOf: file) : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                // A newly fetched icon wins over a pending older disk read.
                let image = self.images.object(forKey: key as NSString) ?? data.flatMap(NSImage.init(data:))
                if let image { self.images.setObject(image, forKey: key as NSString) }
                let callbacks = self.pending.removeValue(forKey: key) ?? []
                callbacks.forEach { $0(image) }
            }
        }
    }

    func remember(_ image: NSImage, for url: URL, profile: UUID) {
        guard let key = key(url, profile: profile),
              let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let bitmap = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        bitmap.interpolationQuality = .high
        bitmap.draw(source, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let thumbnail = bitmap.makeImage(),
              let data = NSBitmapImageRep(cgImage: thumbnail).representation(using: .png, properties: [:]),
              data.count <= 65536 else { return }
        images.setObject(NSImage(cgImage: thumbnail, size: NSSize(width: 64, height: 64)), forKey: key as NSString)
        guard saved[key] != data else { return }
        if saved.count >= 256 { saved.removeAll(keepingCapacity: true) }
        saved[key] = data
        let directory = directory
        queue.async {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic)
        }
        guard !pruneScheduled else { return }
        pruneScheduled = true
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            // Bound disk usage to 512 icons / 8 MiB; remove oldest writes first.
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
            let entries = files.filter { $0.pathExtension == "png" }.map { file in
                (file, try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]))
            }.sorted { ($0.1?.contentModificationDate ?? .distantPast) < ($1.1?.contentModificationDate ?? .distantPast) }
            var bytes = entries.reduce(0) { $0 + ($1.1?.fileSize ?? 0) }
            var count = entries.count
            for (file, values) in entries where count > 512 || bytes > 8 * 1024 * 1024 {
                if (try? fm.removeItem(at: file)) != nil { count -= 1; bytes -= values?.fileSize ?? 0 }
            }
            DispatchQueue.main.async { self?.pruneScheduled = false }
        }
    }
}

@MainActor enum BrowserChromeTone {
    static let world=WKContentWorld.world(name:"WebbyChromeTone")
    static func install(into configuration:WKWebViewConfiguration,handler:WKScriptMessageHandler) {
        let marker="/* Webby top-edge color v1 */"
        guard !configuration.userContentController.userScripts.contains(where:{$0.source.hasPrefix(marker)}),
              let url=Bundle.main.url(forResource:"ChromeTone",withExtension:"js"),
              let source=try? String(contentsOf:url) else {return}
        configuration.userContentController.add(handler,contentWorld:world,name:"browserChromeTone")
        configuration.userContentController.addUserScript(WKUserScript(source:source,injectionTime:.atDocumentEnd,forMainFrameOnly:true,in:world))
    }
}
