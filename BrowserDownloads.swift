import AppKit
import WebKit

@MainActor final class DownloadFolderButton: NSView {
    private let ambient = CAGradientLayer()
    private let paint = CAGradientLayer()
    private let glyph = FileGlyphLayer()
    var onClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.055).cgColor
        layer?.borderWidth = 0.6
        layer?.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        ambient.cornerRadius = 8
        ambient.opacity = 0.42
        layer?.addSublayer(ambient)
        paint.mask = glyph
        layer?.addSublayer(paint)
        toolTip = "Downloads"
        applyTheme(BrowserTheme.profile)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        ambient.frame = bounds
        paint.frame = CGRect(x: (bounds.width - 28) / 2, y: (bounds.height - 18) / 2,
                             width: 28, height: 18)
        glyph.frame = CGRect(origin: .zero, size: CGSize(width: 28, height: 18))
    }

    func applyTheme(_ profile: PetGradientProfile) {
        BrowserTheme.apply(profile.gradients.ambient, to: ambient, alpha: 0.24)
        BrowserTheme.apply(profile.gradients.working, to: paint)
        layer?.borderColor = BrowserTheme.color(profile.palette.highlight, alpha: 0.22).cgColor
    }

    func setOpen(_ open: Bool) {
        glyph.setOpen(open, animated: Motion.enabled)
        let old = ambient.presentation()?.opacity ?? ambient.opacity
        ambient.opacity = open ? 0.9 : 0.42
        Motion.basic(ambient, key: "opacity", from: old, to: ambient.opacity, duration: 0.18)
    }

    func animateIncomingFile() {
        guard Motion.enabled, let layer, window != nil, !isHidden else { return }
        let file = CAShapeLayer()
        let path = CGMutablePath()
        path.addRoundedRect(in: CGRect(x: -4, y: -5, width: 8, height: 10), cornerWidth: 1.5, cornerHeight: 1.5)
        file.path = path
        file.fillColor = NSColor.white.withAlphaComponent(0.9).cgColor
        file.position = CGPoint(x: bounds.midX, y: bounds.midY)
        layer.addSublayer(file)
        let travel = CAKeyframeAnimation(keyPath: "position")
        travel.values = [CGPoint(x: bounds.midX, y: bounds.maxY + 5),
                         CGPoint(x: bounds.midX, y: bounds.midY + 5),
                         CGPoint(x: bounds.midX, y: bounds.midY)]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 1, 0]
        fade.keyTimes = [0, 0.15, 0.7, 1]
        let animation = CAAnimationGroup()
        animation.animations = [travel, fade]
        animation.duration = 0.65
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { file.removeFromSuperlayer() }
        file.add(animation, forKey: "incomingFile")
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

@MainActor final class BrowserDownloads: NSObject, NSMenuDelegate, WKDownloadDelegate {
    struct Entry {
        var name: String
        var url: URL?
        var progress: Progress?
        var status: String
    }

    let button = DownloadFolderButton(frame: .zero)
    private var entries: [Entry] = []
    private struct ActiveDownload { let download: WKDownload; let index: Int }
    private var active = [ObjectIdentifier: ActiveDownload]()
    private var sessionDownloads = [UUID: (session: URLSession?, task: URLSessionDownloadTask?, index: Int)]()
    private let fileQueue = DispatchQueue(label: "local.webby.download-destination")
    private var reservedPaths = Set<String>()
    private let destinationFolder: URL?
    private let defaults: UserDefaults
    private let menu = NSMenu(title: "Downloads")
    var hasActiveDownloads: Bool { !active.isEmpty || !sessionDownloads.isEmpty }

