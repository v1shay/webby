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
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let stem = (name as NSString).deletingPathExtension
                let ext = (name as NSString).pathExtension
                var candidate = folder.appendingPathComponent(name)
                var suffix = 2
                while FileManager.default.fileExists(atPath: candidate.path) || reserved.contains(candidate.path) {
                    let next = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
                    candidate = folder.appendingPathComponent(next); suffix += 1
                }
                reserved.insert(candidate.path)
                return candidate
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
    func release(_ url: URL) { queue.async { self.reserved.remove(url.path) } }
}

@MainActor final class BrowserDownloads: NSObject, NSMenuDelegate, WKDownloadDelegate {
    struct Entry {
        let id = UUID()
        var name: String
        var url: URL?
        var progress: Progress?
        var status: String
    }

    let button = DownloadFolderButton(frame: .zero)
    private var entries: [Entry] = []
    private var active = [ObjectIdentifier: Int]()
    private var retainedDownloads = [ObjectIdentifier: WKDownload]()
    private let destinations: DownloadDestinations
    private let menu = NSMenu(title: "Downloads")
    var hasActiveDownloads: Bool { !active.isEmpty }

    init(directory: URL? = nil) {
        destinations = DownloadDestinations(folder: directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads"))
        super.init()
        menu.delegate = self
        button.onClick = { [weak self] in self?.showMenu() }
        let saved = Array((UserDefaults.standard.stringArray(forKey: "browserRecentDownloads") ?? []).suffix(30))
        entries = saved.compactMap { path in
            return Entry(name: URL(fileURLWithPath: path).lastPathComponent,
                         url: URL(fileURLWithPath: path), progress: nil, status: "Finished")
        }
    }

    func applyTheme(_ profile: PetGradientProfile) { button.applyTheme(profile) }

    var widgetLines: [String] {
        entries.suffix(5).reversed().map { entry in
            let progress = entry.progress?.fractionCompleted ?? 0
            if entry.status == "Downloading" && progress.isFinite {
                return "↓ \(entry.name)  ·  \(Int(max(0, min(1, progress)) * 100))%"
            }
            return "\(entry.status == "Finished" ? "✓" : "!") \(entry.name) · \(entry.status)"
        }
    }

    func attach(_ download: WKDownload) {
        guard active[ObjectIdentifier(download)] == nil else { return }
        retainedDownloads[ObjectIdentifier(download)] = download
        download.delegate = self
        let index = entries.count
        entries.append(Entry(name: "Downloading…", url: nil, progress: download.progress, status: "Downloading"))
        active[ObjectIdentifier(download)] = index
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

    static func safeFilename(_ suggested: String) -> String {
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
        if active.isEmpty && entries.count > 30 { entries = Array(entries.suffix(30)) }
        persistRecent()
    }

    func downloadDidFinish(_ download: WKDownload) { finish(download, status: "Finished") }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download, status: "Failed: \(error.localizedDescription)")
    }

    @objc private func cancelDownload(_ item: NSMenuItem) {
        guard let entryID = item.representedObject as? UUID,
              let index = entries.firstIndex(where: { $0.id == entryID }),
              let id = active.first(where: { $0.value == index })?.key,
              let download = retainedDownloads[id] else { return }
        // Mark terminal before cancellation, so a late failure callback is harmless.
        download.delegate = nil
        finish(download, status: "Cancelled")
        download.cancel { _ in }
    }

    private func persistRecent() {
        UserDefaults.standard.set(entries.compactMap { entry -> String? in
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
