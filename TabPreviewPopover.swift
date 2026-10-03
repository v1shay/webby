import AppKit

/// A lightweight preview of an existing tab. It never creates or loads a web view.
@MainActor final class TabPreviewPopover {
    private let popover = NSPopover()
    private let imageView = NSImageView()
    private let placeholder = NSTextField(labelWithString: "")
    private let title = NSTextField(labelWithString: "")
    private let address = NSTextField(labelWithString: "")
    private(set) var tabID: UUID?

    init() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 340, height: 240))
        root.material = .popover
        root.blendingMode = .withinWindow
        root.state = .active

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 7
        imageView.layer?.masksToBounds = true
        imageView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.alignment = .center
        placeholder.font = .systemFont(ofSize: 15, weight: .medium)
        placeholder.textColor = .secondaryLabelColor
        placeholder.lineBreakMode = .byTruncatingTail

        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        address.translatesAutoresizingMaskIntoConstraints = false
        address.font = .systemFont(ofSize: 11)
        address.textColor = .secondaryLabelColor
        address.lineBreakMode = .byTruncatingMiddle

        root.addSubview(imageView)
        root.addSubview(placeholder)
        root.addSubview(title)
        root.addSubview(address)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 9),
            imageView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -9),
            imageView.topAnchor.constraint(equalTo: root.topAnchor, constant: 9),
            imageView.heightAnchor.constraint(equalToConstant: 175),
            placeholder.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 16),
            placeholder.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -16),
            placeholder.centerYAnchor.constraint(equalTo: imageView.centerYAnchor),
            title.leadingAnchor.constraint(equalTo: imageView.leadingAnchor, constant: 3),
            title.trailingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: -3),
            title.topAnchor.constraint(equalTo: imageView.bottomAnchor, constant: 10),
            address.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            address.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            address.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3)
        ])

        let controller = NSViewController()
        controller.view = root
        popover.contentSize = root.frame.size
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.animates = true
    }

    func show(tabID: UUID, title: String, address: String, image: NSImage?, from row: NSView) {
        hide()
        self.tabID = tabID
        self.title.stringValue = title
        self.address.stringValue = address
        imageView.image = image
        placeholder.stringValue = title
        placeholder.isHidden = image != nil
        popover.show(relativeTo: row.bounds, of: row, preferredEdge: .maxX)
    }

    func updateImage(_ image: NSImage, for id: UUID) {
        guard tabID == id else { return }
        imageView.image = image
        placeholder.isHidden = true
    }

    func hide(for id: UUID? = nil) {
        guard id == nil || id == tabID else { return }
        popover.close()
        tabID = nil
    }
}