    init(destinationFolder: URL? = nil, defaults: UserDefaults = .standard) {
        self.destinationFolder = destinationFolder
        self.defaults = defaults
        super.init()
        menu.delegate = self
        button.onClick = { [weak self] in self?.showMenu() }
        let saved = defaults.stringArray(forKey: "browserRecentDownloads") ?? []
        entries = saved.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Entry(name: URL(fileURLWithPath: path).lastPathComponent,
                         url: URL(fileURLWithPath: path), progress: nil, status: "Finished")
        }
    }

    func applyTheme(_ profile: PetGradientProfile) { button.applyTheme(profile) }

    var widgetLines: [String] {
        entries.suffix(5).reversed().map { entry in
            let progress = entry.progress?.fractionCompleted ?? 0
            if entry.status == "Downloading" {
                return progress.isFinite ? "↓ \(entry.name)  ·  \(Int(max(0, min(1, progress)) * 100))%" : "↓ \(entry.name)"
            }
            return entry.status == "Finished" ? "✓ \(entry.name)" : "⚠ \(entry.name)  ·  \(entry.status)"
        }
    }

    func attach(_ download: WKDownload) {
        let id = ObjectIdentifier(download)
        guard active[id] == nil else { return }
        download.delegate = self
        let index = entries.count
        entries.append(Entry(name: "Downloading…", url: nil, progress: download.progress, status: "Downloading"))
        active[id] = ActiveDownload(download: download, index: index)
        button.animateIncomingFile()
    }

    /// Re-fetch safe GET downloads through URLSession. WKDownload's destination
    /// handoff can block WebKit's main thread in the macOS sandbox service.
    /// Cookie storage is private to this transfer and retains domain scoping.
    func startGET(_ request: URLRequest, from store: WKHTTPCookieStore, sourceURL: URL?, suggestedFilename: String?, expectedMIMEType: String? = nil) {
        let id = UUID(), index = entries.count
        entries.append(Entry(name: suggestedFilename ?? request.url?.lastPathComponent ?? "Downloading…", url: nil, progress: nil, status: "Downloading"))
        sessionDownloads[id] = (nil, nil, index)
        button.animateIncomingFile()
        let folder = destinationFolder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let queue = fileQueue
        store.getAllCookies { [weak self] cookies in
            Task { @MainActor [weak self] in
                guard let self, self.sessionDownloads[id] != nil else { return }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.httpShouldSetCookies = true
                // URLSession has no knowledge of WebKit's site context. Avoid
                // sending profile cookies to a different host on a cross-site
                // link; SameSite and third-party policies must not be bypassed.
                let sourceHost = sourceURL?.host?.lowercased()
                let destinationHost = request.url?.host?.lowercased()
                if let destinationHost, sourceHost == destinationHost {
                    for cookie in cookies {
                        let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn:".")).lowercased()
                        guard destinationHost == domain || destinationHost.hasSuffix("." + domain) else { continue }
                        configuration.httpCookieStorage?.setCookie(cookie)
                    }
                }
                let session = URLSession(configuration: configuration)
                var cleanRequest = request
                // Cookie headers must be generated by URLSession for each host,
                // rather than forwarded unchanged across redirects.
                cleanRequest.setValue(nil, forHTTPHeaderField: "Cookie")
                cleanRequest.setValue(nil, forHTTPHeaderField: "Range")
                cleanRequest.setValue(nil, forHTTPHeaderField: "If-Range")
                cleanRequest.setValue(nil, forHTTPHeaderField: "If-None-Match")
                cleanRequest.setValue(nil, forHTTPHeaderField: "If-Modified-Since")
                let task = session.downloadTask(with: cleanRequest) { [weak self] temporary, response, error in
                    var result: Result<URL, Error>
                    if let error { result = .failure(error) }
                    else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        result = .failure(NSError(domain:"WebbyDownload",code:http.statusCode,userInfo:[NSLocalizedDescriptionKey:"Server returned HTTP \(http.statusCode)"]))
                    } else if let http = response as? HTTPURLResponse, http.statusCode == 206 {
                        result = .failure(NSError(domain:"WebbyDownload",code:206,userInfo:[NSLocalizedDescriptionKey:"The server returned only part of the file"]))
                    } else if let expectedMIMEType, expectedMIMEType.lowercased() != "text/html",
                              response?.mimeType?.lowercased() == "text/html" {
                        result = .failure(NSError(domain:"WebbyDownload",code:0,userInfo:[NSLocalizedDescriptionKey:"The server returned a web page instead of the requested file"]))
                    } else if let temporary {
                        result = Result {
                            try queue.sync {
                                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                                let proposed = response?.suggestedFilename ?? suggestedFilename ?? request.url?.lastPathComponent ?? "Download"
                                let component = URL(fileURLWithPath:proposed).lastPathComponent
                                let name = component.isEmpty || component == "." || component == ".." ? "Download" : component
                                let stem = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                                var target = folder.appendingPathComponent(name), suffix = 2
                                while FileManager.default.fileExists(atPath:target.path) {
                                    target = folder.appendingPathComponent(ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)")
                                    suffix += 1
                                }
                                try FileManager.default.moveItem(at:temporary,to:target)
                                return target
                            }
                        }
                    } else { result = .failure(NSError(domain:"WebbyDownload",code:0,userInfo:[NSLocalizedDescriptionKey:"No downloaded file was returned"])) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let transfer=self.sessionDownloads.removeValue(forKey:id), self.entries.indices.contains(transfer.index) else { return }
                        transfer.session?.finishTasksAndInvalidate()
                        self.entries[transfer.index].progress = nil
                        switch result {
                        case .success(let url): self.entries[transfer.index].name=url.lastPathComponent;self.entries[transfer.index].url=url;self.entries[transfer.index].status="Finished";self.persistRecent()
                        case .failure(let error): self.entries[transfer.index].status="Failed: \(error.localizedDescription)"
                        }
                    }
                }
                self.sessionDownloads[id] = (session,task,index)
                self.entries[index].progress=task.progress
                task.resume()
            }
        }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = destinationFolder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch {
            if let index = active.removeValue(forKey: ObjectIdentifier(download))?.index, entries.indices.contains(index) {
                entries[index].progress = nil
                entries[index].status = "Failed: \(error.localizedDescription)"
            }
            completionHandler(nil)
            return
        }
        let safeName = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        let original = safeName.isEmpty || safeName == "." || safeName == ".." ? "Download" : safeName
        let stem = (original as NSString).deletingPathExtension
        let ext = (original as NSString).pathExtension
        var destination = folder.appendingPathComponent(original)
        var suffix = 2
        while FileManager.default.fileExists(atPath: destination.path) || reservedPaths.contains(destination.path) {
            let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            destination = folder.appendingPathComponent(name)
            suffix += 1
        }
        reservedPaths.insert(destination.path)
        if let index = active[ObjectIdentifier(download)]?.index, entries.indices.contains(index) {
            entries[index].name = destination.lastPathComponent
            entries[index].url = destination
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let index = active.removeValue(forKey: ObjectIdentifier(download))?.index, entries.indices.contains(index) else { return }
        if let path = entries[index].url?.path { reservedPaths.remove(path) }
        entries[index].progress = nil
        entries[index].status = "Finished"
        persistRecent()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let index = active.removeValue(forKey: ObjectIdentifier(download))?.index, entries.indices.contains(index) else { return }
        if let path = entries[index].url?.path { reservedPaths.remove(path) }
        entries[index].progress = nil
        entries[index].status = "Failed: \(error.localizedDescription)"
    }

    private func persistRecent() {
        defaults.set(entries.compactMap { entry -> String? in
            guard entry.status == "Finished" else { return nil }
            return entry.url?.path
        }.suffix(30).map { $0 }, forKey: "browserRecentDownloads")
    }

    private func showMenu() {
        button.setOpen(true)
        rebuildMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -5), in: button)
    }

    func menuDidClose(_ menu: NSMenu) { button.setOpen(false) }

    private func rebuildMenu() {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Downloads", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        if entries.isEmpty {
            let empty = NSMenuItem(title: "No downloads yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for entry in entries.suffix(12).reversed() {
            let percentage = entry.progress.flatMap { progress -> String? in
                let value = progress.fractionCompleted
                guard value.isFinite else { return nil }
                return "  \(Int(max(0, min(1, value)) * 100))%"
            } ?? ""
            let item = menu.addItem(withTitle: entry.name + percentage,
                                    action: entry.status == "Finished" ? #selector(openDownload(_:)) : nil,
                                    keyEquivalent: "")
            item.target = self
            item.representedObject = entry.url
            item.toolTip = entry.status
            item.isEnabled = entry.status == "Finished"
        }
        menu.addItem(.separator())
        let folder = menu.addItem(withTitle: "Open Downloads Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
    }

    @objc private func openDownload(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func openFolder() {
        guard let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(url)
    }
}
