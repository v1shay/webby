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

// Serial reservations prevent two simultaneous downloads choosing the same name.
// Cloud/external Downloads folders never block AppKit's event thread.
private final class DownloadDestinations {
    private let queue = DispatchQueue(label: "local.webby.download-destinations", qos: .utility)
    private var reserved = Set<String>()
    let folder: URL
    init(folder: URL) { self.folder = folder }
    func reserve(_ name: String, completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [self] in
            let result = Result<URL, Error> {
                let candidate = try destination(for: name)
                reserved.insert(candidate.path)
                return candidate
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func release(_ url: URL) { queue.async { self.reserved.remove(url.path) } }

    func store(_ temporary: URL, as name: String) throws -> URL {
        try queue.sync {
            let target = try destination(for: name)
            try FileManager.default.moveItem(at: temporary, to: target)
            return target
        }
    }

    private func destination(for name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
            let next = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            candidate = folder.appendingPathComponent(next); suffix += 1
        }
        return candidate
    }
}

@MainActor final class BrowserDownloads: NSObject, NSMenuDelegate, WKDownloadDelegate {
    struct Entry {
        let id = UUID()
        var name: String
        var url: URL?
        var progress: Progress?
        var status: String
        var isPrivate = false
    }

    let button = DownloadFolderButton(frame: .zero)
    private var entries: [Entry] = []
    private var active = [ObjectIdentifier: Int]()
    private var retainedDownloads = [ObjectIdentifier: WKDownload]()
    private var sessionDownloads = [UUID: (session: URLSession?, task: URLSessionDownloadTask?, index: Int)]()
    private var engineDownloads: [UUID: Int] = [:]
    private var engineCancellations: [UUID: (UUID) -> Void] = [:]
    private let defaults: UserDefaults
    private let destinations: DownloadDestinations
    private let menu = NSMenu(title: "Downloads")
    var hasActiveDownloads: Bool { !active.isEmpty || !sessionDownloads.isEmpty || !engineDownloads.isEmpty }

    convenience init(directory: URL) { self.init(destinationFolder: directory) }

