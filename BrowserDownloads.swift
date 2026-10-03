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

@MainActor final class BrowserDownloads: NSObject, NSMenuDelegate, WKDownloadDelegate {
    struct Entry {
        var name: String
        var url: URL?
        var progress: Progress?
        var status: String
    }

    let button = DownloadFolderButton(frame: .zero)
    private var entries: [Entry] = []
    private var active = [ObjectIdentifier: Int]()
    private var reservedPaths = Set<String>()
    private let menu = NSMenu(title: "Downloads")

    override init() {
        super.init()
        menu.delegate = self
        button.onClick = { [weak self] in self?.showMenu() }
        let saved = UserDefaults.standard.stringArray(forKey: "browserRecentDownloads") ?? []
        entries = saved.compactMap { path in
            guard FileManager.default.fileExists(atPath: path) else { return nil }
            return Entry(name: URL(fileURLWithPath: path).lastPathComponent,
                         url: URL(fileURLWithPath: path), progress: nil, status: "Finished")
        }
    }

    func applyTheme(_ profile: PetGradientProfile) { button.applyTheme(profile) }

    func attach(_ download: WKDownload) {
        download.delegate = self
        let index = entries.count
        entries.append(Entry(name: "Downloading…", url: nil, progress: download.progress, status: "Downloading"))
        active[ObjectIdentifier(download)] = index
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        do { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        catch { completionHandler(nil); return }
        let safeName = URL(fileURLWithPath: suggestedFilename).lastPathComponent
        let original = safeName.isEmpty ? "Download" : safeName
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
        if let index = active[ObjectIdentifier(download)] {
            entries[index].name = destination.lastPathComponent
            entries[index].url = destination
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let index = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if let path = entries[index].url?.path { reservedPaths.remove(path) }
        entries[index].progress = nil
        entries[index].status = "Finished"
        persistRecent()
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let index = active.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if let path = entries[index].url?.path { reservedPaths.remove(path) }
        entries[index].progress = nil
        entries[index].status = "Failed: \(error.localizedDescription)"
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
        NSWorkspace.shared.open(url)
    }

    @objc private func openFolder() {
        guard let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        NSWorkspace.shared.open(url)
    }
}
