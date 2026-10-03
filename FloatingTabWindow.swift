import AppKit

/// Hosts the existing tab view, so its WebKit data store and in-page state remain intact.
@MainActor final class FloatingTabWindow: NSWindow {
    let tabID: UUID
    let contentHost = NSView()
    let addressField = NSTextField()

    init(tabID: UUID, title: String, screen: NSScreen?) {
        self.tabID = tabID
        let available = screen?.visibleFrame ?? NSRect(x: 100, y: 100, width: 1200, height: 800)
        let width = min(550, max(340, available.width * 0.42))
        let height = min(430, max(260, available.height * 0.48))
        let rect = NSRect(x: available.maxX - width - 24,
                          y: available.maxY - height - 38,
                          width: width, height: height)
        super.init(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize = NSSize(width: 320, height: 220)
        titlebarAppearsTransparent = true

        let backdrop = NSVisualEffectView()
        backdrop.material = .hudWindow
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        let bar = NSVisualEffectView()
        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.translatesAutoresizingMaskIntoConstraints = false
        addressField.placeholderString = "Search Google or enter a URL"
        addressField.isBordered = false
        addressField.drawsBackground = false
        addressField.font = .systemFont(ofSize: 13)
        addressField.translatesAutoresizingMaskIntoConstraints = false
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = root
        root.addSubview(backdrop)
        root.addSubview(contentHost)
        root.addSubview(bar)
        bar.addSubview(addressField)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: root.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.topAnchor.constraint(equalTo: root.topAnchor),
            bar.heightAnchor.constraint(equalToConstant: 42),
            addressField.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            addressField.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            addressField.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            contentHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            contentHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            contentHost.topAnchor.constraint(equalTo: bar.bottomAnchor),
            contentHost.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
    }
}