    init(destinationFolder: URL? = nil, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        destinations = DownloadDestinations(folder: destinationFolder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
        super.init()
        menu.delegate = self
        button.onClick = { [weak self] in self?.showMenu() }
        let saved = Array((defaults.stringArray(forKey: "browserRecentDownloads") ?? []).suffix(30))
        entries = saved.compactMap { path in
            return Entry(name: URL(fileURLWithPath: path).lastPathComponent,
                         url: URL(fileURLWithPath: path), progress: nil, status: "Finished")
        }
    }

    func applyTheme(_ profile: PetGradientProfile) { button.applyTheme(profile) }

    var automationEntries: [[String: Any]] {
        entries.suffix(30).reversed().map {
            ["id": $0.id.uuidString, "name": $0.name, "status": $0.status,
             "path": $0.url?.path as Any? ?? NSNull(),
             "fraction": $0.progress?.fractionCompleted as Any? ?? NSNull()]
        }
    }

    var widgetLines: [String] {
        entries.suffix(5).reversed().map { entry in
            let progress = entry.progress?.fractionCompleted ?? 0
            if entry.status == "Downloading" && progress.isFinite {
                return "↓ \(entry.name)  ·  \(Int(max(0, min(1, progress)) * 100))%"
            }
            return "\(entry.status == "Finished" ? "✓" : "!") \(entry.name) · \(entry.status)"
        }
    }

    func attach(_ download: WKDownload, isPrivate: Bool = false) {
        let id = ObjectIdentifier(download)
        guard active[id] == nil else { return }
        retainedDownloads[id] = download
        download.delegate = self
        let index = entries.count
        entries.append(Entry(name: "Downloading…", url: nil, progress: download.progress, status: "Downloading", isPrivate: isPrivate))
        active[id] = index
        button.animateIncomingFile()
    }

    /// Re-fetch safe GET downloads through URLSession. WKDownload's destination
    /// handoff can block WebKit's main thread in the macOS sandbox service.
    /// Cookie storage is private to this transfer and retains domain scoping.
    @discardableResult func startGET(_ request: URLRequest, from store: WKHTTPCookieStore, sourceURL: URL?, suggestedFilename: String?, expectedMIMEType: String? = nil, isPrivate: Bool = false) -> UUID {
        let id = UUID(), index = entries.count
        entries.append(Entry(name: suggestedFilename ?? request.url?.lastPathComponent ?? "Downloading…", url: nil, progress: nil, status: "Downloading", isPrivate: isPrivate))
        sessionDownloads[id] = (nil, nil, index)
        button.animateIncomingFile()
        let allocator = destinations
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
                let task = session.downloadTask(with: cleanRequest) { [weak self, weak session] temporary, response, error in
                    session?.finishTasksAndInvalidate()
                    let result: Result<URL, Error>
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
                            let proposed = response?.suggestedFilename ?? suggestedFilename ?? request.url?.lastPathComponent ?? "Download"
                            return try allocator.store(temporary, as: Self.safeFilename(proposed))
                        }
                    } else { result = .failure(NSError(domain:"WebbyDownload",code:0,userInfo:[NSLocalizedDescriptionKey:"No downloaded file was returned"])) }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        guard let transfer=self.sessionDownloads.removeValue(forKey:id), self.entries.indices.contains(transfer.index) else {
                            // Cancellation can win after the download callback has
                            // moved its temporary file. Do not leave a completed
                            // file behind for a transfer the user cancelled.
                            if case .success(let url) = result {
                                DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: url) }
                            }
                            return
                        }
                        transfer.session?.finishTasksAndInvalidate()
                        self.entries[transfer.index].progress = nil
                        switch result {
                        case .success(let url): self.entries[transfer.index].name=url.lastPathComponent;self.entries[transfer.index].url=url;self.entries[transfer.index].status="Finished"
                        case .failure(let error): self.entries[transfer.index].status="Failed: \(error.localizedDescription)"
                        }
                        self.trimCompletedEntries()
                        self.persistRecent()
                    }
                }
                self.sessionDownloads[id] = (session,task,index)
                self.entries[index].progress=task.progress
                task.resume()
            }
        }
        return entries[index].id
    }

    func queueEngineDownload(_ name: String, isPrivate: Bool = false, onCancel: ((UUID) -> Void)? = nil) -> UUID {
        let index = entries.count
        entries.append(Entry(name: Self.safeFilename(name), url: nil, progress: nil, status: "Downloading", isPrivate: isPrivate))
        let id = entries[index].id
        engineDownloads[id] = index
        engineCancellations[id] = onCancel
        button.animateIncomingFile()
        return id
    }

    func prepareEngineDownload(_ id: UUID, name: String, completion: @escaping (URL?) -> Void) {
        guard engineDownloads[id] != nil else { completion(nil); return }
        let allocator = destinations
        allocator.reserve(Self.safeFilename(name)) { [weak self] result in
            guard let self, let index = self.engineDownloads[id] else {
                if case .success(let url) = result { allocator.release(url) }
                completion(nil); return
            }
            switch result {
            case .success(let url):
                self.entries[index].url = url
                self.entries[index].name = url.lastPathComponent
                completion(url)
            case .failure(let error):
                self.finishEngineDownload(id, status: "Failed: \(error.localizedDescription)")
                completion(nil)
            }
        }
    }

    func finishEngineDownload(_ id: UUID, status: String) {
        guard let index = engineDownloads.removeValue(forKey: id) else { return }
        engineCancellations.removeValue(forKey: id)
        if let url = entries[index].url { destinations.release(url) }
        entries[index].status = status
        trimCompletedEntries()
        persistRecent()
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let allocator = destinations
        let name = Self.safeFilename(suggestedFilename)
        if let index = active[ObjectIdentifier(download)] { entries[index].name = name }
        allocator.reserve(name) { [weak self, weak download] result in
            guard let self, let download, let index = self.active[ObjectIdentifier(download)] else {
                if case .success(let url) = result { allocator.release(url) }
                completionHandler(nil); return
            }
            switch result {
            case .success(let destination):
                self.entries[index].name = destination.lastPathComponent
                self.entries[index].url = destination
                completionHandler(destination)
            case .failure(let error):
                self.finish(download, status: "Failed: \(error.localizedDescription)")
                completionHandler(nil)
            }
        }
    }

    nonisolated static func safeFilename(_ suggested: String) -> String {
        let name = (suggested as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
            .replacingOccurrences(of: ":", with: "-")
        guard !name.isEmpty && name != "." && name != ".." && name != "/" else { return "Download" }
        var bounded = ""
        for character in name {
            guard bounded.utf8.count + String(character).utf8.count <= 180 else { break }
            bounded.append(character)
        }
        return bounded.isEmpty ? "Download" : bounded
    }

    private func finish(_ download: WKDownload, status: String) {
        let id = ObjectIdentifier(download)
        guard let index = active.removeValue(forKey: id) else { return }
        retainedDownloads.removeValue(forKey: id)
        if let url = entries[index].url { destinations.release(url) }
        entries[index].progress = nil
        entries[index].status = status
        // Indices remain stable while other downloads are in flight.
        trimCompletedEntries()
        persistRecent()
    }

    func downloadDidFinish(_ download: WKDownload) { finish(download, status: "Finished") }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, status: "Failed: \(error.localizedDescription)")
    }

    @objc private func cancelDownload(_ item: NSMenuItem) {
        guard let entryID = item.representedObject as? UUID,
              let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        if let id = sessionDownloads.first(where: { $0.value.index == index })?.key,
           let transfer = sessionDownloads.removeValue(forKey: id) {
            transfer.session?.invalidateAndCancel()
            entries[index].progress = nil
            entries[index].status = "Cancelled"
            trimCompletedEntries()
            persistRecent()
            return
        }
        if engineDownloads[entryID] != nil, let cancel = engineCancellations[entryID] {
            cancel(entryID)
            return
        }
        guard let id = active.first(where: { $0.value == index })?.key,
              let download = retainedDownloads[id] else { return }
        // Mark terminal before cancellation, so a late failure callback is harmless.
        download.delegate = nil
        finish(download, status: "Cancelled")
        download.cancel { _ in }
    }

    private func trimCompletedEntries() {
        // Every transport shares these indices until the last transfer ends.
        if !hasActiveDownloads && entries.count > 30 { entries = Array(entries.suffix(30)) }
    }

    private func persistRecent() {
        defaults.set(entries.compactMap { entry -> String? in
            guard !entry.isPrivate, entry.status == "Finished" else { return nil }
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
        for index in entries.indices.suffix(12).reversed() {
            let entry = entries[index]
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
            if entry.status == "Downloading" {
                let cancel = menu.addItem(withTitle: "Cancel \(entry.name)", action: #selector(cancelDownload(_:)), keyEquivalent: "")
                cancel.target = self; cancel.representedObject = entry.id
                cancel.isEnabled = engineDownloads[entry.id] == nil || engineCancellations[entry.id] != nil
            } else if entry.status != "Finished" {
                item.title += " — " + entry.status
            }
        }
        menu.addItem(.separator())
        let folder = menu.addItem(withTitle: "Open Downloads Folder", action: #selector(openFolder), keyEquivalent: "")
        folder.target = self
    }

    @objc private func openDownload(_ item: NSMenuItem) {
        guard let url = item.representedObject as? URL else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let exists = FileManager.default.fileExists(atPath: url.path)
            DispatchQueue.main.async {
                if exists { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                else {
                    let alert = NSAlert()
                    alert.messageText = "This download has moved"
                    alert.informativeText = "We can’t find \(url.lastPathComponent) at its saved location. Let’s check Downloads in Finder."
                    alert.addButton(withTitle: "OK"); alert.runModal()
                }
            }
        }
    }

    @objc private func openFolder() {
        guard let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(url)
    }
}
